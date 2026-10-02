import Foundation

/// StudyBar's own prompts, measured: `StudyBar --eval eval/app-cases.json --engine openai
/// [--save eval/app-results.json]`. The cases are synthetic course material committed with the
/// code; they go through the same functions the app calls — `Quiz.generate`, `LectureNotes.run`,
/// the tutor's full solution — and code scores what comes back, so a prompt change shows up as
/// a number rather than an impression. (`scripts/ai-eval.py` compares models on Ask this note
/// with a copy of an older prompt; this runs the app's.)
enum AppEval {
    struct Cases: Decodable {
        struct Quiz: Decodable { let name: String; let material: String; let count: Int }
        struct Lecture: Decodable { let name: String; let transcript: String; let must: [String]; let end: [String] }
        struct Math: Decodable { let name: String; let problem: String; let answer: Double; let tolerance: Double? }
        let quiz: [Quiz]; let lecture: [Lecture]; let math: [Math]
    }

    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--eval"), i + 1 < args.count, let data = FileManager.default.contents(atPath: args[i + 1]),
              let cases = try? JSONDecoder().decode(Cases.self, from: data) else {
            print("usage: StudyBar --eval <cases.json> [--engine openai|claude|ollama] [--save results.json]"); return 1
        }
        let mode = args.firstIndex(of: "--engine").flatMap { $0 + 1 < args.count ? AIMode(rawValue: args[$0 + 1]) : nil } ?? AIConfig.mode
        guard let provider = AIService.makeProvider(mode: mode) else { print("no engine for \(mode.rawValue)"); return 1 }
        let t0 = Date()
        print("Engine: \(mode.rawValue) · \(AIConfig.modelName(for: mode))\n")

        var quiz: [Double] = []
        for c in cases.quiz {
            let passages = LectureNotes.chunks(c.material, maxChars: 1_500).map { StudyPassage(title: c.name, locator: "", text: $0) }
            let qs = await Quiz.generate(from: passages, count: c.count, exam: false, provider: provider, mode: mode) { _, _ in } ?? []
            let s = quizScore(qs, count: c.count)
            quiz.append(s.score)
            print("QUIZ  \(pct(s.score))  \(c.name)" + (s.problems.isEmpty ? "" : "\n      " + s.problems.joined(separator: "\n      ")))
        }

        var recall: [Double] = [], ending: [Double] = [], added = 0
        for c in cases.lecture {
            let notes = await LectureNotes.run(c.transcript, job: .lecture, provider: provider, mode: mode) { _, _, _ in } ?? ""
            let r = found(c.must, in: notes), e = found(c.end, in: notes), a = LectureNotes.additions(in: notes).count
            recall.append(r.share); ending.append(e.share); added += a
            print("NOTES recall \(pct(r.share)) · end \(pct(e.share)) · \(a) marked additions · \(notes.count) chars  \(c.name)"
                  + (r.missing + e.missing).map { "\n      missing: \($0)" }.joined())
        }

        var right = 0, badChecks = 0, checks = 0
        for c in cases.math {
            let out = (try? await provider.streamPlain(system: Tutor.system(.full, course: nil),
                messages: Tutor.messages(thread: [], question: c.problem, material: "", images: [], imageText: "", mode: .full),
                temperature: 0.3) { _ in }) ?? ""
            let (text, results) = MathCheck.run(out)
            let ok = answers(c.answer, in: String(text.suffix(700)), tolerance: c.tolerance ?? 0.02)
            right += ok ? 1 : 0; checks += results.count; badChecks += results.filter { $0.ok == false }.count
            print("MATH  \(ok ? "right" : "WRONG")  \(results.count) checks, \(results.filter { $0.ok == false }.count) failed  \(c.name)"
                  + (ok ? "" : "\n      expected \(c.answer); the answer ends: …" + text.suffix(160).replacingOccurrences(of: "\n", with: " ")))
        }

        let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        let summary: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: .now), "engine": mode.rawValue, "model": AIConfig.modelName(for: mode),
            "quiz": mean(quiz), "notesRecall": mean(recall), "notesEnd": mean(ending), "notesAdditions": added,
            "mathRight": "\(right)/\(cases.math.count)", "mathChecksFailed": "\(badChecks)/\(checks)",
            "seconds": Int(Date().timeIntervalSince(t0)),
        ]
        print("\nquiz \(pct(mean(quiz))) · notes recall \(pct(mean(recall))), end \(pct(mean(ending))) · math \(right)/\(cases.math.count), "
              + "\(badChecks) of \(checks) checks failed · \(summary["seconds"]!)s")
        if let s = args.firstIndex(of: "--save"), s + 1 < args.count {
            let url = URL(fileURLWithPath: args[s + 1])
            let old = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if let d = try? JSONSerialization.data(withJSONObject: old + [summary], options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
        }
        return 0
    }

    private static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    /// A question code can vouch for: the right shape for its kind, an explanation and a topic,
    /// the answer not given away in it, and not a repeat. Scored against the number asked for.
    static func quizScore(_ qs: [QuizQuestion], count: Int) -> (score: Double, problems: [String]) {
        var problems: [String] = [], seen: Set<String> = [], good = 0
        for q in qs {
            var why: [String] = []
            switch q.kind {
            case .mcq: if Set(q.choices).count < 3 || !(0..<q.choices.count).contains(q.answerIndex ?? -1) { why.append("choices or answer") }
            case .tf: if q.answerBool == nil { why.append("no true/false answer") }
            case .fill, .short: if q.answerText.isEmpty { why.append("no answer") }
            }
            if q.explanation.isEmpty { why.append("no explanation") }
            if q.topic.isEmpty { why.append("no topic") }
            if Quiz.answerGivenAway(q) { why.append("gives the answer away") }
            if !seen.insert(q.prompt.lowercased()).inserted { why.append("a repeat") }
            if why.isEmpty { good += 1 } else { problems.append("\(why.joined(separator: ", ")): \(q.prompt.prefix(70))") }
        }
        if qs.count != count { problems.insert("\(qs.count) questions, \(count) asked for", at: 0) }
        return (Double(min(good, count)) / Double(max(1, count)), problems)
    }

    static func found(_ phrases: [String], in text: String) -> (share: Double, missing: [String]) {
        let missing = phrases.filter { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil }
        return (phrases.isEmpty ? 1 : Double(phrases.count - missing.count) / Double(phrases.count), missing)
    }

    /// Whether the answer states `expected` — as 1.8e-5, 1.8 \times 10^{-5}, 18 μC or 134,850 —
    /// to within `tolerance` of it.
    static func answers(_ expected: Double, in text: String, tolerance: Double) -> Bool {
        numbers(text).contains { abs($0 - expected) <= tolerance * abs(expected) }
    }

    static func numbers(_ s: String) -> [Double] {
        let t = s.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: #"(?<=\d),(?=\d{3})"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "{,}", with: "")
        var out: [Double] = []
        for m in t.matches(of: /(-?\d+(?:\.\d+)?)\s*(?:\\times|×|\\cdot|x)\s*10\s*\^\s*\{?\s*(-?\d+)\s*\}?/) {
            if let a = Double(m.output.1), let b = Double(m.output.2) { out.append(a * pow(10, b)) }
        }
        let prefixes: [String: Double] = ["μ": 1e-6, "µ": 1e-6, "\\mu": 1e-6, "u": 1e-6, "n": 1e-9, "p": 1e-12, "m": 1e-3, "k": 1e3, "M": 1e6]
        for m in t.matches(of: /(-?\d+(?:\.\d+)?(?:[eE]-?\d+)?)(\s*(?:\\[,;! ]|~)?\s*(?:\\(?:text|mathrm)\{)?\s*(\\mu|[μµunpmkM])[A-Za-zΩ\\])?/) {
            guard let v = Double(m.output.1) else { continue }
            out.append(v)
            if let p = m.output.3.flatMap({ prefixes[String($0)] }) { out.append(v * p) }
        }
        return out
    }
}
