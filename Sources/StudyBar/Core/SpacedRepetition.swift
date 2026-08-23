import Foundation

/// SM-2 spaced repetition. `quality` 0–5 (blast from Again..Easy).
enum SM2 {
    enum Grade: Int, CaseIterable {
        case again = 1, hard = 3, good = 4, easy = 5
        var label: String { ["", "Again", "", "Hard", "Good", "Easy"][rawValue] }
    }

    /// Short label for the interval a grade would produce (shown on the grade buttons).
    static func intervalPreview(_ card: Flashcard, grade: Grade) -> String {
        if grade == .again { return "10m" }
        let n = apply(card, grade: grade)
        if n.interval >= 365 { return "\(n.interval / 365)y" }
        if n.interval >= 30 { return "\(n.interval / 30)mo" }
        return "\(max(1, n.interval))d"
    }

    static func apply(_ card: Flashcard, grade: Grade) -> Flashcard {
        var c = card
        let q = Double(grade.rawValue)
        c.reviews += 1
        if grade == .again {
            c.reps = 0
            c.interval = 1
            c.lapses += 1
        } else {
            switch c.reps {
            case 0: c.interval = 1
            case 1: c.interval = 6
            default: c.interval = Int((Double(c.interval) * c.ease).rounded())
            }
            c.reps += 1
        }
        c.ease = max(1.3, c.ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)))
        c.due = Calendar.current.date(byAdding: .day, value: max(1, c.interval), to: .now) ?? .now
        // "Again" comes back within the same session (10 min).
        if grade == .again {
            c.due = Calendar.current.date(byAdding: .minute, value: 10, to: .now) ?? .now
        }
        return c
    }
}
