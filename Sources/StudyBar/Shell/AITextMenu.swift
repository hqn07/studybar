import SwiftUI

/// Drop-in Writing-Tools menu for ANY plain-text field in StudyBar. A small tinted "AI" pill
/// that runs a `NoteAI` action on the bound text and shows the result in a review popover —
/// Replace / Insert / Discard. Nothing routes to the Assistant module; the field is untouched
/// until the user accepts, and it's a single edit. Reuse it beside any `TextEditor`/`TextField`.
struct AITextMenu: View {
    @Binding var text: String
    /// Optional short context (e.g. an assignment title) — reserved for future prompt biasing.
    var context: String? = nil
    /// Show the "AI" word next to the sparkle, or just the icon (for tight rows).
    var showsLabel: Bool = true

    @State private var action: NoteAI?
    @State private var out = ""
    @State private var done = false
    @State private var start: Date?
    @State private var task: Task<Void, Never>?
    @State private var reviewing = false

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Menu {
            if AIConfig.isReady {
                ForEach(NoteAI.allCases) { a in
                    Button { run(a) } label: { Label(a.label, systemImage: a.icon) }
                        .disabled(empty && a != .continueWriting)
                }
            } else {
                Text("Turn on AI in Settings ▸ Intelligence")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                if showsLabel { Text("AI").font(.caption.weight(.medium)) }
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.tint.opacity(0.13), in: Capsule())
        }
        .menuStyle(.borderlessButton).fixedSize().menuIndicator(.hidden)
        .help("AI — summarize, rewrite, or proofread this text")
        .popover(isPresented: $reviewing, arrowEdge: .bottom) { review }
    }

    private var review: some View {
        let a = action ?? .summarize
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: a.icon).foregroundStyle(.tint)
                Text(a.label).font(.caption.weight(.semibold))
                if !done {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(max(0, Int(Date().timeIntervalSince(start ?? Date()))))s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(AIConfig.mode.title).font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(out.isEmpty ? "Thinking…" : out).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(out.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }.frame(width: 320, height: 150)
            if done && !out.isEmpty {
                HStack(spacing: 8) {
                    if a.mode == .insert {
                        Button { insert() } label: { Label("Insert", systemImage: "text.insert") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Replace") { replace() }.buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button { replace() } label: { Label("Replace", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Insert") { insert() }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                    Button("Discard") { close() }.buttonStyle(.bordered).controlSize(.small)
                }
            } else if done {
                Text("No result — check the engine in Settings ▸ Intelligence.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).frame(width: 344)
    }

    private func run(_ a: NoteAI) {
        guard AIConfig.isReady, let provider = AIService.makeProvider() else { return }
        action = a; out = ""; done = false; start = Date(); reviewing = true
        task?.cancel()
        task = Task {
            let msgs = [AIMessage(role: .user, text: text)]
            let r: String?
            if let ollama = provider as? OllamaProvider {
                r = try? await ollama.completePlainStreaming(system: a.system(), messages: msgs) { p in out = p }
            } else {
                r = try? await provider.completePlain(system: a.system(), messages: msgs)
            }
            await MainActor.run { out = (r ?? out).trimmingCharacters(in: .whitespacesAndNewlines); done = true }
        }
    }
    private func replace() { if !out.isEmpty { text = out }; close() }
    private func insert()  { if !out.isEmpty { text = text.isEmpty ? out : text + "\n\n" + out }; close() }
    private func close()   { task?.cancel(); task = nil; reviewing = false; action = nil; out = ""; done = false; start = nil }
}
