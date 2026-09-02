import Foundation
import os
import AVFoundation
import Speech

/// Local, privacy-safe diagnostics for development and bug reports. Events go to the unified
/// log (visible in Console.app) immediately and into an in-memory ring buffer the Diagnostics
/// panel shows and exports. Nothing is sent anywhere; export is user-initiated and redacted
/// (only counts, metadata and technical events — never note bodies or transcripts).
enum DiagCategory: String, CaseIterable, Identifiable {
    case app, data, ai, voice, schedule, sync, net, ui
    var id: String { rawValue }
    var label: String { rawValue == "ai" ? "AI" : rawValue.capitalized }
    fileprivate var logger: Logger { Logger(subsystem: "com.studybar.StudyBar", category: rawValue) }
}

enum DiagLevel: Int, Comparable, CaseIterable, Identifiable {
    case debug = 0, info, warn, error
    var id: Int { rawValue }
    static func < (a: DiagLevel, b: DiagLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["Debug", "Info", "Warn", "Error"][rawValue] }
    var symbol: String { ["ladybug", "info.circle", "exclamationmark.triangle.fill", "xmark.octagon.fill"][rawValue] }
    fileprivate var osType: OSLogType { [.debug, .info, .default, .error][rawValue] }
}

struct DiagEvent: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let category: DiagCategory
    let level: DiagLevel
    let message: String
}

enum HealthStatus { case pass, warn, fail
    var mark: String { switch self { case .pass: "✓"; case .warn: "!"; case .fail: "✗" } }
    var symbol: String { switch self { case .pass: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .fail: "xmark.octagon.fill" } }
}
struct HealthCheck: Identifiable { let id = UUID(); let name: String; let status: HealthStatus; let detail: String }

@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    @Published private(set) var events: [DiagEvent] = []
    /// Set on launch when the previous session ended unexpectedly (crash / force-quit).
    @Published var lastCrash: String?
    private let cap = 1000
    private var verbose: Bool { UserDefaults.standard.bool(forKey: "diagVerbose") }

    /// Thread-safe log entry: writes to the unified log immediately (thread-safe), appends to
    /// the rolling crash-breadcrumb file, and buffers for the panel/export on the main actor.
    nonisolated static func log(_ c: DiagCategory, _ l: DiagLevel, _ m: String) {
        c.logger.log(level: l.osType, "\(m, privacy: .public)")
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        CrashReporter.appendLog("\(f.string(from: Date())) [\(c.rawValue)/\(l.label)] \(redact(m))")
        Task { @MainActor in
            if l == .debug && !shared.verbose { return }
            shared.push(DiagEvent(date: Date(), category: c, level: l, message: m))
        }
    }
    nonisolated static func info(_ c: DiagCategory, _ m: String)  { log(c, .info, m) }
    nonisolated static func warn(_ c: DiagCategory, _ m: String)  { log(c, .warn, m) }
    nonisolated static func error(_ c: DiagCategory, _ m: String) { log(c, .error, m) }
    nonisolated static func debug(_ c: DiagCategory, _ m: String) { log(c, .debug, m) }

    private func push(_ e: DiagEvent) {
        events.append(e)
        if events.count > cap { events.removeFirst(events.count - cap) }
    }
    func clear() { events.removeAll() }

    // MARK: - Environment + report

    nonisolated static func redact(_ s: String) -> String { s.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    static func environment(_ data: AppData?) -> [(String, String)] {
        var rows: [(String, String)] = []
        let b = Bundle.main.infoDictionary
        rows.append(("App", "StudyBar \(b?["CFBundleShortVersionString"] as? String ?? "?") (\(b?["CFBundleVersion"] as? String ?? "?"))"))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        rows.append(("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        let engine = AIConfig.mode.rawValue + (AIConfig.mode == .ollama ? " · \(AIConfig.ollamaModel)" : "")
        rows.append(("AI engine", "\(engine) · ready: \(AIConfig.isReady ? "yes" : "no")"))
        let models = VoiceService.downloadedModels()
        rows.append(("Whisper models", models.isEmpty ? "none" : models.joined(separator: ", ")))
        let iCloud = UserDefaults.standard.bool(forKey: "iCloudSync")
        rows.append(("iCloud sync", iCloud ? "on" : "off"))
        let path = AppState.dataURL(iCloud: iCloud)
        rows.append(("Data path", redact(path.path)))
        if let sz = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? Int {
            rows.append(("Store size", ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file)))
        }
        if let d = data {
            rows.append(("Records", "courses \(d.courses.count) · assignments \(d.assignments.count) · notes \(d.notes.count) · classes \(d.classes.count) · cards \(d.flashcards.count) · sessions \(d.timeEntries.count)"))
        }
        return rows
    }

    /// A redacted plain-text report for the maintainer — environment, health, recent events.
    static func report(_ data: AppData?, health: [HealthCheck]) -> String {
        var out = "StudyBar Diagnostics — \(Date().formatted(date: .abbreviated, time: .standard))\n\n## Environment\n"
        for (k, v) in environment(data) { out += "- \(k): \(v)\n" }
        if let crash = shared.lastCrash { out += "\n## Previous session crash\n\(crash)\n" }
        if !health.isEmpty {
            out += "\n## Health\n"
            for h in health { out += "- [\(h.status.mark)] \(h.name): \(h.detail)\n" }
        }
        let recent = shared.events.suffix(200)
        out += "\n## Recent events (\(recent.count))\n"
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        for e in recent {
            out += "\(f.string(from: e.date)) [\(e.category.rawValue)/\(e.level.label)] \(redact(e.message))\n"
        }
        if recent.isEmpty { out += "(none yet)\n" }
        return out
    }

    // MARK: - Health checks (self-test)

    static func runHealthChecks(_ state: AppState) async -> [HealthCheck] {
        var out: [HealthCheck] = []

        let d = state.data
        let empty = d.courses.isEmpty && d.notes.isEmpty && d.assignments.isEmpty
        out.append(HealthCheck(name: "Data store", status: empty ? .warn : .pass,
                               detail: empty ? "empty — no courses, notes or assignments" : "\(d.courses.count) courses · \(d.assignments.count) assignments · \(d.notes.count) notes"))

        out.append(HealthCheck(name: "Store writable", status: state.dataSaveBlocked ? .fail : .pass,
                               detail: state.dataSaveBlocked ? "READ-ONLY — a data file couldn't be read; saves are blocked to protect it" : "writable"))

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        out.append(HealthCheck(name: "Microphone", status: mic == .authorized ? .pass : (mic == .notDetermined ? .warn : .fail),
                               detail: authLabel(mic.rawValue, kind: .capture)))

        let sp = SFSpeechRecognizer.authorizationStatus()
        out.append(HealthCheck(name: "Speech recognition", status: sp == .authorized ? .pass : (sp == .notDetermined ? .warn : .fail),
                               detail: authLabel(sp.rawValue, kind: .speech)))

        let models = VoiceService.downloadedModels()
        out.append(HealthCheck(name: "Whisper models", status: models.isEmpty ? .warn : .pass,
                               detail: models.isEmpty ? "none downloaded (Apple Speech still works)" : models.joined(separator: ", ")))

        if AIConfig.mode == .ollama {
            let ok = await ollamaReachable()
            out.append(HealthCheck(name: "Ollama", status: ok ? .pass : .fail,
                                   detail: ok ? "reachable at \(AIConfig.ollamaHost)" : "not reachable at \(AIConfig.ollamaHost) — is `ollama serve` running?"))
        }

        if let free = freeDiskBytes() {
            let low = free < 1_000_000_000
            out.append(HealthCheck(name: "Disk space", status: low ? .warn : .pass,
                                   detail: ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free" + (low ? " — low" : "")))
        }
        return out
    }

    private static func ollamaReachable() async -> Bool {
        guard let url = URL(string: AIConfig.ollamaHost) else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: req)) != nil
    }
    private static func freeDiskBytes() -> Int64? {
        let u = URL(fileURLWithPath: NSHomeDirectory())
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    private enum AuthKind { case capture, speech }
    private static func authLabel(_ raw: Int, kind: AuthKind) -> String {
        switch kind {
        case .capture:
            switch raw { case 3: return "granted"; case 0: return "not requested yet"; default: return "denied — grant in System Settings ▸ Privacy" }
        case .speech:
            switch raw { case 3: return "granted"; case 0: return "not requested yet"; default: return "denied — grant in System Settings ▸ Privacy" }
        }
    }
}
