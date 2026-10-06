import Foundation

/// Ranked, typo-tolerant matching for every search box — offline, pure, no dependency.
/// `score(query, text)` returns nil for no match, or a relevance score where higher is
/// better, so results sort by how well they match instead of by data order. Three tiers,
/// strongest first: exact substring · subsequence (small gaps allowed) · fuzzy word (edit
/// distance, catches typos like "assignmnet" → "Assignment").
enum FuzzyMatch {
    /// Best match score of `query` against `text`, or nil if it doesn't match at all.
    static func score(_ query: String, _ text: String) -> Double? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }

        // 1) exact substring — strongest; bonus at the start of the text or a word.
        if let r = t.range(of: q) {
            let at = t.distance(from: t.startIndex, to: r.lowerBound)
            var s = 120.0 - Double(at) * 0.3
            if at == 0 { s += 50 }
            else if t[t.index(before: r.lowerBound)] == " " { s += 30 }
            if q.count == t.count { s += 40 }                 // whole-string exact
            return s
        }
        // 2) subsequence — all query chars appear in order (omissions / spread out).
        if let s = subsequenceScore(Array(q), Array(t)) { return s }
        // 3) fuzzy per word — typo tolerance against each word of the text.
        return fuzzyWordScore(q, t)
    }

    /// Best-of: does `query` match `text` at all (for filtering)?
    static func matches(_ query: String, _ text: String) -> Bool { score(query, text) != nil }

    /// Highest score of `query` across several fields (title, body, tags…). nil if none match.
    static func best(_ query: String, _ fields: [String]) -> Double? {
        fields.compactMap { score(query, $0) }.max()
    }

    // MARK: - Subsequence

    /// The query's letters in order, in the tightest stretch of the text that holds them — and
    /// only while that stretch stays short. A whole note body holds "o…h…m" somewhere in nearly
    /// every paragraph, so with the letters allowed to spread anywhere, "ohm" found every note.
    private static func subsequenceScore(_ q: [Character], _ t: [Character]) -> Double? {
        let limit = q.count * 2                                   // "mp2" in "MAP2302", not "o… h… m"
        var best: (start: Int, span: Int)?
        for start in t.indices where t[start] == q[0] {
            var qi = 1, ti = start + 1
            while qi < q.count, ti < t.count, ti - start < limit {
                if t[ti] == q[qi] { qi += 1 }
                ti += 1
            }
            guard qi == q.count else { continue }
            let span = ti - start
            if best == nil || span < best!.span { best = (start, span) }
            if span == q.count { break }
        }
        guard let best else { return nil }
        var s = 60.0 - Double(best.span - q.count) * 3                                       // tighter is better
        if best.start == 0 || t[best.start - 1] == " " { s += 8 }                           // word-start bonus
        s -= Double(best.start) * 0.05                                                       // earlier is better
        return max(1, s)
    }

    // MARK: - Fuzzy word (bounded edit distance)

    private static func fuzzyWordScore(_ q: String, _ t: String) -> Double? {
        // Three letters is too short to forgive: one edit from "ohm" is "oh", "om", "ohs"…
        guard q.count >= 4 else { return nil }
        let words = t.split { $0 == " " || $0 == "-" || $0 == "/" || $0 == "," }.map(String.init)
        var best: Double? = nil
        for w in words {
            // Only compare words of comparable length (a typo shifts length by ≤ a couple).
            guard abs(w.count - q.count) <= 2 else { continue }
            let d = editDistance(Array(q), Array(w))
            let tolerance = max(1, q.count / 4)                   // ~1 typo per 4 chars
            if d <= tolerance {
                let sim = 1 - Double(d) / Double(max(q.count, w.count))
                best = max(best ?? 0, 20 + sim * 25)             // below subsequence, above nothing
            }
        }
        return best
    }

    /// Standard Levenshtein. Inputs are short (query words), so the full DP is fine.
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1]
                       : 1 + min(prev[j - 1], prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - Self-test (StudyBar --search-selftest)

enum SearchSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ cond: Bool) {
            print(cond ? "  ok    \(name)" : "  FAIL  \(name)"); cond ? (pass += 1) : (fail += 1)
        }
        func s(_ q: String, _ t: String) -> Double { FuzzyMatch.score(q, t) ?? -1 }

        check("exact substring matches", s("assign", "Assignment") > 0)
        check("prefix beats mid-string",
              s("map", "MAP2302") > s("map", "Roadmap review"))
        check("subsequence matches with gaps", s("mp2", "MAP2302") > 0)
        check("typo tolerated (assignmnet → Assignment)", s("assignmnet", "Assignment") > 0)
        check("non-match returns nil", FuzzyMatch.score("zzzq", "Assignment") == nil)
        check("empty query no match", FuzzyMatch.score("", "x") == nil)
        check("whole-string exact ranks highest",
              s("essay", "essay") > s("essay", "essay outline for chem"))
        // A long body holds most letters somewhere; scattered ones must not count as a match.
        let body = "Today we look at how the current through a resistor changes with the voltage. One more thing: homework is due on Monday."
        check("scattered letters in a long body don't match (ohm)", FuzzyMatch.score("ohm", body) == nil)
        check("the word itself still matches", s("ohm", "Ohm's law: V = IR") > 0)
        check("a close-together subsequence still matches", s("ohmlaw", "Ohm's law") > 0)
        check("three letters aren't forgiven a typo", FuzzyMatch.score("ohm", "oh, and the om") == nil)
        check("a tight match beats a looser one", s("mp2", "MAP2302") > s("mp2", "M a p 2"))
        check("best-of fields picks the match",
              (FuzzyMatch.best("chem", ["Lab report", "CHEM2045"]) ?? -1) > 0)

        print(fail == 0 ? "SEARCH SELFTEST: ALL PASS (\(pass))" : "SEARCH SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
