import Foundation

/// Drives every AI surface end-to-end against the engines that are actually configured, using
/// the app's own prompts and parsers, and reports what came back.
///
/// The unit self-tests cover the pure parts — regexes, parsers, budgets. This covers the part
/// they can't: whether a real model, on real data from this store, returns something the app
/// can use. Every bug worth finding today was of that shape — a reply truncated by hidden
/// reasoning, a `{}` from a JSON-forcing flag, an empty answer that read as "nothing found".
///
///     StudyBar --ai-smoke            (add --ai-smoke-verbose to print replies)
enum AISmokeTest {

    struct Outcome {
        let surface: String
        let engine: String
        let ok: Bool
        let detail: String
        let seconds: Double
        let sample: String
    }

    @MainActor
    static func run(verbose: Bool) async -> Int32 {
        guard let state = AppState.current else {
            print("no store loaded"); return 1
        }
        let data = state.data
        var results: [Outcome] = []

        func engineName(_ s: AIService.Surface) -> String {
            let m = AIConfig.engine(for: s)
            switch m {
            case .ollama: return "ollama/\(AIConfig.ollamaModel)"
            case .openai: return AIConfig.openaiModel
            case .claude: return AIConfig.claudeModel
            case .onDevice: return "apple-on-device"
            case .off: return "off"
            }
        }

        func measure(_ surface: String, _ s: AIService.Surface,
                     _ body: @escaping () async -> (Bool, String, String)) async {
            let t = Date()
            let (ok, detail, sample) = await body()
            results.append(Outcome(surface: surface, engine: engineName(s), ok: ok, detail: detail,
                                   seconds: Date().timeIntervalSince(t), sample: sample))
            let mark = ok ? "ok  " : "FAIL"
            print("  \(mark) \(surface.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                  + "\(String(format: "%5.1f", Date().timeIntervalSince(t)))s  \(detail)")
            if verbose && !sample.isEmpty {
                print("       " + sample.replacingOccurrences(of: "\n", with: "\n       ").prefix(600))
            }
        }

        let note = data.notes.max { $0.body.count < $1.body.count }
        let noteBody = String((note?.body ?? "").prefix(6000))
        let noteTitle = note?.title ?? "Untitled"

        print("Routing:")
        for s in AIService.Surface.allCases {
            print("  \(s.label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(engineName(s))")
        }
        print("Store  — \(data.notes.count) notes, \(data.assignments.filter(\.isOpen).count) open assignments\n")

        // 1. Ask this note — the answer must be prose, not a JSON blob or an empty string.
        await measure("Ask this note", .ask) {
            guard let p = AIService.makeProvider(for: .ask) else { return (false, "no engine for questions", "") }
            let msgs = NoteQA.messages(thread: [], question: "In two sentences, what is this note about?",
                                       sources: [.init(id: UUID(), title: noteTitle, body: noteBody)])
            let out = (try? await p.completePlain(system: NoteQA.system(noteTitle: noteTitle, courseName: nil),
                                                  messages: msgs)) ?? ""
            let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { return (false, "empty reply", "") }
            if clean.hasPrefix("{") || clean.hasPrefix("[") { return (false, "returned JSON, not prose", clean) }
            return (true, "\(clean.split(separator: " ").count) words", clean)
        }

        // 2. The guard must refuse before any request is made.
        await measure("Homework guard", .ask) {
            let blocked = HomeworkGuard.check("Write my homework answer for problem 2 exactly as I should submit it.")
            let allowed = HomeworkGuard.check("How do I approach problem 2?")
            let ok = blocked != .allow && allowed == .allow
            return (ok, ok ? "blocks submission, allows method" : "guard misfired", "")
        }

        // 3. Quotation verification against the note actually sent.
        await measure("Quote check", .ask) {
            let fake = "The note says \"this sentence is absolutely not in the note at all\" clearly."
            let r = QuoteCheck.verify(fake, against: [noteBody])
            return (r.count == 1 && !r.text.contains("\"this sentence"),
                    r.count == 1 ? "stripped 1 invented quotation" : "did not strip", r.text)
        }

        // 4. Triage — every item must come back with a kind.
        await measure("Assignment triage", .organize) {
            let sample = Array(data.assignments.filter { $0.isOpen && $0.kind == nil }.prefix(12))
            guard !sample.isEmpty else { return (true, "nothing untriaged — skipped", "") }
            let props = await AssignmentTriage.classify(sample)
            let byAI = props.filter { !$0.deterministic }.count
            return (props.count == sample.count,
                    "\(props.count)/\(sample.count) classified (\(byAI) by model)",
                    props.prefix(4).map { "\($0.kind.rawValue): \($0.title.prefix(40))" }.joined(separator: "\n"))
        }

        // 5. Duplicate deep scan — must return verdicts, and must not flag the pair the user
        //    confirmed is genuinely two different quizzes.
        await measure("Duplicate deep scan", .judge) {
            let groups = await DuplicateFinder.deepScan(data.assignments)
            let falsePositive = groups.contains { g in
                let titles = g.items.map(\.title)
                return titles.contains { $0.localizedCaseInsensitiveContains("Lecture Quiz 1") }
                    && titles.contains { $0.localizedCaseInsensitiveContains("Quiz 1 (L1-L3)") }
            }
            return (!falsePositive,
                    falsePositive ? "flagged the known false positive" : "\(groups.count) flagged, no known false positive",
                    groups.prefix(3).map { $0.items.map(\.title).joined(separator: " ⇄ ") }.joined(separator: "\n"))
        }

        // 6. Inline ✨ actions — the app's own prompt, not an approximation of it. An earlier
        //    version of this test wrote its own and caught the model answering in JSON; the
        //    real prompt forbids that explicitly, and testing a paraphrase tests nothing.
        for action in [NoteAI.summarize, NoteAI.keyPoints] {
            await measure("Inline ✨ \(action.label.lowercased())", .rewrite) {
                guard let p = AIService.makeProvider(for: .rewrite) else { return (false, "no engine", "") }
                let out = (try? await p.streamPlain(system: action.system(),
                                                    messages: [AIMessage(role: .user, text: action.user(String(noteBody.prefix(2500))))],
                                                    temperature: action.temperature) { _ in }) ?? ""
                let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty { return (false, "empty reply", "") }
                if clean.hasPrefix("{") || clean.hasPrefix("[") {
                    return (false, "answered in JSON despite the prompt forbidding it", clean)
                }
                if clean.hasPrefix("```") { return (false, "wrapped in a code fence", clean) }
                return (true, "\(clean.split(separator: " ").count) words", clean)
            }
        }

        // 7. Flashcard generation — front|back lines the deck importer can read.
        await measure("Flashcards from note", .rewrite) {
            guard let p = AIService.makeProvider(for: .rewrite) else { return (false, "no engine", "") }
            let out = (try? await p.streamPlain(
                system: "Write 5 study flashcards from the student's notes. Output ONLY lines of the form "
                      + "front | back — no numbering, no preamble, no JSON, no code fences.",
                messages: [AIMessage(role: .user, text: String(noteBody.prefix(2500)))],
                temperature: 0.3) { _ in }) ?? ""
            let cards = out.split(separator: "\n").filter { $0.contains("|") && !$0.contains("---") }
            if out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                return (false, "answered in JSON instead of front|back lines", out)
            }
            return (cards.count >= 3, "\(cards.count) parseable cards", out)
        }

        // 8. Structured extraction — the long-output path that has failed before.
        await measure("Structured extraction", .extract) {
            guard let p = AIService.makeProvider(for: .ask) else { return (false, "no engine for questions", "") }
            let out: String
            if let ollama = p as? OllamaProvider {
                out = (try? await ollama.completePlainOnce(
                    system: "Extract any dates you find as JSON: [{\"date\":\"YYYY-MM-DD\",\"what\":\"…\"}]. JSON only.",
                    messages: [AIMessage(role: .user, text: noteBody)])) ?? ""
            } else {
                out = (try? await p.completePlain(
                    system: "Extract any dates you find as JSON: [{\"date\":\"YYYY-MM-DD\",\"what\":\"…\"}]. JSON only.",
                    messages: [AIMessage(role: .user, text: noteBody)])) ?? ""
            }
            guard let s = out.firstIndex(of: "["), let e = out.lastIndex(of: "]"), s < e else {
                return (false, out.isEmpty ? "empty reply" : "no JSON array in reply", out)
            }
            let parsed = (try? JSONSerialization.jsonObject(with: Data(out[s...e].utf8))) as? [Any]
            return (parsed != nil, parsed == nil ? "unparseable JSON" : "\(parsed?.count ?? 0) items", out)
        }

        // 9. Autocomplete — local by design, whatever the assistant is set to.
        await measure("Autocomplete (local)", .quick) {
            let outcome = await NoteAutocomplete.suggest(prefix: "The present value of a future cash flow is ")
            switch outcome {
            case .suggestion(let s): return (true, "suggested \"\(s.prefix(30))\"", s)
            case .none:              return (true, "no suggestion offered (allowed)", "")
            case .unavailable(let r): return (false, r, "")
            }
        }

        let failed = results.filter { !$0.ok }
        print("\n\(results.count - failed.count)/\(results.count) surfaces healthy"
              + (failed.isEmpty ? "" : " — failing: " + failed.map(\.surface).joined(separator: ", ")))
        print(String(format: "total %.0fs", results.reduce(0) { $0 + $1.seconds }))
        return failed.isEmpty ? 0 : 1
    }
}
