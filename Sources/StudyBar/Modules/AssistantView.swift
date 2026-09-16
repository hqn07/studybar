import SwiftUI
import UniformTypeIdentifiers

// The Assistant is no longer a sidebar module — it's a summoned floating panel
// (AssistantPanel), which reuses AssistantChat + ContextPill below. The old
// AssistantView wrapper was removed in the v1.8.0 cleanup.

/// Compact indicator of how much conversation context is being sent to the model.
/// Grows as the chat gets longer; nudges the user toward "New chat" when large.
struct ContextPill: View {
    let tokens: Int
    /// Soft "getting long" threshold — comfortably under a small local model's window.
    private var long: Bool { tokens >= 6000 }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: long ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent")
                .font(.caption2)
            Text("~\(Self.format(tokens))")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(long ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(long ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.sbSurface),
                    in: Capsule())
        .help(long
              ? "This conversation is getting long (~\(Self.format(tokens)) tokens). Start a New chat to keep the assistant fast and focused."
              : "Approx. context used this conversation (~\(Self.format(tokens)) tokens).")
    }

    /// 950 → "950", 1240 → "1.2k".
    static func format(_ n: Int) -> String {
        n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000)
    }
}

struct AssistantChat: View {
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
                Button { chat.start(s.prompt, state: state) } label: {
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
                    .background(s.featured ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.sbSurface),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(s.featured ? AnyShapeStyle(.tint.opacity(0.4)) : AnyShapeStyle(.clear), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A turn's reply is a JSON envelope, so partial text can't be shown the way the note's Ask
    /// panel streams prose — a 7B model means half a minute of nothing. Count the seconds and
    /// say what is happening, so the wait reads as work rather than a hang.
    private var typing: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(typingLabel).font(.caption).foregroundStyle(.secondary)
                Button { chat.stop() } label: { Label("Stop", systemImage: "stop.circle") }
                    .buttonStyle(.borderless).controlSize(.small).font(.caption)
            }.padding(.horizontal, 4)
        }
    }

    private var typingLabel: String {
        guard let started = chat.turnStarted else { return "Thinking…" }
        let secs = Int(Date.now.timeIntervalSince(started))
        if secs < 3 { return "Thinking…" }
        return secs < 20 ? "Thinking… \(secs)s" : "Still working — \(secs)s on \(AIConfig.mode.title)"
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask, or tell me what to organize…", text: $input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.sbSurface, in: RoundedRectangle(cornerRadius: 9))
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
        chat.start(t, state: state)
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
                        Group {
                            if msg.isError { Text(msg.text) }
                            else { RichText(text: msg.text).textSelection(.enabled) }
                        }
                        .font(.callout)
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
                // What it will do, in words. The raw tool name stays as the tooltip for
                // anyone who wants to know exactly which call is queued.
                let detail = AIChat.detail(a)
                Text(detail.isEmpty ? a.tool : detail)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(a.tool)
                if let result {
                    HStack(spacing: 6) {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                        if state.undo != nil {
                            Button("Undo") { state.performUndo() }
                                .buttonStyle(.borderless).controlSize(.small).font(.caption2)
                        }
                    }
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
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 9))
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
