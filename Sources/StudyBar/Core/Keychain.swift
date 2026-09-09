import Foundation
import Security

/// Minimal Keychain wrapper for sensitive strings (e.g. the Canvas access token).
///
/// Reads are cached for the life of the process, which is a correctness fix rather than an
/// optimization: `AIConfig.isReady` calls `hasKey`, `isReady` is read from SwiftUI view
/// bodies, and every one of those was a Keychain hit. StudyBar is ad-hoc signed, so its code
/// signature changes with every build and every released update — macOS then treats the new
/// binary as a different app from the one that stored the item and asks for the login
/// keychain password. Per render. The cache makes it at most one prompt per launch.
enum Keychain {
    private static let service = "com.studybar.StudyBar"

    /// account -> value (nil = looked up, genuinely absent). Cleared on write.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func set(_ value: String, account: String) {
        delete(account: account)
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
        lock.lock(); cache[account] = value; lock.unlock()
    }

    static func get(account: String) -> String? {
        lock.lock()
        if let hit = cache[account] { lock.unlock(); return hit }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        let value = (status == errSecSuccess ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil)
        // Cache the miss too — an absent key is the common case, and re-asking for it is what
        // produced a dialog on every render.
        lock.lock(); cache[account] = value; lock.unlock()
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock(); cache[account] = String?.none; lock.unlock()
    }
}
