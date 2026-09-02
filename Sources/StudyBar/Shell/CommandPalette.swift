import SwiftUI

/// (55) ⌘K command palette: jump to modules + quick actions, keyboard-driven.
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @Binding var isPresented: Bool
    var standalone: Bool = false          // true = shown in its own floating panel
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
        let run: () -> Void
    }

    private var actions: [Action] {
        var out: [Action] = []
        // Quick actions
        out.append(.init(title: "New Note", subtitle: "Capture", symbol: "note.text") { newIn("notes") })
        out.append(.init(title: "New Assignment", subtitle: "Assignments", symbol: "checklist") { newIn("assignments") })
        out.append(.init(title: "New Task", subtitle: "Assignments", symbol: "checkmark.circle") { newIn("assignments") })
        out.append(.init(title: state.pomodoro.running ? "Pause Pomodoro" : "Start Pomodoro",
                         subtitle: "Time & Focus", symbol: "timer") {
            state.pomodoro.toggle(); isPresented = false
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
        // Module jumps
        for m in ModuleRegistry.all {
            out.append(.init(title: m.title, subtitle: "Go to · \(m.category.rawValue)", symbol: m.symbol) { go(m.id) })
        }
        return out
    }

    private var filtered: [Action] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return actions }
        var out = actions.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
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
        .onAppear { focused = true }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("Type a command or module…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onChange(of: query) { _, _ in selected = 0 }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { runSelected(); return .handled }
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, a in
                            row(a, active: i == selected).id(i).onTapGesture { a.run() }
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
            Text(a.title).fontWeight(.medium)
            Spacer()
            Text(a.subtitle).font(.caption).foregroundStyle(.secondary)
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
        guard filtered.indices.contains(selected) else { return }
        filtered[selected].run()
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
