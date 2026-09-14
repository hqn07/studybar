import Foundation
import Security

/// Minimal Keychain wrapper for sensitive strings (e.g. the Canvas access token).
///
/// Reads are cached for the life of the process, which is a correctness fix rather than an
/// optimization: `AIConfig.isReady` calls `hasKey`, `isReady` is read from SwiftUI view
/// bodies, and every one of those was a Keychain hit. StudyBar's code signature changes with
/// every released update — macOS then treats the new binary as a different app from the one
/// that stored the item, and asks for the login keychain password. Per render.
///
/// The cache alone was not enough, and a profile said so: the *first* read still happened
/// inside `NoteEditor.body`, and a first read after the signature changed sat in
/// `SecItemCopyMatching` for **3.6 seconds** with the main thread held — 80% of the main
/// thread's time in a 15-second sample, one contiguous call. The whole app was unusable
/// while a view asked whether an API key existed.
///
/// So presence is answered from the cache only (`has`), and the cache is warmed off the main
/// thread at launch. A view that asks early gets "no key yet" and is told to re-render when
/// the answer arrives — never a blocked main thread.
enum Keychain {
    /// Posted when a background warm changes what `has` would answer.
    static let didWarm = Notification.Name("StudyBarKeychainDidWarm")

    private static let service = "com.studybar.StudyBar"

    /// account -> value (nil = looked up, genuinely absent). Cleared on write.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    /// Accounts a background warm is already fetching, so a view asking every frame doesn't
    /// spawn a task every frame.
    nonisolated(unsafe) private static var warming: Set<String> = []

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

    /// Whether a non-empty value exists, answered **only** from the cache.
    ///
    /// Safe to call from a SwiftUI body: it never touches the Keychain. An unknown account
    /// answers `false` and schedules a warm, so the truth arrives a moment later with a
    /// `didWarm` notification rather than by freezing the UI to wait for it.
    static func has(account: String) -> Bool {
        lock.lock(); let known = cache[account]; lock.unlock()
        if let known { return known.map { !$0.isEmpty } ?? false }
        warm([account])
        return false
    }

    /// Populate the cache off the main thread. Call at launch for every account the UI asks
    /// about. Idempotent, and cheap once an account is cached.
    static func warm(_ accounts: [String]) {
        let cold = accounts.filter { a in
            lock.lock(); defer { lock.unlock() }
            return cache[a] == nil && !warming.contains(a)
        }
        guard !cold.isEmpty else { return }
        lock.lock(); warming.formUnion(cold); lock.unlock()
        Task.detached(priority: .utility) {
            var changed = false
            for a in cold where get(account: a) != nil { changed = true }
            lock.lock(); warming.subtract(cold); lock.unlock()
            if changed {
                await MainActor.run { NotificationCenter.default.post(name: didWarm, object: nil) }
            }
        }
    }

    /// Reads the Keychain, blocking. Never call this from a view body — see `has`.
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
