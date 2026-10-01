import Foundation

/// Flashcards written straight into a note, RemNote-style: a line `term :: definition` is a card
/// in the course's deck, kept in step with the note. Change the definition and the card's back
/// follows, keeping its schedule; delete the line and the card goes. The note owns the text, so
/// the card editor sends you back to it rather than letting the two drift apart.
enum NoteCards {
    /// Spaces around the `::`, so `std::vector` and an Anki `{{c1::…}}` stay text.
    private static let separator = #"\s+::\s+"#
    /// A list marker or checkbox in front of the term isn't part of it.
    private static let marker = #"^(?:[-*•◦▪☐☑]|\d+[.)])\s+"#

    static func parse(_ body: String) -> [(front: String, back: String)] {
        var out: [(front: String, back: String)] = [], seen = Set<String>()
        for line in body.components(separatedBy: .newlines) {
            guard let r = line.range(of: separator, options: .regularExpression) else { continue }
            let front = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: marker, with: "", options: .regularExpression)
            let back = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !front.isEmpty, !back.isEmpty, front.count <= 300, back.count <= 1_000,
                  seen.insert(key(front)).inserted else { continue }
            out.append((front, back))
        }
        return out
    }

    static func key(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Bring the note's cards in line with its `::` lines. A card is matched to its line by the
    /// term, so a new term is a new card.
    @MainActor
    static func sync(_ note: Note, state: AppState) {
        let lines = parse(note.body)
        let mine = state.data.flashcards.filter { $0.noteID == note.id }
        guard !lines.isEmpty || !mine.isEmpty else { return }
        let byTerm = Dictionary(mine.map { (key($0.front), $0.id) }, uniquingKeysWith: { a, _ in a })
        let terms = Set(lines.map { key($0.front) })
        var cards = state.data.flashcards
        cards.removeAll { $0.noteID == note.id && !terms.contains(key($0.front)) }
        var deckID = mine.first?.deckID    // where they already are, if the student moved them
        for l in lines {
            if let id = byTerm[key(l.front)], let i = cards.firstIndex(where: { $0.id == id }) {
                if cards[i].front != l.front || cards[i].back != l.back { cards[i].front = l.front; cards[i].back = l.back }
            } else {
                let d = deckID ?? deck(for: note, state: state)
                deckID = d
                cards.append(Flashcard(deckID: d, front: l.front, back: l.back, noteID: note.id))
            }
        }
        if cards != state.data.flashcards { state.data.flashcards = cards }
    }

    /// The course's deck, by the name a study pack gives it; made if there isn't one.
    @MainActor
    private static func deck(for note: Note, state: AppState) -> UUID {
        let name = state.course(note.courseID).map { $0.code.isEmpty ? $0.name : $0.code } ?? (note.title.isEmpty ? "Notes" : note.title)
        if let d = state.data.decks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return d.id }
        let d = Deck(name: name, courseID: note.courseID)
        state.data.decks.append(d)
        return d.id
    }
}
