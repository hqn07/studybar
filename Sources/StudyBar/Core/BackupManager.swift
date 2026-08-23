import AppKit

/// Timestamped JSON backups to a user-chosen folder. Optional daily auto-backup on launch.
enum BackupManager {
    private static let folderKey = "backupFolder"
    private static let autoKey = "backupAuto"
    private static let lastKey = "backupLast"

    static var auto: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
    static var last: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }

    static var folderName: String? { resolveFolder()?.lastPathComponent }
    static var hasFolder: Bool { UserDefaults.standard.data(forKey: folderKey) != nil }

    @MainActor static func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Choose Backup Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let data = (try? url.bookmarkData(options: .withSecurityScope)) ?? (try? url.bookmarkData()) ?? Data()
        UserDefaults.standard.set(data, forKey: folderKey)
        return true
    }

    @discardableResult
    static func backupNow(_ data: AppData) -> Bool {
        guard let dir = resolveFolder() else { return false }
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "studybar-backup-\(df.string(from: .now)).json"
        guard let raw = try? JSONEncoder.studybar.encode(data) else { return false }
        do {
            try raw.write(to: dir.appendingPathComponent(name), options: .atomic)
            UserDefaults.standard.set(Date(), forKey: lastKey)
            pruneOld(in: dir)
            return true
        } catch { return false }
    }

    static func maybeAuto(_ data: AppData) {
        guard auto, hasFolder else { return }
        if let l = last, Date().timeIntervalSince(l) < 20 * 3600 { return }
        _ = backupNow(data)
    }

    private static func resolveFolder() -> URL? {
        guard let bm = UserDefaults.standard.data(forKey: folderKey) else { return nil }
        var stale = false
        return (try? URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale))
    }

    /// Keep only the newest 10 backups.
    private static func pruneOld(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("studybar-backup-") }) else { return }
        let sorted = files.sorted { (mod($0) ?? .distantPast) > (mod($1) ?? .distantPast) }
        for f in sorted.dropFirst(10) { try? FileManager.default.removeItem(at: f) }
    }
    private static func mod(_ u: URL) -> Date? {
        try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
