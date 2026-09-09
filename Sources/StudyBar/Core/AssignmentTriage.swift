import Foundation

/// Sorting a term of imported coursework into what it actually is.
///
/// A Canvas feed arrives as one flat list: `L7 section 2.4` sits next to
/// `SEPTEMBER 10 ATTENDANCE` and `Connect Overview Video`, and nothing distinguishes the work
/// that needs doing from the housekeeping that doesn't. 179 open items and none ever ticked
/// off is what that produces.
///
/// Obvious cases are decided in code — they are stable, free, and don't need a model's opinion.
/// The rest go to the *ask* engine (Settings ▸ Intelligence), because this is exactly the
/// fuzzy semantic judgement a small local model was measured to be unreliable at: the earlier
/// AI duplicate-scan was dropped for grouping "Homework 1" with "Quiz 3".
///
/// Nothing is written without review. The proposal is a list you edit and apply.
enum AssignmentTriage {

    enum Kind: String, CaseIterable, Codable {
        case work, attendance, admin

        var label: String {
            switch self {
            case .work: "Work"; case .attendance: "Attendance"; case .admin: "Admin"
            }
        }
        var blurb: String {
            switch self {
            case .work:       "Something to study, write or submit"
            case .attendance: "Turning up — nothing to prepare"
            case .admin:      "Housekeeping: syllabus quizzes, uploads, orientation"
            }
        }
        var symbol: String {
            switch self {
            case .work: "book.closed"; case .attendance: "hand.raised"; case .admin: "tray"
            }
        }
    }

    struct Proposal: Identifiable, Equatable {
        let id: UUID            // the assignment
        let title: String
        var kind: Kind
        var reason: String
        var accepted = true
        /// Decided in code rather than by the model.
        var deterministic = false
    }

    // MARK: - The part that doesn't need a model

    /// Titles whose kind is not a judgement call. Ordered: the first match wins.
    private static let rules: [(pattern: String, kind: Kind, why: String)] = [
        (#"(?i)\battendance\b"#, .attendance, "Says attendance"),
        // Graded work is claimed *before* anything else can mistake it for housekeeping.
        // The bare-date rule below used to read "any short word then a number", which filed
        // Exam 1, Homework 2 and Quiz 3 as attendance — the exact failure this feature must
        // never make, since a hidden exam is worse than a visible attendance check.
        (#"(?i)^\s*(exam|midterm|final|quiz|test|homework|hw|assignment|lab|project|essay|paper)\b"#, .work, "Graded work"),
        // A real date: a month name, not just any word. "Aug 26", "September 3rd".
        (#"(?i)^\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*\d{1,2}(st|nd|rd|th)?\s*$"#,
         .attendance, "A date, not a task"),
        (#"(?i)\bsyllabus\s+(quiz|acknowledg|agreement)"#, .admin, "Syllabus acknowledgement"),
        (#"(?i)\b(orientation|overview\s+video|getting\s+started|welcome)\b"#, .admin, "Course orientation"),
        (#"(?i)\b(transcript|upload\s+your|photo\s+upload|profile)\b"#, .admin, "Paperwork"),
        (#"(?i)\bhandbook\s+quiz\b"#, .admin, "Handbook acknowledgement"),
        (#"(?i)\b(exam|midterm|final|project|essay|paper|lab\s*report|problem\s*set|homework|hw)\b"#, .work, "Graded work"),
        (#"(?i)\b(quiz|assignment|reading|section|module|chapter|lecture)\b"#, .work, "Coursework"),
    ]

    static func deterministic(_ title: String) -> (kind: Kind, why: String)? {
        for r in rules where title.range(of: r.pattern, options: .regularExpression) != nil {
            return (r.kind, r.why)
        }
        return nil
    }

    // MARK: - The part that does

    static let batchSize = 40

    static func systemPrompt() -> String {
        """
        You sort a student's imported coursework into three kinds so their assignment list can \
        show the work and set the housekeeping aside.

        work — something to study, write, solve or submit: quizzes, problem sets, readings, \
        lab work, exams, projects, lecture sections.
        attendance — being present. Attendance checks, sign-ins, a bare date used as a roll call.
        admin — housekeeping that is graded but isn't study: syllabus quizzes, handbook \
        acknowledgements, orientation videos, transcript or photo uploads, profile setup.

        Reply with ONLY a JSON array, one object per numbered item, no prose:
        [{"i": 1, "kind": "work", "why": "four words"}]

        Judge from the title as a student would read it. When a title is ambiguous, choose work \
        — hiding something real is worse than leaving housekeeping in the list. Keep "why" under \
        six words.
        """
    }

    static func userPrompt(_ items: [(index: Int, title: String)]) -> String {
        items.map { "\($0.index). \($0.title)" }.joined(separator: "\n")
    }

    /// Tolerant of the wrappers models add: fenced blocks, a leading sentence, trailing commas.
    static func parse(_ raw: String, count: Int) -> [(index: Int, kind: Kind, why: String)] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else { return [] }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [(Int, Kind, String)] = []
        for o in arr {
            guard let i = (o["i"] as? Int) ?? (o["i"] as? NSNumber)?.intValue, i >= 1, i <= count,
                  let k = (o["kind"] as? String).flatMap({ Kind(rawValue: $0.lowercased()) }) else { continue }
            out.append((i, k, (o["why"] as? String) ?? ""))
        }
        return out
    }

    // MARK: - Running it

    /// Classify everything untriaged: rules first, then one request per `batchSize` leftovers.
    /// Uses the *ask* engine — this is judgement, and the local model was measured unreliable
    /// at exactly this kind of call.
    @MainActor
    static func classify(_ assignments: [Assignment],
                         progress: @MainActor (Int, Int) -> Void = { _, _ in }) async -> [Proposal] {
        var proposals: [Proposal] = []
        var unresolved: [(index: Int, id: UUID, title: String)] = []

        for a in assignments {
            if let d = deterministic(a.title) {
                proposals.append(Proposal(id: a.id, title: a.title, kind: d.kind, reason: d.why, deterministic: true))
            } else {
                unresolved.append((unresolved.count + 1, a.id, a.title))
            }
        }
        guard !unresolved.isEmpty, let provider = AIService.makeProvider(for: .ask) else {
            // No engine: the rules still did most of it, and the rest stay unclassified rather
            // than being guessed at.
            return proposals
        }

        let batches = stride(from: 0, to: unresolved.count, by: batchSize).map {
            Array(unresolved[$0..<min($0 + batchSize, unresolved.count)])
        }
        for (n, batch) in batches.enumerated() {
            progress(n, batches.count)
            let numbered = batch.enumerated().map { (index: $0.offset + 1, title: $0.element.title) }
            let reply = try? await provider.completePlain(
                system: systemPrompt(),
                messages: [AIMessage(role: .user, text: userPrompt(numbered))])
            for hit in parse(reply ?? "", count: batch.count) {
                let item = batch[hit.index - 1]
                proposals.append(Proposal(id: item.id, title: item.title, kind: hit.kind, reason: hit.why))
            }
        }
        progress(batches.count, batches.count)
        return proposals
    }
}

// MARK: - Self-test (StudyBar --triage-selftest)

enum TriageSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            ok ? { print("  ok   \(name)\(detail.isEmpty ? "" : " (\(detail))")"); pass += 1 }()
               : { print("  FAIL \(name) \(detail)"); fail += 1 }()
        }
        func kind(_ t: String) -> AssignmentTriage.Kind? { AssignmentTriage.deterministic(t)?.kind }

        // Real titles out of the live store.
        check("attendance by name", kind("SEPTEMBER 10 ATTENDANCE") == .attendance)
        check("a bare date is a roll call", kind("Aug 26") == .attendance)
        check("a spelled-out date too", kind("September 3rd") == .attendance)

        // Found by running the rules over the real store: the date rule matched any short
        // word followed by a number, so exams and homework were being filed as attendance.
        check("Exam 1 is work", kind("Exam 1") == .work)
        check("Exam 2 is work", kind("Exam 2") == .work)
        check("Homework 1 is work", kind("Homework 1") == .work)
        check("QUIZ 1 is work", kind("QUIZ 1") == .work)
        check("Quiz 5 is work", kind("Quiz 5") == .work)
        check("Test 3 is work", kind("Test 3") == .work)
        check("Lab 2 is work", kind("Lab 2") == .work)
        check("Project 1 is work", kind("Project 1") == .work)
        check("syllabus quiz is admin", kind("Syllabus Quiz") == .admin)
        check("module-prefixed syllabus quiz too", kind("Module 01: Syllabus Quiz") == .admin)
        check("handbook quiz is admin", kind("Module 01: Handbook Quiz") == .admin)
        check("orientation video is admin", kind("Connect Overview Video") == .admin)
        check("transcript upload is admin", kind("Transient Summer Grades Transcript Upload") == .admin)
        check("lecture section is work", kind("L7 section 2.4") == .work)
        check("lecture quiz is work", kind("Lecture Quiz 7") == .work)
        check("module quiz is work", kind("Module 03: Chapter 2 - US & Canada Quiz") == .work)
        check("numbered quiz is work", kind("Quiz 3.2") == .work)

        // Admin rules must beat the generic "quiz" rule — order matters.
        check("admin wins over the quiz rule", kind("Syllabus Quiz") != .work)

        // Genuinely ambiguous titles are left for the model rather than guessed at.
        check("unknown shape defers to the model", AssignmentTriage.deterministic("Precalc Review") == nil)
        check("bare topic defers", AssignmentTriage.deterministic("Cash Flow Diagrams") == nil)

        // Parsing what a model actually returns.
        let fenced = """
        Here you go:
        ```json
        [{"i": 1, "kind": "work", "why": "problem set"}, {"i": 2, "kind": "admin", "why": "syllabus"}]
        ```
        """
        let parsed = AssignmentTriage.parse(fenced, count: 2)
        check("parses a fenced, prefaced reply", parsed.count == 2)
        check("keeps index and kind", parsed.first?.index == 1 && parsed.first?.kind == .work)
        check("drops out-of-range indexes", AssignmentTriage.parse(#"[{"i": 99, "kind": "work"}]"#, count: 2).isEmpty)
        check("drops unknown kinds", AssignmentTriage.parse(#"[{"i": 1, "kind": "banana"}]"#, count: 2).isEmpty)
        check("survives junk", AssignmentTriage.parse("no json here", count: 2).isEmpty)

        print(fail == 0 ? "TRIAGE SELFTEST: ALL PASS (\(pass))" : "TRIAGE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
