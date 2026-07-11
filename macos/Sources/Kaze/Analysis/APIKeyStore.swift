import Foundation
import Security

/// Per-provider API key storage in the macOS Keychain. Resolution order when reading:
/// provider env var(s) → Keychain. Never logs the value.
enum APIKeyStore {
    private static let service = "\(K.bundleID).llm"

    static func key(for kind: LLMProviderKind) -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in kind.envVars {
            if let v = env[name], !v.isEmpty { return v }
        }
        return readKeychain(account: kind.keychainAccount)
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
    }

    static func clear(for kind: LLMProviderKind) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
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
