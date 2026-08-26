import SwiftUI

/// Lets non-SwiftUI code (global hotkey) open the main window.
enum WindowOpener {
    @MainActor static var open: ((String) -> Void)?
    /// Popover → window hand-off: called when a module is selected inside the
    /// compact menu-bar popover, so deep views render in the roomy window instead
    /// of the ~380 pt popover. AppDelegate wires this and no-ops when the popover
    /// isn't the active surface.
    @MainActor static var routeToWindow: ((String) -> Void)?
    /// Sets the main window's title to the current module (e.g. "StudyBar — Notes").
    @MainActor static var setWindowTitle: ((String) -> Void)?
}

/// StudyBar renders on two surfaces with different jobs (see docs/PHILOSOPHY.md):
/// the menu-bar **popover** is glance + capture; the **window** is the workspace.
enum RootSurface { case popover, window }

struct RootView: View {
    /// Which surface this instance is hosted on. Defaults to `.window` so any
    /// incidental construction gets the full experience.
    var surface: RootSurface = .window
    @EnvironmentObject var state: AppState
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentHex") private var accentHex = "#4F8DFD"
    @AppStorage("density") private var densityRaw = "comfortable"
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("breakScreen") private var breakScreen = true
    @State private var showPalette = false

    private var inBreak: Bool {
        state.pomodoro.running &&
        (state.pomodoro.phase == .shortBreak || state.pomodoro.phase == .longBreak)
    }

    var body: some View {
        shell
            .overlay { if showPalette { CommandPalette(isPresented: $showPalette) } }
            .overlay { if breakScreen && inBreak { BreakOverlay() } }
            .overlay { if !onboarded { OnboardingView(done: { onboarded = true }) } }
            .overlay(alignment: .bottom) { undoToast }
            .animation(.spring(response: 0.35), value: state.undo)
            .background { shortcutKeys }
            .onAppear { onAppearSetup() }
            .onChange(of: state.paletteRequested) { _, v in
                if v { showPalette = true; state.paletteRequested = false }
            }
            // In the popover, selecting a module (from Today, the launcher, search or ⌘K)
            // hands off to the window so deep views get real room; the window instance
            // just retitles. AppDelegate also no-ops the hand-off unless the popover shows.
            .onChange(of: state.selectedModuleID) { _, id in
                if surface == .popover { WindowOpener.routeToWindow?(id) }
                else { WindowOpener.setWindowTitle?(ModuleRegistry.info(id)?.title ?? "StudyBar") }
            }
    }

    private var shell: some View {
        VStack(spacing: 0) {
            if surface == .popover {
                popoverBar
                Divider()
                popoverBody
            } else {
                header
                Divider()
                windowBody
            }
        }
        .environment(\.density, densityRaw == "compact" ? .compact : .comfortable)
        .tint(Color(hex: accentHex) ?? .accentColor)
        .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
    }

    @ViewBuilder private var undoToast: some View {
        if let u = state.undo {
            UndoToast(label: u.label, onUndo: { state.performUndo() }, onDismiss: { state.dismissUndo() })
                .padding(DS.Space.l)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Invisible buttons that carry the window/popover keyboard shortcuts.
    @ViewBuilder private var shortcutKeys: some View {
        Button("") { showPalette.toggle() }
            .keyboardShortcut("k", modifiers: .command).opacity(0).accessibilityHidden(true)
        if state.undo != nil {
            Button("") { state.performUndo() }
                .keyboardShortcut("z", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        Button("") { withAnimation(.snappy(duration: 0.28)) { sidebarCollapsed.toggle() } }
            .keyboardShortcut("\\", modifiers: .command).opacity(0).accessibilityHidden(true)
    }

    private func onAppearSetup() {
        ServicesProvider.register()
        GlobalShortcuts.configure()
        if UserDefaults.standard.bool(forKey: "globalHotkey") && !HotKeyManager.shared.registered {
            HotKeyManager.shared.register()
        }
        if surface == .window {
            WindowOpener.setWindowTitle?(ModuleRegistry.info(state.selectedModuleID)?.title ?? "StudyBar")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.28)) { sidebarCollapsed.toggle() } } label: {
                Image(systemName: "sidebar.leading").font(.system(size: 14))
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help(sidebarCollapsed ? "Expand sidebar (⌘\\)" : "Collapse sidebar (⌘\\)")
            Spacer(minLength: 8)
            SearchField(text: $state.globalSearch).frame(maxWidth: 180)
            Menu {
                Button("Settings") { state.selectedModuleID = "settings"; state.globalSearch = "" }
                Divider()
                Button("Quit StudyBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }.menuStyle(.borderlessButton).controlSize(.small).fixedSize().help("Menu")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        // Hidden quit shortcut so ⌘Q still works even though the button is gone.
        .background {
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
    }

    // MARK: Content

    private var content: some View {
        Group {
            if let m = ModuleRegistry.info(state.selectedModuleID) {
                if m.wide {
                    m.make()                                     // spatial: fill the window
                } else {
                    m.make().frame(maxWidth: 820)                // text/list: readable column,
                }                                                //  centered by the frame below
            } else {
                Text("Select a module").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Window body (sidebar + content)

    @ViewBuilder private var windowBody: some View {
        if state.globalSearch.isEmpty {
            GeometryReader { geo in
                let forced = geo.size.width < 440          // narrow window → auto-rail
                let railed = forced || sidebarCollapsed
                HStack(spacing: 0) {
                    SidebarView(prefs: state.modulePrefs, collapsed: railed)
                        .frame(width: railed ? 48 : 176)
                    Divider()
                    content
                }
                .animation(.snappy(duration: 0.28), value: railed)
            }
        } else {
            UnifiedSearchView(query: state.globalSearch)
        }
    }

    // MARK: Popover body — the calm quick surface (glance / search)

    @ViewBuilder private var popoverBody: some View {
        if state.globalSearch.isEmpty {
            TodayView()
        } else {
            UnifiedSearchView(query: state.globalSearch)
        }
    }

    /// Open a module — from the popover this hands off to the window.
    private func launch(_ id: String) {
        state.globalSearch = ""
        state.selectedModuleID = id
        WindowOpener.routeToWindow?(id)
    }

    // MARK: Popover top bar — search · module launcher · menu

    private var popoverBar: some View {
        HStack(spacing: 8) {
            SearchField(text: $state.globalSearch).frame(maxWidth: .infinity)
            Menu {
                let favs = state.modulePrefs.favorites
                    .compactMap { ModuleRegistry.info($0) }
                    .filter { state.modulePrefs.isVisible($0.id) }
                if !favs.isEmpty {
                    Section("Favorites") {
                        ForEach(favs) { m in
                            Button { launch(m.id) } label: { Label(m.title, systemImage: m.symbol) }
                        }
                    }
                }
                Section("All Modules") {
                    ForEach(ModuleRegistry.all.filter { state.modulePrefs.isVisible($0.id) && $0.id != "settings" }) { m in
                        Button { launch(m.id) } label: { Label(m.title, systemImage: m.symbol) }
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
            .help("Open a module in the window")

            Menu {
                Button("Settings") { launch("settings") }
                Button("Open Window") { WindowOpener.open?("main") }.keyboardShortcut("o")
                Divider()
                Button("Quit StudyBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).controlSize(.small).fixedSize().help("Menu")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background {
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
    }
}

/// Native macOS source list: Favorites + categories/flat, honoring hidden modules.
struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var prefs: ModulePrefs
    var collapsed: Bool = false

    // One custom row list for both modes so collapsing only fades the labels
    // (no List relayout, no view-type swap) — the width animates smoothly.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let favs = prefs.favorites.compactMap { ModuleRegistry.info($0) }.filter { prefs.isVisible($0.id) }
                group("Favorites", favs, isFirst: true)
                if prefs.order == .category {
                    ForEach(prefs.orderedCategories(), id: \.self) { cat in
                        group(cat.rawValue, ModuleRegistry.all.filter { $0.category == cat && prefs.isVisible($0.id) },
                              isFirst: favs.isEmpty && cat == prefs.orderedCategories().first)
                    }
                } else {
                    let flat = prefs.orderedIDs().compactMap { ModuleRegistry.info($0) }
                        .filter { prefs.isVisible($0.id) && !prefs.isFavorite($0.id) }
                    group(prefs.order == .mostUsed ? "Most Used" : "Modules", flat, isFirst: favs.isEmpty)
                }
            }
            .padding(.vertical, DS.Space.s).padding(.horizontal, DS.Space.s)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func group(_ title: String, _ items: [ModuleInfo], isFirst: Bool) -> some View {
        if !items.isEmpty {
            if collapsed {
                if !isFirst { Divider().padding(.horizontal, DS.Space.s).padding(.vertical, 3) }
            } else {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.m).padding(.top, isFirst ? 2 : DS.Space.m).padding(.bottom, 2)
            }
            ForEach(items) { row($0) }
        }
    }

    private func row(_ m: ModuleInfo) -> some View {
        let sel = state.selectedModuleID == m.id
        return Button { state.selectedModuleID = m.id } label: {
            HStack(spacing: 8) {
                Image(systemName: m.symbol).font(.system(size: 14)).frame(width: 22)
                if !collapsed {
                    Text(m.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if let n = badge(for: m.id) {
                        Text("\(n)").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.red))
                    }
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(sel ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .foregroundStyle(sel ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .overlay(alignment: .topTrailing) {
                if collapsed, badge(for: m.id) != nil {
                    Circle().fill(.red).frame(width: 6, height: 6).offset(x: -4, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(collapsed ? m.title : "")
    }
    private func badge(for id: String) -> Int? {
        switch id {
        case "assignments": let n = state.dueSoonCount; return n > 0 ? n : nil
        case "todos": let n = state.data.todos.filter { !$0.done }.count; return n > 0 ? n : nil
        default: return nil
        }
    }
}

struct SidebarRow: View {
    let module: ModuleInfo
    let selected: Bool
    var badge: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: module.symbol).frame(width: 18)
                Text(module.title).lineLimit(1)
                Spacer()
                if let badge {
                    Text("\(badge)").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.red))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }
}

/// Rounded search field used in the header.
struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Search", text: $text).textFieldStyle(.plain).font(.callout)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.background.secondary, in: Capsule())
    }
}

/// Snackbar shown after a destructive action, with a one-tap Undo.
struct UndoToast: View {
    let label: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
            Text(label).font(.callout).lineLimit(1)
            Spacer(minLength: DS.Space.m)
            Button("Undo", action: onUndo).buttonStyle(.borderedProminent).controlSize(.small)
            Button { onDismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(.separator))
        .shadow(radius: 12)
        .frame(maxWidth: 320)
    }
}
