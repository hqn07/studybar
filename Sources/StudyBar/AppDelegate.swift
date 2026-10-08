import AppKit
import SwiftUI
import Combine
import CoreSpotlight

/// Owns the menu-bar status item (left-click popover, right-click menu) and the detached window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// When the menu-bar item was last clicked — so the reopen handler can tell a
    /// status-item interaction (show the popover) from a real app-icon click (show the window).
    private var lastStatusClickAt = Date.distantPast
    private var timer: Timer?
    private var feedTimer: Timer?

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { URLRouter.handle(u) }
    }

    /// Clicking the app (Finder / Launchpad / Dock) while it's already running — which a
    /// menu-bar app always is — sends a reopen event. Without this, nothing happened and
    /// the window was only reachable from the menu bar. Open the window on reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the menu-bar item activates the app, which also fires reopen — don't
        // treat that as an app-icon click, or the window pops up over the popover.
        if Date().timeIntervalSince(lastStatusClickAt) < 0.8 { return true }
        if !flag { showWindow() }
        return true
    }

    /// Custom URL schemes (studybar://) are delivered as a `kAEGetURL` Apple Event, not
    /// through `application(_:open:)` — register a handler so links work whether the app
    /// is already running or cold-launched.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C),   // 'GURL'
            andEventID: AEEventID(0x4755524C))          // 'GURL'
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue,   // '----' keyDirectObject
              let url = URL(string: s) else { return }
        URLRouter.handle(url)
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        if userActivity.activityType == CSSearchableItemActionType,
           let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
            SpotlightIndexer.open(id)
            return true
        }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless self-test hook: `StudyBar --merge-selftest` runs the 3-way merge
        // suite and exits, without touching the menu bar or the user's data file.
        if CommandLine.arguments.contains("--history-selftest") {
            exit(NoteHistorySelfTest.run())
        }
        if CommandLine.arguments.contains("--merge-selftest") {
            exit(MergeSelfTest.run())
        }
        if CommandLine.arguments.contains("--decode-selftest") {
            exit(DecodeSelfTest.run())
        }
        if CommandLine.arguments.contains("--vad-selftest") {
            exit(VADSelfTest.run())
        }
        if CommandLine.arguments.contains("--ai-smoke") {
            let verbose = CommandLine.arguments.contains("--ai-smoke-verbose")
            Task { @MainActor in exit(await AISmokeTest.run(verbose: verbose)) }
            return
        }
        if CommandLine.arguments.contains("--dup-selftest") {
            exit(DupSelfTest.run())
        }
        if CommandLine.arguments.contains("--triage-selftest") {
            exit(TriageSelfTest.run())
        }
        if CommandLine.arguments.contains("--quote-selftest") {
            exit(QuoteSelfTest.run())
        }
        if CommandLine.arguments.contains("--noteqa-selftest") {
            exit(NoteQASelfTest.run())
        }
        if CommandLine.arguments.contains("--week-selftest") {
            exit(WeekSelfTest.run())
        }
        if CommandLine.arguments.contains("--perf-notes") {
            exit(PerfProbe.run(state: state))
        }
        if CommandLine.arguments.contains("--title-selftest") {
            exit(NoteTitleSelfTest.run())
        }
        if CommandLine.arguments.contains("--palette-selftest") {
            exit(PaletteSearchSelfTest.run())
        }
        if CommandLine.arguments.contains("--math-selftest") {
            exit(MathSelfTest.run())
        }
        if CommandLine.arguments.contains("--course-selftest") {
            exit(CourseMathSelfTest.run())
        }
        if CommandLine.arguments.contains("--graph-selftest") {
            exit(GraphSelfTest.run())
        }
        if CommandLine.arguments.contains("--calc-selftest") {
            exit(MathEvalSelfTest.run())
        }
        if CommandLine.arguments.contains("--format-selftest") {
            exit(NoteFormatSelfTest.run())
        }
        if CommandLine.arguments.contains("--cite-selftest") {
            exit(CitationSelfTest.run())
        }
        if CommandLine.arguments.contains("--canvas-selftest") {
            Task { @MainActor in exit(await CanvasSelfTest.run(state: state)) }
            return
        }
        // `StudyBar --lecture-run <transcript.txt> [--complete] [--engine ollama|claude|openai]`:
        // the real notes job on a real engine, printed — to read what a prompt change does.
        if let i = CommandLine.arguments.firstIndex(of: "--lecture-run"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            let mode = args.firstIndex(of: "--engine").flatMap { $0 + 1 < args.count ? AIMode(rawValue: args[$0 + 1]) : nil } ?? .ollama
            Task { @MainActor in
                guard let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8),
                      let provider = AIService.makeProvider(mode: mode) else { print("no input or engine"); exit(1) }
                let t0 = Date()
                // `--slides <deck.pdf|pptx>`: the deck the lecture was given from.
                let slides = args.firstIndex(of: "--slides").map { StudyMaterial.extract(URL(fileURLWithPath: args[$0 + 1])) }?
                    .compactMap { u in Int(u.locator.filter(\.isNumber)).map { (number: $0, text: u.text) } } ?? []
                // `--detail brief|standard|full --shape notes|outline|cornell|qa --fill none|light|thorough --focus "…"`
                func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
                var style = LectureNotes.Style()
                if let v = opt("--detail") { style.detail = LectureNotes.Style.Detail.allCases.first { $0.rawValue.lowercased() == v } ?? style.detail }
                if let v = opt("--shape") { style.shape = LectureNotes.Style.Shape.allCases.first { $0.rawValue.lowercased().replacingOccurrences(of: "&", with: "") == v } ?? style.shape }
                if let v = opt("--fill") { style.fillIn = LectureNotes.Style.FillIn.allCases.first { $0.rawValue.lowercased() == v } ?? style.fillIn }
                style.focus = opt("--focus") ?? ""
                let out = await LectureNotes.run(text, job: args.contains("--complete") ? .complete : .lecture,
                                                 provider: provider, mode: mode, slides: slides, style: style) { _, part, total in
                    FileHandle.standardError.write("\rpart \(part)/\(total)".data(using: .utf8)!)
                }
                print("\n--- \(Int(Date().timeIntervalSince(t0)))s ---\n" + (out ?? "FAILED"))
                exit(out == nil ? 1 : 0)
            }
            return
        }
        // `StudyBar --convert-run <file|https://…> <target>`: one real conversion, for the routes the
        // self-test can't take (Pages, Keynote, Numbers need the user's Automation permission; a
        // real web page). A web page's result stays beside it, not in Downloads.
        if let i = CommandLine.arguments.firstIndex(of: "--convert-run"), i + 2 < CommandLine.arguments.count,
           let t = Converter.Target(rawValue: CommandLine.arguments[i + 2]) {
            let arg = CommandLine.arguments[i + 1], web = arg.hasPrefix("http") ? URL(string: arg) : nil
            Task { @MainActor in
                do {
                    let src = web == nil ? URL(fileURLWithPath: arg) : try await WebPage.fetch(web!)
                    print(try await Converter.convert(src, to: t, in: web == nil ? nil : WebPage.dir).map(\.path)); exit(0)
                } catch { print("FAILED: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--convert-selftest") {
            Task { @MainActor in exit(await ConvertSelfTest.run()) }
            return
        }
        if CommandLine.arguments.contains("--stt-bench") {
            Task { @MainActor in exit(await SpeechBench.run(CommandLine.arguments)) }
            return
        }
        if CommandLine.arguments.contains("--eval") {
            Task { @MainActor in exit(await AppEval.run(CommandLine.arguments)) }
            return
        }
        if CommandLine.arguments.contains("--study-run") {
            Task { @MainActor in exit(await StudyRun.run(CommandLine.arguments)) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--study-snapshot"), i + 1 < CommandLine.arguments.count {
            exit(StudySnapshot.run(state: state, out: CommandLine.arguments[i + 1]))
        }
        if CommandLine.arguments.contains("--design-selftest") {
            exit(DesignSelfTest.run())
        }
        // `scripts/module-audit.sh` runs this from a test copy: every module, rendered.
        if let i = CommandLine.arguments.firstIndex(of: "--module-audit"), i + 1 < CommandLine.arguments.count {
            exit(ModuleAudit.run(state: state, out: CommandLine.arguments[i + 1]))
        }
        if CommandLine.arguments.contains("--study-selftest") {
            exit(StudySelfTest.run())
        }
        if CommandLine.arguments.contains("--lecture-selftest") {
            exit(LectureNotesSelfTest.run())
        }
        if CommandLine.arguments.contains("--take-selftest") {
            Task { @MainActor in exit(await VoiceTakeSelfTest.run()) }
            return
        }
        if CommandLine.arguments.contains("--imagecards-selftest") {
            Task { @MainActor in exit(await ImageCardsSelfTest.run()) }
            return
        }
        if CommandLine.arguments.contains("--pdf-selftest") {
            Task { @MainActor in exit(await PDFSelfTest.run()) }
            return
        }
        if CommandLine.arguments.contains("--search-selftest") {
            exit(SearchSelfTest.run())
        }
        if CommandLine.arguments.contains("--ai-selftest") {
            exit(AIToolSelfTest.run())
        }
        if CommandLine.arguments.contains("--calendar-dedup-test") {
            exit(CalendarDedupTest.run())
        }
        if CommandLine.arguments.contains("--timeblock-selftest") {
            exit(TimeBlockSelfTest.run())
        }
        if CommandLine.arguments.contains("--ollama-stream-test") {
            Task { exit(await OllamaStreamTest.run()) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ai-ask"), i + 1 < CommandLine.arguments.count {
            let q = CommandLine.arguments[i + 1]
            Task { exit(await AIAskTest.run(q, state: state)) }
            return
        }
        if CommandLine.arguments.contains("--ai-plan") {
            Task { exit(await AIPlanTest.run(state: state)) }
            return
        }
        // Dev hook: `--seed-sample` fills an empty throwaway store (STUDYBAR_DATA_DIR only) with a
        // course, notes and an assignment, for driving the UI without touching real data.
        if CommandLine.arguments.contains("--seed-sample"),
           ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] != nil,
           !state.data.courses.contains(where: { $0.code == "PHY2049" }) {   // a fresh store already has "Getting Started"
            let c = Course(name: "Physics II", code: "PHY2049")
            state.data.courses.append(c)
            state.data.notes += [
                Note(title: "Week 3 — Gauss's Law", body: "## Flux\n- **Electric flux** — $\\Phi_E = EA\\cos\\theta$\n- Charges outside a closed surface add no net flux.\n\n## Gauss's law\n$$\\oint \\vec E\\cdot d\\vec A = \\frac{Q_{enc}}{\\varepsilon_0}$$\n- Useful only with spherical, cylindrical or planar symmetry.", courseID: c.id),
                Note(title: "Week 4 — Electric potential", body: "## Potential\n- $V = kq/r$ for a point charge\n- $E = -dV/dx$", courseID: c.id),
            ]
            state.data.assignments += [Assignment(title: "Problem Set 5", courseID: c.id, due: Date().addingTimeInterval(4 * 86_400),
                                                 notes: "Chapter 24, problems 12–20. Problem 18: coaxial cable, a line charge inside a cylindrical shell.")]
            // A lecture's study notes as they're now written — formulas, what was announced — with
            // cards made from it and some quiz answers, so Progress, Deadlines and cards have something to show.
            let lecture = Note(title: "Week 5 — Capacitors", body: "# Capacitors\n## Capacitance\n- **Capacitance** $C = Q/V$, measured in **farads**\n- Parallel plates: $C = \\varepsilon_0 A/d$\n## Energy\n- $U = \\tfrac12 CV^2$\n## Review\n### Formulas\n- $C = Q/V$ — charge per volt\n- $U = \\tfrac12 CV^2$ — stored energy\n### Announced\n- Problem set 6 — due next Friday\n- Read sections 26.3–26.4 — before Monday\n- Quiz 3 — October 16", courseID: c.id)
            state.data.notes.append(lecture)
            let deck = Deck(name: "PHY2049", courseID: c.id)
            state.data.decks.append(deck)
            state.data.flashcards += [("Unit of capacitance?", "The farad"), ("Energy stored in a capacitor?", "U = ½CV²"), ("Gauss's law relates…", "Flux through a closed surface to the charge inside")].map {
                var f = Flashcard(deckID: deck.id, front: $0.0, back: $0.1); f.source = CardSource(noteID: lecture.id); f.due = Date().addingTimeInterval(-3_600); return f
            }
            state.data.topicResults = [("Capacitance", [true, false, false]), ("Gauss's law", [true, true, true, false])]
                .flatMap { t, oks in oks.map { TopicResult(courseID: c.id, topic: t, correct: $0) } }
            state.saveNow()
        }
        // Test/dev hook: SB_DOCK=1 promotes StudyBar to a regular Dock app so UI-automation
        // tools (which can't target an LSUIElement accessory app) can drive the window.
        // No effect on normal launches — 1.0 stays a pure menu-bar app.
        if ProcessInfo.processInfo.environment["SB_DOCK"] == "1"
            || UserDefaults.standard.bool(forKey: "showDock") {
            NSApp.setActivationPolicy(.regular)
        }
        // Warm the Keychain off the main thread before any view asks. `AIConfig.isReady` is read
        // from view bodies, and a cold read there blocked the main thread for 3.6 seconds in a
        // profile — a signature change (every update) makes macOS re-evaluate the item's access.
        Keychain.warm(AIConfig.keyAccounts + [CanvasService.tokenAccount])
        applyAppearanceSetting()
        if let crash = CrashReporter.checkPreviousSession() {
            Diagnostics.shared.lastCrash = crash
            Diagnostics.warn(.app, "Recovered from an unexpected quit in the previous session")
        }
        CrashReporter.markActive()
        Diagnostics.info(.app, "Launched StudyBar \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Notifier.requestAuthorization()
        Notifier.rescheduleAll(state.data)   // class + assignment reminders from current data
        DownloadWatch.sync()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: RootView(surface: .popover).environmentObject(state))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "StudyBar")
            button.imagePosition = .imageLeading
            button.action = #selector(statusClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // Drop anything on the menu-bar icon to park it on the Shelf. The status item's window
        // forwards dragging messages to its delegate; its button can't be subclassed.
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.statusItem.button?.window else { return }
            w.registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png])
            w.delegate = self
        }

        WindowManager.shared.configure(state: state)
        WindowOpener.open = { [weak self] _ in self?.showWindow() }
        // Popover → window hand-off: only acts while the popover is the active surface,
        // so selecting a module inside the popover opens it in the roomy window and
        // dismisses the popover; navigation inside the window is left untouched.
        WindowOpener.routeToWindow = { [weak self] id in
            guard let self, self.popover.isShown else { return }
            self.state.selectedModuleID = id
            self.popover.performClose(nil)
            self.showWindow()
        }
        PopoverSizing.apply = { [weak self] size in
            guard let self else { return }
            let clamped = PopoverSizing.clamp(size)
            self.popover.contentSize = clamped
            UserDefaults.standard.set(NSStringFromSize(clamped), forKey: PopoverSizing.key)
        }
        PopoverSizing.current = { [weak self] in self?.popover.contentSize ?? .zero }
        // Global hotkeys belong to the app, not to a window. They used to be registered from
        // RootView.onAppearSetup, so a menu-bar app that had not yet been asked to show its
        // window or popover had none of them — ⌃⌥N did nothing until you opened StudyBar,
        // which is the one moment you do not need a shortcut for opening StudyBar.
        GlobalShortcuts.configure()
        if UserDefaults.standard.bool(forKey: "globalHotkey") { HotKeyManager.shared.register() }

        installMainMenu()
        SpotlightIndexer.reindex(state.data)
        refreshStatus()
        // Pull assignment due dates from subscribed Canvas/LMS calendar feeds (no API/token):
        // once on launch, then every 30 min while running.
        refreshFeeds()
        feedTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.refreshFeeds()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    /// ⌘Q mid-lecture used to end the recording with no word. Ask first; on Quit, close the
    /// audio properly so what was recorded can still be played.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let voice = state.voice
        guard voice.isActive || voice.status == .transcribing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = voice.isRecording ? "A recording is in progress" : voice.isPaused ? "A recording is paused" : "A recording is still being transcribed"
        alert.informativeText = "Quitting now stops it. The audio and the transcript so far are kept — Voice Note offers them back next time."
        alert.addButton(withTitle: voice.isPaused ? "Keep It" : "Keep Recording")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        voice.stopForQuit()
        // The take becomes an M4A in well under a second; quit once it has.
        Task { @MainActor in await voice.takeReady(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.info(.app, "Clean shutdown")
        CrashReporter.markCleanShutdown()
    }

    // MARK: Status item

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        lastStatusClickAt = Date()
        if NSApp.currentEvent?.type == .rightMouseUp {
            showRightMenu()
        } else if UserDefaults.standard.string(forKey: "menuBarClick") == "window" {
            openOrToggleWindow()
        } else {
            togglePopover()
        }
    }

    /// "Menu bar opens the window" mode: click fronts the main window (creating it if
    /// needed), click again while it's the key window hides it — the popover's toggle feel,
    /// but on the workspace. Right-click still opens the quick-actions menu either way.
    private func openOrToggleWindow() {
        if popover.isShown { popover.performClose(nil) }
        if let w = WindowManager.shared.frontWindow, w.isVisible, w.isKeyWindow {
            for w in WindowManager.shared.windows where w.isVisible { w.orderOut(nil) }
        } else {
            showWindow()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // A size the user dragged the popover to wins over the preset.
            let preset = (PopoverSize(rawValue: UserDefaults.standard.string(forKey: "popoverSize") ?? "") ?? .medium).dimensions
            popover.contentSize = PopoverSizing.custom ?? preset
            // Activating the app for the popover's text fields would drag the workspace
            // window in front of whatever the student is doing — hide it first so the
            // menu bar shows only the popover. Reopen the window explicitly (click the
            // app icon, or a launcher item) to bring it back.
            for w in WindowManager.shared.windows where w.isVisible { w.orderOut(nil) }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make the popover key so its text fields accept keyboard input.
            DispatchQueue.main.async { [weak self] in
                self?.popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func showRightMenu() {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self; m.addItem(item)
        }
        add("New Task…  ⌃⌥T", #selector(newTask))
        add("New Note…  ⌃⌥N", #selector(newNote))
        add("Capture from Screen…  \(HotKeyStore.display(HotKeyStore.binding(.capture)))", #selector(captureScreen))
        let rec = HotKeyStore.display(HotKeyStore.binding(.record))
        switch state.voice.status {
        case .recording:
            add("Pause Recording  \(rec)", #selector(toggleRecording))
            add("Stop Recording", #selector(stopRecording))
            add("Star This Moment  \(HotKeyStore.display(HotKeyStore.binding(.star)))", #selector(starMoment))
        case .paused:
            add("Resume Recording  \(rec)", #selector(toggleRecording))
            add("Stop Recording", #selector(stopRecording))
        case .preparing, .transcribing: break
        default:
            add("Start Recording  \(rec)", #selector(toggleRecording))
        }
        add(state.pomodoro.running ? "Pause Pomodoro" : "Start Pomodoro", #selector(togglePomodoro))
        let due = state.data.flashcards.filter(\.isDue).count
        if due > 0 { add("Review \(due) Due Card\(due == 1 ? "" : "s")…", #selector(reviewCards)) }
        m.addItem(.separator())
        add("Open StudyBar", #selector(openMain))
        add(ShelfPanel.shared?.isVisible == true ? "Hide Shelf" : "Show Shelf", #selector(toggleShelf))
        add("Settings…", #selector(openSettings))
        m.addItem(.separator())
        add("Quit StudyBar", #selector(quit))

        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Menu-bar accessory apps ship no menu bar, so standard editing shortcuts
    /// (⌘Z/⌘⇧Z undo-redo, ⌘X/C/V, ⌘A) have no key equivalent and silently do
    /// nothing in text fields. Install a minimal main menu so they route to the
    /// first responder. Purely editing actions — nothing here touches stored data.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit StudyBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // Text from a web page or PDF without its fonts and colors; NSTextView implements it.
        let plain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())

        // Find, routed to the text view's find bar (RichTextEditor sets usesFindBar). The tags
        // are NSTextFinder.Action raw values — that is how the responder knows which one.
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        func finder(_ title: String, _ key: String, _ tag: Int, _ mods: NSEvent.ModifierFlags = .command) {
            let item = find.addItem(withTitle: title, action: Selector(("performTextFinderAction:")),
                                    keyEquivalent: key)
            item.tag = tag
            item.keyEquivalentModifierMask = mods
        }
        finder("Find…", "f", NSTextFinder.Action.showFindInterface.rawValue)
        finder("Find Next", "g", NSTextFinder.Action.nextMatch.rawValue)
        finder("Find Previous", "g", NSTextFinder.Action.previousMatch.rawValue, [.command, .shift])
        finder("Use Selection for Find", "e", NSTextFinder.Action.setSearchString.rawValue)
        findItem.submenu = find
        edit.addItem(findItem)
        editItem.submenu = edit

        // A Window menu, which the app simply didn't have: no ⌘M, no ⌘W, no ⌃⌘F, and none of
        // the standard window commands a Mac user reaches for without thinking.
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let full = windowMenu.addItem(withTitle: "Enter Full Screen",
                                      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(.separator())
        // New Tab goes to the key window's `newWindowForTab`, the same as the tab bar's "+".
        windowMenu.addItem(withTitle: "New Tab", action: #selector(NSWindow.newWindowForTab(_:)), keyEquivalent: "t")
        let newWin = windowMenu.addItem(withTitle: "New Window", action: #selector(newWorkspaceWindow), keyEquivalent: "n")
        newWin.keyEquivalentModifierMask = [.command, .option]
        newWin.target = self
        windowMenu.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func refreshFeeds() {
        Task { [weak self] in
            guard let self else { return }
            let r = await CanvasFeedImport.run(state: self.state)
            if r.created + r.updated > 0 { self.refreshStatus() }
        }
    }

    private func minsLabel(_ m: Int) -> String { m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60)m" }

    private func refreshStatus() {
        guard let button = statusItem.button else { return }
        let mode = MenuBarContent(rawValue: UserDefaults.standard.string(forKey: "menuBarShow") ?? "") ?? .smart
        let cap = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "StudyBar")
        func sym(_ n: String) -> NSImage? { NSImage(systemSymbolName: n, accessibilityDescription: nil) }
        button.toolTip = "StudyBar"
        switch mode {
        case .smart:
            if state.pomodoro.running {
                button.image = sym("timer"); button.title = " \(state.pomodoro.mmss)"
                button.toolTip = "Focus session — \(state.pomodoro.mmss) left"
            } else if let next = state.nextClassToday, next.minutesUntil <= 60 {
                let name = state.course(next.session.courseID)?.name ?? (next.session.title.isEmpty ? "Class" : next.session.title)
                button.image = sym("clock")
                button.title = next.minutesUntil == 0 ? " now" : " \(minsLabel(next.minutesUntil))"
                button.toolTip = next.minutesUntil == 0 ? "\(name) is on now" : "\(name) in \(minsLabel(next.minutesUntil))"
            } else if state.dueSoonCount > 0 {
                button.image = cap; button.title = " \(state.dueSoonCount)"
                button.toolTip = "\(state.dueSoonCount) assignment\(state.dueSoonCount == 1 ? "" : "s") due soon"
            } else if let next = state.nextClassToday {
                let name = state.course(next.session.courseID)?.name ?? (next.session.title.isEmpty ? "Class" : next.session.title)
                button.image = sym("clock"); button.title = " \(minsLabel(next.minutesUntil))"
                button.toolTip = "\(name) in \(minsLabel(next.minutesUntil))"
            } else {
                button.image = cap; button.title = ""
                button.toolTip = "Nothing due — you're clear"
            }
        case .icon:
            button.image = cap; button.title = ""
        case .badge:
            let n = state.dueSoonCount
            button.image = cap; button.title = n > 0 ? " \(n)" : ""
        case .timer:
            if state.pomodoro.running {
                button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
                button.title = " \(state.pomodoro.mmss)"
            } else { button.image = cap; button.title = "" }
        case .nextClass:
            if let next = state.nextClassToday {
                let mins = next.minutesUntil
                button.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
                button.title = mins == 0 ? " now" : (mins < 60 ? " \(mins)m" : " \(mins/60)h\(mins%60)m")
            } else { button.image = cap; button.title = "" }
        }
    }

    // MARK: Menu actions

    @objc private func newTask() { QuickCapture.shared.show(.task) }
    @objc private func newNote() { QuickCapture.shared.show(.note) }
    @objc private func captureScreen() { ScreenGrab.start() }
    @objc private func reviewCards() { CardsPanel.shared.show(deckID: nil) }
    @objc private func starMoment() { state.voice.star() }
    @objc private func toggleRecording() { AppActions.toggleRecording() }
    @objc private func stopRecording() { state.voice.userStop() }
    @objc private func togglePomodoro() { AppActions.togglePomodoro() }
    @objc private func openMain() { showWindow() }
    @objc private func toggleShelf() { ShelfPanel.toggle() }

    // MARK: Drops on the menu-bar icon → the Shelf

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        statusItem.button?.highlight(true)
        return .copy
    }
    func draggingExited(_ sender: NSDraggingInfo?) { statusItem.button?.highlight(false) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let took = ShelfStore.shared.add(from: sender.draggingPasteboard)
        ShelfPanel.show()
        return took
    }
    @objc private func openSettings() { state.selectedModuleID = "settings"; state.globalSearch = ""; showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Window

    func showWindow() {
        WindowManager.shared.show()
        clampToScreen()          // self-heal a saved frame that ended up oversized/off-screen
    }

    @objc func newWorkspaceWindow() { WindowManager.shared.newWindow() }

    /// Keep the window within the visible screen: shrink it if it's larger than the screen and
    /// nudge it back on if it drifted off (an autosaved frame from before the size fix).
    private func clampToScreen() {
        guard let w = WindowManager.shared.frontWindow, let vis = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        // Only the screen constrains the width. This used to snap anything over 1100pt back to
        // 900, to undo a runaway width the autosave had picked up — but that fired on every
        // showWindow(), so a window deliberately dragged wider was yanked back to 900 the next
        // time the menu bar item or a module was clicked. The content no longer drives the
        // window size (see showWindow), so there is nothing left to undo.
        f.size.width = min(f.size.width, vis.size.width)
        f.size.height = min(f.size.height, vis.size.height)
        f.origin.x = max(vis.minX, min(f.origin.x, vis.maxX - f.size.width))
        f.origin.y = max(vis.minY, min(f.origin.y, vis.maxY - f.size.height))
        if f != w.frame { w.setFrame(f, display: true) }
    }
}

/// Apply the saved "appearance" setting at the AppKit level. `.preferredColorScheme(nil)`
/// alone doesn't reliably clear a previously-forced window appearance when switching back
/// to "Device", so set NSApp.appearance directly: nil = follow the system.
@MainActor func applyAppearanceSetting() {
    switch UserDefaults.standard.string(forKey: "appearance") {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
    default:      NSApp.appearance = nil    // "system"/Device → follow the OS
    }
}
