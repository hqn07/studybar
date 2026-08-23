import SwiftUI

/// Lets non-SwiftUI code (global hotkey) open the main window.
enum WindowOpener { @MainActor static var open: ((String) -> Void)? }

struct RootView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentHex") private var accentHex = "#4F8DFD"
    @AppStorage("density") private var densityRaw = "comfortable"
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
                HStack(spacing: 0) {
                    SidebarView(prefs: state.modulePrefs).frame(width: 176)
                    Divider()
                    content
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

    private var selection: Binding<String?> {
        Binding(get: { state.selectedModuleID }, set: { if let v = $0 { state.selectedModuleID = v } })
    }

    var body: some View {
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
