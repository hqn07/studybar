import Foundation

/// The one rule Ask this note enforces itself, rather than asking the model to.
///
/// The system prompt says "do not produce work that would be submitted for a grade". Measured
/// against three engines on the same question — *"Write my homework answer for problem 2
/// exactly as I should submit it"* — two of the three wrote the full worked solution and boxed
/// the final number. A prompt is a request, and a model that wants to be helpful grants it.
/// docs/PHILOSOPHY.md already said where this ends up: enforcement is architecture, not trust.
///
/// So the check runs before the model is called, on the question text, and is deterministic.
/// It aims at *submission* intent, not at difficulty: "how do I solve problem 2" is exactly
/// what this feature is for and must pass. What gets stopped is "write it the way I hand it
/// in" — and even then the answer isn't a dead end, it's an offer to walk the method.
enum HomeworkGuard {

    enum Verdict: Equatable {
        case allow
        /// Blocked, with the phrase that triggered it — shown to the user so the rule is legible.
        case submission(trigger: String)
    }

    /// Asking to hand over something gradeable. Each needs an explicit hand-it-in signal or an
    /// imperative aimed at the artifact itself — "explain", "how", "why" never match.
    private static let patterns: [(String, String)] = [
        (#"(?i)\b(?:as|exactly as|the way)\s+i\s+(?:should\s+)?(?:submit|turn\s+it\s+in|hand\s+it\s+in)"#, "as I should submit it"),
        (#"(?i)\b(?:write|do|complete|finish|answer)\s+(?:my|the)\s+(?:homework|assignment|problem\s*set|worksheet|lab\s*report|discussion\s*post|essay|paper)\b"#, "write my homework"),
        (#"(?i)\bwrite\s+(?:my|the)\s+(?:answer|solution|response)\b"#, "write my answer"),
        (#"(?i)\b(?:solve|answer|do)\s+(?:problem|question|exercise|q)\s*#?\s*\d+\s+for\s+me\b"#, "solve problem N for me"),
        (#"(?i)\bdo\s+(?:this|these|it)\s+for\s+me\b"#, "do it for me"),
        (#"(?i)\b(?:submit|turn\s+in|hand\s+in)\s+(?:this|it|that)\b"#, "turn it in"),
        (#"(?i)\bjust\s+(?:give|tell)\s+me\s+the\s+(?:final\s+)?answer\b"#, "just give me the answer"),
        (#"(?i)\bwrite\s+(?:me\s+)?(?:an?|the)\s+\d*\s*(?:page|paragraph|word)?\s*essay\b"#, "write an essay"),
    ]

    static func check(_ question: String) -> Verdict {
        for (pattern, label) in patterns {
            if question.range(of: pattern, options: .regularExpression) != nil {
                return .submission(trigger: label)
            }
        }
        return .allow
    }

    /// What the panel says instead of an answer. Names the rule, doesn't scold, and leaves the
    /// door open — the method is the thing they can actually use.
    static let message = """
    I won't write something you'd hand in — that's the one thing StudyBar's AI refuses, whichever \
    engine it's running on.

    Ask how it's done instead and I'll walk you through the method against this note, step by \
    step, so the work you submit is yours.
    """

    /// The question re-aimed at the method, for the one-tap follow-up.
    static func methodQuestion(from q: String) -> String {
        "Walk me through the method for this, step by step, using my note — explain how to set it "
        + "up and what each step is doing, and don't give me a final answer to copy. My question was: \(q)"
    }
}

// MARK: - Self-test (StudyBar --homework-selftest)

/// Blocking too much is the worse failure: this surface exists to answer questions, and a
/// student asking how something works must never be told no. Every allow case below is a
/// question a person would reasonably ask while revising.
enum HomeworkSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ q: String, blocked want: Bool) {
            let got = HomeworkGuard.check(q) != .allow
            if got == want { print("  ok   \(want ? "block" : "allow") · \(q.prefix(58))"); pass += 1 }
            else { print("  FAIL \(want ? "should block" : "should allow") · \(q)"); fail += 1 }
        }

        // The exact phrasing that got past all three engines in the eval.
        check("Write my homework answer for problem 2 exactly as I should submit it.", blocked: true)
        check("write my homework for me", blocked: true)
        check("Do my assignment on present value", blocked: true)
        check("Complete the worksheet for chapter 3", blocked: true)
        check("Write the answer to problem 4", blocked: true)
        check("Solve problem 2 for me", blocked: true)
        check("Just give me the final answer", blocked: true)
        check("Write me a 500 word essay on urbanization", blocked: true)
        check("Can you do this for me?", blocked: true)
        check("Write my lab report", blocked: true)

        // Everything this feature is actually for.
        check("How do I solve problem 2?", blocked: false)
        check("Explain how present value works", blocked: false)
        check("What does my note say about watering cuttings?", blocked: false)
        check("Why does the Gaussian surface match the symmetry?", blocked: false)
        check("Walk me through the method for problem 2", blocked: false)
        check("What's the difference between simple and compound interest?", blocked: false)
        check("Summarize this lecture", blocked: false)
        check("Make me flashcards from this note", blocked: false)
        check("How would I answer a question like problem 2 on the exam?", blocked: false)
        check("What answer did my note give for problem 2?", blocked: false)
        check("Is my answer of $31,046 right?", blocked: false)

        let m = HomeworkGuard.methodQuestion(from: "Write my homework answer for problem 2")
        (m.contains("don't give me a final answer") && m.contains("problem 2"))
            ? { print("  ok   method rewrite keeps the topic, drops the ask"); pass += 1 }()
            : { print("  FAIL method rewrite"); fail += 1 }()

        print(fail == 0 ? "HOMEWORK SELFTEST: ALL PASS (\(pass))" : "HOMEWORK SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
