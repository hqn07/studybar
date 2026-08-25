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
    private var timer: Timer?

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { URLRouter.handle(u) }
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
        // Test/dev hook: SB_DOCK=1 promotes StudyBar to a regular Dock app so UI-automation
        // tools (which can't target an LSUIElement accessory app) can drive the window.
        // No effect on normal launches — 1.0 stays a pure menu-bar app.
        if ProcessInfo.processInfo.environment["SB_DOCK"] == "1" {
            NSApp.setActivationPolicy(.regular)
        }
        Notifier.requestAuthorization()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: RootView().environmentObject(state))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "StudyBar")
            button.imagePosition = .imageLeading
            button.action = #selector(statusClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        WindowOpener.open = { [weak self] _ in self?.showWindow() }
        SpotlightIndexer.reindex(state.data)
        refreshStatus()
        // Pull assignment due dates from subscribed Canvas/LMS calendar feeds (no API/token).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let r = await CanvasFeedImport.run(state: self.state)
            if r.created + r.updated > 0 { self.refreshStatus() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    // MARK: Status item

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
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

    private func refreshStatus() {
        guard let button = statusItem.button else { return }
        let mode = MenuBarContent(rawValue: UserDefaults.standard.string(forKey: "menuBarShow") ?? "") ?? .badge
        let cap = NSImage(systemSymbolName: "graduationcap.fill", accessibilityDescription: "StudyBar")
        switch mode {
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
            w.center()
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("StudyBarMain")
            w.contentViewController = NSHostingController(rootView: RootView().environmentObject(state))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
