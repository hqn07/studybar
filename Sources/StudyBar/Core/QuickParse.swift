import Foundation

/// Parses a natural-language quick-add line into a structured entry — offline,
/// instant, no AI. e.g. "essay due friday for chem" → an assignment titled
/// "essay", course CHEM, due this Friday at 23:59.
enum QuickParse {
    struct Result: Equatable {
        var title: String = ""
        var courseID: UUID? = nil
        var due: Date? = nil
        var priority: Int = 1          // 0 low · 1 normal · 2 high
        var isAssignment: Bool = false
    }

    private static let keywords = ["essay", "quiz", "exam", "test", "midterm", "final",
        "homework", "hw", "assignment", "reading", "read", "problem set", "pset", "ps",
        "project", "lab", "paper", "report", "draft", "worksheet", "discussion", "study"]

    private static let priorityWords: [(String, Int)] = [
        ("high priority", 2), ("low priority", 0), ("urgent", 2), ("important", 2),
        ("high", 2), ("low", 0)]

    static func parse(_ raw: String, courses: [Course], now: Date = .now, calendar: Calendar = .current) -> Result {
        var r = Result()
        let lower = raw.lowercased()
        var work = raw

        // 1) priority
        if raw.contains("!") { r.priority = 2 }
        for (word, pri) in priorityWords where containsWord(lower, word) { r.priority = pri; break }

        // 2) course (strip the matched token from the working title)
        if let (id, token) = matchCourse(raw, courses) {
            r.courseID = id
            work = strip(token, from: work)
        }

        // 3) due date
        if let (date, span) = matchDate(work.lowercased(), now: now, cal: calendar) {
            r.due = endOfDay(date, cal: calendar)
            work = strip(span, from: work)
        }

        // 4) type
        let hasKeyword = keywords.contains { containsWord(lower, $0) }
        r.isAssignment = r.due != nil || r.courseID != nil || hasKeyword

        // 5) title = cleaned remainder
        r.title = cleanTitle(work)
        if r.title.isEmpty { r.title = raw.trimmingCharacters(in: .whitespaces) }
        return r
    }

    // MARK: - Course

    private static func matchCourse(_ raw: String, _ courses: [Course]) -> (UUID, String)? {
        let tokens = raw.split(whereSeparator: { " ,.;:".contains($0) }).map(String.init)
        for course in courses {
            let cands = candidates(course)
            for t in tokens {
                let lt = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@#"))
                guard lt.count >= 2 else { continue }
                if cands.contains(where: { $0 == lt || ($0.count >= 3 && lt.count >= 3 && $0.hasPrefix(lt)) }) {
                    return (course.id, t)
                }
            }
        }
        return nil
    }
    private static func candidates(_ c: Course) -> Set<String> {
        var out: Set<String> = []
        if !c.code.isEmpty { out.insert(c.code.lowercased().replacingOccurrences(of: " ", with: "")) }
        let name = c.name.lowercased()
        out.insert(name.replacingOccurrences(of: " ", with: ""))
        for w in name.split(separator: " ") where w.count >= 3 { out.insert(String(w)) }
        return out
    }

    // MARK: - Dates

    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7]
    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12, "january": 1, "february": 2, "march": 3, "april": 4, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12]

    /// Returns (date, matched-lowercased-substring) for the first date phrase found.
    private static func matchDate(_ s: String, now: Date, cal: Calendar) -> (Date, String)? {
        let today = cal.startOfDay(for: now)

        if let m = firstMatch(#"\b(today|tonight|eod|tod)\b"#, s) { return (today, m.whole) }
        if let m = firstMatch(#"\b(tomorrow|tmrw|tmr)\b"#, s) { return (cal.date(byAdding: .day, value: 1, to: today)!, m.whole) }
        if let m = firstMatch(#"\bnext week\b"#, s) { return (cal.date(byAdding: .day, value: 7, to: today)!, m.whole) }

        if let m = firstMatch(#"\bin (\d{1,2}) (day|days|week|weeks)\b"#, s), let n = Int(m.groups[0]) {
            let days = m.groups[1].hasPrefix("week") ? n * 7 : n
            return (cal.date(byAdding: .day, value: days, to: today)!, m.whole)
        }

        if let m = firstMatch(#"\b(next )?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat)\b"#, s),
           let target = weekdays[m.groups[1]] {
            var d = nextWeekday(target, from: today, cal: cal)
            if !m.groups[0].isEmpty { d = cal.date(byAdding: .day, value: 7, to: d)! }
            return (d, m.whole)
        }

        if let m = firstMatch(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, s),
           let mo = months[m.groups[0]], let day = Int(m.groups[1]) {
            return (monthDay(mo, day, today: today, cal: cal), m.whole)
        }

        if let m = firstMatch(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#, s),
           let mo = Int(m.groups[0]), let day = Int(m.groups[1]), (1...12).contains(mo), (1...31).contains(day) {
            let year = m.groups.count > 2 && !m.groups[2].isEmpty ? normalizeYear(Int(m.groups[2]) ?? 0) : nil
            return (explicitDate(mo, day, year, today: today, cal: cal), m.whole)
        }
        return nil
    }

    private static func nextWeekday(_ target: Int, from today: Date, cal: Calendar) -> Date {
        let cur = cal.component(.weekday, from: today)
        let delta = (target - cur + 7) % 7      // 0 = today counts as the soonest match
        return cal.date(byAdding: .day, value: delta, to: today)!
    }
    private static func monthDay(_ mo: Int, _ day: Int, today: Date, cal: Calendar) -> Date {
        let year = cal.component(.year, from: today)
        var c = DateComponents(); c.year = year; c.month = mo; c.day = day
        let d = cal.date(from: c) ?? today
        return d < today ? (cal.date(byAdding: .year, value: 1, to: d) ?? d) : d
    }
    private static func explicitDate(_ mo: Int, _ day: Int, _ year: Int?, today: Date, cal: Calendar) -> Date {
        if let year { var c = DateComponents(); c.year = year; c.month = mo; c.day = day; return cal.date(from: c) ?? today }
        return monthDay(mo, day, today: today, cal: cal)
    }
    private static func normalizeYear(_ y: Int) -> Int { y < 100 ? 2000 + y : y }
    private static func endOfDay(_ d: Date, cal: Calendar) -> Date {
        cal.date(bySettingHour: 23, minute: 59, second: 0, of: d) ?? d
    }

    // MARK: - Title cleanup

    private static func cleanTitle(_ s: String) -> String {
        var t = " " + s + " "
        t = t.replacingOccurrences(of: "!", with: " ")
        for w in ["due", "by", "for", "on the", "high priority", "low priority", "urgent", "important", "high", "low"] {
            t = t.replacingOccurrences(of: " \(w) ", with: " ", options: .caseInsensitive)
        }
        t = t.replacingOccurrences(of: #"[@#]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private static func containsWord(_ haystack: String, _ word: String) -> Bool {
        firstMatch("\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", haystack) != nil
    }
    private static func strip(_ token: String, from s: String) -> String {
        s.replacingOccurrences(of: token, with: " ", options: .caseInsensitive)
    }

    private struct Match { let whole: String; let groups: [String] }
    private static func firstMatch(_ pattern: String, _ s: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            let rg = m.range(at: i)
            groups.append(rg.location == NSNotFound ? "" : ns.substring(with: rg).lowercased())
        }
        return Match(whole: ns.substring(with: m.range).lowercased(), groups: groups)
    }
}
