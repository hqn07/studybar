import Foundation

/// Drives every AI surface end-to-end against the engines that are actually configured, using
/// the app's own prompts and parsers, and reports what came back.
///
/// The unit self-tests cover the pure parts — regexes, parsers, budgets. This covers the part
/// they can't: whether a real model, on real data from this store, returns something the app
/// can use. Every bug worth finding today was of that shape — a reply truncated by hidden
/// reasoning, a `{}` from a JSON-forcing flag, an empty answer that read as "nothing found".
///
/// Two things it now refuses to do, both learned from a run where the network blocked the
/// strong engine at the TLS handshake:
///   • report a request that never reached a model as a model result — a reset connection, a
///     402 and a genuinely empty completion used to print the same `empty reply`;
///   • let a surface pass because an unreachable engine returned nothing to object to.
///
///     StudyBar --ai-smoke            (add --ai-smoke-verbose to print replies)
enum AISmokeTest {

    /// The verdict for one surface. `engineFault` marks a failure that happened before the
    /// model answered — a connection, a key or a refusal — so it is never mistaken for a
    /// regression in the model's output.
    struct Check {
        let ok: Bool
        let detail: String
        let sample: String
        let engineFault: Bool

        static func pass(_ detail: String, _ sample: String = "") -> Check {
            Check(ok: true, detail: detail, sample: sample, engineFault: false)
        }
        static func fail(_ detail: String, _ sample: String = "") -> Check {
            Check(ok: false, detail: detail, sample: sample, engineFault: false)
        }
        /// The engine never produced an answer to judge.
        static func broken(_ detail: String) -> Check {
            Check(ok: false, detail: detail, sample: "", engineFault: true)
        }
    }

    struct Outcome {
        let surface: String
        let engine: String
        let ok: Bool
        let detail: String
        let seconds: Double
        let sample: String
        let engineFault: Bool
    }

    /// One request, with the reason it failed kept instead of thrown away. `try?` collapsed a
    /// TLS reset, an HTTP 402 and an empty completion into the same empty string, which turned
    /// a five-second diagnosis into a connectivity hunt.
    private struct Reply {
        let text: String
        let failure: String?
        let engineFault: Bool

        var clean: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func attempt(_ body: () async throws -> String) async -> Reply {
        do {
            return Reply(text: try await body(), failure: nil, engineFault: false)
        } catch let e as AIError {
            switch e {
            case .badResponse:
                // A 200 with nothing usable in it. The model's fault, not the connection's.
                return Reply(text: "", failure: "empty reply", engineFault: false)
            case .http(let code, let body):
                let detail = body.isEmpty ? "" : " — \(body.prefix(120))"
                return Reply(text: "", failure: "engine refused: HTTP \(code)\(detail)", engineFault: true)
            case .notConfigured, .unavailable:
                return Reply(text: "", failure: "engine unavailable: \(e.localizedDescription)",
                             engineFault: true)
            }
        } catch let u as URLError {
            let host = u.failingURL?.host.map { " — \($0)" } ?? ""
            return Reply(text: "",
                         failure: "never reached the engine: \(u.localizedDescription) "
                                + "(URLError \(u.code.rawValue))\(host)",
                         engineFault: true)
        } catch {
            return Reply(text: "", failure: "request failed: \(error.localizedDescription)",
                         engineFault: true)
        }
    }

    /// Turn a failed request into a Check that says which kind of failure it was.
    private static func check(_ r: Reply) -> Check? {
        guard let f = r.failure else { return nil }
        return r.engineFault ? .broken(f) : .fail(f)
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
                     _ body: @escaping () async -> Check) async {
            let t = Date()
            let c = await body()
            let secs = Date().timeIntervalSince(t)
            results.append(Outcome(surface: surface, engine: engineName(s), ok: c.ok, detail: c.detail,
                                   seconds: secs, sample: c.sample, engineFault: c.engineFault))
            let mark = c.ok ? "ok  " : (c.engineFault ? "DOWN" : "FAIL")
            print("  \(mark) \(surface.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                  + "\(String(format: "%5.1f", secs))s  \(c.detail)")
            if verbose && !c.sample.isEmpty {
                print("       " + c.sample.replacingOccurrences(of: "\n", with: "\n       ").prefix(600))
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
            guard let p = AIService.makeProvider(for: .ask) else { return .broken("no engine for questions") }
            let msgs = NoteQA.messages(thread: [], question: "In two sentences, what is this note about?",
                                       sources: [.init(id: UUID(), title: noteTitle, body: noteBody)])
            let r = await attempt {
                try await p.completePlain(system: NoteQA.system(noteTitle: noteTitle, courseName: nil),
                                          messages: msgs)
            }
            if let c = check(r) { return c }
            if r.clean.isEmpty { return .fail("empty reply") }
            if r.clean.hasPrefix("{") || r.clean.hasPrefix("[") {
                return .fail("returned JSON, not prose", r.clean)
            }
            return .pass("\(r.clean.split(separator: " ").count) words", r.clean)
        }

        // 2. The guard must refuse before any request is made.
        await measure("Homework guard", .ask) {
            let blocked = HomeworkGuard.check("Write my homework answer for problem 2 exactly as I should submit it.")
            let allowed = HomeworkGuard.check("How do I approach problem 2?")
            let ok = blocked != .allow && allowed == .allow
            return ok ? .pass("blocks submission, allows method") : .fail("guard misfired")
        }

        // 3. Quotation verification against the note actually sent.
        await measure("Quote check", .ask) {
            let fake = "The note says \"this sentence is absolutely not in the note at all\" clearly."
            let r = QuoteCheck.verify(fake, against: [noteBody])
            let ok = r.count == 1 && !r.text.contains("\"this sentence")
            return ok ? .pass("stripped 1 invented quotation", r.text)
                      : .fail("did not strip", r.text)
        }

        // 4. Triage — every item must come back with a kind.
        await measure("Assignment triage", .organize) {
            let sample = Array(data.assignments.filter { $0.isOpen && $0.kind == nil }.prefix(12))
            guard !sample.isEmpty else { return .pass("nothing untriaged — skipped") }
            let props = await AssignmentTriage.classify(sample)
            let byAI = props.filter { !$0.deterministic }.count
            let detail = "\(props.count)/\(sample.count) classified (\(byAI) by model)"
            let s = props.prefix(4).map { "\($0.kind.rawValue): \($0.title.prefix(40))" }.joined(separator: "\n")
            return props.count == sample.count ? .pass(detail, s) : .fail(detail, s)
        }

        // 5. Duplicate deep scan — must actually return verdicts, and must not flag the pair the
        //    user confirmed is genuinely two different quizzes. Checking only the false positive
        //    made this pass in 0.4s while the engine was unreachable: nothing came back, so
        //    nothing was wrong. The report says whether the model was ever heard from.
        await measure("Duplicate deep scan", .judge) {
            let r = await DuplicateFinder.deepScanReport(data.assignments)
            guard r.pairs > 0 else { return .pass("no candidate pairs in this store — nothing to judge") }
            guard r.engineReady else { return .broken("no engine configured for duplicate judgement") }
            guard r.judged else {
                return .broken("\(r.pairs) pairs sent, all \(r.batches) batch(es) returned nothing usable")
            }
            let sample = r.groups.prefix(3).map { $0.items.map(\.title).joined(separator: " ⇄ ") }
                                 .joined(separator: "\n")
            let falsePositive = r.groups.contains { g in
                let titles = g.items.map(\.title)
                return titles.contains { $0.localizedCaseInsensitiveContains("Lecture Quiz 1") }
                    && titles.contains { $0.localizedCaseInsensitiveContains("Quiz 1 (L1-L3)") }
            }
            if falsePositive { return .fail("flagged the known false positive", sample) }
            if r.unreadable > 0 {
                return .fail("\(r.unreadable)/\(r.batches) batches returned nothing usable — "
                             + "\(r.groups.count) flagged from the rest", sample)
            }
            return .pass("\(r.groups.count) flagged from \(r.pairs) pairs across \(r.batches) batch(es), "
                         + "no known false positive", sample)
        }

        // 6. Inline ✨ actions — the app's own prompt, not an approximation of it. An earlier
        //    version of this test wrote its own and caught the model answering in JSON; the
        //    real prompt forbids that explicitly, and testing a paraphrase tests nothing.
        for action in [NoteAI.summarize, NoteAI.keyPoints] {
            await measure("Inline ✨ \(action.label.lowercased())", .rewrite) {
                guard let p = AIService.makeProvider(for: .rewrite) else { return .broken("no engine") }
                let r = await attempt {
                    try await p.streamPlain(
                        system: action.system(),
                        messages: [AIMessage(role: .user, text: action.user(String(noteBody.prefix(2500))))],
                        temperature: action.temperature) { _ in }
                }
                if let c = check(r) { return c }
                if r.clean.isEmpty { return .fail("empty reply") }
                if r.clean.hasPrefix("{") || r.clean.hasPrefix("[") {
                    return .fail("answered in JSON despite the prompt forbidding it", r.clean)
                }
                if r.clean.hasPrefix("```") { return .fail("wrapped in a code fence", r.clean) }
                return .pass("\(r.clean.split(separator: " ").count) words", r.clean)
            }
        }

        // 7. Flashcard generation — front|back lines the deck importer can read.
        await measure("Flashcards from note", .rewrite) {
            guard let p = AIService.makeProvider(for: .rewrite) else { return .broken("no engine") }
            let r = await attempt {
                try await p.streamPlain(
                    system: "Write 5 study flashcards from the student's notes. Output ONLY lines of the form "
                          + "front | back — no numbering, no preamble, no JSON, no code fences.",
                    messages: [AIMessage(role: .user, text: String(noteBody.prefix(2500)))],
                    temperature: 0.3) { _ in }
            }
            if let c = check(r) { return c }
            if r.clean.hasPrefix("{") {
                return .fail("answered in JSON instead of front|back lines", r.text)
            }
            let cards = r.text.split(separator: "\n").filter { $0.contains("|") && !$0.contains("---") }
            let detail = "\(cards.count) parseable cards"
            return cards.count >= 3 ? .pass(detail, r.text) : .fail(detail, r.text)
        }

        // 8. Structured extraction — the long-output path that has failed before.
        await measure("Structured extraction", .extract) {
            guard let p = AIService.makeProvider(for: .ask) else { return .broken("no engine for questions") }
            let system = "Extract any dates you find as JSON: [{\"date\":\"YYYY-MM-DD\",\"what\":\"…\"}]. JSON only."
            let msgs = [AIMessage(role: .user, text: noteBody)]
            let r = await attempt {
                if let ollama = p as? OllamaProvider {
                    return try await ollama.completePlainOnce(system: system, messages: msgs)
                }
                return try await p.completePlain(system: system, messages: msgs)
            }
            if let c = check(r) { return c }
            let out = r.text
            guard let s = out.firstIndex(of: "["), let e = out.lastIndex(of: "]"), s < e else {
                return .fail(out.isEmpty ? "empty reply" : "no JSON array in reply", out)
            }
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(out[s...e].utf8))) as? [Any] else {
                return .fail("unparseable JSON", out)
            }
            return .pass("\(parsed.count) items", out)
        }

        // 9. Autocomplete — local by design, whatever the assistant is set to.
        await measure("Autocomplete (local)", .quick) {
            let outcome = await NoteAutocomplete.suggest(prefix: "The present value of a future cash flow is ")
            switch outcome {
            case .suggestion(let s): return .pass("suggested \"\(s.prefix(30))\"", s)
            case .none:              return .pass("no suggestion offered (allowed)")
            case .unavailable(let r): return .broken(r)
            }
        }

        let failed = results.filter { !$0.ok }
        let down = results.filter(\.engineFault)
        print("\n\(results.count - failed.count)/\(results.count) surfaces healthy"
              + (failed.isEmpty ? "" : " — failing: " + failed.map(\.surface).joined(separator: ", ")))
        if !down.isEmpty {
            let engines = Set(down.map(\.engine)).sorted().joined(separator: ", ")
            print("\(down.count) of those never reached a model (\(engines)) — a connection or a key, "
                  + "not the model's output. Fix that before reading these as regressions.")
        }
        print(String(format: "total %.0fs", results.reduce(0) { $0 + $1.seconds }))
        return failed.isEmpty ? 0 : 1
    }
}
