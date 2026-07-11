import Foundation

/// Lock-protected boolean used as a "single flight" guard (CONCURRENCY = 1 semantics).
/// Sync methods keep NSLock usage out of async contexts (a Swift 6 error).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Sets the flag; returns false if it was already set.
    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        value = false
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
