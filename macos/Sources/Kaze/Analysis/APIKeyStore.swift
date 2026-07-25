import Foundation
import Security

/// Per-provider API key storage in the macOS Keychain. Resolution order when reading:
/// provider env var(s) → Keychain. Never logs the value.
enum APIKeyStore {
    private static let service = "\(K.bundleID).llm"

    /// `SecItemCopyMatching` is a synchronous XPC round-trip to securityd and can take
    /// seconds the first time after the app binary changes. It is read from SwiftUI bodies
    /// and from the analysis timer, both on the main actor, so the answer is memoized.
    /// Only this type writes these items, so it can invalidate its own cache; a key changed
    /// externally in Keychain Access is picked up on the next launch.
    private static let cacheLock = NSLock()
    private static var cache: [String: String?] = [:]

    static func key(for kind: LLMProviderKind) -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in kind.envVars {
            if let v = env[name], !v.isEmpty { return v }
        }
        let account = kind.keychainAccount

        cacheLock.lock()
        let cached = cache[account]
        cacheLock.unlock()
        if let cached { return cached }

        let value = readKeychain(account: account)
        cacheLock.lock()
        cache[account] = value
        cacheLock.unlock()
        return value
    }

    static func hasKey(for kind: LLMProviderKind) -> Bool { key(for: kind)?.isEmpty == false }

    static var hasAnyKey: Bool { LLMProviderKind.allCases.contains { hasKey(for: $0) } }

    static func save(_ key: String, for kind: LLMProviderKind) {
        let account = kind.keychainAccount
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
        cacheLock.lock()
        cache[account] = key
        cacheLock.unlock()
    }

    static func clear(for kind: LLMProviderKind) {
        let account = kind.keychainAccount
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        cacheLock.lock()
        cache[account] = String?.none
        cacheLock.unlock()
    }

    private static func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }
}
