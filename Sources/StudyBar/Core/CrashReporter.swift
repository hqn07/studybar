import Foundation
import AppKit

/// Detects an unexpected quit (crash or force-quit) between sessions and preserves breadcrumbs,
/// without fragile in-signal-handler work. A "session active" flag is set on launch and cleared
/// on a clean shutdown; if it's still set next launch, the previous session ended abnormally.
/// A rolling log file (fed by `Diagnostics`) provides the events leading up to it, and an
/// uncaught-exception handler records a reason when one is available.
enum CrashReporter {
    private static var appSupport: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var logURL: URL { appSupport.appendingPathComponent("diagnostics.log") }
    private static var detailURL: URL { appSupport.appendingPathComponent("crash-detail.txt") }
    private static let activeKey = "sessionActive"
    private static let ioQueue = DispatchQueue(label: "com.studybar.crashlog")

    /// Call ONCE on launch, before `markActive()`. Returns a report if the previous session
    /// ended unexpectedly, else nil. Consumes the crash-detail file.
    static func checkPreviousSession() -> String? {
        let abnormal = UserDefaults.standard.bool(forKey: activeKey)   // still set → never shut down clean
        let detail = try? String(contentsOf: detailURL, encoding: .utf8)
        try? FileManager.default.removeItem(at: detailURL)
        guard abnormal || (detail?.isEmpty == false) else { return nil }
        var report = "Previous session ended unexpectedly (a crash, force-quit, or power loss).\n"
        if let d = detail, !d.isEmpty { report += "\n\(d)\n" }
        report += "\n--- log before it ended ---\n" + logTail()
        return report
    }

    static func markActive() {
        UserDefaults.standard.set(true, forKey: activeKey)
        NSSetUncaughtExceptionHandler { ex in
            let t = "Uncaught exception: \(ex.name.rawValue)\n\(ex.reason ?? "")\n\n"
                + ex.callStackSymbols.prefix(30).joined(separator: "\n")
            try? t.write(to: CrashReporter.detailURL, atomically: true, encoding: .utf8)
        }
    }
    static func markCleanShutdown() { UserDefaults.standard.set(false, forKey: activeKey) }

    /// Append one line to the rolling log (off the caller's thread), rotating when it gets large.
    static func appendLog(_ line: String) {
        ioQueue.async {
            let url = logURL
            guard let d = (line + "\n").data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                try? h.seekToEnd(); try? h.write(contentsOf: d); try? h.close()
            } else { try? d.write(to: url) }
            if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, sz > 1_000_000 {
                if let all = try? Data(contentsOf: url) { try? all.suffix(400_000).write(to: url) }
            }
        }
    }

    static func logTail(_ maxBytes: Int = 15_000) -> String {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return "(no recent log)" }
        return String(data: data.suffix(maxBytes), encoding: .utf8) ?? "(unreadable)"
    }
}
