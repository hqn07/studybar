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
    static func run(_ text: String, provider: AIProvider?) async -> SyllabusDraft? {
        guard let provider, text.count > 40 else { return nil }
        let sys = """
        Extract structured info from a course syllabus. Reply with ONLY a JSON object:
        {"grading":[{"name":"Exams","weight":40}],"keyDates":[{"label":"Midterm","date":"2026-10-15"}],\
        "policies":"…","officeHours":"…","textbooks":["…"]}
        - weight is a percent as a number. Grading rows should roughly sum to 100.
        - date is YYYY-MM-DD, or omit it if the syllabus doesn't give one.
        - Use ONLY what the syllabus states; leave a field empty/[] if it's not there. No prose outside the JSON.
        """
        let user = "SYLLABUS:\n" + String(text.prefix(8000))
        guard let out = try? await provider.completePlain(system: sys, messages: [AIMessage(role: .user, text: user)]) else { return nil }
        return parse(out)
    }

    static func parse(_ raw: String) -> SyllabusDraft? {
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var d = SyllabusDraft()
        for g in (obj["grading"] as? [[String: Any]] ?? []) {
            let n = (g["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let w = (g["weight"] as? Double) ?? Double(g["weight"] as? Int ?? 0)
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
        d.textbooks = (obj["textbooks"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return d.isEmpty ? nil : d
    }
}
