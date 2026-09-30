import AppKit
import Combine
import SwiftUI

/// What one workspace window shows. A window used to *be* `AppState.selectedModuleID`, so a
/// second window, a tab or a split had nothing of its own to show. Each window now owns this;
/// `state.selectedModuleID` remains the way the rest of the app navigates, and `WindowManager`
/// points it at whichever window was last in front.
@MainActor
final class WindowModel: ObservableObject {
    @Published var moduleID: String
    /// The right half of a split: a module id, or `WindowModel.chat`. nil = no split.
    @Published var rightID: String?
    /// What the left pane has open, for the chat beside it.
    @Published var focus: StudyFocus?
    /// A note for this window's Notes to open once — how "Open in New Tab" says which one.
    /// Per window on purpose: `state.pendingOpenNote` reaches every Notes on screen, and the
    /// one already open would take it first.
    var openNote: UUID?
    /// Whether this window shows a tab bar. The header is drawn up into the titlebar strip;
    /// with a tab bar there too, it would sit under the tabs.
    @Published var tabBar = false
    static let chat = "chat"

    init(moduleID: String, rightID: String? = nil) {
        self.moduleID = moduleID
        self.rightID = rightID
    }
}

/// The thing a module has open — published up to the window so the chat beside it knows.
enum StudyFocus: Equatable {
    case note(UUID), reading(UUID, page: Int?), assignment(UUID), course(UUID)
}

struct StudyFocusKey: PreferenceKey {
    static let defaultValue: StudyFocus? = nil
    static func reduce(value: inout StudyFocus?, nextValue: () -> StudyFocus?) { value = nextValue() ?? value }
}

extension View {
    /// Tell the window what this module has open.
    func studyFocus(_ f: StudyFocus?) -> some View { preference(key: StudyFocusKey.self, value: f) }
}

private struct WorkspaceKey: EnvironmentKey { static let defaultValue: WindowModel? = nil }
extension EnvironmentValues {
    /// The window a view is in — nil in the popover and other panels.
    var workspace: WindowModel? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

/// A workspace window that answers the tab bar's "+".
final class WorkspaceWindow: NSWindow {
    override func newWindowForTab(_ sender: Any?) { WindowManager.shared.newTab(from: self) }
}

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private(set) var state: AppState!
    private var entries: [(window: WorkspaceWindow, model: WindowModel)] = []
    /// The window navigation lands in: the last workspace window to be key.
    private(set) var current: WindowModel?
    private var bag = Set<AnyCancellable>()

    func configure(state: AppState) {
        self.state = state
        // Navigation from anywhere — ⌘K, Today, a notification, the popover — moves the
        // window that was last in front.
        state.$selectedModuleID.removeDuplicates().sink { [weak self] id in
            guard let self, let m = self.current, m.moduleID != id else { return }
            m.moduleID = id
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] n in
            guard let self, let w = n.object as? WorkspaceWindow, let e = self.entries.first(where: { $0.window === w }) else { return }
            self.current = e.model
            if state.selectedModuleID != e.model.moduleID { state.selectedModuleID = e.model.moduleID }
        }.store(in: &bag)
        // A tab bar comes and goes as tabs are added, closed or dragged out; there is no
        // notification for it, so look again whenever a workspace window changes hands.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshTabBars() }
            }.store(in: &bag)
        }
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification).sink { [weak self] n in
            guard let self, let w = n.object as? WorkspaceWindow else { return }
            // The first window is kept for reopening from the menu bar; the rest go.
            if self.entries.count > 1 { self.entries.removeAll { $0.window === w } }
            if self.current.map({ c in !self.entries.contains { $0.model === c } }) ?? false { self.current = self.entries.last?.model }
        }.store(in: &bag)
    }

    var windows: [NSWindow] { entries.map(\.window) }

    func refreshTabBars() {
        for e in entries {
            let shown = e.window.tabGroup?.isTabBarVisible ?? false
            if e.model.tabBar != shown { e.model.tabBar = shown }
        }
    }
    var frontWindow: NSWindow? { entries.first { $0.model === current }?.window ?? entries.first?.window }

    /// Show the workspace, creating the first window if there is none.
    func show() {
        if entries.isEmpty { _ = make(moduleID: state.selectedModuleID, restoreFrame: true) }
        NSApp.activate(ignoringOtherApps: true)
        frontWindow?.makeKeyAndOrderFront(nil)
    }

    /// A new tab beside `window` (the key workspace window when nil), showing `moduleID`
    /// (the same module when nil) — then `configure` runs on its model before it appears.
    @discardableResult
    func newTab(from window: NSWindow? = nil, moduleID: String? = nil, configure: ((WindowModel) -> Void)? = nil) -> WindowModel {
        let host = (window as? WorkspaceWindow) ?? (frontWindow as? WorkspaceWindow)
        let model = make(moduleID: moduleID ?? current?.moduleID ?? "today", restoreFrame: false)
        configure?(model)
        let new = entries.last!.window
        if let host, host.isVisible { host.addTabbedWindow(new, ordered: .above) } else { new.center() }
        NSApp.activate(ignoringOtherApps: true)
        new.makeKeyAndOrderFront(nil)
        return model
    }

    /// A separate window, cascaded from the front one.
    @discardableResult
    func newWindow(moduleID: String? = nil, configure: ((WindowModel) -> Void)? = nil) -> WindowModel {
        let model = make(moduleID: moduleID ?? current?.moduleID ?? "today", restoreFrame: false)
        configure?(model)
        let new = entries.last!.window
        new.tabbingMode = .disallowed                 // opened as a window, it stays one
        if let front = frontWindow, front !== new { new.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28)) }
        else { new.center() }
        NSApp.activate(ignoringOtherApps: true)
        new.makeKeyAndOrderFront(nil)
        new.tabbingMode = .automatic
        return model
    }

    private func make(moduleID: String, restoreFrame: Bool) -> WindowModel {
        // Read the autosaved frame before the window exists. Installing the hosting
        // controller resizes the window to the SwiftUI view's fitting size — smaller than
        // `minSize` — and the autosave would write that back over the real saved frame.
        let savedFrame = restoreFrame ? UserDefaults.standard.string(forKey: "NSWindow Frame StudyBarMain") : nil
        let w = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        w.title = "StudyBar"
        // The app's own header row is drawn up into the titlebar strip (RootView.shell), so
        // the strip must not also draw a title; `w.title` still feeds the Window menu, the tab,
        // the app switcher and accessibility.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // Low enough to sit in half a screen beside a PDF or a lecture stream.
        w.minSize = NSSize(width: 560, height: 420)
        w.isReleasedWhenClosed = false
        w.tabbingIdentifier = "StudyBarWorkspace"
        w.tabbingMode = .automatic
        let model = WindowModel(moduleID: moduleID)
        let host = NSHostingController(rootView: RootView(surface: .window, win: model).environmentObject(state))
        // The content fills the window rather than sizing it — a wide view (the Diagnostics
        // log) could otherwise grow the window past the screen.
        host.sizingOptions = []
        w.contentViewController = host
        // Installing the content shrank the window to its fitting size — the 560×420 minimum.
        // A new window or tab takes the size of the one in front instead.
        w.setContentSize(frontWindow?.contentLayoutRect.size ?? NSSize(width: 900, height: 620))
        if restoreFrame {
            w.center()
            w.setFrameAutosaveName("StudyBarMain")
            if let savedFrame { w.setFrame(from: savedFrame) }
            // The first window keeps its split between launches.
            model.rightID = UserDefaults.standard.string(forKey: "splitRight")
            model.$rightID.dropFirst().sink { UserDefaults.standard.set($0, forKey: "splitRight") }.store(in: &bag)
        }
        model.$moduleID.sink { [weak w] id in
            let t = ModuleRegistry.info(id)?.title ?? ""
            w?.title = t.isEmpty ? "StudyBar" : "StudyBar — \(t)"
            w?.tab.title = t.isEmpty ? "StudyBar" : t
        }.store(in: &bag)
        // The window navigation lands in follows its own module too — a sidebar click in the
        // front window is where the rest of the app should think you are.
        model.$moduleID.dropFirst().sink { [weak self, weak model] id in
            guard let self, let model, self.current === model, self.state.selectedModuleID != id else { return }
            self.state.selectedModuleID = id
        }.store(in: &bag)
        entries.append((w, model))
        if current == nil { current = model }
        return model
    }
}
