import AppKit

/// (24) Get the active tab URL + title from the frontmost supported browser via AppleScript.
enum BrowserURL {
    struct Tab { let title: String; let url: String }

    static func current() -> Tab? {
        for (app, script) in scripts {
            if isRunning(app), let tab = run(script) { return tab }
        }
        return nil
    }

    private static let scripts: [(String, String)] = [
        ("Safari", """
        tell application "Safari"
            set theURL to URL of front document
            set theTitle to name of front document
            return theTitle & "\\n" & theURL
        end tell
        """),
        ("Google Chrome", """
        tell application "Google Chrome"
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            return theTitle & "\\n" & theURL
        end tell
        """),
        ("Arc", """
        tell application "Arc"
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            return theTitle & "\\n" & theURL
        end tell
        """),
    ]

    private static func isRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    private static func run(_ source: String) -> Tab? {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let out = script.executeAndReturnError(&err)
        guard err == nil, let s = out.stringValue else { return nil }
        let parts = s.components(separatedBy: "\n")
        guard parts.count >= 2 else { return nil }
        return Tab(title: parts[0], url: parts[1])
    }
}

/// (4) Interactive screen capture to a PNG in Application Support/Screenshots.
enum ScreenshotService {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Interactive region capture. Hides StudyBar's windows first (so the popover
    /// isn't in the way / in the shot), runs async, restores them, then reports the
    /// filename (in `directory`) via `completion`, or nil if cancelled.
    @MainActor
    static func captureInteractive(completion: @escaping (String?) -> Void) {
        let windows = NSApp.windows.filter { $0.isVisible }
        windows.forEach { $0.alphaValue = 0 }

        let name = "shot-\(Int(Date().timeIntervalSince1970)).png"
        let url = directory.appendingPathComponent(name)

        // Let the alpha change take effect before the capture overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-i", url.path]
            proc.terminationHandler = { _ in
                DispatchQueue.main.async {
                    windows.forEach { $0.alphaValue = 1 }
                    completion(FileManager.default.fileExists(atPath: url.path) ? name : nil)
                }
            }
            do { try proc.run() }
            catch { windows.forEach { $0.alphaValue = 1 }; completion(nil) }
        }
    }
}
