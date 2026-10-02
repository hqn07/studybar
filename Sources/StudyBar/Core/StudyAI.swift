import AVFoundation
import PDFKit

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
    static func system(count: Int, exam: Bool, weak: [String] = []) -> String {
        let lean = weak.isEmpty ? "" : " The student is weakest on \(weak.joined(separator: ", ")): where this material covers those, make about a third of the questions about them."
        return """
        You write practice questions for a student from their own course material.

        Write exactly \(count) questions that test understanding of the material: the ideas, \
        definitions, results and how to apply them — not trivia about where something appears. Mix \
        the types: multiple choice (4 options, exactly one correct, the wrong ones plausible), \
        true/false, fill in the blank (a short phrase or number, the blank written ___), and short \
        answer (1–3 sentences).\(exam ? " Make them exam-level: include calculation and application questions wherever the material has them." : "")\(lean) \
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
    static func generate(from passages: [StudyPassage], count: Int, exam: Bool, weak: [String] = [], provider: AIProvider, mode: AIMode,
                         progress: @escaping @MainActor (_ part: Int, _ total: Int) -> Void) async -> [QuizQuestion]? {
        let local = mode == .ollama || mode == .onDevice
        let groups = StudyMaterial.groups(passages, maxChars: LectureNotes.readChars(for: mode))
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
            guard let raw = try? await provider.complete(system: system(count: ask, exam: exam, weak: weak),
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
        // Compatibility forms first: an answer key's ε₀ or m² against a typed ε0 or m2.
        func norm(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." } }
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

// MARK: - Glossary

/// A course's terms with their definitions, gathered from what the student already has — no AI:
/// `term :: definition` lines, the "**Term** — definition" lines study notes and guides are
/// written in, and flashcards whose front is a term rather than a question. One entry per term,
/// the first definition found, in that order of trust; A to Z.
enum Glossary {
    struct Entry: Identifiable, Equatable {
        var id: String { term.lowercased() }
        let term: String, definition: String, source: String
    }

    /// `- **Flux** — the field through a surface`, `**Flux**: …`; at most 60 characters of term.
    private static let bold = #"^\s*(?:[-*•]\s+)?\*\*([^*\n]{2,60})\*\*\s*(?:—|–|-|:)\s*(.+)$"#

    static func build(notes: [Note], cards: [(front: String, back: String, deck: String)]) -> [Entry] {
        var out: [String: Entry] = [:], order: [String] = []
        func add(_ term: String, _ def: String, _ source: String) {
            let t = term.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let d = def.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, t.count <= 60, !d.isEmpty, !t.hasSuffix("?") else { return }
            let k = t.lowercased()
            if out[k] == nil { out[k] = Entry(term: t, definition: d, source: source); order.append(k) }
        }
        for n in notes {
            let title = n.title.isEmpty ? "Untitled note" : n.title
            for c in NoteCards.parse(n.body) { add(c.front, c.back, title) }
        }
        for n in notes {
            let title = n.title.isEmpty ? "Untitled note" : n.title
            for line in n.body.components(separatedBy: .newlines) {
                guard let m = line.range(of: bold, options: .regularExpression) else { continue }
                let l = String(line[m])
                guard let open = l.range(of: "**"), let close = l.range(of: "**", range: open.upperBound..<l.endIndex) else { continue }
                let rest = l[close.upperBound...].trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^(?:—|–|-|:)\s*"#, with: "", options: .regularExpression)
                add(String(l[open.upperBound..<close.lowerBound]), rest, title)
            }
        }
        for c in cards where !c.front.contains("{{") && c.front.split(separator: " ").count <= 6 { add(c.front, c.back, c.deck) }
        return order.compactMap { out[$0] }.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }
}

// MARK: - Audio review

/// Notes as something to listen to on a walk or a commute: the AI writes a spoken review of
/// them, and the Mac's best voice reads it into an audio file.
enum AudioReview {
    static let system = """
    You write a spoken review of a student's notes, to be read aloud by a text-to-speech voice \
    while they walk or commute: about 8 minutes, roughly 1,100 words. Go through the main ideas \
    in a sensible order — what each is, why it matters, any formula said in words ("E equals k q \
    over r squared"), and a quick example where the notes have one. End with three questions to \
    think over. Write only plain spoken sentences: no Markdown, no lists, no headings, no LaTeX \
    or symbols, no stage directions.
    """

    /// What a voice would read aloud wrongly or as punctuation, gone: Markdown marks, `$`, LaTeX
    /// backslashes, and the brackets of a citation.
    static func spoken(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[[^\]\n]{1,80}\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*(?:#+|[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`", "$", "\\"] { t = t.replacingOccurrences(of: mark, with: "") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes the review into `out` and returns its script. Progress is a word for the jobs bar.
    @MainActor @discardableResult
    static func make(from notes: [Note], to out: URL, provider: AIProvider, mode: AIMode,
                     progress: @escaping (String) -> Void) async throws -> String {
        let text = notes.map { "\($0.title)\n\($0.body)" }.joined(separator: "\n\n")
        progress("writing the script")
        let script = try await provider.completePlain(system: system, messages: [
            AIMessage(role: .user, text: "NOTES:\n\"\"\"\n\(text.prefix(LectureNotes.readChars(for: mode)))\n\"\"\"\n\nWrite the spoken review.")])
        let clean = spoken(script)
        guard clean.count > 200 else { throw AIError.badResponse }
        progress("reading it aloud")
        try await Converter.speak(clean, to: out)
        return clean
    }
}

// MARK: - A quiz to share

/// A quiz as one web page a classmate can open in any browser and take: the questions, then
/// Check answers marks them the way Study does and shows each answer with why. The math
/// renders with the KaTeX the app carries, inside the file, so it works offline too.
enum QuizShare {
    static func html(_ qs: [QuizQuestion], title: String) -> String {
        let items: [[String: Any]] = qs.map { q in
            var d: [String: Any] = ["kind": q.kind.rawValue, "prompt": q.prompt, "answer": q.correctText,
                                    "why": q.explanation, "source": q.source]
            if q.kind == .mcq { d["choices"] = q.choices; d["index"] = q.answerIndex ?? -1 }
            if q.kind == .tf { d["bool"] = q.answerBool ?? false }
            return d
        }
        // JSONSerialization writes "/" as "\/", so no question can close the <script> it sits in.
        let json = (try? JSONSerialization.data(withJSONObject: items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let t = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return #"""
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\#(t)</title>
        \#(KatexAssets.prelude)
        <style>
          :root{color-scheme:light dark;}
          body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:720px;margin:32px auto;padding:0 16px;color:#1d1d20;background:#fff;}
          @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#eee;}.q{border-color:#3a3a3c;}}
          h1{font-size:24px;margin:0 0 4px;} .n{color:#888;font-size:13px;} .q{border:1px solid #ddd;border-radius:10px;padding:12px 16px;margin:14px 0;}
          label{display:block;margin:4px 0;cursor:pointer;} input[type=text],textarea{width:100%;font:inherit;padding:6px;box-sizing:border-box;}
          .why{display:none;margin-top:8px;padding:8px 10px;border-radius:8px;background:rgba(127,127,127,.12);font-size:14px;}
          .done .why{display:block;} .right{color:#1a7f37;font-weight:600;} .wrong{color:#c62828;font-weight:600;}
          button{font:inherit;padding:8px 18px;border-radius:8px;border:0;background:#0a64d8;color:#fff;cursor:pointer;}
          #score{font-size:20px;font-weight:600;}
        </style></head><body>
        <h1>\#(t)</h1><p class="n">\#(qs.count) questions · made with StudyBar</p>
        <div id="qs"></div><p id="score"></p><button id="check">Check answers</button>
        <script>
        var Q=\#(json);
        // As Study marks a blank: letters, digits and points only; numbers within 1%.
        function norm(s){return s.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}.]/gu,'');}
        function num(s){return s!==''&&!isNaN(Number(s));}
        function fillOK(g,a){g=norm(g);a=norm(a);if(!g)return false;if(g===a)return true;
          if(num(g)&&num(a)){var x=Number(g),y=Number(a);return Math.abs(x-y)<=0.01*Math.max(Math.abs(x),Math.abs(y));}
          return a.length>=4&&((a.indexOf(g)>=0&&g.length*2>=a.length)||g.indexOf(a)>=0);}
        function add(p,tag,text,cls){var e=document.createElement(tag);if(text)e.textContent=text;if(cls)e.className=cls;p.appendChild(e);return e;}
        var box=document.getElementById('qs');
        Q.forEach(function(q,i){
          var d=add(box,'div',null,'q'),p=add(d,'p');
          add(p,'span',(i+1)+'. ','n');p.appendChild(document.createTextNode((q.kind==='tf'?'True or false: ':'')+q.prompt));
          function radio(text,val){var l=add(d,'label'),r=add(l,'input');r.type='radio';r.name='q'+i;r.value=val;l.appendChild(document.createTextNode(' '+text));}
          if(q.kind==='mcq')q.choices.forEach(function(c,j){radio(c,j);});
          else if(q.kind==='tf'){radio('True','true');radio('False','false');}
          else{var a=add(d,q.kind==='short'?'textarea':'input');if(q.kind!=='short')a.type='text';a.id='a'+i;}
          add(d,'p',null).id='m'+i;
          add(d,'div','Answer: '+q.answer+(q.why?' — '+q.why:'')+(q.source?' ['+q.source+']':''),'why');
        });
        renderMathInElement(document.body,{delimiters:[{left:'$$',right:'$$',display:true},{left:'\\[',right:'\\]',display:true},
          {left:'$',right:'$',display:false},{left:'\\(',right:'\\)',display:false}],throwOnError:false});
        document.getElementById('check').onclick=function(){
          var right=0,marked=0;
          Q.forEach(function(q,i){
            var ok=null,c=document.querySelector('input[name=q'+i+']:checked');
            if(q.kind==='mcq')ok=!!c&&Number(c.value)===q.index;
            else if(q.kind==='tf')ok=!!c&&(c.value==='true')===q.bool;
            else if(q.kind==='fill')ok=fillOK(document.getElementById('a'+i).value,q.answer);
            var m=document.getElementById('m'+i);
            if(ok===null){m.textContent='Compare yours with the answer below.';m.className='';}
            else{marked++;if(ok)right++;m.textContent=ok?'✓ Right':'✗ Not quite';m.className=ok?'right':'wrong';}
          });
          document.body.classList.add('done');
          document.getElementById('score').textContent=right+' of '+marked+' right'+(Q.length>marked?', and '+(Q.length-marked)+' to compare yourself':'');
        };
        </script></body></html>
        """#
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
        let groups = StudyMaterial.groups(passages, maxChars: LectureNotes.readChars(for: mode))
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
        case check = "Check my work", teach = "Explain it back", quiz = "Quiz me"
        var id: String { rawValue }
        static let help: [Mode] = [.hint, .step, .full, .explain]
        static let practice: [Mode] = [.check, .teach, .quiz]
        var directive: String {
            switch self {
            case .hint: return "Give ONE hint that gets the student unstuck — the idea or the first move — without working the problem or giving the answer."
            case .step: return "Show only the next step of the solution from where the student is (the first step if they haven't started), with its working. Then stop, and ask them to try the step after it."
            case .full: return "Solve it completely, step by step: name the principle that applies, show each step with its working, and state the final answer plainly."
            case .explain: return "Explain the concept: the intuition first, then the precise statement, then a short example."
            case .check: return "The student shows their own work on a problem — typed, or in the image. Solve it yourself first, without showing that. Then go through their steps in order and stop at the FIRST step that is wrong: quote it, say what is wrong and why, and show that one step done correctly. Don't go on to the answer — they finish it. If every step is right, say so and confirm the answer."
            case .teach: return "The student explains a concept in their own words, to find out what they really understand. Judge it against the material and what is true: first, in a line, what they got right; then each thing missing, vague or wrong, most important first, with a one-line correction; then a score out of 10. End with one question that probes the biggest gap. Don't rewrite the explanation for them."
            case .quiz: return "Quiz the student, one question at a time, on what is OPEN if something is, otherwise on the COURSE MATERIAL. If their message answers your last question, mark it first — **Right** or **Not quite**, then the correct answer and one sentence of why — and then ask the next question. Otherwise just ask the first. Mix recall, understanding and application, never repeat a question, and don't give the answer away in it. Ask only the question: no preamble."
            }
        }
    }

    static func system(_ mode: Mode, course: String?, weak: [String] = []) -> String {
        let lean = weak.isEmpty ? "" : "\n\nFrom their quizzes, the student is weakest on \(weak.joined(separator: ", ")). " + (mode == .quiz
            ? "Ask about these more often." : "Where a question touches them, take extra care with those parts.")
        return """
        You are a tutor for a student\(course.map { " in \($0)" } ?? ""). Use the COURSE MATERIAL when it \
        is relevant, citing it in [brackets]; otherwise answer from what you know. When the student \
        attaches an image, the problem is in it (course pages sent as pictures are material, and \
        say so). When something is OPEN beside you, it is \
        what the student is looking at: "this", "this step" and "here" mean it.

        \(mode.directive)\(lean)\(AIConfig.answerStyle)

        Write math as LaTeX in $…$ (display math in $$…$$). Use Markdown.\(mode == .full ? "\n\n" + MathCheck.instruction : mode == .check ? "\n\n" + MathCheck.studentInstruction : "")

        \(NoteFormat.listRules)
        """
    }

    struct Turn: Identifiable, Hashable {
        let id = UUID()
        var question: String
        var mode: Mode
        var images: [Data] = []
        /// PDF pages sent along as pictures ("Serway, p. 745"), so the student sees what went.
        var pages: [String] = []
        var answer = ""
        var checks: [MathCheck.Result] = []
    }

    /// What a window has open, as the chat sees it: its course, a title, and its text (up to
    /// `limit`) — the note, the pages around where the book is open, the assignment's brief.
    @MainActor
    static func open(_ f: StudyFocus?, in data: AppData, limit: Int) -> (course: UUID?, title: String, text: String)? {
        switch f {
        case .note(let id)?:
            guard let n = data.notes.first(where: { $0.id == id }) else { return nil }
            return (n.courseID, n.title.isEmpty ? "Untitled note" : n.title, String(n.body.prefix(limit)))
        case .reading(let id, let page)?:
            guard let r = data.reading.first(where: { $0.id == id }) else { return nil }
            let chunks = BookText.chunks(id)
            let near = page.map { p in chunks.filter { abs($0.page - p) <= 1 } } ?? Array(chunks.prefix(3))
            let text = near.map { "[p. \($0.page)]\n\($0.text)" }.joined(separator: "\n\n")
            return (r.courseID, r.title + (page.map { ", around p. \($0)" } ?? ""), String(text.prefix(limit)))
        case .assignment(let id)?:
            guard let a = data.assignments.first(where: { $0.id == id }) else { return nil }
            var text = "Assignment: \(a.title)"
            if let due = a.due { text += "\nDue: \(due.formatted(date: .abbreviated, time: .shortened))" }
            if !a.notes.isEmpty { text += "\n\n\(a.notes)" }
            if !a.checklist.isEmpty { text += "\n\nSteps:\n" + a.checklist.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") }
            if !a.link.isEmpty { text += "\n\nLink: \(a.link)" }
            return (a.courseID, a.title, String(text.prefix(limit)))
        case .course(let id)?:
            guard let c = data.courses.first(where: { $0.id == id }) else { return nil }
            return (id, c.code.isEmpty ? c.name : c.code, "")
        case nil:
            return nil
        }
    }

    /// The passages a question goes with: as many of the best matches as the engine can take —
    /// a quarter of what a quiz reads on a hosted engine (~30k characters), the five that always
    /// fit on a local one. Quiz me takes what the last question was about, to mark the answer
    /// by, then a random stretch of the material for the next — so the questions roam the
    /// course, not one page — unless something is open beside the chat, which it quizzes on.
    static func material(for query: String, mode: Mode, lastAnswer: String, in pool: [StudyPassage],
                         hasOpen: Bool, engine: AIMode) -> [StudyPassage] {
        let chars = max(7_500, LectureNotes.readChars(for: engine) / 4)
        guard mode == .quiz else { return query.isEmpty ? [] : StudyIndex.fitting(query, in: pool, chars: chars) }
        let graded = query.isEmpty ? [] : StudyIndex.fitting(lastAnswer + " " + query, in: pool, chars: chars / 3)
        let next = hasOpen ? [] : StudyMaterial.groups(pool, maxChars: chars * 2 / 3).randomElement() ?? []
        return graded + next.filter { !graded.contains($0) }
    }

    /// The last few turns for context; the course material and the images go on the new one only.
    static func messages(thread: [Turn], question: String, material: String, images: [Data], imageText: String,
                         mode: Mode = .explain, open: (title: String, text: String)? = nil, pages: [String] = []) -> [AIMessage] {
        var msgs: [AIMessage] = []
        for t in thread.suffix(4) where !t.answer.isEmpty {
            msgs.append(AIMessage(role: .user, text: t.question))
            msgs.append(AIMessage(role: .assistant, text: t.answer))
        }
        var text = material.isEmpty ? "" : "COURSE MATERIAL:\n\"\"\"\n\(material)\n\"\"\"\n\n"
        if let open, !open.text.isEmpty { text += "OPEN — \(open.title):\n\"\"\"\n\(open.text)\n\"\"\"\n\n" }
        if !imageText.isEmpty { text += "TEXT READ FROM THE ATTACHED IMAGE:\n\"\"\"\n\(imageText)\n\"\"\"\n\n" }
        // Page pictures go after the student's own images; they are material, not the problem.
        if !pages.isEmpty {
            text += "COURSE PAGES AS PICTURES: the last \(pages.count) image\(pages.count == 1 ? " is" : "s are") [\(pages.joined(separator: "], ["))], " +
                "as printed. Use them for the figures, graphs and equations the text above can't show.\n\n"
        }
        let empty = mode == .quiz ? "Ask me a question." : mode == .check ? "Check my work in the image." : "Help me with the problem in the image."
        text += "QUESTION: \(question.isEmpty ? empty : question)"
        // Repeated here for the same reason as LectureNotes.user: in the system prompt alone,
        // qwen2.5:7b wrote a "### CHECK" heading over "7.18e6 = 7.18e6" — nothing to verify.
        if mode == .full { text += "\n\n" + MathCheck.reminder }
        if mode == .check { text += "\n\n" + MathCheck.studentReminder }
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

    /// Checking the student's work: their arithmetic is recomputed too, so a slip the model
    /// reads past is still caught.
    static let studentInstruction = """
    After your reply, for each numeric step in the STUDENT's work add a line `CHECK: <the \
    arithmetic the student did> = <the value the student wrote>`, using only numbers, + - * / ^, \
    parentheses, sqrt, sin, cos, tan, ln, log and pi — no variables, no units. Software recomputes \
    these lines, so copy the student's own numbers, not corrected ones.
    """

    static let studentReminder = """
    End with one line per numeric step of the student's work, in exactly this form, with their \
    arithmetic and the value they wrote: CHECK: 2e-6 / (4 * pi * 8.85e-12 * 0.05^2) = 7.19e6
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
        check("fill matching", Quiz.fillMatches("Surface.", "surface") && Quiz.fillMatches("7.2e6", "7200000") && Quiz.fillMatches("ε0", "ε₀")
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

        // The tutor's practice modes: the student's own arithmetic goes to the calculator, and
        // Quiz me starts from an empty message.
        let checkMsg = Tutor.messages(thread: [], question: "", material: "", images: [Data([0xFF])], imageText: "", mode: .check).last?.text ?? ""
        check("Check my work asks for the student's CHECK lines", checkMsg.contains(MathCheck.studentReminder)
              && Tutor.system(.check, course: nil).contains(MathCheck.studentInstruction) && !Tutor.system(.teach, course: nil).contains("CHECK"))
        check("Quiz me asks for a question", Tutor.messages(thread: [], question: "", material: "", images: [], imageText: "", mode: .quiz)
              .last?.text.hasSuffix("QUESTION: Ask me a question.") == true)

        // A course's file arriving in Downloads.
        let lecture = Course(name: "Physics 2", code: "PHY2049"), lab = Course(name: "Physics 2 lab", code: "PHY2049L")
        check("downloads: a code in the name, spaced or not; the longest code wins",
              DownloadWatch.course(for: "phy 2049 - lecture 7.pdf", in: [lecture, lab])?.id == lecture.id
              && DownloadWatch.course(for: "PHY2049L_lab1.pdf", in: [lecture, lab])?.id == lab.id
              && DownloadWatch.course(for: "syllabus.pdf", in: [lecture, lab]) == nil
              && DownloadWatch.course(for: "x.pdf", in: [Course(name: "X", code: "")]) == nil)
        if let state = AppState.current, let scratch = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] {
            let dl = URL(fileURLWithPath: scratch).appendingPathComponent("Downloads-\(UUID().uuidString.prefix(6))")
            try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
            try? Data("old".utf8).write(to: dl.appendingPathComponent("PHY2049 old.pdf"))
            let (folder, offer) = (DownloadWatch.folder, DownloadWatch.offer)
            var offered: [String] = []
            DownloadWatch.folder = dl
            DownloadWatch.offer = { url, c in offered.append("\(url.lastPathComponent) → \(c.code)") }
            state.data.courses += [lecture, lab]
            DownloadWatch.start()
            for name in ["PHY2049L Lab 1.pdf.crdownload", "notes.pdf", "PHY2049 photo.png"] {
                try? Data("x".utf8).write(to: dl.appendingPathComponent(name))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            try? FileManager.default.moveItem(at: dl.appendingPathComponent("PHY2049L Lab 1.pdf.crdownload"),
                                              to: dl.appendingPathComponent("PHY2049L Lab 1.pdf"))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            check("downloads: only a finished, new course document is offered, to its course",
                  offered == ["PHY2049L Lab 1.pdf → PHY2049L"], "\(offered)")
            DownloadWatch.stop()
            (DownloadWatch.folder, DownloadWatch.offer) = (folder, offer)
            state.data.courses.removeAll { $0.id == lecture.id || $0.id == lab.id }
            try? FileManager.default.removeItem(at: dl)
        }

        // Reading a book's PDF in StudyBar: a selection becomes a highlight on its page, and a
        // highlight is drawn where its text is.
        if let scratch = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] {
            let pdf = URL(fileURLWithPath: scratch).appendingPathComponent("book-\(UUID().uuidString.prefix(6)).pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            if let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) {
                for t in ["Chapter 24. Electric flux through a surface.", "Gauss's law relates the net flux to the enclosed charge.", "Conductors in equilibrium."] {
                    ctx.beginPDFPage(nil)
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                    NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 16)]).draw(in: CGRect(x: 72, y: 600, width: 468, height: 100))
                    NSGraphicsContext.restoreGraphicsState(); ctx.endPDFPage()
                }
                ctx.closePDF()
            }
            let reader = ReaderModel(), view = PDFView()
            view.document = PDFDocument(url: pdf); reader.view = view
            if let doc = view.document, let found = doc.findString("net flux to the enclosed charge", withOptions: []).first {
                view.setCurrentSelection(found, animate: false)
                let h = reader.takeSelection()
                check("reader: a selection becomes a highlight on its page", h?.page == 2 && h?.text == "net flux to the enclosed charge" && view.currentSelection == nil)
                if let h { reader.draw(h) }
                reader.draw(Highlight(page: 3, text: "not on this page"))
                let drawn = (0..<doc.pageCount).map { doc.page(at: $0)?.annotations.filter { $0.type == "Highlight" }.count ?? 0 }
                check("reader: drawn where its text is, and nowhere for text that isn't", drawn == [0, 1, 0], "\(drawn)")
            } else { check("reader: test book", false) }
            try? FileManager.default.removeItem(at: pdf)
        }

        // The glossary: from :: lines, bold definitions and term-like flashcards; first wins.
        let gNotes = [Note(title: "Week 3", body: "Flux :: the field through a surface\n- **Gauss's law** — net flux equals $Q/\\varepsilon_0$\n**Flux**: a later, different definition\nWhat is **this**? not a definition"),
                      Note(title: "Week 4", body: "## Potential\n- **Electric potential** — energy per unit charge")]
        let g = Glossary.build(notes: gNotes, cards: [(front: "Capacitance", back: "Q/V", deck: "PHY2049"),
                                                      (front: "What is a conductor?", back: "…", deck: "PHY2049"),
                                                      (front: "{{c1::Gauss}} said flux", back: "", deck: "PHY2049")])
        check("glossary: three sources, one entry per term, the first definition, A to Z",
              g.map(\.term) == ["Capacitance", "Electric potential", "Flux", "Gauss's law"]
              && g.first { $0.term == "Flux" }?.definition == "the field through a surface"
              && g.first { $0.term == "Gauss's law" }?.source == "Week 3", "\(g.map(\.term))")

        // A quiz shared as a web page.
        let shareQs = [QuizQuestion(kind: .mcq, prompt: "The field inside a conductor in equilibrium is", choices: ["zero", "$\\sigma/\\varepsilon_0$", "infinite"],
                                    answerIndex: 0, explanation: "Free charges move until it cancels.", topic: "Conductors", source: "Notes"),
                       QuizQuestion(kind: .tf, prompt: "Outside charges change the net flux. </script><b>x</b>", answerBool: false),
                       QuizQuestion(kind: .fill, prompt: "Flux through a closed surface is Q / ___", answerText: "ε₀"),
                       QuizQuestion(kind: .fill, prompt: "k = ___ × 10^9", answerText: "8.99"),
                       QuizQuestion(kind: .short, prompt: "Why does Gauss's law need symmetry to find $E$?", answerText: "So E is constant on the surface.")]
        let page = QuizShare.html(shareQs, title: "Quiz — PHY2049")
        check("shared quiz: every question in it, none can close its script", page.contains("Free charges move until it cancels.")
              && page.contains("<\\/script>") && page.components(separatedBy: "</script>").count == page.components(separatedBy: "<script>").count
              && page.contains("renderMathInElement"))
        if let dir = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"], ProcessInfo.processInfo.environment["SB_KEEP"] == "1" {
            try? page.write(toFile: dir + "/shared-quiz.html", atomically: true, encoding: .utf8)
        }

        // Flashcards written in a note.
        let parsed = NoteCards.parse("""
        - Flux :: the field through a surface
        1. Gauss's law :: $\\oint \\vec E \\cdot d\\vec A = Q/\\varepsilon_0$
        std::vector<int> v;
        {{c1::cloze}} stays text
        flux :: a second line for the same term is ignored
        Empty back ::
        """)
        check("note cards: terms, list markers dropped, code and cloze left alone",
              parsed.map(\.front) == ["Flux", "Gauss's law"] && parsed.first?.back == "the field through a surface")
        if let state = AppState.current {
            let course = Course(name: "Selftest physics", code: "ST101")
            var note = Note(title: "Cards", body: "Flux :: the field through a surface\nCharge :: what makes a field", courseID: course.id)
            state.data.courses.append(course); state.data.notes.append(note)
            NoteCards.sync(note, state: state)
            var cards = state.data.flashcards.filter { $0.noteID == note.id }
            let deck = state.data.decks.first { $0.name == "ST101" }
            check("note cards: made in the course's deck", cards.count == 2 && cards.allSatisfy { $0.deckID == deck?.id })
            let flux = cards.first { $0.front == "Flux" }
            if let i = state.data.flashcards.firstIndex(where: { $0.id == flux?.id }) { state.data.flashcards[i].reps = 4 }
            note.body = "Flux :: field lines through a surface"
            NoteCards.sync(note, state: state)
            cards = state.data.flashcards.filter { $0.noteID == note.id }
            check("note cards: an edited definition updates the card and keeps its schedule, a deleted line deletes it",
                  cards.count == 1 && cards.first?.id == flux?.id && cards.first?.reps == 4 && cards.first?.back == "field lines through a surface")
            state.data.flashcards.removeAll { $0.noteID == note.id }
            state.data.decks.removeAll { $0.id == deck?.id }
            state.data.notes.removeAll { $0.id == note.id }; state.data.courses.removeAll { $0.id == course.id }
        }

        // Study guide merge.
        let merged = StudyGuide.merge(["## Definitions\n- **Flux** — field through a surface [A]\n## Formulas\n- $E=kq/r^2$ [A]",
                                       "## Definitions\n- **Flux** — field through a surface [A]\n- **Gaussian surface** — imaginary [B]"],
                                      title: "Study guide")
        check("one Definitions section", merged.components(separatedBy: "## Definitions").count == 2)
        check("duplicates dropped", merged.components(separatedBy: "**Flux**").count == 2 && merged.contains("Gaussian surface"))
        let inline = StudyGuide.merge(["## Key concepts — bullets: **Flux** — field through a surface.\n- **Gauss** — flux is charge over ε₀."], title: "G")
        check("a point on the heading line is kept", inline.contains("- **Flux** — field through a surface.") && inline.contains("**Gauss**"), inline)
        check("sections in order", (merged.range(of: "## Definitions")?.lowerBound ?? merged.endIndex) < (merged.range(of: "## Formulas")?.lowerBound ?? merged.startIndex))

        // A job's state lives past its pane: the same course gets the same session back.
        if let state = AppState.current {
            let c = UUID()
            check("a course's study session is kept", state.studySession(c) === state.studySession(c)
                  && state.studySession(c) !== state.studySession(UUID()))
        }
        let job = Jobs.shared.begin("Quiz · TEST", module: "study")
        Jobs.shared.update(job, "part 1 of 2")
        let listed = Jobs.shared.running.first { $0.id == job }?.detail == "part 1 of 2"
        Jobs.shared.end(job, done: nil)
        check("a job is listed while it runs, and not after", listed && !Jobs.shared.running.contains { $0.id == job })

        // Topic scores: one topic however the model capitalized it, weakest first, recent answers only.
        do {
            let c = UUID(), day = Date(timeIntervalSince1970: 1_000_000)
            func r(_ topic: String, _ ok: Bool, _ n: Double, course: UUID? = nil) -> TopicResult {
                TopicResult(courseID: course ?? c, topic: topic, correct: ok, at: day.addingTimeInterval(n))
            }
            var rs = [r("Gauss's law", false, 1), r("gauss's Law", false, 2), r("Gauss's law ", true, 3),
                      r("Conductors", true, 4), r("Conductors", true, 5), r("Flux", false, 6, course: UUID())]
            var scores = TopicScores.of(course: c, in: rs)
            check("topics merge across spelling, weakest first",
                  scores.map(\.topic) == ["Gauss's law", "Conductors"] && scores.first?.right == 1 && scores.first?.total == 3,
                  "\(scores)")
            let weak = TopicScores.weak(course: c, in: rs)
            check("weak topics: three answers or more, under 70%", weak == ["Gauss's law (1 of 3 right)"], "\(weak)")
            check("weak topics reach the tutor and a quiz, not when there are none",
                  Tutor.system(.explain, course: nil, weak: weak).contains("weakest on Gauss's law (1 of 3 right)")
                  && Quiz.system(count: 5, exam: false, weak: weak).contains("about a third")
                  && !Tutor.system(.explain, course: nil).contains("weakest"))
            rs = (0..<25).map { r("Flux", $0 >= 5, Double($0)) }
            scores = TopicScores.of(course: c, in: rs)
            check("old mistakes age out of a topic", scores.first?.right == 20 && scores.first?.total == 20, "\(scores)")
            let q = QuizQuestion(kind: .tf, prompt: "p", answerBool: true, explanation: "", topic: "Flux", source: "")
            let skipped = QuizQuestion(kind: .mcq, prompt: "p", choices: ["a", "b"], answerIndex: 0, explanation: "", topic: "Flux", source: "")
            let marked = TopicScores.results([q, skipped], [q.id: QuizResponse(bool: true)], course: c)
            check("a finished quiz records its marked answers", marked.count == 1 && marked[0].correct)
            let a = r("A", true, 1), b = r("B", false, 2)
            let merged = mergeOptLists(base: nil, mine: [a], theirs: [b]) ?? []
            check("results from two devices both survive", Set(merged.map(\.id)) == [a.id, b.id])
        }

        // Exam plan: spaced back from the exam, around classes, never on or after exam day.
        do {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 20, minute: 0))!   // a Thursday, 8 pm
            var exam = Assignment(title: "PHY2049 Midterm")
            exam.due = cal.date(byAdding: .day, value: 9, to: now)
            var lab = ClassSession(); lab.days = [2, 3, 4, 5, 6]; lab.startMinutes = 16 * 60; lab.endMinutes = 18 * 60   // weekdays 4–6 pm
            let blocks = ExamPlan.blocks(for: exam, classes: [lab], existing: [], now: now, cal: cal)
            let before = blocks.map { cal.dateComponents([.day], from: cal.startOfDay(for: $0.day), to: cal.startOfDay(for: exam.due!)).day! }
            check("sessions spaced back from the exam", before == [7, 5, 3, 2, 1], "\(before)")
            check("a practice exam two days out", blocks.first { $0.title.hasPrefix("Practice exam") }.map { before[blocks.firstIndex(of: $0)!] } == 2)
            let clash = blocks.contains { b in
                lab.meets(on: cal.component(.weekday, from: b.day)) && b.startMinutes < lab.endMinutes && lab.startMinutes < b.endMinutes
            }
            check("no session during a class", !clash, "\(blocks.map { ($0.day, $0.startMinutes) })")
            check("an exam that's already past plans nothing",
                  ExamPlan.blocks(for: { var e = exam; e.due = now.addingTimeInterval(-86_400); return e }(), classes: [], existing: [], now: now, cal: cal).isEmpty)
            check("exams are recognized by their title", ExamPlan.looksLikeExam("Final Exam") && ExamPlan.looksLikeExam("Quiz 3")
                  && !ExamPlan.looksLikeExam("Problem Set 5"))
        }

        // Reading sized to the engine: a hosted one takes a whole course, a local one what it always did.
        do {
            let ps = (1...30).map { StudyPassage(title: "Notes", locator: "p. \($0)", text: "Flux through surface number \($0). " + String(repeating: "Gauss law detail. ", count: 50)) }
            let fit = StudyIndex.fitting("flux surface Gauss", in: ps, chars: 5_000)
            let used = fit.reduce(0) { $0 + $1.text.count }
            check("the tutor's passages fit its budget", !fit.isEmpty && used <= 5_000 && fit.count > 1, "(\(fit.count) passages, \(used) chars)")
            check("a hosted engine reads a whole course at once", LectureNotes.readChars(for: .claude) >= 100_000)
            check("a local engine reads what it always did", LectureNotes.readChars(for: .ollama) == 6_000)
        }

        // Pages as pictures: one per page, in order, capped; passages without a PDF page give none.
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-pages-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            var box = CGRect(x: 0, y: 0, width: 300, height: 400)
            if let ctx = CGContext(url as CFURL, mediaBox: &box, nil) {
                for g in [0.9, 0.6, 0.3] { ctx.beginPDFPage(nil); ctx.setFillColor(gray: g, alpha: 1); ctx.fill(box.insetBy(dx: 40, dy: 40)); ctx.endPDFPage() }
                ctx.closePDF()
            }
            func p(_ loc: String, _ pdf: URL? = url) -> StudyPassage { StudyPassage(title: "Deck", locator: loc, text: "x", pdf: pdf) }
            let got = StudyMaterial.pageImages([p("p. 2"), p("p. 2"), p("", nil), p("p. 1"), p("p. 3")], max: 2)
            check("page pictures: one per page, best first, capped", got.cited == ["Deck, p. 2", "Deck, p. 1"] && got.images.count == 2, "\(got.cited)")
            check("a note passage has no page picture", StudyMaterial.pageImages([p("", nil), p("p. 9")], max: 3).images.isEmpty)
            let msg = Tutor.messages(thread: [], question: "What does the graph show?", material: "", images: got.images, imageText: "", pages: got.cited).last
            check("page pictures are named as course material", msg?.images.count == 2 && (msg?.text.contains("[Deck, p. 2], [Deck, p. 1]") ?? false))
        }

        // Syllabus coverage: objectives from the model's JSON, then counted locally.
        do {
            let objs = Coverage.parse(#"Here: {"objectives":[{"text":"Apply Gauss's law","keys":["Gauss's law","flux","x"]},{"text":"Grading","keys":[]},{"text":"Capacitance","keys":["capacitor","capacitance"]}]}"#) ?? []
            check("objectives parse; an empty one is dropped, short keys too", objs.count == 2 && objs[0].keys == ["gauss's law", "flux"], "\(objs.map(\.keys))")
            let course = UUID(), deck = UUID()
            let notes = [Note(title: "Week 3", body: "Gauss’s law and the Gaussian surface", courseID: course)]
            let cards = [Flashcard(deckID: deck, front: "Electric flux?", back: "E·A cos θ")]
            let results = [TopicResult(courseID: course, topic: "Gauss's law", correct: true), TopicResult(courseID: course, topic: "Gauss's Law", correct: false)]
            let rows = Coverage.rows(objs, notes: notes, cards: cards, results: results)
            check("coverage counts notes (curly apostrophe), cards and quiz answers",
                  rows.count == 2 && rows[0].notes == 1 && rows[0].cards == 1 && rows[0].right == 1 && rows[0].answered == 2 && rows[0].gaps == 0,
                  "\(rows.map { ($0.notes, $0.cards, $0.right, $0.answered) })")
            check("an objective with nothing on it is three gaps", rows[1].gaps == 3)
        }

        // The eval's scorer: a final answer in its usual spellings, and a quiz's checkable faults.
        do {
            let spellings = ["Q = 1.8 \\times 10^{-5}\\,\\text{C}", "$Q = 18\\,\\mu\\text{C}$", "each holds 18 μC", "about 1.8e-5 C"]
            check("eval reads an answer however it's written", spellings.allSatisfy { AppEval.answers(1.8e-5, in: $0, tolerance: 0.02) })
            check("eval: thousands, prefixes, rounding", AppEval.answers(134_850, in: "V = 134,850 V", tolerance: 0.02) && AppEval.answers(134_850, in: "≈ 1.35e5 V", tolerance: 0.02)
                  && AppEval.answers(0.003384, in: "U = 3.38 mJ", tolerance: 0.02) && AppEval.answers(1.18e-10, in: "C ≈ 118 pF", tolerance: 0.02))
            check("eval: a wrong answer is wrong", !AppEval.answers(1.8e-5, in: "Q = 27 μC at 0.20 m", tolerance: 0.02))
            let good = QuizQuestion(kind: .mcq, prompt: "Unit of capacitance?", choices: ["farad", "henry", "ohm", "tesla"], answerIndex: 0, explanation: "C/V", topic: "Capacitance")
            var bad = good; bad.answerIndex = 7
            let s = AppEval.quizScore([good, bad, good], count: 4)
            check("eval scores a quiz by what code can check", abs(s.score - 0.25) < 0.001 && s.problems.count == 3, "\(s)")
        }

        // Answer settings: nothing by default; each choice becomes one plain instruction.
        if let d = UserDefaults(suiteName: "studybar-selftest-answers") {
            defer { d.removePersistentDomain(forName: "studybar-selftest-answers") }
            check("no answer settings → no extra prompt", AIConfig.answerStyle(d).isEmpty)
            d.set("short", forKey: "aiAnswerLength"); d.set("graduate", forKey: "aiAnswerLevel"); d.set("Vietnamese", forKey: "aiAnswerLanguage")
            let s = AIConfig.answerStyle(d)
            check("answer settings reach the prompt", s.contains("short") && s.contains("graduate level") && s.contains("Write in Vietnamese"), s)
        }

        print(fail == 0 ? "STUDY SELFTEST: ALL PASS" : "STUDY SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}

// MARK: - Headless runs (StudyBar --study-run quiz|guide|tutor|cards|extract <file> [question] [--engine x])

/// The real jobs on a real engine, printed — to read what the prompts produce.
enum StudyRun {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard let i = args.firstIndex(of: "--study-run"), i + 2 < args.count else { return 1 }
        let kind = args[i + 1], url = URL(fileURLWithPath: args[i + 2])
        let mode = args.firstIndex(of: "--engine").flatMap { $0 + 1 < args.count ? AIMode(rawValue: args[$0 + 1]) : nil } ?? .ollama
        let units = StudyMaterial.extract(url)
        let pdf = url.pathExtension.lowercased() == "pdf" ? url : nil
        let passages = units.flatMap { u in
            LectureNotes.chunks(u.text, maxChars: 1_500).map { StudyPassage(title: url.lastPathComponent, locator: u.locator, text: $0, pdf: pdf) }
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
        case "cards":
            let text = units.map(\.text).joined(separator: "\n\n")
            let raw = (try? await provider.completePlain(system: StudyPack.cardSystem, messages: [
                AIMessage(role: .user, text: String(text.prefix(LectureNotes.chunkChars(for: mode))))])) ?? ""
            let cards = NoteQA.parseCards(raw)
            print("--- \(took()) · \(cards.count) cards ---")
            for c in cards { print("Q: \(c.front)\nA: \(c.back)\n") }
            if cards.isEmpty { print(raw) }
            return cards.isEmpty ? 1 : 0
        case "live":
            // The running summary as a recording would get it: the text in stretches of ~1,500 characters.
            let text = units.map(\.text).joined(separator: " ")
            var earlier: [String] = []
            for (n, stretch) in LectureNotes.chunks(text, maxChars: 1_500).prefix(4).enumerated() {
                let points = await LiveSummary.points(stretch, earlier: Array(earlier.suffix(6)), provider: provider)
                print("--- stretch \(n + 1) ---\n" + points.map { "- " + $0 }.joined(separator: "\n"))
                earlier += points
            }
            print("--- \(took()) ---")
            return earlier.isEmpty ? 1 : 0
        case "audio":
            let out = URL(fileURLWithPath: args.firstIndex(of: "--out").map { args[$0 + 1] } ?? NSTemporaryDirectory() + "review.m4a")
            do {
                let script = try await AudioReview.make(from: [Note(title: url.deletingPathExtension().lastPathComponent,
                                                                    body: units.map(\.text).joined(separator: "\n\n"))],
                                                        to: out, provider: provider, mode: mode) { _ in }
                let seconds = (try? AVAudioFile(forReading: out)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
                print("--- \(took()) · \(script.split(separator: " ").count) words · \(Int(seconds)) s of audio at \(out.path) ---\n\(script)")
                return 0
            } catch { print("FAILED: \(error.localizedDescription)"); return 1 }
        case _ where kind.hasPrefix("essay:"):
            // `essay:outline|thesis|counterArguments|draft <text> [--refs library.bib]`
            guard let action = NoteAI(rawValue: String(kind.dropFirst(6))), action.isEssay else { print("no such essay action"); return 1 }
            let refs = args.firstIndex(of: "--refs").flatMap { try? String(contentsOfFile: args[$0 + 1], encoding: .utf8) }.map(CitationFormatter.parse) ?? []
            let out = try? await provider.streamPlain(system: action.system(), messages: [
                AIMessage(role: .user, text: action.user(units.map(\.text).joined(separator: "\n\n"), sources: refs))], temperature: action.temperature) { _ in }
            print("--- \(took()) · \(action.label) ---\n\(out ?? "FAILED")")
            return out == nil ? 1 : 0
        case "objectives":
            let objs = await Coverage.extract(units.map(\.text).joined(separator: "\n\n"), provider: provider)
            print("--- \(took()) · \(objs?.count ?? 0) objectives ---")
            for o in objs ?? [] { print("- \(o.text)  [\(o.keys.joined(separator: ", "))]") }
            return objs == nil ? 1 : 0
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
            // `--thread <file.json>` carries a conversation between runs, one turn per run —
            // how Quiz me is tried: ask, read the question, answer it in the next run.
            let q = i + 3 < args.count && !args[i + 3].hasPrefix("--") ? args[i + 3] : ""
            let tutorMode = Tutor.Mode(rawValue: args.firstIndex(of: "--mode").map { args[$0 + 1] } ?? "") ?? .full
            let threadURL = args.firstIndex(of: "--thread").map { URL(fileURLWithPath: args[$0 + 1]) }
            let saved = threadURL.flatMap { try? JSONDecoder().decode([[String]].self, from: Data(contentsOf: $0)) } ?? []
            let thread = saved.map { Tutor.Turn(question: $0[0], mode: Tutor.Mode(rawValue: $0[2]) ?? tutorMode, answer: $0[1]) }
            let found = Tutor.material(for: q, mode: tutorMode, lastAnswer: thread.last?.answer ?? "", in: passages, hasOpen: false, engine: mode)
            let pages = AIConfig.canSee(mode) ? StudyMaterial.pageImages(found, max: 3) : (images: [], cited: [])
            print("retrieved: \(found.map(\.cite))  ·  pages as pictures: \(pages.cited)")
            let weak = args.firstIndex(of: "--weak").map { [args[$0 + 1]] } ?? []
            let out = try? await provider.streamPlain(system: Tutor.system(tutorMode, course: nil, weak: weak),
                                                      messages: Tutor.messages(thread: thread, question: q, material: StudyMaterial.block(found),
                                                                               images: pages.images, imageText: "", mode: tutorMode, pages: pages.cited),
                                                      temperature: 0.3, onReply: { _ in })
            let (text, checks) = MathCheck.run(out ?? "")
            print("--- \(took()) ---\n\(text)\n--- checks ---")
            for c in checks { print("\(c.ok.map { $0 ? "OK  " : "BAD " } ?? "??  ") \(c.expression) = \(c.claimed)  (calc: \(c.actual.map { MathEval.format($0) } ?? "–"))") }
            if let threadURL, out != nil { try? JSONEncoder().encode(saved + [[q, text, tutorMode.rawValue]]).write(to: threadURL) }
            return out == nil ? 1 : 0
        default:
            return 1
        }
    }
}

// MARK: - Study pack

/// After a lecture, one step from its notes to studying them: flashcards in the course's deck
/// and a quiz from the note waiting in Study. The notes' own review already carries the
/// summary, likely exam questions and questions to ask. Runs as a job, so leaving is fine.
@MainActor
enum StudyPack {
    static let cardSystem = """
    You turn a student's lecture notes into study flashcards. Write 8–15 cards covering the key \
    terms, definitions, formulas, facts and methods: each "front" is a question that tests one \
    idea, each "back" its concise answer, drawn ONLY from the notes. Keep each side under 200 \
    characters, and write any mathematics as LaTeX between single dollar signs. This is \
    transforming the student's own material — never refuse. Reply with ONLY a JSON array:
    [{"front":"…","back":"…"}]
    """

    static func make(from note: Note, state: AppState) {
        guard let provider = AIService.makeProvider(for: .ask) else { return }
        let engine = AIConfig.engine(for: .ask)
        let title = note.title.isEmpty ? "Untitled note" : note.title
        let deckName = state.course(note.courseID).map { $0.code.isEmpty ? $0.name : $0.code } ?? title
        let quiz = state.studySession(note.courseID).quiz
        let passages = StudyMaterial.passages(.note(note.id), in: state.data)
        let job = Jobs.shared.begin("Study pack · \(title)", module: "study")
        Task {
            Jobs.shared.update(job, "flashcards")
            let raw = (try? await provider.completePlain(system: cardSystem, messages: [
                AIMessage(role: .user, text: String(note.body.prefix(LectureNotes.chunkChars(for: engine))))])) ?? ""
            let cards = NoteQA.parseCards(raw)
            if !cards.isEmpty {
                let deck = state.data.decks.first { $0.name.caseInsensitiveCompare(deckName) == .orderedSame }
                    ?? Deck(name: deckName, courseID: note.courseID)
                if !state.data.decks.contains(where: { $0.id == deck.id }) { state.data.decks.append(deck) }
                let known = Set(state.data.flashcards.filter { $0.deckID == deck.id }.map(\.front))
                state.data.flashcards += cards.filter { !known.contains($0.front) }
                    .map { Flashcard(deckID: deck.id, front: $0.front, back: $0.back) }
            }

            // A quiz in progress in that course's Study is the student's — don't replace it.
            var questions = 0
            if quiz.phase == .setup || quiz.phase == .done, !passages.isEmpty {
                Jobs.shared.update(job, "quiz")
                quiz.phase = .generating; quiz.progress = (0, 0); quiz.error = nil
                let qs = await Quiz.generate(from: passages, count: 10, exam: false, provider: provider, mode: engine) { p, t in
                    quiz.progress = (p, t)
                }
                if quiz.phase == .generating {
                    if let qs, !qs.isEmpty {
                        quiz.questions = qs; quiz.responses = [:]; quiz.revealed = []; quiz.index = 0
                        quiz.addedTo = nil; quiz.feedback = [:]; quiz.deadline = nil
                        quiz.phase = .taking
                        questions = qs.count
                        UserDefaults.standard.set(note.courseID?.uuidString ?? "", forKey: "studyCourse")
                        UserDefaults.standard.set(StudyModuleView.Tab.quiz.rawValue, forKey: "studyTab")
                    } else {
                        quiz.phase = .setup
                    }
                }
            }
            let made = [cards.isEmpty ? nil : "\(cards.count) flashcards in \(deckName)",
                        questions == 0 ? nil : "a \(questions)-question quiz in Study"].compactMap { $0 }
            Jobs.shared.end(job, done: made.isEmpty ? "Couldn't make the study pack" : "Study pack ready: " + made.joined(separator: " and "))
        }
    }
}

// MARK: - Topic scores

/// One marked answer from a Study quiz or exam: the raw record topic scores are made from.
struct TopicResult: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseID: UUID?
    var topic: String
    var correct: Bool
    var at: Date = .now
}

enum TopicScores {
    struct Score: Identifiable, Equatable {
        let topic: String, right: Int, total: Int
        var id: String { topic.lowercased() }
        var ratio: Double { Double(right) / Double(max(1, total)) }
    }

    /// Answers kept per topic: recent work counts, and a topic you've since learned recovers.
    static let window = 20

    /// A course's topics, weakest first. Topic names come from the model, so "Gauss's law" and
    /// "gauss's Law" are one topic, shown as first written.
    static func of(course: UUID?, in results: [TopicResult]) -> [Score] {
        let mine = results.filter { $0.courseID == course && !$0.topic.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.at < $1.at }
        let groups = Dictionary(grouping: mine) { $0.topic.trimmingCharacters(in: .whitespaces).lowercased() }
        return groups.values.map { rs in
            let recent = rs.suffix(window)
            return Score(topic: rs[0].topic.trimmingCharacters(in: .whitespaces), right: recent.filter(\.correct).count, total: recent.count)
        }
        .sorted { ($0.ratio, -$0.total, $0.topic) < ($1.ratio, -$1.total, $1.topic) }
    }

    /// What the AI should know about the student: up to three topics with at least three marked
    /// answers and under 70% of them right, weakest first — what the tutor and new quizzes lean on.
    static func weak(course: UUID?, in results: [TopicResult]) -> [String] {
        of(course: course, in: results).filter { $0.total >= 3 && $0.ratio < 0.7 }.prefix(3)
            .map { "\($0.topic) (\($0.right) of \($0.total) right)" }
    }

    /// The marked answers of a finished quiz, for the record. Short answers not yet marked are left out.
    static func results(_ questions: [QuizQuestion], _ responses: [UUID: QuizResponse], course: UUID?) -> [TopicResult] {
        questions.compactMap { q in
            Quiz.isCorrect(q, responses[q.id] ?? QuizResponse())
                .map { TopicResult(courseID: course, topic: q.topic.isEmpty ? "Other" : q.topic, correct: $0) }
        }
    }
}

// MARK: - Syllabus coverage

/// What the syllabus says you'll learn, against what you have on it: notes, flashcards, quiz
/// answers. The AI reads the syllabus once, for its objectives and the phrases that mark each;
/// the counting after that is local, so the map keeps up as notes are written.
enum Coverage {
    static let system = """
    From this course syllabus, list what the course expects students to learn: its stated learning \
    objectives or outcomes — or, where it states none, the topics of its weekly schedule. Give 6 to 20 \
    items in the syllabus's order, each a short phrase. For each, give 2 to 5 search phrases that notes \
    on it would contain: the key terms, named laws or methods, common synonyms ("gauss's law", \
    "electric flux", "gaussian surface"). Lowercase. Never a generic word such as "analysis", \
    "understanding" or "concepts". Skip grading, policies and logistics.
    Reply with ONLY JSON: {"objectives":[{"text":"…","keys":["…","…"]}]}
    """

    static func extract(_ syllabus: String, provider: AIProvider) async -> [SyllabusObjective]? {
        guard syllabus.count > 40,
              let raw = try? await provider.completePlain(system: system, messages: [AIMessage(role: .user, text: "SYLLABUS:\n" + syllabus.prefix(40_000))])
        else { return nil }
        return parse(raw)
    }

    static func parse(_ raw: String) -> [SyllabusObjective]? {
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [String: Any],
              let list = obj["objectives"] as? [[String: Any]] else { return nil }
        let out = list.compactMap { o -> SyllabusObjective? in
            let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let keys = (o["keys"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.count >= 3 }
            return text.isEmpty || keys.isEmpty ? nil : SyllabusObjective(text: text, keys: keys)
        }
        return out.isEmpty ? nil : out
    }

    /// Curly apostrophes are how a pasted note writes "Gauss’s law".
    static func mentions(_ text: String, _ keys: [String]) -> Bool {
        let t = text.replacingOccurrences(of: "’", with: "'")
        return keys.contains { t.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    struct Row: Identifiable {
        let objective: SyllabusObjective
        let notes: Int, cards: Int, right: Int, answered: Int
        var id: UUID { objective.id }
        var gaps: Int { (notes == 0 ? 1 : 0) + (cards == 0 ? 1 : 0) + (answered == 0 ? 1 : 0) }
    }

    static func rows(_ objectives: [SyllabusObjective], notes: [Note], cards: [Flashcard], results: [TopicResult]) -> [Row] {
        objectives.map { o in
            let quiz = results.filter { mentions($0.topic, o.keys) }
            return Row(objective: o,
                       notes: notes.filter { mentions($0.title + "\n" + $0.body, o.keys) }.count,
                       cards: cards.filter { mentions($0.front + "\n" + $0.back, o.keys) }.count,
                       right: quiz.filter(\.correct).count, answered: quiz.count)
        }
    }
}

// MARK: - Exam plan

/// "Midterm in 9 days" as sessions on the day planner: reviews spaced back from the exam, a
/// practice exam two days out and a light review the day before, each in the first free
/// slot around classes and blocks already there. Arithmetic, not AI.
enum ExamPlan {
    struct Session { let daysBefore: Int; let kind: String; let minutes: Int }
    static let schedule: [Session] = [
        .init(daysBefore: 14, kind: "Review", minutes: 60), .init(daysBefore: 10, kind: "Quiz", minutes: 45),
        .init(daysBefore: 7, kind: "Review", minutes: 60), .init(daysBefore: 5, kind: "Quiz", minutes: 45),
        .init(daysBefore: 3, kind: "Review", minutes: 60), .init(daysBefore: 2, kind: "Practice exam", minutes: 90),
        .init(daysBefore: 1, kind: "Last review", minutes: 45),
    ]

    static func looksLikeExam(_ title: String) -> Bool {
        title.range(of: #"\b(exam|midterm|final|test|quiz)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The sessions still ahead of the exam, from `now`: today only while a slot is left in it.
    static func blocks(for exam: Assignment, classes: [ClassSession], existing: [TimeBlock],
                       now: Date = .now, cal: Calendar = .current) -> [TimeBlock] {
        guard let due = exam.due else { return [] }
        let examDay = cal.startOfDay(for: due), today = cal.startOfDay(for: now)
        let clock = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        var taken = existing, out: [TimeBlock] = []
        for s in schedule {
            guard let day = cal.date(byAdding: .day, value: -s.daysBefore, to: examDay), day >= today,
                  let start = freeSlot(on: day, minutes: s.minutes, after: day == today ? clock + 15 : 0,
                                       classes: classes, blocks: taken, cal: cal) else { continue }
            var b = TimeBlock(title: "\(s.kind) · \(exam.title)", day: day, startMinutes: start, endMinutes: start + s.minutes)
            b.courseID = exam.courseID
            b.assignmentID = exam.id
            b.notes = hint(s.kind)
            out.append(b)
            taken.append(b)
        }
        return out
    }

    static func hint(_ kind: String) -> String {
        switch kind {
        case "Quiz": return "Study ▸ Quiz, or Progress ▸ Quiz me on the weakest."
        case "Practice exam": return "Study ▸ Practice exam, timed, then go over what you missed."
        case "Last review": return "The study guide and the flashcards you keep missing — then sleep."
        default: return "Go over the notes and slides; Study ▸ Study guide has the key points."
        }
    }

    /// Evenings first (16:00–22:00), then the day (08:00–16:00), on the quarter hour.
    static func freeSlot(on day: Date, minutes: Int, after earliest: Int, classes: [ClassSession],
                         blocks: [TimeBlock], cal: Calendar) -> Int? {
        let wd = cal.component(.weekday, from: day)
        let busy = classes.filter { $0.meets(on: wd) }.map { ($0.startMinutes, $0.endMinutes) }
            + blocks.filter { cal.isDate($0.day, inSameDayAs: day) }.map { ($0.startMinutes, $0.endMinutes) }
        for (from, to) in [(16 * 60, 22 * 60), (8 * 60, 16 * 60)] {
            var t = max(from, (earliest + 14) / 15 * 15)
            while t + minutes <= to {
                if !busy.contains(where: { t < $0.1 && $0.0 < t + minutes }) { return t }
                t += 15
            }
        }
        return nil
    }
}
