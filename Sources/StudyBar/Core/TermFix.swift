import AppKit

/// A misheard term fixed everywhere it appears: "ferrets" → "farads". Whole words only, any
/// case, and a capital stays a capital ("Ferrets are…" → "Farads are…"). Plain text and a
/// note's rich text alike, so the two never disagree.
enum TermFix {
    private static func regex(_ find: String) -> NSRegularExpression? {
        let f = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: f) + #"(?![\p{L}\p{N}])"#,
                                        options: .caseInsensitive)
    }

    /// The replacement in the original's case: a capital where it had one — but only one the
    /// sentence gave it. "I can value" → "eigenvalue" stays lower case: the I was the term's own.
    private static func cased(_ new: String, like old: String, find: String) -> String {
        guard let o = old.first, o.isUppercase, find.first?.isLowercase == true,
              let n = new.first, n.isLowercase else { return new }
        return n.uppercased() + new.dropFirst()
    }

    static func count(_ text: String, _ find: String) -> Int {
        regex(find)?.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
    }

    static func replace(_ text: String, _ find: String, with new: String) -> (text: String, count: Int) {
        guard let re = regex(find) else { return (text, 0) }
        let m = NSMutableString(string: text)
        let n = replace(in: m, re: re, find: find, with: new)
        return (m as String, n)
    }

    /// In place, keeping each match's formatting (bold, highlight, a heading's size).
    @discardableResult
    static func replace(in rich: NSMutableAttributedString, _ find: String, with new: String) -> Int {
        guard let re = regex(find) else { return 0 }
        let matches = re.matches(in: rich.string, range: NSRange(location: 0, length: rich.length))
        for match in matches.reversed() {
            rich.replaceCharacters(in: match.range, with: cased(new, like: (rich.string as NSString).substring(with: match.range), find: find))
        }
        return matches.count
    }

    private static func replace(in s: NSMutableString, re: NSRegularExpression, find: String, with new: String) -> Int {
        let matches = re.matches(in: s as String, range: NSRange(location: 0, length: s.length))
        for match in matches.reversed() {
            s.replaceCharacters(in: match.range, with: cased(new, like: s.substring(with: match.range), find: find))
        }
        return matches.count
    }

    /// A note with the term fixed in its title, text and rich text; nil if it never says it.
    static func fixed(_ note: Note, _ find: String, with new: String) -> (note: Note, count: Int)? {
        var n = note
        let body = replace(note.body, find, with: new), title = replace(note.title, find, with: new)
        guard body.count + title.count > 0 else { return nil }
        n.body = body.text; n.title = title.text
        if let data = note.rich, let attr = NSAttributedString.fromRTFD(data) {
            let m = NSMutableAttributedString(attributedString: attr)
            replace(in: m, find, with: new)
            n.rich = m.rtfdData()
        }
        n.updatedAt = .now
        return (n, body.count + title.count)
    }

    /// Remember the right word for the course, so recognition expects it next time.
    static func learn(_ word: String, course: UUID?, in data: inout AppData) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, let i = data.courses.firstIndex(where: { $0.id == course }) else { return }
        var words = data.courses[i].words ?? []
        guard !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        words.append(w)
        data.courses[i].words = words
    }
}
