import SwiftUI

/// Lets non-SwiftUI code (global hotkey) open the main window.
enum WindowOpener { @MainActor static var open: ((String) -> Void)? }

struct RootView: View {
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
        VStack(spacing: 0) {
            header
            Divider()
            if state.globalSearch.isEmpty {
                GeometryReader { geo in
                    let forced = geo.size.width < 440          // Compact popover → auto-rail
                    let railed = forced || sidebarCollapsed
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            collapseBar(forced: forced, railed: railed)
                            SidebarView(prefs: state.modulePrefs, collapsed: railed)
                        }
                        .frame(width: railed ? 48 : 176)
                        Divider()
                        content
                    }
                    .animation(.spring(response: 0.3), value: railed)
                }
            } else {
                UnifiedSearchView(query: state.globalSearch)
            }
        }
        .environment(\.density, densityRaw == "compact" ? .compact : .comfortable)
        .tint(Color(hex: accentHex) ?? .accentColor)
        .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
        .background {
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        .overlay {
            if showPalette { CommandPalette(isPresented: $showPalette) }
        }
        .overlay {
            if breakScreen && inBreak { BreakOverlay() }
        }
        .overlay {
            if !onboarded { OnboardingView(done: { onboarded = true }) }
        }
        .overlay(alignment: .bottom) {
            if let u = state.undo {
                UndoToast(label: u.label, onUndo: { state.performUndo() }, onDismiss: { state.dismissUndo() })
                    .padding(DS.Space.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35), value: state.undo)
        .background {
            if state.undo != nil {
                Button("") { state.performUndo() }
                    .keyboardShortcut("z", modifiers: .command).opacity(0).accessibilityHidden(true)
            }
        }
        .background {
            Button("") { withAnimation(.spring(response: 0.3)) { sidebarCollapsed.toggle() } }
                .keyboardShortcut("\\", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        .onAppear {
            ServicesProvider.register()
            GlobalShortcuts.configure()
            if UserDefaults.standard.bool(forKey: "globalHotkey") && !HotKeyManager.shared.registered {
                HotKeyManager.shared.register()
            }
        }
        .onChange(of: state.paletteRequested) { _, v in
            if v { showPalette = true; state.paletteRequested = false }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "graduationcap.fill").foregroundStyle(.tint).font(.system(size: 15))
            Text("StudyBar").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 8)
            SearchField(text: $state.globalSearch).frame(maxWidth: 180)
            Button { WindowOpener.open?("main") } label: {
                Image(systemName: "macwindow")
            }.help("Open in resizable window (⌘O)").buttonStyle(.borderless).controlSize(.small)
                .keyboardShortcut("o", modifiers: .command)
            Menu {
                Button("Settings") { state.selectedModuleID = "settings"; state.globalSearch = "" }
                Button("Open in Window") { WindowOpener.open?("main") }.keyboardShortcut("o")
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

    // MARK: Sidebar collapse toggle

    @ViewBuilder private func collapseBar(forced: Bool, railed: Bool) -> some View {
        if !forced {
            Button { withAnimation(.spring(response: 0.3)) { sidebarCollapsed.toggle() } } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .help(railed ? "Expand sidebar (⌘\\)" : "Collapse sidebar (⌘\\)")
            .frame(maxWidth: .infinity, alignment: railed ? .center : .trailing)
            .padding(.horizontal, railed ? 0 : 8).padding(.top, 6)
        }
    }

    // MARK: Content

    private var content: some View {
        Group {
            if let m = ModuleRegistry.info(state.selectedModuleID) {
                m.make()
            } else {
                Text("Select a module").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Native macOS source list: Favorites + categories/flat, honoring hidden modules.
struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var prefs: ModulePrefs
    var collapsed: Bool = false

    private var selection: Binding<String?> {
        Binding(get: { state.selectedModuleID }, set: { if let v = $0 { state.selectedModuleID = v } })
    }

    var body: some View {
        if collapsed { rail } else { fullList }
    }

    // MARK: Icon-only rail

    private var rail: some View {
        ScrollView {
            VStack(spacing: 3) {
                let favs = prefs.favorites.compactMap { ModuleRegistry.info($0) }.filter { prefs.isVisible($0.id) }
                if !favs.isEmpty { ForEach(favs) { railButton($0) }; railDivider }
                if prefs.order == .category {
                    ForEach(prefs.orderedCategories(), id: \.self) { cat in
                        let visible = ModuleRegistry.all.filter { $0.category == cat && prefs.isVisible($0.id) }
                        if !visible.isEmpty { ForEach(visible) { railButton($0) }; railDivider }
                    }
                } else {
                    let flat = prefs.orderedIDs().compactMap { ModuleRegistry.info($0) }
                        .filter { prefs.isVisible($0.id) && !prefs.isFavorite($0.id) }
                    ForEach(flat) { railButton($0) }
                }
            }.padding(.vertical, DS.Space.s)
        }
        .scrollIndicators(.hidden)
    }
    private var railDivider: some View { Divider().padding(.horizontal, DS.Space.m).padding(.vertical, 2) }

    private func railButton(_ m: ModuleInfo) -> some View {
        let sel = state.selectedModuleID == m.id
        return Button { state.selectedModuleID = m.id } label: {
            Image(systemName: m.symbol)
                .font(.system(size: 15))
                .frame(width: 34, height: 30)
                .background(sel ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: DS.Radius.control))
                .foregroundStyle(sel ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .overlay(alignment: .topTrailing) {
                    if badge(for: m.id) != nil {
                        Circle().fill(.red).frame(width: 6, height: 6).offset(x: -3, y: 3)
                    }
                }
        }
        .buttonStyle(.plain).help(m.title)
    }

    // MARK: Full list

    private var fullList: some View {
        List(selection: selection) {
            let favs = prefs.favorites.compactMap { ModuleRegistry.info($0) }.filter { prefs.isVisible($0.id) }
            if !favs.isEmpty {
                Section("Favorites") { ForEach(favs) { row($0) } }
            }
            if prefs.order == .category {
                ForEach(prefs.orderedCategories(), id: \.self) { cat in
                    let visible = ModuleRegistry.all.filter { $0.category == cat && prefs.isVisible($0.id) }
                    if !visible.isEmpty {
                        Section(cat.rawValue) { ForEach(visible) { row($0) } }
                    }
                }
            } else {
                let flat = prefs.orderedIDs().compactMap { ModuleRegistry.info($0) }
                    .filter { prefs.isVisible($0.id) && !prefs.isFavorite($0.id) }
                Section(prefs.order == .mostUsed ? "Most Used" : "Modules") { ForEach(flat) { row($0) } }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func row(_ m: ModuleInfo) -> some View {
        if let n = badge(for: m.id) {
            Label(m.title, systemImage: m.symbol).badge(n).tag(m.id)
        } else {
            Label(m.title, systemImage: m.symbol).tag(m.id)
        }
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
