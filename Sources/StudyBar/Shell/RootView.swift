import SwiftUI

/// Lets non-SwiftUI code (global hotkey) open the main window.
enum WindowOpener {
    @MainActor static var open: ((String) -> Void)?
    /// Popover → window hand-off: called when a module is selected inside the
    /// compact menu-bar popover, so deep views render in the roomy window instead
    /// of the ~380 pt popover. AppDelegate wires this and no-ops when the popover
    /// isn't the active surface.
    @MainActor static var routeToWindow: ((String) -> Void)?
}

/// StudyBar renders on two surfaces with different jobs (see docs/PHILOSOPHY.md):
/// the menu-bar **popover** is glance + capture; the **window** is the workspace.
enum RootSurface { case popover, window }

struct RootView: View {
    /// Which surface this instance is hosted on. Defaults to `.window` so any
    /// incidental construction gets the full experience.
    var surface: RootSurface = .window
    /// This window's own module and split. The popover has none of its own — it shows Today
    /// and hands everything else to the window.
    @ObservedObject var win = WindowModel(moduleID: "today")
    @EnvironmentObject var state: AppState
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentHex") private var accentHex = "#4F8DFD"
    @AppStorage(SurfaceTheme.storageKey) private var surfaceThemeRaw = "system"
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("breakScreen") private var breakScreen = true
    @State private var showPalette = false
    @State private var showShortcuts = false

    private var inBreak: Bool {
        state.pomodoro.running &&
        (state.pomodoro.phase == .shortBreak || state.pomodoro.phase == .longBreak)
    }

    var body: some View {
        shell
            // The popover has no window edge to grab, so it carries its own grip.
            .overlay(alignment: .bottomTrailing) {
                if surface == .popover { PopoverResizeGrip() }
            }
            // One overlay at a time: ⌘/ over an open ⌘K drew the sheet on top of the palette's
            // list, with both still live underneath.
            .overlay { if showPalette && !showShortcuts { CommandPalette(isPresented: $showPalette) } }
            .overlay { if showShortcuts { ShortcutSheet(isPresented: $showShortcuts) } }
            .onChange(of: showShortcuts) { _, on in if on { showPalette = false } }
            .onChange(of: showPalette) { _, on in if on { showShortcuts = false } }
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
            }
            // Focus mode belongs to writing. Leaving Notes with the chrome hidden would
            // strand a module with no rail, no header and no button to bring them back.
            .onChange(of: win.moduleID) { _, id in if id != "notes" { state.focusMode = false } }
            // Drive the window appearance at the AppKit level so switching to "Device"
            // reliably re-follows the system (preferredColorScheme(nil) alone doesn't).
            .onChange(of: appearance) { _, _ in applyAppearanceSetting() }
    }

    /// Persistent recording control, pinned below every module on both surfaces (outside the
    /// per-module `.id` swap) — so a lecture keeps recording while you take notes, check the
    /// schedule, etc., and Stop / the live clock are always one tap away.
    @ViewBuilder private var recordingBar: some View {
        RecordingBar(voice: state.voice, open: openVoice)
    }
    private func openVoice() {
        if surface == .popover { state.selectedModuleID = "voice"; WindowOpener.routeToWindow?("voice") }
        else { win.moduleID = "voice" }
    }

    private var shell: some View {
        VStack(spacing: 0) {
            dataSafetyBanner
            if surface == .popover {
                popoverBar
                Divider()
                popoverBody
            } else {
                // Focus mode takes the whole shell down to the module: no header row, and
                // windowBody drops the rail. `fullSizeContentView` leaves the traffic lights
                // floating over the content, which is what a distraction-free surface wants.
                if !state.focusMode {
                    header
                    Divider()
                }
                windowBody
            }
            recordingBar
            JobsBar(here: surface == .window ? win.moduleID : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window is `fullSizeContentView` with a transparent titlebar, but SwiftUI still
        // inset the content below it — so the app drew an empty 28pt strip and then its own
        // header underneath, two rows of chrome before any content. Taking the top safe area
        // lets the header sit *in* the titlebar; `header` leaves room for the traffic lights.
        .ignoresSafeArea(.container, edges: surface == .window && !win.tabBar ? .top : [])
        .background(baseFill)
        .tint(Color(hex: accentHex) ?? .accentColor)
        .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
    }

    /// Shown app-wide (both surfaces) only when the store could not be read at launch and
    /// saving is blocked — so the user is never silently editing a read-only session. The
    /// real file is preserved untouched (see AppState's load guard); this points them at it.
    @ViewBuilder private var dataSafetyBanner: some View {
        if state.dataSaveBlocked {
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Read-only — couldn't open your data file").font(.caption.weight(.semibold))
                        Text("Your data is safe and untouched, but changes now won't be saved. Quit and reopen StudyBar; if it persists, restore a backup from the data folder.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.s)
                    Button("Reveal Backups") { revealDataFolder() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
                Divider()
            }
        }
    }

    private func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([state.dataFileURL])
    }

    /// The base surface behind everything. Reading `surfaceThemeRaw` (an `@AppStorage`)
    /// here ties the whole tree to the preset, so switching it re-renders live.
    ///
    /// - `.system`: unchanged behavior — the popover paints an opaque window background
    ///   (macOS vibrancy otherwise lets the desktop bleed through as a muddy tint), the
    ///   window stays clear.
    /// - a preset: an opaque near-black base on both surfaces (which also kills the
    ///   popover bleed).
    private var baseFill: AnyShapeStyle {
        let theme = SurfaceTheme(rawValue: surfaceThemeRaw) ?? .system
        if theme == .system {
            return surface == .popover
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(Color.clear)
        }
        return AnyShapeStyle(theme.base)   // any preset paints its own base
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
        Button("") { showShortcuts.toggle() }
            .keyboardShortcut("/", modifiers: .command).opacity(0).accessibilityHidden(true)
        if surface == .window {
            // The chat beside whatever is open.
            Button("") { win.rightID = win.rightID == WindowModel.chat ? nil : WindowModel.chat }
                .keyboardShortcut("j", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        // ⌘⇧F is what iA Writer, Bear and Ulysses all use for this.
        Button("") { withAnimation(.easeInOut(duration: 0.2)) { state.focusMode.toggle() } }
            .keyboardShortcut("f", modifiers: [.command, .shift]).opacity(0).accessibilityHidden(true)
    }

    private func onAppearSetup() {
        ServicesProvider.register()
        GlobalShortcuts.configure()
        if UserDefaults.standard.bool(forKey: "globalHotkey") && !HotKeyManager.shared.registered {
            HotKeyManager.shared.register()
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
                Button("Settings") { win.moduleID = "settings"; state.globalSearch = "" }
                Divider()
                Button("New Tab") { WindowManager.shared.newTab() }
                Button("New Window") { WindowManager.shared.newWindow() }
                Divider()
                Button("Quit StudyBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }.menuStyle(.borderlessButton).controlSize(.small).fixedSize().help("Menu")
        }
        // 78pt of leading room: the header now shares the titlebar strip with the traffic
        // lights, which AppKit draws over the content.
        .padding(.leading, win.tabBar ? 12 : 78).padding(.trailing, 12).padding(.vertical, 6)
        .frame(height: 38)
        // Hidden quit shortcut so ⌘Q still works even though the button is gone.
        .background {
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
    }

    // MARK: Content

    @AppStorage("splitWidth") private var splitWidth = 420.0

    /// The module on the left, and — when the window is split — a second module or the chat on
    /// the right. Only the left pane's open item reaches the chat.
    private var content: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                pane(win.moduleID)
                    .onPreferenceChange(StudyFocusKey.self) { f in win.focus = f }
                if let right = win.rightID {
                    PaneDivider(width: Binding(get: { CGFloat(splitWidth) }, set: { splitWidth = Double($0) }),
                                range: 320...max(320, geo.size.width - 360), resetTo: 420, inverted: true)
                    VStack(spacing: 0) {
                        rightBar(right)
                        Divider()
                        if right == WindowModel.chat { ContextChatPane(win: win) } else { pane(right) }
                    }
                    .frame(width: min(CGFloat(splitWidth), max(320, geo.size.width - 360)))
                }
            }
        }
    }

    private func pane(_ id: String) -> some View {
        Group {
            if let m = ModuleRegistry.info(id) {
                if m.wide {
                    m.make()                                     // spatial: fill the pane
                } else {
                    m.make().frame(maxWidth: 820)                // text/list: readable column,
                }                                                //  centered by the frame below
            } else {
                Text("Select a module").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.workspace, win)
        .id(id)                                                  // clean swap per module
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.16), value: id)        // subtle crossfade
    }

    /// The right pane's own strip: what's in it, swap sides, close.
    private func rightBar(_ right: String) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button { win.rightID = WindowModel.chat } label: { Label("Chat", systemImage: "text.bubble") }
                Divider()
                ForEach(ModuleRegistry.all.filter { state.modulePrefs.isVisible($0.id) && $0.id != win.moduleID }) { m in
                    Button { win.rightID = m.id } label: { Label(m.title, systemImage: m.symbol) }
                }
            } label: {
                Text(right == WindowModel.chat ? "Chat" : ModuleRegistry.info(right)?.title ?? right).font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if right != WindowModel.chat {
                Button { let l = win.moduleID; win.moduleID = right; win.rightID = l } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.borderless).help("Swap sides")
            }
            Button { win.rightID = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close this side (⌘J for chat)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.sbSurface)
    }

    // MARK: Window body (sidebar + content)

    @ViewBuilder private var windowBody: some View {
        if state.globalSearch.isEmpty {
            GeometryReader { geo in
                // 760, not 440: at a half-screen width the 176pt labelled sidebar pushed Notes
                // under its 640pt split threshold, so a window sized to sit beside a PDF showed
                // the list *instead of* the note. Railed, the same window fits list + editor.
                let forced = geo.size.width < 760          // narrow window → auto-rail
                let railed = forced || sidebarCollapsed
                HStack(spacing: 0) {
                    if !state.focusMode {
                        SidebarView(prefs: state.modulePrefs, win: win, collapsed: railed)
                            .frame(width: railed ? 48 : 176)
                        Divider()
                    }
                    content
                }
                .animation(.snappy(duration: 0.28), value: railed)
                .animation(.easeInOut(duration: 0.2), value: state.focusMode)
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

/// The persistent recording control, pinned below every module on both surfaces.
///
/// Its own view, observing the recorder directly, for a performance reason: while recording,
/// `VoiceService` publishes a waveform about thirty times a second. When this lived inside
/// `RootView` — which observes `AppState`, which forwarded every voice change — each of those
/// ticks invalidated the sidebar, the header and whichever module was on screen, and using the
/// app during a lecture recording was visibly slow. `AppState` now forwards only `status` and
/// `startedAt`, and the meter's churn stops at this bar.
/// Long AI jobs started in another module, under the window like the recording bar — so
/// leaving the module a quiz is being written in doesn't hide that it's still coming.
struct JobsBar: View {
    @ObservedObject private var jobs = Jobs.shared
    /// The module on screen; its own jobs already show their progress there.
    let here: String?

    var body: some View {
        ForEach(jobs.running.filter { $0.module != here }) { j in
            Divider()
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(j.detail.isEmpty ? j.title : "\(j.title) · \(j.detail)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Open") { AppActions.open(module: j.module) }.buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.tint.opacity(0.05))
        }
    }
}

struct RecordingBar: View {
    @ObservedObject var voice: VoiceService
    let open: () -> Void

    var body: some View {
        switch voice.status {
        case .recording:
            Divider()
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 9, height: 9)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(clock).font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.red).contentTransition(.numericText())
                }
                LevelMeter(meter: voice.meter).frame(width: 44, height: 16)
                Text("Recording").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button { voice.star() } label: {
                    Label(voice.timeline.stars.isEmpty ? "Star" : "\(voice.timeline.stars.count)", systemImage: "star.fill")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.orange)
                .help("Star this moment — it's marked in the note's transcript and stressed in the study notes")
                .accessibilityLabel(voice.timeline.stars.isEmpty ? "Star this moment" : "Star this moment, \(voice.timeline.stars.count) starred")
                Button("Open", action: open).buttonStyle(.borderless).font(.caption)
                Button { voice.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Pause for a break — Resume carries on in the same recording")
                Button { voice.userStop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.red.opacity(0.06))
            .contentShape(Rectangle()).onTapGesture(perform: open)
            .help("Recording — tap to open Voice, Pause for a break, or Stop to finish")
        case .paused:
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                Text(clock).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.orange)
                Text("Paused — the transcript is kept").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Open", action: open).buttonStyle(.borderless).font(.caption)
                Button { voice.resume() } label: { Label("Resume", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { voice.userStop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.orange.opacity(0.06))
            .contentShape(Rectangle()).onTapGesture(perform: open)
            .help("Paused — Resume carries on in the same recording, or Stop to finish")
        case .transcribing:
            Divider()
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcribing your recording…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Open", action: open).buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.tint.opacity(0.05))
            .contentShape(Rectangle()).onTapGesture(perform: open)
        default:
            EmptyView()
        }
    }

    /// Recorded time; it stands still through a pause.
    private var clock: String {
        let s = max(0, Int(voice.elapsed))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Native macOS source list: Favorites + categories/flat, honoring hidden modules.
struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var prefs: ModulePrefs
    @ObservedObject var win: WindowModel
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
        let sel = win.moduleID == m.id
        // ⌥-click puts it on the right, beside what's open.
        return Button {
            if NSEvent.modifierFlags.contains(.option), m.id != win.moduleID { win.rightID = m.id } else { win.moduleID = m.id }
        } label: {
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
            .padding(.vertical, 6).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            // The whole row takes the click. Without this only the drawn glyphs are
            // hit-testable — an unselected row's background is `.clear`, which isn't — so
            // the target was the icon and the text, and the space around them was dead.
            .contentShape(Rectangle())
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
        .contextMenu {
            Button("Open on the Right") { win.rightID = m.id }.disabled(m.id == win.moduleID)
            Button("Open in New Tab") { WindowManager.shared.newTab(moduleID: m.id) }
            Button("Open in New Window") { WindowManager.shared.newWindow(moduleID: m.id) }
        }
        // Collapsed, the row is a bare SF Symbol, and VoiceOver then reads the symbol's own
        // name — "Books Standing Vertically On A Shelf" for Library, "Gear Shape" for
        // Settings. Name the row after the module, and fold the badge into the same label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge(for: m.id).map { "\(m.title), \($0) due soon" } ?? m.title)
        .accessibilityAddTraits(win.moduleID == m.id ? [.isButton, .isSelected] : .isButton)
        // A replaced element doesn't inherit the button's action: without this, VoiceOver
        // announced the row as a button and pressing it did nothing.
        .accessibilityAction { win.moduleID = m.id }
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
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(.sbSurface, in: Capsule())
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


/// The bottom-right corner grip that resizes the menu-bar popover.
///
/// `NSPopover` gives the user no way to resize it, which left three presets buried in Settings
/// as the only answer to "this is too small". Dragging here resizes the live popover and the
/// size is remembered for next time (see `PopoverSizing`).
private struct PopoverResizeGrip: View {
    @State private var startSize: CGSize?
    @State private var hovering = false

    var body: some View {
        Image(systemName: "line.diagonal")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help("Drag to resize — the size is remembered")
            .accessibilityHidden(true)
            .gesture(
                // Global space: the view itself moves as the popover grows, and a local
                // translation would then chase its own tail.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startSize ?? PopoverSizing.current?() ?? .zero
                        if startSize == nil { startSize = base }
                        guard base.width > 0 else { return }
                        PopoverSizing.apply?(CGSize(width: base.width + value.translation.width,
                                                    height: base.height + value.translation.height))
                    }
                    .onEnded { _ in startSize = nil })
    }
}
