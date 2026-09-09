import Foundation

/// Asking a question *about the note you are looking at* — including questions the note
/// doesn't answer.
///
/// This is the one surface where StudyBar's AI explains rather than only reorganizes. The
/// operator surface (`AIService`) still refuses to teach; here the note is context for a
/// question that may go past it — reading about Coleus and wondering how scallions differ is
/// studying, not homework. What stays refused is work you would submit: the essay, the
/// problem set, the graded answer. See docs/PHILOSOPHY.md, "Organize, never do the homework".
enum NoteQA {

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: String
    }

    /// Notes here are small — the largest in a real store is ~3.6k tokens — so the whole note
    /// goes in rather than being retrieved from. No chunking means no retrieval to get wrong,
    /// which is where local-model answers usually fall apart.
    static let noteCharLimit = 24_000

    /// Across every attached note. Well past a term of one course (the largest here is 15k
    /// chars), and short of the length where a 7B's attention over the pile goes vague and a
    /// question takes a minute to answer.
    static let totalCharLimit = 60_000

    /// One note in the context, carrying the title it will be cited by.
    struct Source: Identifiable, Equatable {
        let id: UUID
        let title: String
        let body: String
    }

    static func system(noteTitle: String, courseName: String?, extraNotes: Int = 0) -> String {
        let subject = courseName.map { " for their course \($0)" } ?? ""
        let multi = extraNotes > 0
            ? """


            They have attached \(extraNotes) earlier note\(extraNotes == 1 ? "" : "s") as well. \
            Use whichever notes answer the question, and say which one you took something from \
            — by its title, e.g. "from Week 1 — Soils". Their titles are the only names you have \
            for them, so use those exactly.
            """
            : ""
        return """
        A student is reading their own lecture note\(subject) titled "\(noteTitle)" and asks you \
        a question about it.\(multi)

        Answer the question. Use the note when it covers the answer, and quote or refer to what \
        it says. When the question goes beyond the note — a related concept, a term they didn't \
        write down, background the lecture assumed — answer it anyway from what you know. Do not \
        say the note doesn't cover it and stop; that is the point of asking here.

        Be concrete and brief: a short direct answer first, then only the detail that earns its \
        place. Write ALL mathematics as LaTeX between single dollar signs — $y' = y$, $e^{x}$ — \
        never as plain text, and never with \\( \\) or \\[ \\] delimiters. Use Markdown for \
        structure, and a Markdown table when comparing things.

        Say plainly when you are unsure or when a detail depends on specifics you don't have \
        (their region, their instructor's definition, the edition of a text) — a student acting \
        on a confident wrong answer is the failure that matters here.

        Never put words in quotation marks unless they appear in the note exactly as written. \
        Paraphrase instead. A quotation the student cannot find in their own note is worse than \
        no quotation. Refer to a note only by the title given in its "--- Note: ---" header, \
        never by a heading inside it.

        One refusal stands: do not produce work that would be submitted for a grade — the essay, \
        the problem set solution, the lab answer. Explain the concept and let them write it.
        """
    }

    /// Prior turns give a follow-up its thread; only the newest turn carries the notes, so
    /// the history stays small. The note being read comes first — the question is about it,
    /// and the ones added by hand are background.
    static func messages(thread: [Turn], question: String, sources: [Source]) -> [AIMessage] {
        var msgs: [AIMessage] = []
        for prior in thread where !prior.answer.isEmpty {
            msgs.append(AIMessage(role: .user, text: "Question: \(prior.question)"))
            msgs.append(AIMessage(role: .assistant, text: prior.answer))
        }
        var budget = totalCharLimit
        var blocks: [String] = []
        for src in sources {
            guard budget > 500 else { break }        // a scrap of a note helps nobody
            let body = String(src.body.prefix(min(noteCharLimit, budget)))
            budget -= body.count
            blocks.append("--- Note: \(src.title) ---\n\(body)")
        }
        msgs.append(AIMessage(role: .user, text: blocks.joined(separator: "\n\n") + "\n\nQuestion: \(question)"))
        return msgs
    }

    /// Roughly four characters per token, plus headroom for the answer and the thread.
    static func contextTokens(chars: Int) -> Int {
        let needed = chars / 4 + 2_000
        return max(8_192, min(32_768, Int(pow(2, ceil(log2(Double(max(needed, 1))))))))
    }
}

// MARK: - Self-test (StudyBar --noteqa-selftest)

enum NoteQASelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ n: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("  ok   \(n)\(detail.isEmpty ? "" : " (\(detail))")"); pass += 1 }
            else { print("  FAIL \(n) \(detail)"); fail += 1 }
        }

        let sys = NoteQA.system(noteTitle: "Week 3 — Coleus", courseName: "ORH1030")
        check("names the note", sys.contains("Week 3 — Coleus"))
        check("names the course", sys.contains("ORH1030"))
        check("answers past the note", sys.contains("answer it anyway from what you know"))
        check("keeps the homework refusal", sys.lowercased().contains("submitted for a grade"))
        check("asks for $…$ math", sys.contains("single dollar signs"))
        // qwen invented a quotation on the first real multi-note run — words in quotes that
        // were nowhere in the note — and cited a heading inside a note as if it were the
        // note's title.
        check("bans invented quotations", sys.contains("unless they appear in the note exactly as written"))
        check("pins citations to the note header", sys.contains("never by a heading inside it"))
        check("no attribution ask for a single note", !sys.contains("say which one you took"))

        let multi = NoteQA.system(noteTitle: "Week 3 — Coleus", courseName: "ORH1030", extraNotes: 2)
        check("mentions the attached notes", multi.contains("attached 2 earlier notes"))
        check("asks which note an answer came from", multi.contains("say which one you took"))

        func src(_ t: String, _ b: String) -> NoteQA.Source { .init(id: UUID(), title: t, body: b) }

        // A follow-up replays the thread; the notes ride only on the newest turn.
        let thread = [NoteQA.Turn(question: "What is a coleus?", answer: "A foliage plant.")]
        let msgs = NoteQA.messages(thread: thread, question: "How do scallions differ?",
                                   sources: [src("Week 3 — Coleus", "Coleus propagation notes.")])
        check("thread replayed", msgs.count == 3, "\(msgs.count) messages")
        check("note attached once", msgs.filter { $0.text.contains("Coleus propagation notes.") }.count == 1)
        check("question is last", msgs.last?.text.contains("How do scallions differ?") == true)

        // Several notes: all present, each labelled, the one being read first.
        let many = NoteQA.messages(thread: [], question: "q", sources: [
            src("Week 3 — Coleus", "third"), src("Week 1 — Soils", "first"), src("Week 2 — Light", "second"),
        ])
        let text = many.last?.text ?? ""
        check("every note is included", text.contains("third") && text.contains("first") && text.contains("second"))
        check("each note is labelled", text.contains("--- Note: Week 1 — Soils ---"))
        check("the note being read comes first",
              (text.range(of: "Week 3 — Coleus")?.lowerBound ?? text.endIndex)
                  < (text.range(of: "Week 1 — Soils")?.lowerBound ?? text.startIndex))

        // Budget: one huge note is clipped, and a pile stops at the total.
        let long = String(repeating: "x", count: 40_000)
        let clipped = NoteQA.messages(thread: [], question: "q", sources: [src("t", long)])
        check("one long note is clipped", (clipped.last?.text.count ?? 0) < 25_500,
              "\(clipped.last?.text.count ?? 0) chars")
        let pile = (1...6).map { src("n\($0)", String(repeating: "y", count: 20_000)) }
        let piled = NoteQA.messages(thread: [], question: "q", sources: pile)
        check("the pile stops at the budget", (piled.last?.text.count ?? 0) <= NoteQA.totalCharLimit + 500,
              "\(piled.last?.text.count ?? 0) chars")

        check("small context gets the floor window", NoteQA.contextTokens(chars: 200) == 8_192)
        let big = NoteQA.contextTokens(chars: 60_000)
        check("big context widens the window", big > 8_192 && big <= 32_768, "\(big)")

        print(fail == 0 ? "NOTEQA SELFTEST: ALL PASS (\(pass))" : "NOTEQA SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
