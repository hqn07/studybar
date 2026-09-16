import AppKit
import SwiftUI
import Combine
import CoreSpotlight

/// Owns the menu-bar status item (left-click popover, right-click menu) and the detached window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
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
        if CommandLine.arguments.contains("--homework-selftest") {
            exit(HomeworkSelfTest.run())
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
        if CommandLine.arguments.contains("--pdf-selftest") {
            exit(PDFSelfTest.run())
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
        WindowOpener.setWindowTitle = { [weak self] t in
            self?.window?.title = (t.isEmpty || t == "StudyBar") ? "StudyBar" : "StudyBar — \(t)"
        }
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
        if let w = window, w.isVisible, w.isKeyWindow {
            w.orderOut(nil)
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
            if window?.isVisible == true { window?.orderOut(nil) }
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
        add(state.pomodoro.running ? "Pause Pomodoro" : "Start Pomodoro", #selector(togglePomodoro))
        m.addItem(.separator())
        add("Open StudyBar", #selector(openMain))
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
    @objc private func togglePomodoro() { AppActions.togglePomodoro() }
    @objc private func openMain() { showWindow() }
    @objc private func openSettings() { state.selectedModuleID = "settings"; state.globalSearch = ""; showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Window

    func showWindow() {
        if window == nil {
            // Read the autosaved frame before the window exists. Installing the hosting
            // controller below resizes the window to the SwiftUI view's fitting size — which
            // is smaller than `minSize`, so the window lands on the minimum — and the autosave
            // writes that back over the real saved frame. The size a user picked therefore
            // never survived a relaunch: every launch opened at 720×480 and saved 720×480.
            // Captured here, re-applied after the content is in, it round-trips.
            let savedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame StudyBarMain")
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "StudyBar"
            w.titlebarAppearsTransparent = true
            // The app's own header row is drawn up into the titlebar strip (RootView.shell),
            // so the strip must not also draw a title. `w.title` still feeds the Window menu,
            // the app switcher and accessibility.
            w.titleVisibility = .hidden
            // Low enough that the window fits a half-screen split next to a PDF or a lecture
            // stream, which is how a note gets taken. Notes already lays out as a single pane
            // under 640pt (NotesView.splitMinWidth) — that layout was unreachable while the
            // window could not go below 720.
            w.minSize = NSSize(width: 560, height: 420)
            w.center()
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("StudyBarMain")
            let host = NSHostingController(rootView: RootView(surface: .window).environmentObject(state))
            // Don't let SwiftUI content resize the window to fit its intrinsic width — a wide
            // view (e.g. the Diagnostics log) could otherwise grow the window past the screen.
            // The content fills the window instead; wide content wraps or scrolls inside it.
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            w.contentViewController = host
            if let savedFrame { w.setFrame(from: savedFrame) }
            window = w
        }
        clampToScreen()          // self-heal a saved frame that ended up oversized/off-screen
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keep the window within the visible screen: shrink it if it's larger than the screen and
    /// nudge it back on if it drifted off (an autosaved frame from before the size fix).
    private func clampToScreen() {
        guard let w = window, let vis = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
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
