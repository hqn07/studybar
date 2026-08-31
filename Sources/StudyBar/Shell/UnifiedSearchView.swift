import SwiftUI

/// (45) Unified search across every module. Clicking a result jumps to its module.
struct UnifiedSearchView: View {
    @EnvironmentObject var state: AppState
    let query: String

    private struct Result: Identifiable {
        let id = UUID()
        let moduleID: String
        let symbol: String
        let title: String
        let subtitle: String
    }

    private var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        func has(_ s: String) -> Bool { s.localizedCaseInsensitiveContains(q) }
        var out: [Result] = []

        for a in state.data.assignments where has(a.title) || has(a.notes) {
            out.append(.init(moduleID: "assignments", symbol: "checklist",
                             title: a.title.isEmpty ? "Untitled" : a.title,
                             subtitle: a.due?.dayMonth ?? "Assignment"))
        }
        for n in state.data.notes where has(n.title) || has(n.body) {
            out.append(.init(moduleID: "notes", symbol: "note.text",
                             title: n.title.isEmpty ? "Note" : n.title,
                             subtitle: String(n.body.prefix(50))))
        }
        for t in state.data.todos where has(t.text) {
            // Legacy to-dos (pre-merge) — route to Assignments, where they can be imported.
            out.append(.init(moduleID: "assignments", symbol: "checkmark.circle",
                             title: t.text, subtitle: t.done ? "Done · old to-do" : "Old to-do"))
        }
        for l in state.data.links where has(l.title) || has(l.url) {
            out.append(.init(moduleID: "links", symbol: l.symbol,
                             title: l.title.isEmpty ? l.url : l.title, subtitle: l.url))
        }
        for s in state.data.snippets where has(s.title) || has(s.body) || has(s.keyword) {
            out.append(.init(moduleID: "snippets", symbol: "text.badge.plus",
                             title: s.title.isEmpty ? "Snippet" : s.title, subtitle: s.keyword))
        }
        for c in state.data.courses where has(c.name) || has(c.code) {
            out.append(.init(moduleID: "courses", symbol: "graduationcap",
                             title: c.name, subtitle: c.code))
        }
        for b in state.data.reading where has(b.title) || has(b.author) {
            out.append(.init(moduleID: "reading", symbol: "book",
                             title: b.title, subtitle: b.author.isEmpty ? "Reading" : b.author))
        }
        for c in state.data.references where has(c.title) || c.authors.contains(where: has) {
            out.append(.init(moduleID: "citations", symbol: "quote.opening",
                             title: c.title.isEmpty ? "Citation" : c.title,
                             subtitle: c.authors.first ?? (c.year.isEmpty ? "Citation" : c.year)))
        }
        for r in state.data.readingList where has(r.title) || has(r.url) {
            out.append(.init(moduleID: "readinglist", symbol: "books.vertical",
                             title: r.title.isEmpty ? r.url : r.title, subtitle: r.url))
        }
        for card in state.data.flashcards where has(card.front) || has(card.back) {
            let deck = state.data.decks.first { $0.id == card.deckID }?.name ?? "Flashcards"
            out.append(.init(moduleID: "flashcards", symbol: "rectangle.on.rectangle.angled",
                             title: String(card.front.prefix(48)), subtitle: deck))
        }
        for cl in state.data.classes where has(cl.title) || has(state.course(cl.courseID)?.name ?? "") {
            out.append(.init(moduleID: "schedule", symbol: "graduationcap",
                             title: cl.title.isEmpty ? (state.course(cl.courseID)?.name ?? "Class") : cl.title,
                             subtitle: cl.startString))
        }
        return out
    }

    var body: some View {
        Group {
            if results.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches",
                           subtitle: "Nothing found for “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { r in
                            Button {
                                state.selectedModuleID = r.moduleID
                                state.globalSearch = ""
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: r.symbol).frame(width: 20).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.title).fontWeight(.medium).lineLimit(1)
                                        Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(10).contentShape(Rectangle())
                                .background(.sbSurface, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
