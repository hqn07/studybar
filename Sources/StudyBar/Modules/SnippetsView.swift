import SwiftUI

/// (6) Reusable text snippets. v1 = library with one-click copy.
/// (keyword auto-expansion needs Accessibility access — planned for a later phase.)
struct SnippetsView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Snippet?
    @State private var search = ""
    @State private var byUse = false

    private var snippets: [Snippet] {
        var list = state.data.snippets
        if !search.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(search) ||
                $0.keyword.localizedCaseInsensitiveContains(search) ||
                $0.body.localizedCaseInsensitiveContains(search)
            }
        }
        return byUse ? list.sorted { $0.uses > $1.uses } : list
    }

    var body: some View {
        NavigationStack {
            ModulePane(title: "Snippets") {
                HStack(spacing: 8) {
                    Menu {
                        Button { byUse.toggle() } label: {
                            Label("Sort by most used", systemImage: byUse ? "checkmark" : "arrow.up.arrow.down")
                        }
                        Divider()
                        Button { addSamples() } label: { Label("Add sample snippets", systemImage: "sparkles") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button { editing = Snippet() } label: { Image(systemName: "plus") }
                }
            } content: {
                VStack(spacing: 0) {
                    if state.data.snippets.count > 4 { SearchField(text: $search).padding(8); Divider() }
                    if snippets.isEmpty {
                        VStack(spacing: 12) {
                            EmptyState(symbol: "text.badge.plus",
                                       title: state.data.snippets.isEmpty ? "No snippets" : "No matches",
                                       subtitle: state.data.snippets.isEmpty ? "Save email templates, citations or boilerplate. Placeholders {date} {time} {clipboard} expand on copy." : "Try a different search.")
                            if state.data.snippets.isEmpty {
                                Button { addSamples() } label: { Label("Add sample snippets", systemImage: "sparkles") }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(snippets) { s in SnippetRow(snippet: s) { editing = s } }
                            }.padding(10)
                        }
                    }
                }
            }
            .navigationDestination(item: $editing) { SnippetEditor(snippet: $0) }
        }
    }

    private func addSamples() {
        let samples: [Snippet] = [
            Snippet(keyword: ";ext", title: "Email — extension request",
                    body: "Dear Professor [Name],\n\nI'm writing to ask whether it would be possible to receive a short extension on [assignment], currently due {date}. [Brief reason]. I'd be grateful for any flexibility, and happy to discuss.\n\nThank you for your time,\n[Your Name]"),
            Snippet(keyword: ";oh", title: "Email — office hours question",
                    body: "Hi Professor [Name],\n\nI had a question about [topic] from [lecture/reading]. Would it be alright to stop by office hours on [day], or is there a better time?\n\nThanks,\n[Your Name]"),
            Snippet(keyword: ";lec", title: "Lecture notes header",
                    body: "# [Course] — [Topic]\n{datetime}\n\n## Key points\n- \n\n## Questions\n- \n\n## To review\n- [ ] "),
            Snippet(keyword: ";lab", title: "Lab report skeleton",
                    body: "# [Title]\n\n## Objective\n\n## Materials\n\n## Procedure\n\n## Results\n\n## Discussion\n\n## Conclusion"),
            Snippet(keyword: ";quote", title: "Quote with citation",
                    body: "\"{clipboard}\" ([Author], [Year], p. )"),
            Snippet(keyword: ";cite", title: "Accessed date",
                    body: "Accessed {date}."),
            Snippet(keyword: ";todo", title: "Checklist item",
                    body: "- [ ] "),
            Snippet(keyword: ";sig", title: "Email signature",
                    body: "Best regards,\n[Your Name]\n[Program] · [University]"),
            Snippet(keyword: ";mtg", title: "Meeting / study session",
                    body: "Study session — {datetime}\nWith: \nGoals:\n- \nRecap:\n- "),
            Snippet(keyword: ";thx", title: "Email — thank you",
                    body: "Hi [Name],\n\nThank you so much for [help]. It really made a difference with [thing]. I appreciate you taking the time.\n\nBest,\n[Your Name]"),
        ]
        let existing = Set(state.data.snippets.map { $0.title })
        for s in samples where !existing.contains(s.title) {
            state.data.snippets.append(s)
        }
    }
}

struct SnippetRow: View {
    @EnvironmentObject var state: AppState
    let snippet: Snippet
    let onEdit: () -> Void
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snippet.title.isEmpty ? "Untitled" : snippet.title).fontWeight(.medium)
                    if !snippet.keyword.isEmpty {
                        Text(snippet.keyword).font(.caption2.monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule()).foregroundStyle(.tint)
                    }
                }
                Text(snippet.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if copied {
                        Label("Copied to clipboard", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                    } else {
                        if SnippetExpand.hasPlaceholders(snippet.body) {
                            Label("placeholders", systemImage: "curlybraces").font(.caption2).foregroundStyle(.tint)
                        }
                        if snippet.uses > 0 { Text("used \(snippet.uses)×").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }
            }
            Spacer()
            Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless).foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                .help("Copy (expands placeholders)")
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy() {
        let expanded = SnippetExpand.run(snippet.body)     // reads current clipboard for {clipboard}
        state.clipboard.enabled = false
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(expanded, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state.clipboard.enabled = true }
        if let i = state.data.snippets.firstIndex(where: { $0.id == snippet.id }) {
            state.data.snippets[i].uses += 1
        }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

struct SnippetEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Snippet
    init(snippet: Snippet) { _draft = State(initialValue: snippet) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader("Snippet") {
                Button("Delete", role: .destructive) {
                    state.data.snippets.removeAll { $0.id == draft.id }; dismiss()
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
                TextField("Keyword (e.g. ;addr)", text: $draft.keyword).textFieldStyle(.roundedBorder)
                TextEditor(text: $draft.body).frame(height: 150)
                    .font(.body).scrollContentBackground(.hidden)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                Text("Placeholders expand when you copy: {date} · {time} · {datetime} · {clipboard}")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(14)
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .toolbar(.hidden, for: .windowToolbar)
    }

    private func save() {
        let empty = draft.title.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.body.trimmingCharacters(in: .whitespaces).isEmpty
        if empty {
            state.data.snippets.removeAll { $0.id == draft.id }
        } else if let i = state.data.snippets.firstIndex(where: { $0.id == draft.id }) {
            state.data.snippets[i] = draft
        } else {
            state.data.snippets.append(draft)
        }
        dismiss()
    }
}
