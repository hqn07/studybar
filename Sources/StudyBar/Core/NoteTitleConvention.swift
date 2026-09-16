import Foundation

/// Naming a new note the way this course's notes are already named.
///
/// A voice note used to be saved as "Voice note Sep 15", which tells you nothing and sorts
/// next to nothing. But there is no single house style to impose: in a real store PHY2049's
/// notes are "Weeks 4 — Gauss's Law", URP2001's are "An Urban World — Lecture 1", and
/// EIN3354's are bare topics like "Annuities". So the convention is *read* from the course,
/// not decided here — and titles that disagree with the majority are ignored rather than
/// averaged in, because one stray "PHY2049" should not make every future note look like it.
enum NoteTitleConvention {

    /// The shape of a title, with the spelling that shape was written in — "Week" and "Weeks",
    /// "#4" and "4" are the same shape but not the same house style, and copying the majority's
    /// spelling is most of what makes a generated title look like it belongs.
    enum Shape: Equatable, Hashable {
        /// "Weeks #4 — Gauss's Law"
        case weekTopic(word: String, hash: Bool, separator: String)
        /// "An Urban World — Lecture 1"
        case topicOrdinal(word: String, separator: String)
        /// "Annuities"
        case plain

        /// Shapes group into families first: which *kind* of title this course uses is a
        /// stronger signal than which spelling of it, and the spelling is settled inside the
        /// winning family.
        var family: String {
            switch self {
            case .weekTopic:    return "week"
            case .topicOrdinal: return "ordinal"
            case .plain:        return "plain"
            }
        }
    }

    struct Parsed: Equatable {
        let shape: Shape
        /// The week or lecture number, when the shape carries one.
        let number: Int?
        let topic: String
    }

    private static let weekRE = try! NSRegularExpression(
        pattern: #"^\s*(Weeks?)\s+(#?)(\d+)\s*([—–-])\s*(.+?)\s*$"#, options: [.caseInsensitive])
    private static let ordinalRE = try! NSRegularExpression(
        pattern: #"^\s*(.+?)\s*([—–-])\s*(Lecture|Lec|Class|Session|Part|Day)\s+(#?)(\d+)\s*$"#,
        options: [.caseInsensitive])

    static func parse(_ title: String) -> Parsed? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let ns = t as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let m = weekRE.firstMatch(in: t, range: full) {
            return Parsed(shape: .weekTopic(word: ns.substring(with: m.range(at: 1)),
                                            hash: ns.substring(with: m.range(at: 2)) == "#",
                                            separator: ns.substring(with: m.range(at: 4))),
                          number: Int(ns.substring(with: m.range(at: 3))),
                          topic: ns.substring(with: m.range(at: 5)))
        }
        if let m = ordinalRE.firstMatch(in: t, range: full) {
            return Parsed(shape: .topicOrdinal(word: ns.substring(with: m.range(at: 3)),
                                               separator: ns.substring(with: m.range(at: 2))),
                          number: Int(ns.substring(with: m.range(at: 5))),
                          topic: ns.substring(with: m.range(at: 1)))
        }
        return Parsed(shape: .plain, number: nil, topic: t)
    }

    /// The house style of a course, or nil when its notes do not agree on one.
    ///
    /// `courseCode` is excluded because a note titled with nothing but the course code
    /// ("PHY2049") is a placeholder, not a convention, and there are several in a real store.
    /// `minimum` guards the other direction: one note cannot establish a house style.
    static func detect(titles: [String], courseCode: String? = nil, minimum: Int = 2) -> Shape? {
        let usable = titles.filter { t in
            let trimmed = t.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            if let code = courseCode, trimmed.caseInsensitiveCompare(code) == .orderedSame { return false }
            return true
        }
        let parsed = usable.compactMap { parse($0) }
        guard parsed.count >= minimum else { return nil }

        var byFamily: [String: [Parsed]] = [:]
        for p in parsed { byFamily[p.shape.family, default: []].append(p) }
        guard let winner = byFamily.max(by: { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.key > rhs.key : lhs.value.count < rhs.value.count
        }), winner.value.count >= minimum else { return nil }

        // Inside the winning family, the most common exact spelling wins.
        var byShape: [Shape: Int] = [:]
        for p in winner.value { byShape[p.shape, default: 0] += 1 }
        return byShape.max { $0.value < $1.value }?.key
    }

    /// Build the next title in a course's own style.
    static func title(topic: String, shape: Shape?, existing titles: [String],
                      date: Date = .now, termStart: Date? = nil) -> String {
        let topic = clean(topic)
        guard let shape else { return fallback(topic: topic, date: date) }
        switch shape {
        case .weekTopic(let word, let hash, let separator):
            // The term calendar is the truth for a week number; only when there is no term
            // does the sequence fall back to "one past the highest week already written".
            let n = SemesterWeek.number(for: date, termStart: termStart)
                ?? ((numbers(in: titles, family: "week").max() ?? 0) + 1)
            return "\(word) \(hash ? "#" : "")\(n) \(separator) \(topic)"
        case .topicOrdinal(let word, let separator):
            let n = (numbers(in: titles, family: "ordinal").max() ?? 0) + 1
            return "\(topic) \(separator) \(word) \(n)"
        case .plain:
            return topic
        }
    }

    /// No convention to follow: date first, so a pile of them still sorts and scans.
    static func fallback(topic: String, date: Date = .now) -> String {
        let t = clean(topic)
        return t.isEmpty ? date.dayMonth : "\(date.dayMonth) — \(t)"
    }

    private static func numbers(in titles: [String], family: String) -> [Int] {
        titles.compactMap { parse($0) }.filter { $0.shape.family == family }.compactMap(\.number)
    }

    /// The subject of a note, taken from what the organizer already wrote: its first heading,
    /// else its first real line. Free and instant — the AI ran a moment ago and gave the note
    /// a heading, so asking a model again to name what it just named is a round trip for
    /// nothing.
    static func topic(fromNoteBody body: String) -> String {
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                return clean(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            }
            // A bold first line is how several engines open a summary.
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                return clean(String(line.dropFirst(2).dropLast(2)))
            }
            return clean(line)
        }
        return ""
    }

    /// Trim the punctuation and markup a heading tends to carry, and keep it short enough to
    /// read in a list row.
    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;—–-"))
        if t.count > 60 {
            let cut = t.prefix(60)
            t = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return t
    }
}

// MARK: - Self-test (StudyBar --title-selftest)

/// The fixtures are the title shapes of a real store, outliers included — that is the point.
enum NoteTitleSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want { print("  ok   \(name)"); pass += 1 }
            else { print("  FAIL \(name): got \(got.debugDescription) want \(want.debugDescription)"); fail += 1 }
        }
        func checkB(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(name)"); pass += 1 } else { print("  FAIL \(name) \(detail)"); fail += 1 }
        }

        let phy = ["PHY2049", "Weeks 3 — Gauss's Law", "Weeks 3 — Gauss's Law II",
                   "Weeks 4 — Gauss's Law Pt.3", "Weeks #4 — Electrical Potential",
                   "Weeks #4 — Eletrical Potential II"]
        let urp = ["An Urban World — Lecture 1", "The Urban City — Lecture 2",
                   "An Urban Location — Lecture 3", "Weeks 4 — US and Canada"]
        let ein = ["Week 3 — Present Value & Future Value", "Effective Interest", "Annuities",
                   "Effective Interest and Annuities problems"]
        let orh = ["Artifical Breeding and Natural Selection", "Weeks #3 — ORH1030", "Weeks #3 — ORH1030"]

        // A term that started five weeks ago puts "now" in week 5.
        let termStart = Calendar.current.date(byAdding: .day, value: -29, to: .now)
        let today = Date.now

        // Majority shape per course, outliers ignored.
        let phyShape = NoteTitleConvention.detect(titles: phy, courseCode: "PHY2049")
        check("physics keeps its own spelling",
              NoteTitleConvention.title(topic: "Capacitance", shape: phyShape, existing: phy,
                                        date: today, termStart: termStart),
              "Weeks 5 — Capacitance")
        let urpShape = NoteTitleConvention.detect(titles: urp, courseCode: "URP2001")
        check("a lecture series counts on",
              NoteTitleConvention.title(topic: "Migration and Cities", shape: urpShape, existing: urp,
                                        date: today, termStart: termStart),
              "Migration and Cities — Lecture 4")
        let einShape = NoteTitleConvention.detect(titles: ein, courseCode: "EIN3354")
        check("bare topics stay bare",
              NoteTitleConvention.title(topic: "Bond Valuation", shape: einShape, existing: ein,
                                        date: today, termStart: termStart),
              "Bond Valuation")
        let orhShape = NoteTitleConvention.detect(titles: orh, courseCode: "ORH1030")
        check("the hash is part of the house style",
              NoteTitleConvention.title(topic: "Grafting", shape: orhShape, existing: orh,
                                        date: today, termStart: termStart),
              "Weeks #5 — Grafting")

        // One note proves nothing, and a course code is not a convention.
        checkB("a single note sets no convention",
               NoteTitleConvention.detect(titles: ["Week 4 — Intro. to Civil Engineering"],
                                          courseCode: "CGN2002") == nil)
        checkB("a bare course code is ignored",
               NoteTitleConvention.detect(titles: ["PHY2049L"], courseCode: "PHY2049L") == nil)
        check("no convention falls back to date and topic",
              NoteTitleConvention.title(topic: "Thermal Expansion", shape: nil, existing: [],
                                        date: today, termStart: termStart),
              "\(today.dayMonth) — Thermal Expansion")

        // Without a term, the week number continues the sequence already written.
        check("no term calendar continues the sequence",
              NoteTitleConvention.title(topic: "Capacitance", shape: phyShape, existing: phy,
                                        date: today, termStart: nil),
              "Weeks 5 — Capacitance")

        // Topic extraction from what the organizer wrote.
        check("topic comes from the first heading",
              NoteTitleConvention.topic(fromNoteBody: "## Gauss's Law and Applications\n\n- flux\n"),
              "Gauss's Law and Applications")
        check("a bold opener works too",
              NoteTitleConvention.topic(fromNoteBody: "**Ohm's Law**\nsome text"), "Ohm's Law")
        check("otherwise the first real line",
              NoteTitleConvention.topic(fromNoteBody: "\n\nToday we covered resistors.\n"),
              "Today we covered resistors")
        check("a long heading is cut to fit a row",
              NoteTitleConvention.topic(fromNoteBody: "# " + String(repeating: "verylongword ", count: 12)).count <= 61
                ? "short" : "long", "short")

        // Parsing details that the renderer depends on.
        checkB("an em dash and a hyphen are both separators",
               NoteTitleConvention.parse("Week 2 - Something")?.number == 2)
        checkB("a plain title parses as plain",
               NoteTitleConvention.parse("Annuities")?.shape == .plain)

        print(fail == 0 ? "TITLE SELFTEST: ALL PASS (\(pass))" : "TITLE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
