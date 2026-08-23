import Foundation

/// Runs a user-chosen macOS Shortcut when a focus session starts / ends. macOS has no
/// public API to toggle a Focus (DND) directly, so the user creates Shortcuts that set
/// their Focus and names them here — StudyBar invokes them via the `shortcuts` CLI.
@MainActor
enum FocusAutomation {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "focusAutomation") }
    static var startShortcut: String { UserDefaults.standard.string(forKey: "focusStartShortcut") ?? "" }
    static var endShortcut: String { UserDefaults.standard.string(forKey: "focusEndShortcut") ?? "" }

    static func focusBegan() { guard enabled else { return }; run(startShortcut) }
    static func focusEnded() { guard enabled else { return }; run(endShortcut) }

    private static func run(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", n]
        try? p.run()
    }
}
