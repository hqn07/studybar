import SwiftUI

struct ClipboardView: View {
    @EnvironmentObject var state: AppState
    @State private var filter = ""
    @State private var paused = false

    private var items: [ClipItem] {
        let base = state.data.clips.sorted { ($0.pinned ? 1 : 0) > ($1.pinned ? 1 : 0) }
        guard !filter.isEmpty else { return base }
        return base.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        ModulePane(title: "Clipboard") {
            HStack(spacing: 8) {
                Button { paused.toggle(); state.clipboard.userPaused = paused } label: {
                    Image(systemName: paused ? "pause.circle.fill" : "record.circle")
                        .foregroundStyle(paused ? .orange : .red)
                }.help(paused ? "Capture paused — tap to resume" : "Capturing — tap to pause")
                Menu {
                    Button("Clear unpinned") { state.data.clips.removeAll { !$0.pinned } }
                    Button("Clear all", role: .destructive) { state.data.clips.removeAll() }
                } label: { Image(systemName: "trash") }
            }
        } content: {
            VStack(spacing: 0) {
                SearchField(text: $filter).padding(8)
                if paused {
                    Text("Capture paused — new copies won't be saved.")
                        .font(.caption2).foregroundStyle(.orange).frame(maxWidth: .infinity)
                }
                Divider()
                if items.isEmpty {
                    EmptyState(symbol: "doc.on.clipboard", title: "Clipboard is empty",
                               subtitle: "Copied text shows up here automatically. Passwords from password managers are skipped.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(items) { clip in ClipRow(clip: clip) }
                        }.padding(8)
                    }
                }
            }
        }
        .onAppear { paused = state.clipboard.userPaused }
    }
}

struct ClipRow: View {
    @EnvironmentObject var state: AppState
    let clip: ClipItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.text).font(.callout).lineLimit(3)
                Text(clip.copiedAt.relativeShort).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 6) {
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                Button { pin() } label: {
                    Image(systemName: clip.pinned ? "pin.fill" : "pin")
                }.buttonStyle(.borderless).foregroundStyle(clip.pinned ? .orange : .secondary)
                Button { state.data.clips.removeAll { $0.id == clip.id } } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(9)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .contextMenu {
            Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button { toNote() } label: { Label("Save as Note", systemImage: "note.text") }
            Button { toSnippet() } label: { Label("Save as Snippet", systemImage: "text.badge.plus") }
            if !clip.pinned { Button { pin() } label: { Label("Pin", systemImage: "pin") } }
            Divider()
            Button(role: .destructive) { state.data.clips.removeAll { $0.id == clip.id } } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func toNote() {
        state.data.notes.append(Note(title: "Clip · \(clip.copiedAt.dayMonth)", body: clip.text))
    }
    private func toSnippet() {
        state.data.snippets.append(Snippet(title: String(clip.text.prefix(30)), body: clip.text))
    }

    private func copy() {
        state.clipboard.enabled = false
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip.text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { state.clipboard.enabled = true }
    }
    private func pin() {
        guard let i = state.data.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        state.data.clips[i].pinned.toggle()
    }
}
