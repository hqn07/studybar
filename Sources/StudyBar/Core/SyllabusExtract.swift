import Foundation

/// AI extraction of a syllabus's structured details — grading breakdown, key dates, policies,
/// office hours and textbooks — as a draft the user reviews before it's applied (propose→accept).
/// Grading rows become `GradeItem`s; the rest is stored on the course's `SyllabusItem`.
struct SyllabusDraft: Hashable {
    var grading: [GradeRow] = []
    var keyDates: [SyllabusDate] = []
    var policies: String = ""
    var officeHours: String = ""
    var textbooks: [String] = []

    struct GradeRow: Identifiable, Hashable { let id = UUID(); var name: String; var weight: Double }

    var isEmpty: Bool {
        grading.isEmpty && keyDates.isEmpty && textbooks.isEmpty
            && policies.isEmpty && officeHours.isEmpty
    }
}

enum SyllabusExtract {
    /// `provider` is nil when no engine is ready → returns nil (attach still works without AI).
    /// `datesOnly` = the fast path: only the schedule dates, so a smaller prompt and less output.
    static func run(_ text: String, provider: AIProvider?, datesOnly: Bool = false) async -> SyllabusDraft? {
        guard let provider, text.count > 40 else { return nil }
        if datesOnly {
            let sys = """
            List EVERY dated deliverable from this course schedule — each homework, quiz and exam — \
            with its due date. Reply with ONLY a JSON array: [{"label":"HW 1","date":"2026-08-24"}]. \
            date is YYYY-MM-DD, inferring the year and month from the term. Include the final exam. \
            No prose outside the JSON array.
            """
            let user = "SYLLABUS SCHEDULE:\n" + scheduleFocus(text)
            guard let out = try? await provider.completePlain(system: sys, messages: [AIMessage(role: .user, text: user)]) else { return nil }
            return parseDates(out)
        }
        let sys = """
        You extract structured facts from a university course syllabus. Reply with ONLY a JSON object:
        {"grading":[{"name":"Homework","weight":20}],\
        "keyDates":[{"label":"HW 1","date":"2026-08-24"}],\
        "policies":"…","officeHours":"…","textbooks":["…"]}
        Rules:
        - grading: include a component ONLY if the syllabus explicitly gives its PERCENTAGE OF THE \
        FINAL GRADE (e.g. "Exams 40%"). Never invent weights, and never use general-education \
        outcome categories (Content, Communication, Critical Thinking) or learning-outcome / \
        "Methods of Evaluation" tables as grades — those are not grade weights. If the syllabus \
        states no explicit percentages, return "grading": [].
        - keyDates: from the course schedule, list EVERY dated deliverable — each homework, quiz \
        and exam — with its due date as YYYY-MM-DD (infer the year and month from the term and the \
        schedule). Include the final exam. Prefer the due date over the assigned date.
        - textbooks: required book title(s) and author.
        - policies: the late-work / attendance policy in one short paragraph.
        - officeHours: instructor office hours if given.
        Use only what the syllabus states. No prose outside the JSON.
        """
        let user = "SYLLABUS:\n" + focus(text)
        guard let out = try? await provider.completePlain(system: sys, messages: [AIMessage(role: .user, text: user)]) else { return nil }
        return parse(out)
    }

    /// Just the schedule region — no front matter — for the fast dates-only path.
    private static func scheduleFocus(_ text: String) -> String {
        let lower = text.lowercased()
        if let a = lower.range(of: "course schedule") ?? lower.range(of: "schedule") {
            return String(text[a.lowerBound...].prefix(14000))
        }
        return String(text.prefix(14000))
    }

    /// Parse a bare JSON array of {label, date} (the dates-only reply).
    static func parseDates(_ raw: String) -> SyllabusDraft? {
        guard let s = raw.firstIndex(of: "["), let e = raw.lastIndex(of: "]"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        var dates: [SyllabusDate] = []
        for k in arr {
            let l = (k["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dt = (k["date"] as? String).flatMap { df.date(from: $0) }
            if !l.isEmpty { dates.append(SyllabusDate(label: l, date: dt)) }
        }
        guard !dates.isEmpty else { return nil }
        var d = SyllabusDraft(); d.keyDates = dates; return d
    }

    /// Keep the front matter (instructor, textbook, office hours) plus the schedule/grading region,
    /// and drop the Gen-Ed boilerplate in the middle — it bloats prompt-eval (slow on a local model)
    /// and its outcome table is exactly what made the grade extraction hallucinate.
    private static func focus(_ text: String) -> String {
        let head = String(text.prefix(3000))
        let lower = text.lowercased()
        let anchor = lower.range(of: "course schedule") ?? lower.range(of: "schedule")
            ?? lower.range(of: "grading") ?? lower.range(of: "evaluation")
        if let a = anchor, a.lowerBound > text.index(text.startIndex, offsetBy: 3000, limitedBy: text.endIndex) ?? text.startIndex {
            return head + "\n\n[…]\n\n" + String(text[a.lowerBound...].prefix(13000))
        }
        return String(text.prefix(16000))
    }

    static func parse(_ raw: String) -> SyllabusDraft? {
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var d = SyllabusDraft()
        for g in (obj["grading"] as? [[String: Any]] ?? []) {
            let n = (g["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let w = number(g["weight"])   // weight may come back "7.5%", "7.5", 7.5, or 7
            if !n.isEmpty { d.grading.append(.init(name: n, weight: max(0, min(100, w)))) }
        }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        for k in (obj["keyDates"] as? [[String: Any]] ?? []) {
            let l = (k["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dt = (k["date"] as? String).flatMap { df.date(from: $0) }
            if !l.isEmpty { d.keyDates.append(SyllabusDate(label: l, date: dt)) }
        }
        d.policies = (obj["policies"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        d.officeHours = (obj["officeHours"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // textbooks may be plain strings or objects {title, author, edition, …}.
        if let arr = obj["textbooks"] as? [String] {
            d.textbooks = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let arr = obj["textbooks"] as? [[String: Any]] {
            d.textbooks = arr.compactMap { t in
                let parts = ["title", "author", "edition"].compactMap { (t[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
        }
        return d.isEmpty ? nil : d
    }

    /// Coerce a JSON number that might arrive as a Double, Int, or a string like "7.5%".
    private static func number(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s.filter { $0.isNumber || $0 == "." }) ?? 0 }
        return 0
    }
}
