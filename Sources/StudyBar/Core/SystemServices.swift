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

/// Grab a region of the screen — a Zoom slide, a figure on a web page, a problem in a PDF — and
/// turn it into something to study with. Apple's own `screencapture -i` draws the selection
/// (Esc cancels); a menu at the pointer then says what to do with it.
@MainActor
enum ScreenGrab {
    static func start() {
        Task {
            guard let img = await capture() else { return }
            choose(img)
        }
    }

    static func capture() async -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("studybar-grab-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }
            if (try? p.run()) == nil { p.terminationHandler = nil; c.resume() }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }   // no file: cancelled
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func choose(_ img: CGImage) {
        let state = AppState.current
        let engine = AIConfig.engine(for: .ask)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(GrabItem("Copy Text") { copyText(img) })
        menu.addItem(GrabItem(AIConfig.canSee(engine) ? "Copy Math as LaTeX" : "Copy Math as LaTeX — needs an engine that reads images",
                              enabled: AIConfig.canSee(engine)) { copyLatex(img) })
        menu.addItem(GrabItem("Ask the Tutor", enabled: AIConfig.isReady(for: .ask) && state?.data.courses.isEmpty == false) { askTutor(img) })
        menu.addItem(GrabItem("Make Image Cards…") {
            state?.pendingImageCards = ImageCardsRequest(image: img)
            AppActions.open(module: "flashcards")
        })
        menu.addItem(.separator())
        menu.addItem(GrabItem("Copy Image") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: img, size: .zero)])
        })
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func copyText(_ img: CGImage) {
        Task {
            let text = await Task.detached { StudyMaterial.ocr(img) }.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { Notifier.post(title: "No text found", body: "Nothing readable in that part of the screen."); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Notifier.post(title: "Text copied", body: String(text.prefix(120)))
        }
    }

    static let latexSystem = """
    Transcribe the mathematics in the image as LaTeX. Reply with the LaTeX only: no $ or \\[ delimiters, \
    no code fence, no explanation. Separate expressions go one per line.
    """

    private static func copyLatex(_ img: CGImage) {
        guard let provider = AIService.makeProvider(for: .ask), let jpeg = TutorPane.jpeg(NSImage(cgImage: img, size: .zero)) else { return }
        Task {
            let out = try? await provider.completePlain(system: latexSystem, messages: [
                AIMessage(role: .user, text: "Transcribe the math in this image as LaTeX.", images: [jpeg])])
            let tex = bareLatex(out ?? "")
            guard !tex.isEmpty else { Notifier.post(title: "Couldn't read the math", body: "Try a tighter selection, or another engine."); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tex, forType: .string)
            Notifier.post(title: "LaTeX copied", body: String(tex.prefix(120)))
        }
    }

    /// The expression without the fences and delimiters models add despite being asked not to.
    static func bareLatex(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") { t = t.split(separator: "\n").filter { !$0.hasPrefix("```") }.joined(separator: "\n") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        where t.count > open.count + close.count && t.hasPrefix(open) && t.hasSuffix(close) {
            t = String(t.dropFirst(open.count).dropLast(close.count)); break
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Into the tutor of the class in session, else the course Study has open.
    private static func askTutor(_ img: CGImage) {
        guard let state = AppState.current, let jpeg = TutorPane.jpeg(NSImage(cgImage: img, size: .zero)) else { return }
        let picked = state.data.courses.first { $0.id.uuidString == UserDefaults.standard.string(forKey: "studyCourse") }
        guard let course = state.currentCourseID ?? picked?.id ?? state.data.courses.first?.id else { return }
        UserDefaults.standard.set(course.uuidString, forKey: "studyCourse")
        state.studySession(course).tutor.images.append(jpeg)
        AppActions.open(module: "study")
    }
}

/// A menu item that runs a closure — NSMenu wants a target and a selector.
private final class GrabItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}
