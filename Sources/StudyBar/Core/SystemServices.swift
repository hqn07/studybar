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

/// (4) Screenshot storage. Images now come in via drag-and-drop / paste (see the Notes
/// editor); this only vends the folder that older screenshot-notes still load from.
enum ScreenshotService {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar/Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
