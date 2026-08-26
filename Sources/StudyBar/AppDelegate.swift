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
        if CommandLine.arguments.contains("--ai-selftest") {
            exit(AIToolSelfTest.run())
        }
        // Test/dev hook: SB_DOCK=1 promotes StudyBar to a regular Dock app so UI-automation
        // tools (which can't target an LSUIElement accessory app) can drive the window.
        // No effect on normal launches — 1.0 stays a pure menu-bar app.
        if ProcessInfo.processInfo.environment["SB_DOCK"] == "1"
            || UserDefaults.standard.bool(forKey: "showDock") {
            NSApp.setActivationPolicy(.regular)
        }
        applyAppearanceSetting()
        Notifier.requestAuthorization()

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
        WindowOpener.setWindowTitle = { [weak self] t in
            self?.window?.title = (t.isEmpty || t == "StudyBar") ? "StudyBar" : "StudyBar — \(t)"
        }
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

    // MARK: Status item

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        lastStatusClickAt = Date()
        if NSApp.currentEvent?.type == .rightMouseUp {
            showRightMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            let size = (PopoverSize(rawValue: UserDefaults.standard.string(forKey: "popoverSize") ?? "") ?? .medium).dimensions
            popover.contentSize = size
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
        editItem.submenu = edit

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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "StudyBar"
            w.titlebarAppearsTransparent = true
            w.minSize = NSSize(width: 720, height: 480)
            w.center()
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("StudyBarMain")
            w.contentViewController = NSHostingController(rootView: RootView(surface: .window).environmentObject(state))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
