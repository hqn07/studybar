import SwiftUI

/// (2) Always-there single text buffer. Auto-saves. Live word/char count. Markdown preview.
struct ScratchpadView: View {
    @EnvironmentObject var state: AppState
    @State private var showPreview = false
    @State private var saved = false

    private var words: Int {
        state.data.scratchpad.split { $0.isWhitespace || $0.isNewline }.count
    }
    private var empty: Bool { state.data.scratchpad.isEmpty }

    var body: some View {
        ModulePane(title: "Scratchpad") {
            HStack(spacing: 8) {
                Button { showPreview.toggle() } label: { Image(systemName: showPreview ? "eye.fill" : "eye") }
                    .foregroundStyle(showPreview ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).help("Preview Markdown")
                Button { saveAsNote() } label: { Image(systemName: "note.text.badge.plus") }
                    .help("Save to a note").disabled(empty)
                Button { state.data.scratchpad = "" } label: { Image(systemName: "trash") }.disabled(empty)
            }
        } content: {
            VStack(spacing: 0) {
                if showPreview {
                    ScrollView {
                        MarkdownText(text: empty ? "_Nothing to preview yet._" : state.data.scratchpad)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                } else {
                    TextEditor(text: $state.data.scratchpad)
                        .font(.body).padding(8).scrollContentBackground(.hidden)
                }
                Divider()
                HStack {
                    Text("\(words) words · \(state.data.scratchpad.count) chars")
                        .font(.caption).foregroundStyle(.secondary)
                    if saved { Text("· saved to Notes").font(.caption).foregroundStyle(.green) }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.data.scratchpad, forType: .string)
                    } label: { Label("Copy all", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.caption).disabled(empty)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private func saveAsNote() {
        guard !empty else { return }
        let firstLine = state.data.scratchpad.split(separator: "\n").first.map(String.init) ?? "Scratch note"
        state.data.notes.append(Note(title: String(firstLine.prefix(40)), body: state.data.scratchpad))
        state.data.scratchpad = ""
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
