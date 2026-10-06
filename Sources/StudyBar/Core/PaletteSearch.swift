import Foundation

/// What ⌘K finds in the student's own material.
///
/// Kept out of the view so it can be tested: the palette could previously jump to *Notes* but
/// not to *a note*, and the fix is only worth anything if "gauss" reliably ranks the Gauss note
/// above everything else in a store of a couple of hundred objects.
enum PaletteSearch {
    struct Hit: Identifiable {
        enum Kind: Equatable { case note(UUID), assignment(UUID), deck(UUID), book(UUID, page: Int?), file(UUID) }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
        let score: Double
    }

    /// Two characters is the floor — one letter matches half the store and ranks nothing.
    static let minQuery = 2

    /// Notes first: they are what a student reaches for mid-lecture, and a note's body is
    /// searched (a slice of it) so "flux" finds the note that never says so in its title.
    static func hits(_ query: String, data: AppData, courseCode: (UUID?) -> String?) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= minQuery else { return [] }
        var out: [Hit] = []

        for n in data.notes {
            let title = n.title.isEmpty ? "Untitled note" : n.title
            guard let s = FuzzyMatch.best(q, [title, String(n.body.prefix(400))]) else { continue }
            out.append(Hit(kind: .note(n.id), title: title,
                           detail: [courseCode(n.courseID), "Note"].compactMap { $0 }.joined(separator: " · "),
                           score: s))
        }
        for a in data.assignments where a.status != .done {
            guard let s = FuzzyMatch.best(q, [a.title]) else { continue }
            out.append(Hit(kind: .assignment(a.id), title: a.title,
                           detail: [courseCode(a.courseID), a.due.map { "due \($0.dayMonth)" }, "Assignment"]
                               .compactMap { $0 }.joined(separator: " · "),
                           // Slightly behind an equally-matched note: opening a note is the
                           // move, an assignment is usually being checked rather than opened.
                           score: s * 0.95))
        }
        for d in data.decks {
            guard let s = FuzzyMatch.best(q, [d.name]) else { continue }
            out.append(Hit(kind: .deck(d.id), title: d.name, detail: "Deck", score: s * 0.9))
        }
        // A card's words find its deck; one row a deck.
        var decked: Set<UUID> = Set(out.compactMap { if case .deck(let id) = $0.kind { return id }; return nil })
        for c in data.flashcards where !decked.contains(c.deckID) {
            guard let s = FuzzyMatch.best(q, [c.front, c.back]), s >= 100 else { continue }
            decked.insert(c.deckID)
            let deck = data.decks.first { $0.id == c.deckID }?.name ?? "Flashcards"
            out.append(Hit(kind: .deck(c.deckID), title: String(c.front.prefix(60)), detail: "Card · \(deck)", score: s * 0.8))
        }
        for b in data.reading {
            guard let s = FuzzyMatch.best(q, [b.title, b.author]) else { continue }
            out.append(Hit(kind: .book(b.id, page: nil), title: b.title, detail: [courseCode(b.courseID), "Book"].compactMap { $0 }.joined(separator: " · "), score: s * 0.85))
        }
        return out.sorted { $0.score > $1.score }
    }
}

// MARK: - Self-test (StudyBar --palette-selftest)

enum PaletteSearchSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(name)"); pass += 1 }
            else { print("  FAIL \(name) \(detail)"); fail += 1 }
        }

        var data = AppData()
        let phys = Course(name: "Physics 2", code: "PHY2049")
        data.courses = [phys]
        data.notes = [
            Note(title: "Weeks 4 — Gauss's Law Pt.3", body: "Gauss's law and applications", courseID: phys.id),
            Note(title: "Annuities", body: "Module 3, Section 2: annuities and payments"),
            Note(title: "Weeks 3 — ORH1030", body: "Coleus trials, propagation, electric fields nowhere here"),
        ]
        data.assignments = [Assignment(title: "Gauss homework", courseID: phys.id)]
        data.decks = [Deck(name: "Gauss cards", courseID: phys.id)]
        let code: (UUID?) -> String? = { id in data.courses.first { $0.id == id }?.code }

        let hits = PaletteSearch.hits("gauss", data: data, courseCode: code)
        check("finds the note, the assignment and the deck", hits.count == 3, "\(hits.count)")
        if case .note = hits.first?.kind { check("a note ranks first", true) }
        else { check("a note ranks first", false, "\(String(describing: hits.first?.kind))") }
        check("the note's course rides along", hits.first?.detail.contains("PHY2049") == true,
              hits.first?.detail ?? "")

        // Body text, not just titles: "that note about propagation".
        let body = PaletteSearch.hits("propagation", data: data, courseCode: code)
        check("body text is searched", body.contains { $0.title.contains("ORH1030") })

        // A done assignment is not something you are looking for.
        var done = data
        done.assignments[0].status = .done
        check("finished assignments drop out",
              !PaletteSearch.hits("gauss", data: done, courseCode: code).contains { if case .assignment = $0.kind { return true }; return false })

        // A card's words find its deck, once; a book by its title.
        var more = data
        more.flashcards = [Flashcard(deckID: more.decks[0].id, front: "What is a Gaussian surface?", back: "An imagined closed surface"),
                           Flashcard(deckID: more.decks[0].id, front: "Gaussian surface shape?", back: "Follows the symmetry")]
        more.decks[0].name = "Week 3"
        more.reading = [ReadingItem(title: "Serway — Physics for Scientists")]
        let found = PaletteSearch.hits("gaussian surface", data: more, courseCode: code)
        check("a card's words find its deck, once", found.filter { if case .deck = $0.kind { return true }; return false }.count == 1)
        check("a book by its title", PaletteSearch.hits("serway", data: more, courseCode: code).contains { if case .book = $0.kind { return true }; return false })

        check("one letter ranks nothing", PaletteSearch.hits("g", data: data, courseCode: code).isEmpty)
        check("nonsense finds nothing", PaletteSearch.hits("zzzzq", data: data, courseCode: code).isEmpty)

        print(fail == 0 ? "PALETTE SELFTEST: ALL PASS (\(pass))" : "PALETTE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
