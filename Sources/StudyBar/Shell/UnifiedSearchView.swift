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
        var score: Double = 0
        var libraryTab: String? = nil   // when moduleID == "library", which shelf to open
    }

    private var results: [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [Result] = []
        // Score each item across its searchable fields; keep matches, ranked by relevance.
        func add(_ fields: [String], _ make: (Double) -> Result) {
            if let s = FuzzyMatch.best(q, fields.filter { !$0.isEmpty }) { out.append(make(s)) }
        }

        for a in state.data.assignments {
            add([a.title, a.notes]) { .init(moduleID: "assignments", symbol: "checklist",
                title: a.title.isEmpty ? "Untitled" : a.title, subtitle: a.due?.dayMonth ?? "Assignment", score: $0) }
        }
        for n in state.data.notes {
            add([n.title, n.body]) { .init(moduleID: "notes", symbol: "note.text",
                title: n.title.isEmpty ? "Note" : n.title, subtitle: String(n.body.prefix(50)), score: $0) }
        }
        for t in state.data.todos {   // legacy to-dos → route to Assignments for import
            add([t.text]) { .init(moduleID: "assignments", symbol: "checkmark.circle",
                title: t.text, subtitle: t.done ? "Done · old to-do" : "Old to-do", score: $0) }
        }
        for l in state.data.links {
            add([l.title, l.url]) { .init(moduleID: "library", symbol: l.symbol,
                title: l.title.isEmpty ? l.url : l.title, subtitle: l.url, score: $0) }
        }
        for s in state.data.snippets {
            add([s.title, s.body, s.keyword]) { .init(moduleID: "snippets", symbol: "text.badge.plus",
                title: s.title.isEmpty ? "Snippet" : s.title, subtitle: s.keyword, score: $0) }
        }
        for c in state.data.courses {
            add([c.name, c.code]) { .init(moduleID: "courses", symbol: "graduationcap",
                title: c.name, subtitle: c.code, score: $0) }
        }
        for b in state.data.reading {
            add([b.title, b.author]) { .init(moduleID: "reading", symbol: "book",
                title: b.title, subtitle: b.author.isEmpty ? "Reading" : b.author, score: $0) }
        }
        for c in state.data.references {
            add([c.title] + c.authors) { .init(moduleID: "citations", symbol: "quote.opening",
                title: c.title.isEmpty ? "Citation" : c.title,
                subtitle: c.authors.first ?? (c.year.isEmpty ? "Citation" : c.year), score: $0) }
        }
        for r in state.data.readingList {
            add([r.title, r.url]) { .init(moduleID: "library", symbol: "books.vertical",
                title: r.title.isEmpty ? r.url : r.title, subtitle: r.url, score: $0,
                libraryTab: LibraryTab.readlater.rawValue) }
        }
        for card in state.data.flashcards {
            let deck = state.data.decks.first { $0.id == card.deckID }?.name ?? "Flashcards"
            add([card.front, card.back]) { .init(moduleID: "flashcards", symbol: "rectangle.on.rectangle.angled",
                title: String(card.front.prefix(48)), subtitle: deck, score: $0) }
        }
        for cl in state.data.classes {
            let cname = state.course(cl.courseID)?.name ?? ""
            add([cl.title, cname]) { .init(moduleID: "schedule", symbol: "graduationcap",
                title: cl.title.isEmpty ? (cname.isEmpty ? "Class" : cname) : cl.title,
                subtitle: cl.startString, score: $0) }
        }
        return out.sorted { $0.score > $1.score }
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
                                if let t = r.libraryTab { UserDefaults.standard.set(t, forKey: "libraryTab") }
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
