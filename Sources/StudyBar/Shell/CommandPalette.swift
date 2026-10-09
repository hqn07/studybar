import SwiftUI

/// (55) ⌘K command palette: jump to modules + quick actions, keyboard-driven.
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @Binding var isPresented: Bool
    var standalone: Bool = false          // true = shown in its own floating panel
    /// The window's selected row — its actions lead the palette. Nil in the floating panel.
    var selection: ItemRef? = nil
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
        /// The header the row sits under in the empty palette ("Recent", "Go to", an item's title).
        var section: String? = nil
        /// A key that does the same, shown at the row's end.
        var shortcut: String? = nil
        /// What ⌘K remembers when this runs: the item's key; nil → `"cmd:<title>"`.
        var recentKey: String? = nil
        let run: () -> Void
    }

    /// A global hotkey's keys, when the hotkeys are on.
    private func hotkey(_ a: HotAction) -> String? {
        UserDefaults.standard.bool(forKey: "globalHotkey") ? HotKeyStore.display(HotKeyStore.binding(a)) : nil
    }

    private var actions: [Action] { quickActions + moduleJumps }

    /// Every module, the sidebar's first nine with ⌘1–⌘9.
    private var moduleJumps: [Action] {
        let order = SidebarLayout.shortcutOrder(prefs: state.modulePrefs)
        let modules = order.compactMap { ModuleRegistry.info($0) } + ModuleRegistry.all.filter { !order.contains($0.id) }
        return modules.map { m in
            let i = order.firstIndex(of: m.id)
            return Action(title: m.title, subtitle: "Go to · \(m.category.rawValue)", symbol: m.symbol, section: "Go to",
                          shortcut: i.map { "⌘\($0 + 1)" }) { go(m.id) }
        }
    }

    private var quickActions: [Action] {
        var out: [Action] = []
        // Quick actions
        out.append(.init(title: "New Note", subtitle: "Capture", symbol: "note.text") { newIn("notes") })
        out.append(.init(title: "New Assignment", subtitle: "Assignments", symbol: "checklist") { newIn("assignments") })
        out.append(.init(title: "New Task", subtitle: "Assignments", symbol: "checkmark.circle") { newIn("assignments") })
        out.append(.init(title: state.pomodoro.running ? "Pause Pomodoro" : "Start Pomodoro",
                         subtitle: "Time & Focus", symbol: "timer", shortcut: hotkey(.pomodoro)) {
            state.pomodoro.toggle(); isPresented = false
        })
        out.append(.init(title: "Calculator", subtitle: "Math", symbol: "function", shortcut: hotkey(.calculator)) {
            isPresented = false; CalculatorPanel.shared.show()
        })
        out.append(.init(title: "Capture from Screen", subtitle: "Text · LaTeX · ask the tutor", symbol: "text.viewfinder", shortcut: hotkey(.capture)) {
            isPresented = false; ScreenGrab.start()
        })
        out.append(.init(title: "Open in Window", subtitle: "View", symbol: "macwindow") {
            WindowOpener.open?("main"); isPresented = false
        })
        if AIConfig.isReady {
            out.append(.init(title: "Assistant", subtitle: "Ask · plan · cross-note jobs", symbol: "sparkles") {
                isPresented = false; AssistantPanel.shared.show()
            })
        }
        out.append(.init(title: "Quit StudyBar", subtitle: "App", symbol: "power") { NSApp.terminate(nil) })
        return out
    }

    /// The selected item's actions — the same list as its row's context menu.
    private var selectionActions: [Action] {
        guard let ref = selection, let title = ItemActions.title(of: ref, in: state.data) else { return [] }
        return ItemActions.actions(for: ref, state: state).map { a in
            Action(title: a.title, subtitle: "", symbol: a.systemImage, section: title, shortcut: a.shortcut,
                   recentKey: ref.recentKey) { isPresented = false; a.run() }
        }
    }

    /// Recents as rows: an item opens (its first action), a command runs again; anything that
    /// no longer exists is left out. Static so the self-test can check it.
    @MainActor static func recentActions(_ entries: [String], state: AppState, commands: [Action]) -> [Action] {
        entries.compactMap { e in
            if let ref = ItemRef(recentKey: e) {
                guard let title = ItemActions.title(of: ref, in: state.data),
                      let open = ItemActions.actions(for: ref, state: state).first else { return nil }
                let (kind, symbol) = recentLabel(ref)
                return Action(title: title, subtitle: kind, symbol: symbol, section: "Recent", recentKey: e, run: open.run)
            }
            guard e.hasPrefix("cmd:"), let c = commands.first(where: { $0.title == String(e.dropFirst(4)) }) else { return nil }
            return Action(title: c.title, subtitle: c.subtitle, symbol: c.symbol, section: "Recent", shortcut: c.shortcut, run: c.run)
        }
    }

    private static func recentLabel(_ ref: ItemRef) -> (String, String) {
        switch ref {
        case .note: ("Note", "note.text")
        case .assignment: ("Assignment", "checklist")
        case .deck: ("Deck", "rectangle.on.rectangle.angled")
        case .book: ("Book", "book")
        case .link: ("Link", "link")
        case .readLater: ("Read later", "books.vertical")
        case .citation: ("Citation", "quote.opening")
        case .snippet: ("Snippet", "text.badge.plus")
        }
    }

    /// The student's own material, ranked — see `PaletteSearch`, which is where the ranking
    /// lives so it can be tested (`StudyBar --palette-selftest`).
    ///
    /// The palette could jump to *Notes* but not to *a note*: opening one meant the window,
    /// the list, a mouse-only search field, then a click. This is the shortest path in the app
    /// and it should reach the thing, not the room it lives in.
    private var contentMatches: [Action] {
        var hits = PaletteSearch.hits(query, data: state.data) { id in
            state.course(id).map { $0.code.isEmpty ? $0.name : $0.code }
        }
        // The words inside books and course files, after the closer matches.
        hits += MaterialSearch.hits(query, data: state.data, perSource: 1, limit: 3).map { h in
            switch h.source {
            case .book(let id, let page): return .init(kind: .book(id, page: page), title: "\(h.title), \(h.locator)", detail: h.snippet, score: 0)
            case .file(let id): return .init(kind: .file(id), title: h.locator.isEmpty ? h.title : "\(h.title), \(h.locator)", detail: h.snippet, score: 0)
            }
        }
        return hits.prefix(8).map { hit in
            switch hit.kind {
            case .note(let id):
                return .init(title: hit.title, subtitle: hit.detail, symbol: "note.text", recentKey: ItemRef.note(id).recentKey) {
                    isPresented = false
                    WindowOpener.open?("main")
                    state.globalSearch = ""
                    state.pendingOpenNote = id
                    state.selectedModuleID = "notes"
                }
            case .assignment:
                return .init(title: hit.title, subtitle: hit.detail, symbol: "checklist") { go("assignments") }
            case .deck(let id):
                return .init(title: hit.title, subtitle: hit.detail, symbol: "rectangle.on.rectangle.angled", recentKey: ItemRef.deck(id).recentKey) {
                    state.pendingDeck = id
                    go("flashcards")
                }
            case .book(let id, let page):
                return .init(title: hit.title, subtitle: hit.detail, symbol: page == nil ? "book" : "book.pages", recentKey: ItemRef.book(id).recentKey) {
                    state.pendingBook = .init(id: id, page: page)
                    go("reading")
                }
            case .file(let id):
                return .init(title: hit.title, subtitle: hit.detail, symbol: "doc.text") {
                    isPresented = false
                    if let f = state.data.studyFiles?.first(where: { $0.id == id }) { NSWorkspace.shared.open(StudyMaterial.fileURL(f)) }
                }
            }
        }
    }

    private var filtered: [Action] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return PaletteSections.emptyQuery(selection: selectionActions,
                                              recents: Self.recentActions(PaletteRecents.current, state: state, commands: actions),
                                              goTo: moduleJumps, others: quickActions.map { a in
                                                  var a = a; a.section = "Actions"; return a
                                              })
        }
        var out = selectionActions.filter { $0.title.localizedCaseInsensitiveContains(q) }
        out += contentMatches
        out += actions.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
        // Arithmetic answers itself, at the top, without opening anything. `looksCalculable`
        // requires an operator and a successful evaluation, so a note title or a course code
        // never turns the palette into a calculator.
        if MathEval.looksCalculable(q),
           let r = try? MathEval.evaluate(q, angle: CalculatorPanel.shared.model.angle) {
            out.insert(.init(title: "= \(r.display)", subtitle: "Copy · ↩ · open in Calculator with ⌥↩",
                             symbol: "function") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(r.display, forType: .string)
                isPresented = false
            }, at: 0)
        } else if let u = UnitConvert.run(q) {
            out.insert(.init(title: "= \(u.display)", subtitle: "Copy · ↩", symbol: "ruler") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.display, forType: .string)
                isPresented = false
            }, at: 0)
        }
        if AIConfig.isReady {
            out.append(.init(title: "Ask Assistant: “\(q)”", subtitle: "Intelligence", symbol: "sparkles") {
                isPresented = false
                AppActions.assistant(q)   // opens the summoned assistant panel
            })
        }
        return out
    }

    var body: some View {
        Group {
            if standalone {
                card
            } else {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { isPresented = false }
                    card.padding(.top, 60)
                }
            }
        }
        // Deferred, like Ask's field: focused right away, the field often isn't in the window
        // yet, so the header search kept the keyboard — ⌘K, then typing, searched instead, and
        // Escape (handled by this field) couldn't close the palette.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Type a command, a note, a deck…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onChange(of: query) { _, _ in selected = 0 }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { runSelected(); return .handled }
                    // Not onKeyPress(.escape): a focused text field takes Escape as its own
                    // cancel command, so that handler never ran and Escape left the palette open.
                    .onExitCommand { isPresented = false }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Keyed by position. Each Action gets a new UUID whenever the list is
                        // rebuilt, and the extra `.id(i)` pinned rows to their index, so the lazy
                        // stack kept drawing the old rows: typing "3 ft in cm" gave the right
                        // number of rows under the wrong titles, and ↩ ran one you couldn't see.
                        let list = filtered
                        ForEach(Array(list.enumerated()), id: \.offset) { i, a in
                            VStack(alignment: .leading, spacing: 2) {
                                if let sec = a.section, i == 0 || list[i - 1].section != sec {
                                    Text(sec.uppercased()).font(.caption2.weight(.bold)).tracking(0.5)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                        .padding(.horizontal, 10).padding(.top, i == 0 ? 2 : 8)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                row(a, active: i == selected).onTapGesture { run(a) }
                                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                                    .accessibilityAction { run(a) }
                            }
                        }
                    }.padding(6)
                }
                .frame(height: standalone ? 340 : 320)
                .onChange(of: selected) { _, v in withAnimation { proxy.scrollTo(v, anchor: .center) } }
            }
        }
        .frame(width: standalone ? 540 : 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .shadow(radius: 20, y: 8)
    }

    private func row(_ a: Action, active: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: a.symbol).frame(width: 20).foregroundStyle(.tint)
            Text(a.title).fontWeight(.medium).lineLimit(1)
            Spacer()
            if !a.subtitle.isEmpty { Text(a.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let k = a.shortcut {
                Text(k).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(.separator))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        .background(active ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 7))
    }

    private func move(_ d: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selected = (selected + d + n) % n
    }
    private func runSelected() {
        let list = filtered
        guard list.indices.contains(selected) else { return }
        run(list[selected])
    }
    /// Run a row and remember it: the item it acts on, or the command itself.
    private func run(_ a: Action) {
        PaletteRecents.record(a.recentKey ?? "cmd:\(a.title)")
        a.run()
    }
    private func go(_ id: String) {
        state.selectedModuleID = id
        state.globalSearch = ""
        isPresented = false
        if standalone { WindowOpener.open?("main") }   // surface the module in the window
    }
    private func newIn(_ id: String) {
        state.pendingNew = id
        go(id)
    }
}
