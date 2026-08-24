import SwiftUI
import UniformTypeIdentifiers

/// The AI Assistant module: a chat pane that turns plain-English intent into
/// proposed StudyBar actions. Every action is confirmed inline (no sheets/alerts —
/// the popover would dismiss). Organizes your data; never tutors.
struct AssistantView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            ModulePane(title: "Assistant") {
                HStack(spacing: 8) {
                    if !state.aiChat.isEmpty {
                        Button { state.aiChat.clear() } label: { Image(systemName: "square.and.pencil") }
                            .help("New chat")
                    }
                    Menu {
                        Label("Engine: \(AIConfig.mode.title)", systemImage: "sparkles")
                        Button("Intelligence settings…") { state.selectedModuleID = "settings" }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            } content: {
                if AIConfig.isReady {
                    AssistantChat(chat: state.aiChat)
                } else {
                    notConfigured
                }
            }
        }
    }

    private var notConfigured: some View {
        VStack(spacing: 14) {
            EmptyState(symbol: "sparkles",
                       title: "Turn on the assistant",
                       subtitle: "Pick an engine in Settings ▸ Intelligence — free on-device, or your own Claude / ChatGPT key. It organizes your studies; it won't do your homework.")
            Button("Open Intelligence settings") { state.selectedModuleID = "settings" }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct AssistantChat: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var chat: AIChat
    @State private var input = ""
    @State private var dropActive = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.isEmpty { starters }
                        ForEach(chat.messages) { m in MessageView(msg: m, chat: chat) }
                        if chat.sending { typing }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: chat.messages.count) { _, _ in scrollDown(proxy) }
                .onChange(of: chat.sending) { _, _ in scrollDown(proxy) }
            }
            Divider()
            composer
        }
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in handleDrop(providers) }
        .overlay {
            if dropActive {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    VStack(spacing: 6) {
                        Image(systemName: "doc.text.viewfinder").font(.largeTitle).foregroundStyle(.tint)
                        Text("Drop a syllabus (PDF or text) to import").font(.callout.weight(.medium))
                    }
                }
                .allowsHitTesting(false)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(6))
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let u = item as? URL { url = u }
            guard let url else { return }
            Task { @MainActor in SyllabusImport.triage(url: url) }
        }
        return true
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // Empty-state: greeting + context-aware starter chips.
    private var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 5) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.tint)
                Text("What should we organize?").font(.headline)
                Text(AIConfig.mode == .onDevice ? "Running on-device — nothing leaves your Mac." : "Ask, or tap a suggestion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)

            Button { SyllabusImport.pickAndTriage() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.viewfinder").frame(width: 22).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Import a syllabus file…").font(.callout.weight(.medium))
                        Text("Pick or drop a PDF / text syllabus to organize it").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "square.and.arrow.down").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(10).contentShape(Rectangle())
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.tint.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)

            ForEach(Starters.suggestions(state: state)) { s in
                Button { Task { await chat.send(s.prompt, state: state) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol).frame(width: 22).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                            Text(s.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let tag = s.contextTag {
                            Text(tag.uppercased()).font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule()).foregroundStyle(.tint)
                        } else {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10).contentShape(Rectangle())
                    .background(s.featured ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.background.secondary),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(s.featured ? AnyShapeStyle(.tint.opacity(0.4)) : AnyShapeStyle(.clear), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var typing: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 4)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask, or tell me what to organize…", text: $input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.sending)
        }
        .padding(10)
    }

    private func send() {
        let t = input
        input = ""
        Task { await chat.send(t, state: state) }
    }
}

/// One chat message: user bubble, assistant prose, or an assistant turn with
/// inline proposed-action cards (each confirmed or skipped independently).
private struct MessageView: View {
    @EnvironmentObject var state: AppState
    let msg: AIChat.Msg
    @ObservedObject var chat: AIChat

    var body: some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: 32)
                Text(msg.text)
                    .font(.callout)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !msg.text.isEmpty {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: msg.isError ? "exclamationmark.triangle.fill" : "sparkles")
                            .font(.caption).foregroundStyle(msg.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                            .padding(.top, 2)
                        Text(msg.text).font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !msg.actions.isEmpty { actionCards }
            }
        }
    }

    private var unresolvedCount: Int {
        msg.actions.filter { msg.results[$0.id] == nil && !msg.skipped.contains($0.id) }.count
    }

    private var actionCards: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(msg.actions) { a in card(a) }
            if unresolvedCount >= 2 {
                Button { chat.applyAll(messageID: msg.id, state: state) } label: {
                    Label("Apply all (\(unresolvedCount))", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.leading, 22)
    }

    @ViewBuilder private func card(_ a: AIAction) -> some View {
        let result = msg.results[a.id]
        let skipped = msg.skipped.contains(a.id)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon(a.tool))
                .font(.caption).foregroundStyle(.tint).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.label).font(.caption.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                Text(a.tool).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                if let result {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else if skipped {
                    Text("Skipped").font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Button("Apply") { chat.apply(a, messageID: msg.id, state: state) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Skip") { chat.skip(a, messageID: msg.id) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }.padding(.top, 2)
                }
            }
        }
        .padding(9)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
        .opacity(skipped ? 0.55 : 1)
    }

    private func icon(_ tool: String) -> String {
        switch tool {
        case "add_task", "plan_study_block": return "checklist"
        case "add_note":                     return "note.text"
        case "create_assignment":            return "doc.badge.plus"
        case "prioritize_assignments":       return "list.bullet.indent"
        case "make_flashcards":              return "rectangle.on.rectangle.angled"
        case "start_pomodoro":               return "timer"
        default:                             return "sparkles"
        }
    }
}
