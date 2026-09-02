import SwiftUI

/// (6) Reusable text snippets — a keyword-triggered library with one-click copy,
/// organized into free-text categories (collapsible groups + filter chips).
struct SnippetsView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: Snippet?
    @State private var search = ""
    @State private var byUse = false
    @State private var selectedCategory: String? = nil     // nil = All

    private static func cat(_ s: Snippet) -> String { s.category.isEmpty ? "General" : s.category }

    private var searched: [Snippet] {
        let list = state.data.snippets
        if !search.isEmpty {
            // Fuzzy + relevance-ranked while searching.
            return list.compactMap { s in FuzzyMatch.best(search, [s.title, s.keyword, s.body, s.category]).map { (s, $0) } }
                .sorted { $0.1 > $1.1 }.map(\.0)
        }
        return byUse ? list.sorted { $0.uses > $1.uses } : list
    }
    /// Category names present, sorted (General last).
    private var categories: [String] {
        let names = Set(searched.map { Self.cat($0) })
        return names.sorted { a, b in
            if a == "General" { return false }; if b == "General" { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }
    private func items(in category: String) -> [Snippet] {
        searched.filter { Self.cat($0) == category }
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
                    Button { editing = Snippet(category: selectedCategory ?? "") } label: { Image(systemName: "plus") }
                }
            } content: {
                VStack(spacing: 0) {
                    if state.data.snippets.count > 4 { SearchField(text: $search).padding(8); Divider() }
                    if categories.count > 1 { categoryChips; Divider() }

                    if searched.isEmpty { emptyState } else { snippetList }
                }
            }
            .navigationDestination(item: $editing) { SnippetEditor(snippet: $0) }
        }
        .onAppear(perform: migrateCategories)
    }

    /// Backfill categories on the built-in sample snippets that predate categories,
    /// so an existing library organizes itself. Only fills empty categories.
    private func migrateCategories() {
        let map: [String: String] = [
            ";ext": "Email", ";oh": "Email", ";thx": "Email", ";sig": "Email",
            ";lec": "Notes", ";lab": "Notes",
            ";quote": "Citations", ";cite": "Citations",
            ";todo": "Tasks", ";mtg": "Meetings",
        ]
        var changed = false
        for i in state.data.snippets.indices where state.data.snippets[i].category.isEmpty {
            if let c = map[state.data.snippets[i].keyword.lowercased()] {
                state.data.snippets[i].category = c; changed = true
            }
        }
        _ = changed
    }

    // Filter chips: All · <categories>
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", active: selectedCategory == nil) { selectedCategory = nil }
                ForEach(categories, id: \.self) { c in
                    chip(c, active: selectedCategory == c) { selectedCategory = (selectedCategory == c ? nil : c) }
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
    private func chip(_ label: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) { Chip(label, .filter, selected: active) }.buttonStyle(.plain)
    }

    /// Categories shown right now — every one with matching items, or just the picked chip.
    private var visibleCategories: [String] {
        if let c = selectedCategory { return items(in: c).isEmpty ? [] : [c] }
        return categories.filter { !items(in: $0).isEmpty }
    }
    /// Reorder is only meaningful on the natural order — not while searching or sorted-by-use.
    private var reorderable: Bool { search.isEmpty && !byUse }

    /// One plain List: light section labels + hairline-separated rows, drag to reorder
    /// within a category. Chips narrow it to a single section.
    private var snippetList: some View {
        List {
            ForEach(visibleCategories, id: \.self) { c in
                Section {
                    ForEach(items(in: c)) { s in
                        SnippetRow(snippet: s) { editing = s }
                            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 8))
                            .listRowBackground(Color.clear)
                    }
                    .onMove { from, to in move(category: c, from: from, to: to) }
                    .moveDisabled(!reorderable)
                } header: {
                    Text("\(c) · \(items(in: c).count)")
                        .font(.caption2.weight(.semibold)).tracking(0.5)
                        .foregroundStyle(.secondary).textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Reorder within a category, written back into `state.data.snippets` in place so the
    /// other categories keep their positions.
    private func move(category c: String, from: IndexSet, to: Int) {
        var all = state.data.snippets
        let slots = all.indices.filter { Self.cat(all[$0]) == c }
        var sub = slots.map { all[$0] }
        sub.move(fromOffsets: from, toOffset: to)
        for (k, i) in slots.enumerated() { all[i] = sub[k] }
        state.data.snippets = all
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyState(symbol: "text.badge.plus",
                       title: state.data.snippets.isEmpty ? "No snippets" : "No matches",
                       subtitle: state.data.snippets.isEmpty ? "Save email templates, citations or boilerplate. Type a keyword like ;quote in the Notes editor to expand it inline, or Copy. Placeholders {date} {time} {clipboard} resolve on expand." : "Try a different search.")
            if state.data.snippets.isEmpty {
                Button { addSamples() } label: { Label("Add sample snippets", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func addSamples() {
        let samples: [Snippet] = [
            .init(keyword: ";ext", title: "Email — extension request",
                  body: "Dear Professor [Name],\n\nI'm writing to ask whether it would be possible to receive a short extension on [assignment], currently due {date}. [Brief reason]. I'd be grateful for any flexibility, and happy to discuss.\n\nThank you for your time,\n[Your Name]", category: "Email"),
            .init(keyword: ";oh", title: "Email — office hours question",
                  body: "Hi Professor [Name],\n\nI had a question about [topic] from [lecture/reading]. Would it be alright to stop by office hours on [day], or is there a better time?\n\nThanks,\n[Your Name]", category: "Email"),
            .init(keyword: ";lec", title: "Lecture notes header",
                  body: "# [Course] — [Topic]\n{datetime}\n\n## Key points\n- \n\n## Questions\n- \n\n## To review\n- [ ] ", category: "Notes"),
            .init(keyword: ";lab", title: "Lab report skeleton",
                  body: "# [Title]\n\n## Objective\n\n## Materials\n\n## Procedure\n\n## Results\n\n## Discussion\n\n## Conclusion", category: "Notes"),
            .init(keyword: ";quote", title: "Quote with citation",
                  body: "\"{clipboard}\" ([Author], [Year], p. )", category: "Citations"),
            .init(keyword: ";cite", title: "Accessed date",
                  body: "Accessed {date}.", category: "Citations"),
            .init(keyword: ";todo", title: "Checklist item",
                  body: "- [ ] ", category: "Tasks"),
            .init(keyword: ";sig", title: "Email signature",
                  body: "Best regards,\n[Your Name]\n[Program] · [University]", category: "Email"),
            .init(keyword: ";mtg", title: "Meeting / study session",
                  body: "Study session — {datetime}\nWith: \nGoals:\n- \nRecap:\n- ", category: "Meetings"),
            .init(keyword: ";thx", title: "Email — thank you",
                  body: "Hi [Name],\n\nThank you so much for [help]. It really made a difference with [thing]. I appreciate you taking the time.\n\nBest,\n[Your Name]", category: "Email"),
        ]
        let existing = Set(state.data.snippets.map { $0.title })
        for s in samples where !existing.contains(s.title) { state.data.snippets.append(s) }
    }
}

/// A keyword-forward compact row: `;kw`  Title / one-line preview  ·  copy · edit.
struct SnippetRow: View {
    @EnvironmentObject var state: AppState
    let snippet: Snippet
    let onEdit: () -> Void
    @State private var copied = false

    private var preview: String {
        snippet.body.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? snippet.body.replacingOccurrences(of: "\n", with: " ")
    }

    var body: some View {
        HStack(spacing: 11) {
            KeywordPill(keyword: snippet.keyword)
            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.title.isEmpty ? "Untitled" : snippet.title)
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            Button { copy() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            .help("Copy (expands placeholders)")
            .accessibilityLabel(copied ? "Copied" : "Copy snippet")
        }
        .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.m)
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)   // the row edits; copy is the one explicit control
    }

    private func copy() {
        let expanded = SnippetExpand.run(snippet.body)
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

/// The trigger keyword shown as a neutral "keyboard-key" pill.
struct KeywordPill: View {
    let keyword: String
    var body: some View {
        Text(keyword.isEmpty ? "—" : keyword)
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(keyword.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.sbSurface2, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
            .frame(minWidth: 42)
    }
}

struct SnippetEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Snippet
    init(snippet: Snippet) { _draft = State(initialValue: snippet) }

    private var categories: [String] {
        Array(Set(state.data.snippets.map { $0.category }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Category").font(.caption).foregroundStyle(.secondary)
                    CategoryPicker(suggestions: categories, selection: $draft.category)
                }
                TextEditor(text: $draft.body).frame(height: 140)
                    .overlay(alignment: .topTrailing) { AITextMenu(text: $draft.body).padding(6) }
                    .font(.body).scrollContentBackground(.hidden)
                    .background(.sbSurface, in: RoundedRectangle(cornerRadius: 6))
                Text("Type the keyword in the Notes editor (then space) to expand inline — start it with a symbol like “;” for that to fire. Placeholders resolve on expand or copy: {date} · {time} · {datetime} · {clipboard}")
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
        draft.category = draft.category.trimmingCharacters(in: .whitespaces)
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

/// Single-select, free-text category picker — chips for existing categories plus
/// a field to type a new one (same idiom as the flashcard tag chips).
struct CategoryPicker: View {
    let suggestions: [String]
    @Binding var selection: String
    @State private var newCategory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "number").font(.caption2).foregroundStyle(.secondary)
                TextField("New category…", text: $newCategory).textFieldStyle(.plain).font(.caption)
                    .onSubmit(commit)
                if !newCategory.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: commit) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.sbSurface, in: Capsule())

            if !allChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(allChips, id: \.self) { chip($0) } }.padding(.vertical, 1)
                }
            }
        }
    }

    private var allChips: [String] {
        var out = suggestions
        let sel = selection.trimmingCharacters(in: .whitespaces)
        if !sel.isEmpty && !out.contains(sel) { out.insert(sel, at: 0) }
        return out
    }
    private func chip(_ c: String) -> some View {
        let on = selection == c
        return Button { selection = (on ? "" : c) } label: {
            HStack(spacing: 3) {
                if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                Text(c).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.sbSurface), in: Capsule())
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }.buttonStyle(.plain)
    }
    private func commit() {
        let c = newCategory.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        selection = c; newCategory = ""
    }
}
