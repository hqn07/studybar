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

    static func system(noteTitle: String, courseName: String?) -> String {
        let subject = courseName.map { " for their course \($0)" } ?? ""
        return """
        A student is reading their own lecture note\(subject) titled "\(noteTitle)" and asks you \
        a question about it.

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

        One refusal stands: do not produce work that would be submitted for a grade — the essay, \
        the problem set solution, the lab answer. Explain the concept and let them write it.
        """
    }

    /// Prior turns give a follow-up its thread; only the newest turn carries the note, so the
    /// history stays small.
    static func messages(thread: [Turn], question: String, noteTitle: String, noteBody: String) -> [AIMessage] {
        var msgs: [AIMessage] = []
        for prior in thread where !prior.answer.isEmpty {
            msgs.append(AIMessage(role: .user, text: "Question: \(prior.question)"))
            msgs.append(AIMessage(role: .assistant, text: prior.answer))
        }
        let body = String(noteBody.prefix(noteCharLimit))
        msgs.append(AIMessage(role: .user, text: """
        My note "\(noteTitle)":
        \(body)

        Question: \(question)
        """))
        return msgs
    }

    /// Roughly four characters per token, plus headroom for the answer and the thread.
    static func contextTokens(noteBody: String) -> Int {
        let needed = noteBody.count / 4 + 2_000
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

        // A follow-up carries the thread, but the note only once.
        let thread = [NoteQA.Turn(question: "What is a coleus?", answer: "A foliage plant.")]
        let msgs = NoteQA.messages(thread: thread, question: "How do scallions differ?",
                                   noteTitle: "Week 3 — Coleus", noteBody: "Coleus propagation notes.")
        check("thread replayed", msgs.count == 3, "\(msgs.count) messages")
        check("note attached to the new turn only",
              msgs.filter { $0.text.contains("Coleus propagation notes.") }.count == 1)
        check("question is last", msgs.last?.text.contains("How do scallions differ?") == true)

        // A long note must not be sent whole, and must not blow the window.
        let long = String(repeating: "x", count: 40_000)
        let clipped = NoteQA.messages(thread: [], question: "q", noteTitle: "t", noteBody: long)
        check("long note is clipped", (clipped.last?.text.count ?? 0) < 25_000)
        check("small note gets the floor window", NoteQA.contextTokens(noteBody: "short") == 8_192)
        let big = NoteQA.contextTokens(noteBody: String(repeating: "x", count: 60_000))
        check("big note widens the window", big > 8_192 && big <= 32_768, "\(big)")

        print(fail == 0 ? "NOTEQA SELFTEST: ALL PASS (\(pass))" : "NOTEQA SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
