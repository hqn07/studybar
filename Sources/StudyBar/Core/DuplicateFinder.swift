import Foundation

/// Finds likely-duplicate assignments — the same real task imported from two sources (e.g. a
/// Canvas feed and the syllabus), which have different UIDs so the import dedup misses them.
/// A group is a set of assignments the user reviews; merging keeps one and deletes the rest
/// (undoable — nothing is removed without confirmation).
struct DupGroup: Identifiable {
    let id = UUID()
    var items: [Assignment]     // ≥2, likely the same assignment
    var reason: String
}

enum DuplicateFinder {
    // MARK: Deterministic (fast, safe)

    /// Group open assignments that share a course + due date and have similar titles.
    static func find(_ assignments: [Assignment]) -> [DupGroup] {
        let cal = Calendar.current
        var buckets: [String: [Assignment]] = [:]
        for a in assignments where a.isOpen {
            guard let due = a.due else { continue }   // undated can't be matched confidently
            let day = Int(cal.startOfDay(for: due).timeIntervalSince1970)
            buckets["\(a.courseID?.uuidString ?? "-")|\(day)", default: []].append(a)
        }
        var groups: [DupGroup] = []
        for bucket in buckets.values where bucket.count >= 2 {
            var used = Set<UUID>()
            for i in bucket.indices where !used.contains(bucket[i].id) {
                var cluster = [bucket[i]]
                for j in (i + 1)..<bucket.count where !used.contains(bucket[j].id) {
                    if similar(bucket[i].title, bucket[j].title) {
                        cluster.append(bucket[j]); used.insert(bucket[j].id)
                    }
                }
                if cluster.count >= 2 {
                    used.insert(bucket[i].id)
                    groups.append(DupGroup(items: cluster, reason: "Same due date · similar title"))
                }
            }
        }
        return groups
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let ta = Set(na.split(separator: " ")), tb = Set(nb.split(separator: " "))
        let jac = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        return jac >= 0.6      // conservative — avoid false merges; AI deep-scan catches the rest
    }

    // MARK: - Deep scan
    //
    // The AI pass was built once before and dropped: a 7B grouped "Homework 1" with "Quiz 3",
    // and a wrong merge destroys work. It comes back with the failure designed out rather than
    // prompted away. The model never sees arbitrary pairs — only ones already close enough to
    // be plausible — so a pair with nothing in common cannot be proposed no matter what the
    // model thinks. It also answers a question the fast pass structurally cannot: the same
    // assignment re-imported under a *different* due date, which lands in a different bucket.

    struct Candidate: Identifiable {
        let id = UUID()
        let a: Assignment
        let b: Assignment
        let overlap: Double
        let daysApart: Int
    }

    /// Pairs worth a second opinion: same course, within a week of each other, and either
    /// partially similar, or so similar that only the differing date kept them apart.
    static func candidates(_ assignments: [Assignment]) -> [Candidate] {
        let cal = Calendar.current
        let open = assignments.filter(\.isOpen)
        var byCourse: [String: [Assignment]] = [:]
        for a in open { byCourse[a.courseID?.uuidString ?? "-", default: []].append(a) }

        var out: [Candidate] = []
        for group in byCourse.values where group.count >= 2 {
            for i in group.indices {
                for j in (i + 1)..<group.count {
                    let x = group[i], y = group[j]
                    let days: Int
                    switch (x.due, y.due) {
                    case let (dx?, dy?):
                        days = abs(cal.dateComponents([.day], from: cal.startOfDay(for: dx),
                                                      to: cal.startOfDay(for: dy)).day ?? 99)
                    case (nil, nil): days = 0
                    default: continue          // one dated, one not: too weak to ask about
                    }
                    guard days <= 7 else { continue }
                    let o = overlap(x.title, y.title)
                    let sameDay = days == 0
                    // Below 0.25 there is no shared vocabulary — "Homework 1" and "Quiz 3"
                    // score 0 and can never reach the model.
                    let worthAsking = (o >= 0.25 && o < 0.6) || (o >= 0.6 && !sameDay)
                    if worthAsking { out.append(Candidate(a: x, b: y, overlap: o, daysApart: days)) }
                }
            }
        }
        return out.sorted { $0.overlap > $1.overlap }
    }

    static func overlap(_ a: String, _ b: String) -> Double {
        let ta = Set(normalize(a).split(separator: " ")), tb = Set(normalize(b).split(separator: " "))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    static func deepScanSystemPrompt() -> String {
        """
        A student's assignment list was imported from their university and may contain the same         assignment twice — re-imported under a slightly different title or date. You are shown         numbered pairs from the same course, due within a week of each other.

        For each pair decide whether they are ONE assignment listed twice, or two different         pieces of work.

        Reply with ONLY a JSON array, no prose:
        [{"i": 1, "same": false, "why": "different chapters"}]

        Say same only when you are confident: a merge deletes one of them, and losing real work \
        is far worse than leaving a duplicate in the list. Sequence numbers, chapter or section \
        numbers, week numbers and part letters that differ mean different work.

        Scope matters as much as numbering. A quiz on one lecture and a quiz covering a range of \
        lectures are different work even when their numbers line up: "Lecture Quiz 1" is about \
        lecture 1, while "Quiz 1 (L1-L3)" covers lectures 1 to 3. Likewise a prelab and its lab, \
        a draft and its final, a practice set and the graded one.

        Keep "why" under six words.
        """
    }

    static func deepScanUserPrompt(_ items: [Candidate]) -> String {
        items.enumerated().map { n, c in
            "\(n + 1). A: \(c.a.title)\n   B: \(c.b.title)\n   (due \(c.daysApart) day(s) apart)"
        }.joined(separator: "\n")
    }

    static func parseDeepScan(_ raw: String, count: Int) -> [(index: Int, same: Bool, why: String)] {
        guard let s = raw.firstIndex(of: "["), let e = raw.lastIndex(of: "]"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let i = (o["i"] as? Int) ?? (o["i"] as? NSNumber)?.intValue, i >= 1, i <= count,
                  let same = (o["same"] as? Bool) ?? (o["same"] as? NSNumber)?.boolValue else { return nil }
            return (i, same, (o["why"] as? String) ?? "")
        }
    }

    /// Ask the *ask* engine about the candidates and return the pairs it calls duplicates.
    /// Pairs per request. Reasoning grows with the batch — 20 pairs produced 3,550 reasoning
    /// tokens on the hardest batch of a real list, which crowded the verdicts out of a 4,096
    /// ceiling and returned a truncated reply that looked exactly like "no duplicates". Twelve
    /// keeps the thinking well inside the budget.
    static let scanBatch = 12

    /// A term's imports generate a couple of hundred plausible pairs. Ranked by overlap and
    /// capped, so a scan is bounded in time and cost — the pairs past this point share barely a
    /// quarter of their words.
    static let scanLimit = 120

    @MainActor
    static func deepScan(_ assignments: [Assignment]) async -> [DupGroup] {
        let cands = Array(candidates(assignments).prefix(scanLimit))
        guard !cands.isEmpty, let provider = AIService.makeProvider(for: .ask) else { return [] }
        var found: [DupGroup] = []
        var unreadable = 0
        for chunk in stride(from: 0, to: cands.count, by: scanBatch).map({ Array(cands[$0..<min($0 + scanBatch, cands.count)]) }) {
            let msgs = [AIMessage(role: .user, text: deepScanUserPrompt(chunk))]
            let reply: String?
            if let openAI = provider as? OpenAIProvider {
                reply = try? await openAI.completeClassification(system: deepScanSystemPrompt(), messages: msgs)
            } else {
                reply = try? await provider.completePlain(system: deepScanSystemPrompt(), messages: msgs)
            }
            let verdicts = parseDeepScan(reply ?? "", count: chunk.count)
            // A reply with no verdicts in it looks exactly like "no duplicates found", which is
            // how the syllabus extractor hid a truncation bug for a week. Say so instead.
            if verdicts.isEmpty { unreadable += 1 }
            for hit in verdicts where hit.same {
                let c = chunk[hit.index - 1]
                found.append(DupGroup(items: [c.a, c.b],
                                      reason: hit.why.isEmpty ? "AI: likely the same item" : "AI: \(hit.why)"))
            }
        }
        Diagnostics.log(.ai, unreadable > 0 ? .warn : .info,
                        "Duplicate deep scan: \(cands.count) pairs, \(found.count) flagged"
                        + (unreadable > 0 ? ", \(unreadable) batch(es) returned nothing usable" : ""))
        return found
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pick which assignment to keep when merging: prefer a synced/imported one (stable id),
    /// then one with a due date, then the longest title (most descriptive).
    static func keeper(_ items: [Assignment]) -> Assignment {
        items.max { a, b in
            (rank(a), a.title.count) < (rank(b), b.title.count)
        } ?? items[0]
    }
    private static func rank(_ a: Assignment) -> Int {
        (a.canvasID != nil ? 2 : 0) + (a.sourceUID != nil ? 1 : 0) + (a.due != nil ? 1 : 0)
    }
}


// MARK: - Self-test (StudyBar --dup-selftest)

/// The failure this feature was withdrawn for once already: a model calling two different
/// assignments the same one. The guard is structural — such a pair never becomes a candidate —
/// so that is what gets tested, not the model's manners.
enum DupSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            ok ? { print("  ok   \(name)\(detail.isEmpty ? "" : " (\(detail))")"); pass += 1 }()
               : { print("  FAIL \(name) \(detail)"); fail += 1 }()
        }
        let course = UUID()
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func make(_ title: String, _ offsetDays: Int = 0) -> Assignment {
            var a = Assignment(title: title)
            a.courseID = course
            a.due = Calendar.current.date(byAdding: .day, value: offsetDays, to: day)
            return a
        }

        // The exact pair that got the first attempt withdrawn.
        check("Homework 1 vs Quiz 3 never reaches the model",
              DuplicateFinder.candidates([make("Homework 1"), make("Quiz 3")]).isEmpty)
        check("no shared words scores zero", DuplicateFinder.overlap("Homework 1", "Quiz 3") == 0)

        // What it should ask about: a re-import whose date moved — the fast pass buckets by
        // day and so cannot see these at all.
        let moved = DuplicateFinder.candidates([make("Module 3 Quiz 2.1"), make("Module 3 Quiz 2.1", 2)])
        check("same title, different day is a candidate", moved.count == 1)

        // A near-identical pair on the same day needs no model — the fast pass already has it,
        // and asking again would only add a way to get it wrong.
        check("near-identical same-day pairs are caught deterministically",
              DuplicateFinder.find([make("Lecture Quiz 7"), make("Lecture Quiz 7 (makeup)")]).count == 1)
        check("...and are not sent to the model",
              DuplicateFinder.candidates([make("Lecture Quiz 7"), make("Lecture Quiz 7 (makeup)")]).isEmpty)

        // The band the model is actually for: related enough to be plausible, not enough to act on.
        // Real titles from a live store, overlap 0.40 — plausible, not actionable.
        let partial = DuplicateFinder.candidates([make("Quiz 1 (L1-L3)"), make("Lecture Quiz 1")])
        check("partially similar titles are candidates", partial.count == 1,
              "overlap \(String(format: "%.2f", partial.first?.overlap ?? 0))")

        // Different sections of the same series must not be proposed by the rules alone — they
        // go to the model, which is told sequence numbers mean different work.
        check("different sections are still only candidates, not merges",
              DuplicateFinder.find([make("L7 section 2.4"), make("L8 section 2.5")]).isEmpty)

        // Distance and course scoping.
        check("far apart is not a candidate", DuplicateFinder.candidates([make("Quiz 2"), make("Quiz 2", 30)]).isEmpty)
        var other = make("Quiz 2"); other.courseID = UUID()
        check("different courses are not paired", DuplicateFinder.candidates([make("Quiz 2"), other]).isEmpty)

        // Parsing.
        let parsed = DuplicateFinder.parseDeepScan(#"[{"i":1,"same":true,"why":"same quiz"},{"i":2,"same":false}]"#, count: 2)
        check("parses both verdicts", parsed.count == 2 && parsed[0].same && !parsed[1].same)
        check("drops out-of-range", DuplicateFinder.parseDeepScan(#"[{"i":9,"same":true}]"#, count: 2).isEmpty)
        check("survives junk", DuplicateFinder.parseDeepScan("sorry, no", count: 2).isEmpty)

        print(fail == 0 ? "DUP SELFTEST: ALL PASS (\(pass))" : "DUP SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
