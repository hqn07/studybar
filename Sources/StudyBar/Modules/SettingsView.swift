import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("menuBarShow") private var menuBarShow = MenuBarContent.smart.rawValue
    @AppStorage("popoverSize") private var popoverSize = PopoverSize.medium.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("density") private var density = "comfortable"
    @AppStorage("accentHex") private var accentHex = "#4F8DFD"
    @AppStorage("globalHotkey") private var globalHotkey = false
    @AppStorage("onboarded") private var onboarded = true
    @AppStorage("focusAutomation") private var focusAutomation = false
    @AppStorage("focusStartShortcut") private var focusStartShortcut = ""
    @AppStorage("focusEndShortcut") private var focusEndShortcut = ""
    @AppStorage("spotlightIndex") private var spotlightIndex = true
    @AppStorage("showDock") private var showDock = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var iCloud = false
    @State private var exporting = false
    @State private var importing = false
    @State private var autoBackup = BackupManager.auto
    @State private var backupStatus = ""
    @State private var confirmClear = false
    @State private var pendingRestore: URL? = nil
    @State private var hotkeyTick = 0
    @State private var remindersStatus = ""
    @State private var canvasHost = ""
    @State private var canvasToken = ""
    @State private var canvasHasToken = false
    @State private var canvasStatus = ""
    @State private var canvasSyncing = false
    @State private var selectedTab = SettingsTab.general
    // Intelligence
    @State private var aiMode = AIConfig.mode
    @State private var aiKey = ""
    @State private var aiHasKey = false
    @State private var aiModel = ""
    @State private var aiHost = ""
    @State private var aiStatus = ""
    @State private var aiTesting = false
    @State private var starterStatus = ""

    var body: some View {
        ModulePane(title: "Settings") { EmptyView() } content: {
            VStack(spacing: 0) {
                tabBar
                Divider()
                Form { tabSections }.formStyle(.grouped)
            }
        }
        .fileExporter(isPresented: $exporting,
                      document: JSONFile(url: state.dataFileURL),
                      contentType: .json, defaultFilename: "studybar-backup") { _ in }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { importData(url) }
        }
        .onAppear {
            iCloud = state.usingICloud; autoBackup = BackupManager.auto
            canvasHost = CanvasService.host; canvasHasToken = CanvasService.hasToken
            loadAI()
        }
        .overlay {
            if confirmClear {
                ConfirmCard(title: "Erase all data?",
                            message: "This deletes every course, note, assignment, deck and setting on this Mac. You can undo right after with ⌘Z.",
                            confirmLabel: "Erase everything",
                            onConfirm: { state.withUndo("Erased all data") { state.data = AppData() }; confirmClear = false },
                            onCancel: { confirmClear = false })
            }
        }
        .overlay {
            if let url = pendingRestore {
                ConfirmCard(title: "Restore this backup?",
                            message: "Replaces your current data with the backup from \(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "studybar-backup-", with: "")). Undoable with ⌘Z.",
                            confirmLabel: "Restore", destructive: false,
                            onConfirm: {
                                if let d = BackupManager.load(url) { state.withUndo("Restored backup") { state.data = d } }
                                pendingRestore = nil
                            },
                            onCancel: { pendingRestore = nil })
            }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { t in
                    Button { selectedTab = t } label: {
                        HStack(spacing: 4) {
                            Image(systemName: t.icon)
                            Text(t.rawValue)
                        }
                        .font(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(selectedTab == t ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.background.secondary), in: Capsule())
                        .foregroundStyle(selectedTab == t ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 10).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var tabSections: some View {
        switch selectedTab {
        case .general:      generalSections
        case .appearance:   appearanceSections
        case .shortcuts:    shortcutsSections
        case .modules:      Section("Modules") { ModuleManagerSection(prefs: state.modulePrefs) }
        case .data:         dataSections
        case .integrations: integrationsSections
        case .intelligence: intelligenceSections
        case .about:        aboutSections
        }
    }

    @ViewBuilder private var generalSections: some View {
        Section("Menu Bar") {
            Picker("Show in menu bar", selection: $menuBarShow) {
                ForEach(MenuBarContent.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Popover size", selection: $popoverSize) {
                ForEach(PopoverSize.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Text("Reopen the popover to apply a new size. For a resizable view, open the window (⌘O).")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Startup") {
            Toggle("Launch StudyBar at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
        }
        Section("Window") {
            Toggle("Show StudyBar in the Dock", isOn: $showDock)
                .onChange(of: showDock) { _, v in
                    NSApp.setActivationPolicy(v ? .regular : .accessory)
                    if v { NSApp.activate(ignoringOtherApps: true) }
                }
            Text("Adds a Dock icon and a full app menu. StudyBar stays in the menu bar either way.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Breaks") {
            Toggle("Break reminders", isOn: Binding(get: { state.breaks.enabled }, set: { state.breaks.enabled = $0 }))
            if state.breaks.enabled {
                Stepper("Remind me every \(state.breaks.intervalMinutes) min", value: Binding(
                    get: { state.breaks.intervalMinutes }, set: { state.breaks.intervalMinutes = $0 }), in: 10...180, step: 5)
            }
        }
        Section("Notifications") {
            Button("Send a test notification") { Notifier.post(title: "StudyBar", body: "Notifications are working.") }
            Text("If nothing appears, allow StudyBar in System Settings ▸ Notifications.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Starter Content") {
            HStack {
                Button("Add study links") { starterStatus = "Added \(StarterContent.addLinks(state)) links." }
                Button("Add snippets") { starterStatus = "Added \(StarterContent.addSnippets(state)) snippets." }
                Button("Add getting-started tasks") { starterStatus = "Added \(StarterContent.addTodos(state)) tasks." }
            }
            if !starterStatus.isEmpty { Text(starterStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Curated free resources, useful snippets, and a setup checklist. Safe to tap again — duplicates are skipped.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var appearanceSections: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
            Picker("Density", selection: $density) {
                Text("Comfortable").tag("comfortable"); Text("Compact").tag("compact")
            }.pickerStyle(.segmented)
            LabeledContent("Accent") {
                HStack(spacing: 6) {
                    ForEach(Palette.swatches.prefix(6), id: \.self) { hex in
                        Button { accentHex = hex } label: {
                            Circle().fill(Color(hex: hex) ?? .gray).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.primary, lineWidth: accentHex == hex ? 2 : 0))
                        }.buttonStyle(.plain)
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: accentHex) ?? .accentColor }, set: { accentHex = $0.hexString })).labelsHidden()
                }
            }
        }
    }

    @ViewBuilder private var shortcutsSections: some View {
        Section("Global Shortcuts") {
            Toggle("Global shortcuts (work from any app)", isOn: $globalHotkey)
                .onChange(of: globalHotkey) { _, v in HotKeyManager.shared.setEnabled(v) }
            if globalHotkey {
                ForEach(HotAction.allCases) { a in
                    LabeledContent(a.title) {
                        HStack(spacing: 6) {
                            KeyRecorder(display: HotKeyStore.display(HotKeyStore.binding(a))) { b in
                                HotKeyStore.set(a, b); GlobalShortcuts.configure(); hotkeyTick += 1
                            }
                            Button { HotKeyStore.reset(a); GlobalShortcuts.configure(); hotkeyTick += 1 } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }.buttonStyle(.borderless).help("Reset to default")
                        }
                    }
                }
                .id(hotkeyTick)
            } else {
                Text("Turn on to use ⌃⌥N (note), ⌃⌥T (task), ⌃⌥P (Pomodoro) and ⌃⌥S (palette) system-wide. Click a shortcut to rebind it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("In-App Shortcuts") {
            shortcut("⌘K", "Command palette")
            shortcut("⌘O", "Open resizable window")
            shortcut("⌘[", "Back (in editors)")
            shortcut("⌘Q", "Quit StudyBar")
        }
        Section("Focus Automation") {
            Toggle("Run a Shortcut when focus starts / ends", isOn: $focusAutomation)
            if focusAutomation {
                TextField("On focus start (Shortcut name, e.g. DND On)", text: $focusStartShortcut)
                TextField("On focus end (Shortcut name, e.g. DND Off)", text: $focusEndShortcut)
            }
            Text("macOS has no direct API to toggle a Focus. In the Shortcuts app, make shortcuts that turn a Focus (e.g. Do Not Disturb) on and off, name them here, and StudyBar will run them around Pomodoro focus sessions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var dataSections: some View {
        Section("Data") {
            Toggle("Sync via iCloud Drive", isOn: $iCloud)
                .disabled(!state.iCloudAvailable)
                .onChange(of: iCloud) { _, v in state.setICloud(v) }
            HStack {
                Button("Export…") { exporting = true }
                Button("Import…") { importing = true }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([state.dataFileURL]) }
            }
            Toggle("Daily auto-backup", isOn: $autoBackup)
                .onChange(of: autoBackup) { _, v in
                    BackupManager.auto = v
                    if v && !BackupManager.hasFolder { _ = BackupManager.chooseFolder(); refreshBackup() }
                }
            HStack {
                Button("Choose folder…") { if BackupManager.chooseFolder() { refreshBackup() } }
                Button("Back up now") {
                    if !BackupManager.hasFolder { _ = BackupManager.chooseFolder() }
                    backupStatus = BackupManager.backupNow(state.data) ? "Backed up ✓" : "Backup failed"
                }
                let backups = BackupManager.listBackups()
                Menu("Restore…") {
                    if backups.isEmpty {
                        Text("No backups found")
                    } else {
                        ForEach(backups, id: \.url) { b in
                            Button(b.date.formatted(date: .abbreviated, time: .shortened)) { pendingRestore = b.url }
                        }
                    }
                }.disabled(backups.isEmpty)
            }
            Text(backupInfo).font(.caption).foregroundStyle(backupStatus.contains("✓") ? .green : .secondary)
        }
        Section("Spotlight") {
            Toggle("Index notes & assignments in Spotlight", isOn: $spotlightIndex)
                .onChange(of: spotlightIndex) { _, v in
                    if v { SpotlightIndexer.reindex(state.data) } else { SpotlightIndexer.clear() }
                }
            Button("Rebuild Spotlight index") { SpotlightIndexer.reindex(state.data) }.disabled(!spotlightIndex)
            Text("Find notes and open assignments from system-wide Spotlight; opening a result launches StudyBar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Storage") { statsCard }
        Section("Danger Zone") {
            Button { onboarded = false } label: { Label("Show welcome again", systemImage: "sparkles") }
            Button(role: .destructive) { confirmClear = true } label: { Label("Erase all data…", systemImage: "trash") }
        }
    }

    @ViewBuilder private var integrationsSections: some View {
        Section("Canvas") {
            TextField("Canvas URL (e.g. canvas.university.edu)", text: $canvasHost)
            SecureField(canvasHasToken ? "Access token saved — enter to replace" : "Access token", text: $canvasToken)
            HStack {
                Button("Save") {
                    CanvasService.host = canvasHost.trimmingCharacters(in: .whitespaces)
                    if !canvasToken.isEmpty {
                        Keychain.set(canvasToken, account: CanvasService.tokenAccount)
                        canvasToken = ""; canvasHasToken = true
                    }
                    canvasStatus = "Saved."
                }
                Button("Sync now") {
                    Task { canvasSyncing = true; canvasStatus = await CanvasService.sync(state: state); canvasSyncing = false }
                }.disabled(canvasSyncing || canvasHost.isEmpty || (!canvasHasToken && canvasToken.isEmpty))
                if canvasSyncing { ProgressView().controlSize(.small) }
                Spacer()
                if canvasHasToken {
                    Button("Remove", role: .destructive) {
                        Keychain.delete(account: CanvasService.tokenAccount); canvasHasToken = false; canvasStatus = "Token removed."
                    }
                }
            }
            if !canvasStatus.isEmpty { Text(canvasStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Get a token in Canvas: Account ▸ Settings ▸ + New Access Token. Stored in your macOS Keychain, never in the data file. Sync pulls active courses + upcoming assignments.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Apple & Automation") {
            Button("Push assignments to Reminders") {
                Task { remindersStatus = await RemindersService.push(state.data) }
            }
            if !remindersStatus.isEmpty { Text(remindersStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Also: Shortcuts.app actions, the Services menu (select text ▸ Add to StudyBar), and the studybar:// URL scheme.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var intelligenceSections: some View {
        Section("Assistant Engine") {
            Picker("Engine", selection: $aiMode) {
                ForEach(AIMode.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: aiMode) { _, m in AIConfig.mode = m; loadAI() }
            Text(aiMode.subtitle).font(.caption).foregroundStyle(.secondary)

            if aiMode == .onDevice && !AIConfig.onDeviceAvailable {
                Label("On-device model unavailable on this Mac. Needs macOS 26+ with Apple Intelligence enabled — or pick Claude / ChatGPT.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }

        if aiMode.needsKey {
            Section(aiMode == .claude ? "Anthropic API" : "OpenAI API") {
                SecureField(aiHasKey ? "Key saved — enter to replace" : "API key", text: $aiKey)
                TextField("Model", text: $aiModel)
                    .onSubmit { saveAIModel() }
                HStack {
                    Button("Save") { saveAIKey() }
                    Button("Test connection") {
                        saveAIModel()
                        Task { aiTesting = true; aiStatus = await AIService.test(); aiTesting = false }
                    }
                    .disabled(aiTesting || (!aiHasKey && aiKey.isEmpty))
                    if aiTesting { ProgressView().controlSize(.small) }
                    Spacer()
                    if aiHasKey {
                        Button("Remove", role: .destructive) {
                            if let acct = aiMode.keyAccount { Keychain.delete(account: acct) }
                            aiHasKey = false; aiStatus = "Key removed."
                        }
                    }
                }
                if !aiStatus.isEmpty {
                    Text(aiStatus).font(.caption)
                        .foregroundStyle(aiStatus.hasPrefix("✓") ? .green : (aiStatus.hasPrefix("✗") ? .red : .secondary))
                }
                Text(aiMode == .claude
                     ? "A Claude Pro/Max subscription is NOT an API key. Create a developer key at console.anthropic.com ▸ API Keys (pay-as-you-go). Stored in your macOS Keychain."
                     : "A ChatGPT Plus subscription is NOT an API key. Create a developer key at platform.openai.com ▸ API keys. Stored in your macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if aiMode == .ollama {
            Section("Ollama (local)") {
                TextField("Model (e.g. llama3.1)", text: $aiModel).onSubmit { saveAIModel() }
                TextField("Server URL", text: $aiHost).onSubmit { AIConfig.ollamaHost = aiHost.trimmingCharacters(in: .whitespaces) }
                Button("Test connection") {
                    saveAIModel(); AIConfig.ollamaHost = aiHost.trimmingCharacters(in: .whitespaces)
                    Task { aiTesting = true; aiStatus = await AIService.test(); aiTesting = false }
                }.disabled(aiTesting)
                if aiTesting { ProgressView().controlSize(.small) }
                if !aiStatus.isEmpty {
                    Text(aiStatus).font(.caption)
                        .foregroundStyle(aiStatus.hasPrefix("✓") ? .green : (aiStatus.hasPrefix("✗") ? .red : .secondary))
                }
                Text("Install Ollama from ollama.com, then run `ollama pull \(aiModel.isEmpty ? "llama3.1" : aiModel)` in Terminal. Runs fully on your Mac — no key, no cloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if aiMode == .onDevice {
            Section("On-device") {
                Button("Test connection") {
                    Task { aiTesting = true; aiStatus = await AIService.test(); aiTesting = false }
                }.disabled(aiTesting || !AIConfig.onDeviceAvailable)
                if aiTesting { ProgressView().controlSize(.small) }
                if !aiStatus.isEmpty {
                    Text(aiStatus).font(.caption)
                        .foregroundStyle(aiStatus.hasPrefix("✓") ? .green : (aiStatus.hasPrefix("✗") ? .red : .secondary))
                }
            }
        }

        Section("Boundaries") {
            Label("Organizes, never tutors. The assistant sorts and schedules your own data — it won't explain material, answer questions, or write assignments.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            if aiMode == .claude || aiMode == .openai {
                Label("Cloud mode sends only the items in scope for a request (never your whole data file) to \(aiMode == .claude ? "Anthropic" : "OpenAI").",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            } else if aiMode == .onDevice || aiMode == .ollama {
                Label("Local mode keeps everything on this Mac — nothing is sent anywhere.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadAI() {
        aiMode = AIConfig.mode
        aiKey = ""
        aiHasKey = aiMode.needsKey && AIConfig.hasKey(aiMode)
        switch aiMode {
        case .openai: aiModel = AIConfig.openaiModel
        case .ollama: aiModel = AIConfig.ollamaModel
        default:      aiModel = AIConfig.claudeModel
        }
        aiHost = AIConfig.ollamaHost
        aiStatus = ""
    }
    private func saveAIModel() {
        let m = aiModel.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        switch aiMode {
        case .openai: AIConfig.openaiModel = m
        case .ollama: AIConfig.ollamaModel = m
        default:      AIConfig.claudeModel = m
        }
    }
    private func saveAIKey() {
        saveAIModel()
        guard aiMode.needsKey, let acct = aiMode.keyAccount else { return }
        let k = aiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { Keychain.set(k, account: acct); aiKey = ""; aiHasKey = true; aiStatus = "Saved." }
    }

    @ViewBuilder private var aboutSections: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Text("Free & open source. A menu bar study companion.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private var backupInfo: String {
        if !backupStatus.isEmpty { return backupStatus }
        var s = BackupManager.folderName.map { "Folder: \($0)" } ?? "No backup folder chosen."
        if let l = BackupManager.last { s += " · last \(l.relativeShort)" }
        return s
    }
    private func refreshBackup() { backupStatus = BackupManager.hasFolder ? "Folder set ✓" : "" }

    private var statsCard: some View {
        let d = state.data
        let attrs = try? FileManager.default.attributesOfItem(atPath: state.dataFileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let rows: [(String, Int)] = [
            ("Courses", d.courses.count), ("Assignments", d.assignments.count), ("Notes", d.notes.count),
            ("To-dos", d.todos.count), ("Flashcards", d.flashcards.count), ("Citations", d.references.count),
            ("Books", d.reading.count), ("Links", d.links.count), ("Clips", d.clips.count),
        ]
        return VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: Array(repeating: .init(.flexible(), alignment: .leading), count: 3), spacing: 4) {
                ForEach(rows, id: \.0) { r in
                    HStack(spacing: 4) { Text("\(r.1)").fontWeight(.semibold); Text(r.0).foregroundStyle(.secondary) }
                        .font(.caption)
                }
            }
            Text("Data size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func shortcut(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(key).font(.caption.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 4))
            Text(desc).font(.caption)
            Spacer()
        }
    }

    private func importData(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.studybar.decode(AppData.self, from: raw) {
            state.data = decoded
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", shortcuts = "Shortcuts"
    case modules = "Modules", data = "Data", integrations = "Integrations"
    case intelligence = "Intelligence", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .modules: return "square.grid.2x2"
        case .data: return "externaldrive"
        case .integrations: return "puzzlepiece.extension"
        case .intelligence: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

/// Order, show/hide and favorite each module.
struct ModuleManagerSection: View {
    @ObservedObject var prefs: ModulePrefs

    private var rows: [ModuleInfo] {
        prefs.order == .custom
            ? prefs.orderedIDs().compactMap { ModuleRegistry.info($0) }
            : ModuleRegistry.all
    }

    var body: some View {
        Group {
            Picker("Sidebar order", selection: $prefs.order) {
                ForEach(OrderMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text(hint).font(.caption).foregroundStyle(.secondary)
            if prefs.order == .category {
                let cats = prefs.orderedCategories()
                ForEach(Array(cats.enumerated()), id: \.element) { i, cat in
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            Button { prefs.moveCategory(cat.rawValue, up: true) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(i == 0)
                            Button { prefs.moveCategory(cat.rawValue, up: false) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(i == cats.count - 1)
                        }.font(.caption2)
                        Text(cat.rawValue)
                        Spacer()
                        Text("category").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                HStack(spacing: 8) {
                    if prefs.order == .custom {
                        HStack(spacing: 2) {
                            Button { prefs.move(m.id, up: true) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(i == 0)
                            Button { prefs.move(m.id, up: false) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(i == rows.count - 1)
                        }.font(.caption2)
                    }
                    Button { prefs.toggleFavorite(m.id) } label: {
                        Image(systemName: prefs.isFavorite(m.id) ? "star.fill" : "star")
                            .foregroundStyle(prefs.isFavorite(m.id) ? .yellow : .secondary)
                    }.buttonStyle(.borderless)
                    Image(systemName: m.symbol).frame(width: 18).foregroundStyle(.tint)
                    Text(m.title)
                    Spacer()
                    if ModulePrefs.locked.contains(m.id) {
                        Text("Always on").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { prefs.isVisible(m.id) },
                            set: { _ in prefs.toggleHidden(m.id) })).labelsHidden()
                    }
                }
            }
        }
    }

    private var hint: String {
        switch prefs.order {
        case .category: "Grouped by category. Star to pin to Favorites; uncheck to hide."
        case .mostUsed: "Auto-sorted by how often you open each module. Star to pin; uncheck to hide."
        case .custom:   "Use ▲▼ to set your own order. Star to pin; uncheck to hide."
        }
    }
}

/// Minimal file wrapper for export.
struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(url: URL) { data = (try? Data(contentsOf: url)) ?? Data() }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
