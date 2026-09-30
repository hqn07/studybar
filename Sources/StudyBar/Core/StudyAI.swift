import Foundation

// MARK: - Practice questions

struct QuizQuestion: Identifiable, Hashable {
    enum Kind: String { case mcq, tf, fill, short }
    let id = UUID()
    var kind: Kind
    var prompt: String
    var choices: [String] = []
    var answerIndex: Int?                 // mcq
    var answerBool: Bool?                 // tf
    var answerText = ""                   // fill / short: the answer or a model answer
    var explanation = ""
    var topic = ""
    var source = ""

    /// The right answer as words — for the review and the flashcard's back.
    var correctText: String {
        switch kind {
        case .mcq: return answerIndex.flatMap { choices.indices.contains($0) ? choices[$0] : nil } ?? answerText
        case .tf:  return answerBool.map { $0 ? "True" : "False" } ?? answerText
        default:   return answerText
        }
    }
}

/// What the student answered: a choice, true/false, or text. `selfGrade` is their own call on
/// a short answer, which the app can't mark.
struct QuizResponse: Hashable {
    var choice: Int?
    var bool: Bool?
    var text = ""
    var selfGrade: Bool?
    var answered: Bool { choice != nil || bool != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum Quiz {
    static func system(count: Int, exam: Bool) -> String {
        """
        You write practice questions for a student from their own course material.

        Write exactly \(count) questions that test understanding of the material: the ideas, \
        definitions, results and how to apply them — not trivia about where something appears. Mix \
        the types: multiple choice (4 options, exactly one correct, the wrong ones plausible), \
        true/false, fill in the blank (a short phrase or number, the blank written ___), and short \
        answer (1–3 sentences).\(exam ? " Make them exam-level: include calculation and application questions wherever the material has them." : "") \
        Use only what the material says or directly implies. Write math as LaTeX in $…$.

        Reply with ONLY a JSON object:
        {"questions":[
         {"type":"mcq","question":"…","choices":["…","…","…","…"],"answer":2,"explanation":"why, in one or two sentences","topic":"1–4 word topic","source":"the [bracketed] source it came from"},
         {"type":"tf","question":"…","answer":true,"explanation":"…","topic":"…","source":"…"},
         {"type":"fill","question":"… ___ …","answer":"…","explanation":"…","topic":"…","source":"…"},
         {"type":"short","question":"…","answer":"a model answer","explanation":"…","topic":"…","source":"…"}]}
        For mcq, "answer" is the 0-based index of the correct choice.
        """
    }

    static func user(_ material: String, count: Int) -> String {
        "MATERIAL:\n\"\"\"\n\(material)\n\"\"\"\n\nWrite \(count) questions from this material as the JSON object described."
    }

    /// Questions from the whole of the material: it is packed into request-sized groups and a
    /// share of the questions is asked of groups spread across it. nil if every request failed.
    static func generate(from passages: [StudyPassage], count: Int, exam: Bool, provider: AIProvider, mode: AIMode,
                         progress: @escaping @MainActor (_ part: Int, _ total: Int) -> Void) async -> [QuizQuestion]? {
        let local = mode == .ollama || mode == .onDevice
        let groups = StudyMaterial.groups(passages, maxChars: LectureNotes.chunkChars(for: mode) * 2 / 3)
        let calls = min(groups.count, local ? max(1, (count + 3) / 4) : max(1, (count + 14) / 15))
        let picked = StudyMaterial.spread(groups, count: calls)
        // A few more than needed per request: the check below drops the ones it can't stand behind.
        let per = Int((Double(count) / Double(max(1, picked.count))).rounded(.up))
        let ask = per + max(1, per / 4)
        var out: [QuizQuestion] = [], anyOK = false
        for (i, g) in picked.enumerated() {
            guard !Task.isCancelled else { return nil }
            await progress(i + 1, picked.count)
            let block = StudyMaterial.block(g)
            guard let raw = try? await provider.complete(system: system(count: ask, exam: exam),
                                                         messages: [AIMessage(role: .user, text: user(block, count: ask))])
            else { continue }
            anyOK = true
            out += await verify(parse(raw).filter { !answerGivenAway($0) }, material: block, provider: provider)
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0.prompt.lowercased()).inserted }
        return anyOK ? Array(out.prefix(count)) : nil
    }

    /// A second reading of each question against the material it came from, and the ones judged
    /// wrong are dropped rather than corrected. On qwen2.5:7b, before this, three of eight
    /// questions had a wrong answer key or no answer — "net flux is zero with no charge
    /// enclosed" marked False. A wrong key teaches the wrong thing; a shorter quiz doesn't.
    /// If the verdicts can't be read, everything is kept.
    static func verify(_ qs: [QuizQuestion], material: String, provider: AIProvider) async -> [QuizQuestion] {
        guard !qs.isEmpty else { return qs }
        let listing = qs.enumerated().map { i, q in
            var s = "\(i + 1). \(q.kind == .tf ? "True or false: " : "")\(q.prompt)"
            if q.kind == .mcq { s += "\n" + q.choices.enumerated().map { "   \(["A", "B", "C", "D", "E", "F"][min($0.offset, 5)]). \($0.element)" }.joined(separator: "\n") }
            return s + "\n   Marked answer: \(q.correctText)"
        }.joined(separator: "\n")
        let sys = """
        You check practice questions against the course material they were written from. For each \
        numbered question, work out the correct answer yourself from the material, then compare it \
        with the marked answer. A question fails if the marked answer is wrong, if it is ambiguous, \
        or if the material doesn't settle it. Reply with ONLY a JSON object: \
        {"verdicts":[{"n":1,"ok":true},{"n":2,"ok":false,"reason":"…"}]}
        """
        let msg = "MATERIAL:\n\"\"\"\n\(material)\n\"\"\"\n\nQUESTIONS:\n\(listing)"
        guard let raw = try? await provider.complete(system: sys, messages: [AIMessage(role: .user, text: msg)]),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let d = try? JSONSerialization.jsonObject(with: Data(AIProtocol.sanitizeJSON(latexSafeJSON(String(raw[start...end]))).utf8)) as? [String: Any],
              let verdicts = d["verdicts"] as? [[String: Any]] else { return qs }
        let bad = Set(verdicts.compactMap { v -> Int? in
            let ok = (v["ok"] as? Bool) ?? ((v["ok"] as? String).map { $0.lowercased() == "true" } ?? true)
            return ok ? nil : ((v["n"] as? Int) ?? Int("\(v["n"] ?? "")")).map { $0 - 1 }
        })
        if !bad.isEmpty { Diagnostics.info(.ai, "Quiz check dropped \(bad.count) of \(qs.count) questions") }
        return qs.enumerated().filter { !bad.contains($0.offset) }.map(\.element)
    }

    /// A blank whose answer is already written in the sentence around it.
    static func answerGivenAway(_ q: QuizQuestion) -> Bool {
        guard q.kind == .fill else { return false }
        let a = q.answerText.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        guard !a.isEmpty else { return true }
        let words = Set(q.prompt.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return a.contains(" ") ? q.prompt.lowercased().contains(a) : words.contains(a)
    }

    /// Tolerant of the shapes models actually return: an object or a bare array, `options` for
    /// `choices`, an answer given as index, letter, or the choice's text.
    static func parse(_ raw: String) -> [QuizQuestion] {
        let text = latexSafeJSON(raw)
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return [] }
        // Up to the last closer: a closing ``` fence after the object would fail the parse.
        let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }) ?? text.index(before: text.endIndex)
        let json = AIProtocol.sanitizeJSON(String(text[start...max(start, end)]))
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return [] }
        let list = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["questions"] as? [[String: Any]]) ?? []
        return list.compactMap { d in
            func str(_ keys: String...) -> String {
                for k in keys { if let s = d[k] as? String { return MathSupport.normalized(s).trimmingCharacters(in: .whitespaces) } }
                for k in keys { if let n = d[k] as? NSNumber { return n.stringValue } }
                return ""
            }
            let prompt = str("question", "prompt")
            guard !prompt.isEmpty else { return nil }
            let type = str("type", "kind").lowercased()
            var q = QuizQuestion(kind: .short, prompt: prompt, explanation: str("explanation", "why"),
                                 topic: str("topic"), source: str("source").trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            let choices = ((d["choices"] ?? d["options"]) as? [Any])?.map { MathSupport.normalized("\($0)") } ?? []
            if choices.count >= 2 || type.contains("mc") || type.contains("multiple") {
                q.kind = .mcq
                q.choices = choices.map { $0.replacingOccurrences(of: #"^\s*[A-Da-d][).:]\s+"#, with: "", options: .regularExpression) }
                let a = d["answer"]
                if let n = a as? Int, q.choices.indices.contains(n) { q.answerIndex = n }
                else if let s = a as? String {
                    let t = s.trimmingCharacters(in: .whitespaces)
                    if t.count == 1, let c = t.uppercased().unicodeScalars.first, (65...68).contains(c.value) { q.answerIndex = Int(c.value) - 65 }
                    else { q.answerIndex = q.choices.firstIndex { $0.caseInsensitiveCompare(t) == .orderedSame } }
                }
                guard q.answerIndex != nil, q.choices.count >= 2 else { return nil }
            } else if type.contains("tf") || type.contains("true") || d["answer"] is Bool {
                q.kind = .tf
                if let b = d["answer"] as? Bool { q.answerBool = b }
                else { q.answerBool = ["true", "t", "yes"].contains(str("answer").lowercased()) ? true
                                    : ["false", "f", "no"].contains(str("answer").lowercased()) ? false : nil }
                guard q.answerBool != nil else { return nil }
            } else {
                q.kind = type.contains("fill") || prompt.contains("___") ? .fill : .short
                q.answerText = str("answer", "model_answer")
                guard !q.answerText.isEmpty else { return nil }
            }
            return q
        }
    }

    /// LaTeX inside a JSON string is where model JSON breaks: `\frac` reads as a form feed and
    /// `\(` isn't an escape at all. Every backslash that isn't a real JSON escape is doubled. The
    /// hard case is `\n`, `\t`, `\b`, `\f`, `\r` followed by letters — a newline before a word, or
    /// `\nabla`? — decided by whether the letters spell a LaTeX command.
    static func latexSafeJSON(_ s: String) -> String {
        var out = "", chars = Array(s), i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else { out.append(c); i += 1; continue }
            let n = chars[i + 1]
            if n == "\\" || n == "\"" || n == "/" { out.append(c); out.append(n); i += 2; continue }
            if n == "u", i + 5 < chars.count, chars[(i + 2)...(i + 5)].allSatisfy(\.isHexDigit) { out.append(c); i += 1; continue }
            if "bfnrt".contains(n) {
                let word = String(chars[(i + 1)...].prefix { $0.isLetter })
                if !latexCommands.contains(word) { out.append(c); i += 1; continue }
            }
            out += "\\\\"; i += 1
        }
        return out
    }

    /// LaTeX commands that begin with a JSON escape letter.
    private static let latexCommands: Set<String> = [
        "beta", "bar", "bf", "binom", "boldsymbol", "big", "bigg", "begin", "bot", "bullet", "bmod", "backslash",
        "frac", "forall", "flat", "frown",
        "nabla", "nu", "neq", "ne", "not", "newline", "neg", "ni", "notin", "nexists", "nleq", "ngeq", "nmid",
        "rho", "right", "rangle", "rightarrow", "rm", "rceil", "rfloor", "rbrace", "rvert", "real",
        "theta", "times", "tau", "tan", "tanh", "text", "textbf", "textit", "textrm", "to", "tilde", "top",
        "triangle", "tfrac", "therefore", "tag", "tt",
    ]

    /// nil when the app can't tell (a short answer the student hasn't marked).
    static func isCorrect(_ q: QuizQuestion, _ r: QuizResponse) -> Bool? {
        switch q.kind {
        case .mcq:   return r.choice.map { $0 == q.answerIndex }
        case .tf:    return r.bool.map { $0 == q.answerBool }
        case .fill:  return r.answered ? fillMatches(r.text, q.answerText) : false
        case .short: return r.answered ? r.selfGrade : false
        }
    }

    /// A blank is right when the words match once case, spacing, `$` and punctuation are set
    /// aside, or when both are numbers within 1%.
    static func fillMatches(_ given: String, _ answer: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." } }
        let g = norm(given), a = norm(answer)
        guard !g.isEmpty else { return false }
        if g == a { return true }
        if let x = Double(g), let y = Double(a) { return abs(x - y) <= 0.01 * max(abs(x), abs(y)) }
        return a.count >= 4 && (a.contains(g) && g.count * 2 >= a.count || g.contains(a))
    }

    /// Marking a short answer against the model answer, when the student asks for it.
    static func grade(_ q: QuizQuestion, answer: String, provider: AIProvider) async -> (correct: Bool, feedback: String)? {
        let sys = """
        Grade a student's short answer against the model answer. It is correct if it says the same \
        thing in substance, even in different words. Reply with ONLY a JSON object: \
        {"correct": true or false, "feedback": "one sentence: what was right or what was missing"}
        """
        let msg = "QUESTION: \(q.prompt)\nMODEL ANSWER: \(q.answerText)\nSTUDENT ANSWER: \(answer)"
        guard let raw = try? await provider.complete(system: sys, messages: [AIMessage(role: .user, text: msg)]),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let d = try? JSONSerialization.jsonObject(with: Data(AIProtocol.sanitizeJSON(latexSafeJSON(String(raw[start...end]))).utf8)) as? [String: Any],
              let ok = d["correct"] as? Bool else { return nil }
        return (ok, (d["feedback"] as? String) ?? "")
    }

    /// A missed question as a flashcard: the question (with its choices) on the front, the
    /// answer and why on the back.
    static func card(_ q: QuizQuestion) -> (front: String, back: String) {
        var front = q.prompt
        if q.kind == .mcq { front += "\n\n" + q.choices.enumerated().map { "\(["A", "B", "C", "D", "E", "F"][min($0.offset, 5)]). \($0.element)" }.joined(separator: "\n") }
        if q.kind == .tf { front = "True or false: " + front }
        let back = q.correctText + (q.explanation.isEmpty ? "" : "\n\n" + q.explanation)
        return (front, back)
    }

    /// Missed questions into the course's "Missed questions" deck. Undoable.
    @MainActor
    static func addMissed(_ qs: [QuizQuestion], course: Course?, state: AppState) -> String? {
        guard !qs.isEmpty else { return nil }
        let name = "\(course.map { $0.code.isEmpty ? $0.name : $0.code } ?? "Study") · Missed questions"
        state.withUndo("Added \(qs.count) missed question\(qs.count == 1 ? "" : "s") to flashcards") {
            let deckID: UUID
            if let d = state.data.decks.first(where: { $0.name == name }) { deckID = d.id }
            else { let d = Deck(name: name, courseID: course?.id); state.data.decks.append(d); deckID = d.id }
            for q in qs {
                let c = card(q)
                state.data.flashcards.append(Flashcard(deckID: deckID, front: c.front, back: c.back))
            }
        }
        return name
    }
}

// MARK: - Study guide

enum StudyGuide {
    static let sections = ["Key concepts", "Definitions", "Formulas", "Worked examples"]

    /// A template to fill in, not a description of one: described as "## Key concepts — bullets:
    /// **concept** — …", qwen2.5:7b wrote that line back with its first bullet on the end.
    static let system = """
    You write a study guide from a student's own course material. Fill in this template, leaving \
    out any section the material has nothing for. Each `##` heading stays on its own line.

    ## Key concepts
    - **Concept** — what it is and why it matters, in one or two sentences. [source]

    ## Definitions
    - **Term** — its definition. [source]

    ## Formulas
    - $formula$ — what it gives, and what each symbol means. [source]

    ## Worked examples
    - A short problem the material works or sets up, solved step by step. [source]

    Use only the material, and replace [source] with the bracketed source the point came from. \
    Write math as LaTeX in $…$. Output ONLY Markdown — no title, no preamble.

    \(NoteFormat.listRules)
    """

    static func user(_ material: String) -> String {
        "MATERIAL:\n\"\"\"\n\(material)\n\"\"\"\n\nWrite the study guide sections for this material."
    }

    /// Each group's guide, merged section by section, so a guide over a whole term has one
    /// Definitions list rather than one per request. Repeated lines are dropped.
    static func merge(_ parts: [String], title: String) -> String {
        var bodies: [String: [String]] = [:]
        var seen = Set<String>()
        for part in parts {
            var current: String?
            for line in part.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") {
                    let h = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    current = sections.first { h.lowercased().hasPrefix($0.lowercased()) }
                    // A heading with its first point written onto the end of it.
                    if let s = current {
                        let rest = h.dropFirst(s.count).trimmingCharacters(in: CharacterSet(charactersIn: " —–-:"))
                            .replacingOccurrences(of: #"^(?i)bullets?:\s*"#, with: "", options: .regularExpression)
                        if !rest.isEmpty, seen.insert(rest.lowercased()).inserted { bodies[s, default: []].append("- " + rest) }
                    }
                    continue
                }
                guard let s = current else { continue }
                if !t.isEmpty, !t.hasPrefix("$$"), !seen.insert(t.lowercased()).inserted { continue }
                bodies[s, default: []].append(line)
            }
            if let s = current { bodies[s, default: []].append("") }
        }
        var out = "# \(title)\n"
        for s in sections {
            let body = (bodies[s] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { out += "\n## \(s)\n\(body)\n" }
        }
        return out
    }

    static func generate(from passages: [StudyPassage], title: String, provider: AIProvider, mode: AIMode,
                         progress: @escaping @MainActor (_ part: Int, _ total: Int) -> Void) async -> String? {
        let groups = StudyMaterial.groups(passages, maxChars: LectureNotes.chunkChars(for: mode) * 2 / 3)
        let picked = StudyMaterial.spread(groups, count: mode == .ollama || mode == .onDevice ? 8 : 4)
        var parts: [String] = []
        for (i, g) in picked.enumerated() {
            guard !Task.isCancelled else { return nil }
            await progress(i + 1, picked.count)
            if let out = try? await provider.streamPlain(system: system,
                    messages: [AIMessage(role: .user, text: user(StudyMaterial.block(g)))],
                    temperature: 0.3, onReply: { _ in }) {
                parts.append(NoteFormat.tidy(MathSupport.normalized(LectureNotes.unfenced(out))))
            }
        }
        return parts.isEmpty ? nil : merge(parts, title: title)
    }
}

// MARK: - Tutor

enum Tutor {
    enum Mode: String, CaseIterable, Identifiable {
        case hint = "Hint", step = "Next step", full = "Full solution", explain = "Explain"
        var id: String { rawValue }
        var directive: String {
            switch self {
            case .hint: return "Give ONE hint that gets the student unstuck — the idea or the first move — without working the problem or giving the answer."
            case .step: return "Show only the next step of the solution from where the student is (the first step if they haven't started), with its working. Then stop, and ask them to try the step after it."
            case .full: return "Solve it completely, step by step: name the principle that applies, show each step with its working, and state the final answer plainly."
            case .explain: return "Explain the concept: the intuition first, then the precise statement, then a short example."
            }
        }
    }

    static func system(_ mode: Mode, course: String?) -> String {
        """
        You are a tutor for a student\(course.map { " in \($0)" } ?? ""). Use the COURSE MATERIAL when it \
        is relevant, citing it in [brackets]; otherwise answer from what you know. When a question \
        comes with an image, the problem is in the image.

        \(mode.directive)

        Write math as LaTeX in $…$ (display math in $$…$$). Use Markdown.\(mode == .full ? "\n\n" + MathCheck.instruction : "")

        \(NoteFormat.listRules)
        """
    }

    struct Turn: Identifiable, Hashable {
        let id = UUID()
        var question: String
        var mode: Mode
        var images: [Data] = []
        var answer = ""
        var checks: [MathCheck.Result] = []
    }

    /// The last few turns for context; the course material and the images go on the new one only.
    static func messages(thread: [Turn], question: String, material: String, images: [Data], imageText: String,
                         mode: Mode = .explain) -> [AIMessage] {
        var msgs: [AIMessage] = []
        for t in thread.suffix(4) where !t.answer.isEmpty {
            msgs.append(AIMessage(role: .user, text: t.question))
            msgs.append(AIMessage(role: .assistant, text: t.answer))
        }
        var text = material.isEmpty ? "" : "COURSE MATERIAL:\n\"\"\"\n\(material)\n\"\"\"\n\n"
        if !imageText.isEmpty { text += "TEXT READ FROM THE ATTACHED IMAGE:\n\"\"\"\n\(imageText)\n\"\"\"\n\n" }
        text += "QUESTION: \(question.isEmpty ? "Help me with the problem in the image." : question)"
        // Repeated here for the same reason as LectureNotes.user: in the system prompt alone,
        // qwen2.5:7b wrote a "### CHECK" heading over "7.18e6 = 7.18e6" — nothing to verify.
        if mode == .full { text += "\n\n" + MathCheck.reminder }
        msgs.append(AIMessage(role: .user, text: text, images: images))
        return msgs
    }
}

// MARK: - Checking the arithmetic

/// A model that sets up a problem correctly still gets the arithmetic wrong. A full solution
/// ends with `CHECK: <expression> = <value>` lines, and StudyBar's own calculator (`MathEval`)
/// recomputes each: the value is right if it matches to the significant figures it was given to.
enum MathCheck {
    struct Result: Hashable {
        let expression: String
        let claimed: String
        let actual: Double?               // nil: the expression couldn't be evaluated
        var ok: Bool?                     // nil: couldn't check
    }

    static let instruction = """
    After the solution, for each numeric result add a line `CHECK: <arithmetic> = <value>`, using \
    only numbers, + - * / ^, parentheses, sqrt, sin, cos, tan, ln, log and pi — no variables, no \
    units. Example: `CHECK: 8.99e9 * 2e-6 / 0.05^2 = 7.19e6`. Software reads these lines, so write \
    them exactly like that.
    """

    static let reminder = """
    End with one line per numeric result in exactly this form, with the arithmetic written out \
    (not the answer repeated): CHECK: 2e-6 / (4 * pi * 8.85e-12 * 0.05^2) = 7.19e6
    """

    /// The answer without its CHECK lines, and what each one found.
    static func run(_ answer: String) -> (text: String, results: [Result]) {
        var keep: [String] = [], results: [Result] = []
        for line in answer.components(separatedBy: "\n") {
            // Behind a bullet, a heading mark or code ticks is still a CHECK line.
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t`*#->"))
            guard t.uppercased().hasPrefix("CHECK:") else { keep.append(line); continue }
            let body = t.dropFirst(6)
            guard let eq = body.lastIndex(of: "=") else { continue }   // a bare "CHECK:" heading is dropped too
            let expr = body[..<eq].trimmingCharacters(in: .whitespaces)
            let claimed = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`*$ "))
            let actual = try? MathEval.evaluate(normalize(expr)).value
            let c = try? MathEval.evaluate(normalize(claimed)).value
            results.append(Result(expression: expr, claimed: claimed, actual: actual,
                                  ok: actual.flatMap { a in c.map { agrees(a, $0, sig: sigFigs(claimed)) } }))
        }
        return (keep.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), results)
    }

    /// The expression the way `MathEval` reads it. Models write CHECK lines in LaTeX whatever
    /// the instructions say, and `2e-6` is 2·e−6 to the calculator (it has the constant e).
    /// A number times a power of ten becomes one grouped number first: `2 × 10^{-6} / 8.85 ×
    /// 10^{-12}` means (2e-6)/(8.85e-12), and read left to right it would not.
    static func normalize(_ s: String) -> String {
        func rx(_ t: String, _ p: String, _ with: String) -> String {
            t.replacingOccurrences(of: p, with: with, options: .regularExpression)
        }
        var t = s
        for d in ["\\(", "\\)", "\\[", "\\]", "$", "\\left", "\\right", "\\,", "\\!", "\\ "] {
            t = t.replacingOccurrences(of: d, with: " ")
        }
        t = rx(t, #"(\d+(?:\.\d+)?)\s*(?:\\times|×|\*|\\cdot|·)\s*10\s*\^\s*\{?\s*\(?\s*([+\-−]?\s*\d+)\s*\)?\s*\}?"#, "($1*10^($2))")
        t = rx(t, #"(\d(?:\.\d+)?|\.\d+)[eE]([+\-]?\d+)"#, "($1*10^($2))")
        var prev = ""
        while prev != t { prev = t; t = rx(t, #"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#, "(($1)/($2))") }
        t = rx(t, #"\\sqrt\s*\{([^{}]*)\}"#, "sqrt($1)")
        for (a, b) in [("\\times", "*"), ("\\cdot", "*"), ("×", "*"), ("·", "*"), ("−", "-"), ("\\pi", "pi"), ("π", "pi"),
                       ("{", "("), ("}", ")")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Significant figures in a value as written — its leading number: `7.19e6` and
    /// `7.19 \times 10^6` → 3, `0.050` → 2, `7200` → 2.
    static func sigFigs(_ s: String) -> Int {
        guard let m = s.firstMatch(of: /\d+(?:\.\d+)?/) else { return 15 }
        let mant = String(m.output)
        var digits = mant.filter(\.isNumber)
        while digits.hasPrefix("0") { digits.removeFirst() }
        if !mant.contains(".") { while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() } }
        return max(1, min(15, digits.count))
    }

    static func agrees(_ actual: Double, _ claimed: Double, sig: Int) -> Bool {
        guard actual != 0 else { return abs(claimed) < 1e-12 }
        let scale = pow(10, Double(sig) - 1 - floor(log10(abs(actual))))
        let rounded = (actual * scale).rounded() / scale
        return abs(rounded - claimed) <= 1e-9 * max(1, abs(claimed)) || abs(actual - claimed) <= 0.005 * abs(actual)
    }
}

// MARK: - Self-test (StudyBar --study-selftest)

enum StudySelfTest {
    @MainActor
    static func run() -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }

        // Retrieval: the page about conductors, asked in other words.
        let passages = [
            StudyPassage(title: "Serway", locator: "p. 700", text: "Coulomb's law gives the force between two point charges, proportional to the product of the charges."),
            StudyPassage(title: "Serway", locator: "p. 745", text: "In electrostatic equilibrium the electric field inside a conductor is zero, and any excess charge resides on its surface."),
            StudyPassage(title: "Serway", locator: "p. 760", text: "The potential difference between two points is the negative line integral of the field."),
        ]
        check("keyword retrieval", StudyIndex.search("conductor surface charge", in: passages, k: 1).first?.locator == "p. 745")
        check("paraphrased retrieval", StudyIndex.search("why is there no field in a metal", in: passages, k: 1).first?.locator == "p. 745")
        check("empty material → nothing", StudyIndex.search("x", in: [], k: 3).isEmpty)
        check("groups keep passages whole", StudyMaterial.groups(passages, maxChars: 150).count == 3)
        check("spread picks across", StudyMaterial.spread(Array(0..<10), count: 3) == [0, 3, 6])

        // Model JSON, as it actually comes back: fences, LaTeX, letters for answers.
        let raw = #"""
        ```json
        {"questions":[
         {"type":"mcq","question":"The field inside a conductor is","choices":["A) zero","B) $\frac{\sigma}{\epsilon_0}$","C) infinite","D) $kq/r^2$"],"answer":"A","explanation":"Charges rearrange.","topic":"Conductors","source":"[Serway, p. 745]"},
         {"type":"tf","question":"Flux depends on charges outside.","answer":"false","explanation":"They cancel.","topic":"Flux"},
         {"type":"fill","question":"Excess charge sits on the ___.","answer":"surface"},
         {"type":"short","question":"Why is E zero inside?","answer":"Free charges move until the field cancels."},
         {"type":"mcq","question":"broken","choices":["a","b"],"answer":7}
        ]}
        ```
        """#
        let qs = Quiz.parse(raw)
        check("parses four good questions, drops the broken one", qs.count == 4, "(\(qs.count))")
        check("letter answer → index", qs.first?.answerIndex == 0 && qs.first?.choices.first == "zero")
        check("LaTeX survives JSON", qs.first?.choices[1].contains("\\frac") == true, qs.first?.choices[1] ?? "")
        check("string true/false", qs.count > 1 && qs[1].kind == .tf && qs[1].answerBool == false)
        check("fill and short kinds", qs.count > 3 && qs[2].kind == .fill && qs[3].kind == .short)
        check("a blank that gives its answer away is caught",
              Quiz.answerGivenAway(QuizQuestion(kind: .fill, prompt: "E = λ/(2π ε₀ r). ___", answerText: "r"))
              && !Quiz.answerGivenAway(qs.count > 2 ? qs[2] : QuizQuestion(kind: .fill, prompt: "", answerText: "")))
        check("source unbracketed", qs.first?.source == "Serway, p. 745")
        check("fill matching", Quiz.fillMatches("Surface.", "surface") && Quiz.fillMatches("7.2e6", "7200000")
              && Quiz.fillMatches("3.14", "3.141") && !Quiz.fillMatches("volume", "surface"))
        check("json escapes kept", Quiz.latexSafeJSON(#"{"a":"x\ny \"q\" \\"}"#) == #"{"a":"x\ny \"q\" \\"}"#)
        check("latex escaped", Quiz.latexSafeJSON(#"$\theta$ \( \nabla"#) == #"$\\theta$ \\( \\nabla"#)

        // The arithmetic check.
        let answer = "So $E = 7.19\\times10^6$ N/C.\n\nCHECK: 8.99e9 * 2e-6 / 0.05^2 = 7.19e6\nCHECK: 2 * 3 = 7\nCHECK: sqrt(2) = 1.414\nCHECK: x + 1 = 2"
        let (text, results) = MathCheck.run(answer)
        check("CHECK lines removed", !text.contains("CHECK"))
        check("right arithmetic passes", results.first?.ok == true, "\(results.first?.actual ?? -1)")
        check("wrong arithmetic fails", results.count > 1 && results[1].ok == false)
        check("rounded value passes", results.count > 2 && results[2].ok == true)
        check("variables can't be checked", results.count > 3 && results[3].ok == nil)
        check("sig figs", MathCheck.sigFigs("7.19e6") == 3 && MathCheck.sigFigs("0.050") == 2 && MathCheck.sigFigs("7200") == 2)
        // As qwen2.5:7b actually wrote them: LaTeX, and a wrong field (the right one is 7.19e6).
        let latex = MathCheck.run(#"""
        CHECK: \( 2 \times 10^{-6} / (4 \times 3.14159 \times 8.85 \times 10^{-12} \times 0.0025) = 1.77 \times 10^6 \)
        CHECK: \( 2 \times 10^{-6} / 8.85 \times 10^{-12} = 2.26 \times 10^5 \)
        - CHECK: $\frac{2 \times 10^{-6}}{8.85 \times 10^{-12}} = 2.26 \times 10^{5}$
        ### CHECK:
        """#).results
        check("LaTeX CHECK is read, and the wrong field caught", latex.first?.ok == false, "\(latex.first?.actual.map(MathEval.format) ?? "unread")")
        check("a × 10^n groups as one number", latex.count > 1 && latex[1].ok == true, "\(latex.count > 1 ? latex[1].actual.map(MathEval.format) ?? "unread" : "")")
        check("\\frac and a bullet", latex.count > 2 && latex[2].ok == true)
        check("a bare CHECK heading is not a check", latex.count == 3)

        // Study guide merge.
        let merged = StudyGuide.merge(["## Definitions\n- **Flux** — field through a surface [A]\n## Formulas\n- $E=kq/r^2$ [A]",
                                       "## Definitions\n- **Flux** — field through a surface [A]\n- **Gaussian surface** — imaginary [B]"],
                                      title: "Study guide")
        check("one Definitions section", merged.components(separatedBy: "## Definitions").count == 2)
        check("duplicates dropped", merged.components(separatedBy: "**Flux**").count == 2 && merged.contains("Gaussian surface"))
        let inline = StudyGuide.merge(["## Key concepts — bullets: **Flux** — field through a surface.\n- **Gauss** — flux is charge over ε₀."], title: "G")
        check("a point on the heading line is kept", inline.contains("- **Flux** — field through a surface.") && inline.contains("**Gauss**"), inline)
        check("sections in order", (merged.range(of: "## Definitions")?.lowerBound ?? merged.endIndex) < (merged.range(of: "## Formulas")?.lowerBound ?? merged.startIndex))

        print(fail == 0 ? "STUDY SELFTEST: ALL PASS" : "STUDY SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}

// MARK: - Headless runs (StudyBar --study-run quiz|guide|tutor|extract <file> [question] [--engine x])

/// The real jobs on a real engine, printed — to read what the prompts produce.
enum StudyRun {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--study-run"), i + 2 < args.count else { return 1 }
        let kind = args[i + 1], url = URL(fileURLWithPath: args[i + 2])
        let mode = args.firstIndex(of: "--engine").flatMap { $0 + 1 < args.count ? AIMode(rawValue: args[$0 + 1]) : nil } ?? .ollama
        let units = StudyMaterial.extract(url)
        let passages = units.flatMap { u in
            LectureNotes.chunks(u.text, maxChars: 1_500).map { StudyPassage(title: url.lastPathComponent, locator: u.locator, text: $0) }
        }
        if kind == "extract" {
            for u in units { print("[\(u.locator)] \(u.text.prefix(200).replacingOccurrences(of: "\n", with: " ⏎ "))") }
            return units.isEmpty ? 1 : 0
        }
        guard let provider = AIService.makeProvider(mode: mode) else { print("no engine"); return 1 }
        let t0 = Date()
        func took() -> String { "\(Int(Date().timeIntervalSince(t0)))s" }
        switch kind {
        case "quiz", "exam":
            let qs = await Quiz.generate(from: passages, count: 8, exam: kind == "exam", provider: provider, mode: mode) { p, t in
                FileHandle.standardError.write("\rpart \(p)/\(t)".data(using: .utf8)!)
            }
            print("\n--- \(took()) · \(qs?.count ?? 0) questions ---")
            for q in qs ?? [] {
                print("[\(q.kind.rawValue)] \(q.prompt)")
                if q.kind == .mcq { for (n, c) in q.choices.enumerated() { print("   \(n == q.answerIndex ? "*" : " ") \(c)") } }
                else { print("   → \(q.correctText)") }
                print("   why: \(q.explanation)  · \(q.topic) · \(q.source)")
            }
            return (qs?.isEmpty ?? true) ? 1 : 0
        case "guide-raw":
            let g = StudyMaterial.groups(passages, maxChars: LectureNotes.chunkChars(for: mode) * 2 / 3).first ?? []
            let out = try? await provider.streamPlain(system: StudyGuide.system,
                messages: [AIMessage(role: .user, text: StudyGuide.user(StudyMaterial.block(g)))], temperature: 0.3, onReply: { _ in })
            print(out ?? "FAILED")
            return 0
        case "guide":
            let g = await StudyGuide.generate(from: passages, title: "Study guide", provider: provider, mode: mode) { _, _ in }
            print("--- \(took()) ---\n\(g ?? "FAILED")")
            return g == nil ? 1 : 0
        case "tutor":
            let q = i + 3 < args.count && !args[i + 3].hasPrefix("--") ? args[i + 3] : "Explain the main idea."
            let tutorMode = Tutor.Mode(rawValue: args.firstIndex(of: "--mode").map { args[$0 + 1] } ?? "") ?? .full
            let found = StudyIndex.search(q, in: passages, k: 5)
            print("retrieved: \(found.map(\.cite))")
            let out = try? await provider.streamPlain(system: Tutor.system(tutorMode, course: nil),
                                                      messages: Tutor.messages(thread: [], question: q, material: StudyMaterial.block(found),
                                                                               images: [], imageText: "", mode: tutorMode),
                                                      temperature: 0.3, onReply: { _ in })
            let (text, checks) = MathCheck.run(out ?? "")
            print("--- \(took()) ---\n\(text)\n--- checks ---")
            for c in checks { print("\(c.ok.map { $0 ? "OK  " : "BAD " } ?? "??  ") \(c.expression) = \(c.claimed)  (calc: \(c.actual.map { MathEval.format($0) } ?? "–"))") }
            return out == nil ? 1 : 0
        default:
            return 1
        }
    }
}
