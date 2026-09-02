import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("menuBarShow") private var menuBarShow = MenuBarContent.smart.rawValue
    @AppStorage("popoverSize") private var popoverSize = PopoverSize.medium.rawValue
    @AppStorage("menuBarClick") private var menuBarClick = "popover"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accentHex") private var accentHex = "#4F8DFD"
    @AppStorage(SurfaceTheme.storageKey) private var surfaceTheme = "system"
    @AppStorage("notifyClasses") private var notifyClasses = true
    @AppStorage("notifyAssignments") private var notifyAssignments = true
    @AppStorage("notifyClassLead") private var notifyClassLead = 10
    @AppStorage("globalHotkey") private var globalHotkey = false
    @AppStorage("onboarded") private var onboarded = true
    @AppStorage("focusAutomation") private var focusAutomation = false
    @AppStorage("focusStartShortcut") private var focusStartShortcut = ""
    @AppStorage("focusEndShortcut") private var focusEndShortcut = ""
    @AppStorage("spotlightIndex") private var spotlightIndex = true
    @AppStorage("notesAutocomplete") private var notesAutocomplete = false
    @AppStorage("aiProactive") private var aiProactive = false
    @AppStorage("notesFont") private var notesFont = "system"
    @AppStorage("notesFontSize") private var notesFontSize = 15.0
    @AppStorage("notesLineSpacing") private var notesLineSpacing = 3.5
    @AppStorage("showDock") private var showDock = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var iCloud = false
    @State private var exporting = false
    @State private var importing = false
    @State private var autoBackup = BackupManager.auto
    @State private var backupStatus = ""
    @State private var confirmClear = false
    @State private var confirmEmptyTrash = false
    @State private var pendingRestore: URL? = nil
    @State private var hotkeyTick = 0
    @State private var remindersStatus = ""
    @State private var canvasHost = ""
    @State private var canvasToken = ""
    @State private var canvasHasToken = false
    @State private var canvasStatus = ""
    @State private var canvasSyncing = false
    @State private var selectedTab = SettingsTab.general
    @State private var openRelease: String?
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
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            Form { tabSections }.formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if confirmEmptyTrash {
                ConfirmCard(title: "Empty Trash?",
                            message: "Permanently delete \(state.trashCount) item\(state.trashCount == 1 ? "" : "s") in the trash. This can't be undone.",
                            confirmLabel: "Empty Trash",
                            onConfirm: { state.emptyTrash(); confirmEmptyTrash = false },
                            onCancel: { confirmEmptyTrash = false })
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

    // MARK: Sections sidebar

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.title2.bold())
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 12)
                navGroup([.general, .appearance, .shortcuts])
                navSeparator
                navGroup([.modules, .integrations, .intelligence])
                navSeparator
                navGroup([.data, .openSource, .about])
            }
            .padding(10)
        }
        .frame(width: 216)
        .scrollIndicators(.hidden)
        .background(.sbSurface)
    }

    private var navSeparator: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 9)
    }

    @ViewBuilder private func navGroup(_ tabs: [SettingsTab]) -> some View {
        ForEach(tabs) { navRow($0) }
    }

    private func navRow(_ t: SettingsTab) -> some View {
        let sel = selectedTab == t
        let title = t == .data ? "Data & Backup" : t.rawValue
        return Button { selectedTab = t } label: {
            HStack(spacing: 11) {
                Image(systemName: t.icon).font(.system(size: 14)).frame(width: 20)
                Text(title).font(.callout.weight(sel ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sel ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(sel ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
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
        case .openSource:   openSourceSections
        case .about:        aboutSections
        }
    }

    @ViewBuilder private var generalSections: some View {
        Section("Menu Bar") {
            Picker("Show in menu bar", selection: $menuBarShow) {
                ForEach(MenuBarContent.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Clicking the icon opens", selection: $menuBarClick) {
                Text("Quick popover").tag("popover")
                Text("Main window").tag("window")
            }
            if menuBarClick == "popover" {
                Picker("Popover size", selection: $popoverSize) {
                    ForEach(PopoverSize.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Text("Reopen the popover to apply a new size. For a resizable view, open the window (⌘O).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The icon opens the main window; click again to hide it. Right-click still opens the quick-actions menu (new task, note, Pomodoro).")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            Toggle("Remind me before class", isOn: $notifyClasses)
            if notifyClasses {
                Stepper("Lead time: \(notifyClassLead) min", value: $notifyClassLead, in: 0...60, step: 5)
                    .font(.caption)
            }
            Toggle("Remind me about due assignments", isOn: $notifyAssignments)
            Text("Class reminders repeat weekly; assignment reminders fire the evening before, for work due in the next two weeks.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Send a test notification") { Notifier.post(title: "StudyBar", body: "Notifications are working.") }
            Text("If nothing appears, allow StudyBar in System Settings ▸ Notifications.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: notifyClasses) { _, _ in Notifier.rescheduleAll(state.data) }
        .onChange(of: notifyAssignments) { _, _ in Notifier.rescheduleAll(state.data) }
        .onChange(of: notifyClassLead) { _, _ in Notifier.rescheduleAll(state.data) }
        Section("Snippets") {
            Button("Manage snippets…") { state.selectedModuleID = "snippets" }
            Text("Reusable text with placeholders like {date}, {time} and {clipboard}. Expand them by keyword in the editor, or from the system Services menu — no need for a sidebar module.")
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
        Section("Theme") {
            Picker("Appearance", selection: $appearance) {
                Text("Light").tag("light"); Text("Dark").tag("dark"); Text("Device").tag("system")
            }.pickerStyle(.segmented)
            Picker("Surface", selection: $surfaceTheme) {
                ForEach(SurfaceTheme.allCases) { Text($0.label).tag($0.rawValue) }
            }.pickerStyle(.menu)
            Text("Near-black and Dim gray repaint dark mode; Warm paper repaints light mode. The other appearance stays native, and accent + status colors are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Accent") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 12)], spacing: 12) {
                ForEach(Palette.accents, id: \.self) { hex in accentSwatch(hex) }
            }
            .padding(.vertical, 6)
            LabeledContent("Custom") {
                ColorPicker("", selection: Binding(
                    get: { Color(hex: accentHex) ?? .accentColor },
                    set: { accentHex = $0.hexString }), supportsOpacity: false).labelsHidden()
            }
            Text("Status colors — due, overdue, done — keep their fixed red / amber / teal on every theme.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Notes") {
            Picker("Font", selection: $notesFont) {
                Text("System").tag("system"); Text("Serif").tag("serif"); Text("Mono").tag("mono")
            }.pickerStyle(.segmented)
            Picker("Text size", selection: $notesFontSize) {
                Text("Small").tag(13.0); Text("Medium").tag(15.0); Text("Large").tag(17.0)
            }.pickerStyle(.segmented)
            Picker("Line spacing", selection: $notesLineSpacing) {
                Text("Tight").tag(2.0); Text("Normal").tag(3.5); Text("Relaxed").tag(6.0)
            }.pickerStyle(.segmented)
            notesTypePreview
            Text("Applies to the Notes editor. Reopen a note to see the change.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var notesTypePreview: some View {
        let family: Font.Design = notesFont == "serif" ? .serif : (notesFont == "mono" ? .monospaced : .default)
        return VStack(alignment: .leading, spacing: CGFloat(notesLineSpacing)) {
            Text("Photosynthesis").font(.system(size: CGFloat(notesFontSize) + 5, weight: .bold, design: family))
            Text("Plants convert light into chemical energy — the body wants room to breathe.")
                .font(.system(size: CGFloat(notesFontSize), design: family))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func accentSwatch(_ hex: String) -> some View {
        let selected = accentHex.caseInsensitiveCompare(hex) == .orderedSame
        let color = Color(hex: hex) ?? .gray
        return Button { accentHex = hex } label: {
            RoundedRectangle(cornerRadius: 9).fill(color).frame(width: 36, height: 36)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(color, lineWidth: selected ? 2 : 0).padding(-3))
                .shadow(color: color.opacity(selected ? 0.45 : 0.18), radius: selected ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(hex)
        .accessibilityLabel("Accent \(hex)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    @ViewBuilder private var recentlyDeletedSection: some View {
        if let trash = state.data.trash, !trash.isEmpty {
            Section("Recently Deleted (\(trash.count))") {
                ForEach(trash.sorted { $0.deletedAt > $1.deletedAt }) { t in
                    HStack(spacing: 10) {
                        Image(systemName: t.symbol).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.label).lineLimit(1)
                            Text(t.deletedAt.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { state.restoreFromTrash([t.id]) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless).help("Restore")
                        Button(role: .destructive) { state.purgeFromTrash([t.id]) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Delete forever")
                    }
                }
                HStack {
                    Button("Restore all") { state.restoreFromTrash(Set(trash.map(\.id))) }
                    Spacer()
                    Button("Empty Trash", role: .destructive) { confirmEmptyTrash = true }
                }
                Text("Deleted items are kept here for 30 days, then removed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        recentlyDeletedSection
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
                TextField("Model (e.g. qwen2.5:7b)", text: $aiModel).onSubmit { saveAIModel() }
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
                Text("Install Ollama from ollama.com, then run `ollama pull \(aiModel.isEmpty ? "qwen2.5:7b" : aiModel)` in Terminal. qwen2.5 follows formatting and math far better than llama3.1. Runs fully on your Mac — no key, no cloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Smart typing") {
                Toggle("Autocomplete in Notes", isOn: $notesAutocomplete)
                Text("As you type in a note, Ollama suggests the next few words in grey — press Tab to accept. Runs on your Mac, only with a local (Ollama) engine. It finishes your phrasing, not your homework.")
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

        Section("Inline AI") {
            Toggle("Suggest actions as I work", isOn: $aiProactive)
            Text("Off by default — AI stays out of the way until you invoke it (the ✨ on any text). Turn this on and StudyBar adds a gentle, dismissible chip when it could help — e.g. \"Summarize?\" on a long note. Still a suggestion you accept; nothing is applied on its own.")
                .font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder private var openSourceSections: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("StudyBar is built on free, open-source software.").font(.callout.weight(.medium))
                    Text("\(Dependencies.all.count) components, all under permissive licenses (\(Dependencies.licenses.joined(separator: ", "))). Everything runs on-device — nothing here phones home.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Direct dependencies") {
            ForEach(Dependencies.direct) { depRow($0) }
        }
        Section("Also included") {
            Text("Pulled in automatically by the libraries above.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Dependencies.transitive) { depRow($0) }
        }
        Section("Updates") {
            Label("Libraries are compiled into StudyBar and update with each app release — there's nothing to update separately here.",
                  systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            Link(destination: URL(string: "https://github.com/hqn07/studybar")!) {
                Label("StudyBar source & release notes", systemImage: "arrow.up.right.square")
            }.font(.caption)
        }
    }

    private func depRow(_ d: Dependency) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(d.name).font(.callout.weight(.semibold))
                Text("v\(d.version)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(d.license).font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(.tint)
                Spacer(minLength: 6)
                Link(destination: URL(string: d.url)!) {
                    Image(systemName: "arrow.up.right.square")
                }.help("Open \(d.name) on GitHub").font(.callout)
            }
            Text(d.purpose).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.name), version \(d.version), \(d.license) license. \(d.purpose)")
    }

    @ViewBuilder private var aboutSections: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            Text("Free & open source. A menu bar study companion.")
                .font(.caption).foregroundStyle(.secondary)
            Link(destination: feedbackMailURL) {
                Label("Send feedback by email", systemImage: "envelope")
            }
            Text("Email gets the fastest reply — GitHub is checked less often.")
                .font(.caption2).foregroundStyle(.secondary)
            Link(destination: URL(string: "https://github.com/hqn07/studybar/issues/new/choose")!) {
                Label("Report a bug (GitHub)", systemImage: "ladybug")
            }
            Link(destination: URL(string: "https://github.com/hqn07/studybar/discussions")!) {
                Label("Ideas & questions (Discussions)", systemImage: "bubble.left.and.bubble.right")
            }
        }
        releaseNotesSection
    }

    @ViewBuilder private var releaseNotesSection: some View {
        let releases = Changelog.releases()
        if !releases.isEmpty {
            Section("Release Notes") {
                ForEach(releases.prefix(12)) { rel in
                    DisclosureGroup(isExpanded: Binding(
                        get: { (openRelease ?? releases.first?.version) == rel.version },
                        set: { openRelease = $0 ? rel.version : "" })) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(rel.notes.indices, id: \.self) { i in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(changeMarkdown(rel.notes[i])).font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.padding(.top, 4)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Version \(rel.version)").font(.callout.weight(.medium))
                            if !rel.date.isEmpty { Text(rel.date).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    /// A mailto: to the maintainer, pre-filled with a subject and the version/OS footer.
    private var feedbackMailURL: URL {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = "unrest.green_6d@icloud.com"
        c.queryItems = [
            URLQueryItem(name: "subject", value: "StudyBar feedback (v\(v))"),
            URLQueryItem(name: "body", value: "\n\n\n———\nStudyBar \(v) · \(os)"),
        ]
        return c.url ?? URL(string: "mailto:unrest.green_6d@icloud.com")!
    }

    /// Render a changelog bullet's inline markdown (**bold**, `code`, *italic*).
    private func changeMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
                .background(.sbSurface, in: RoundedRectangle(cornerRadius: 4))
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
    case intelligence = "Intelligence", openSource = "Open Source", about = "About"
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
        case .openSource: return "shippingbox"
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
