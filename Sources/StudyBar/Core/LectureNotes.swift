import AppKit

/// Lecture transcripts and typed notes, turned into notes a student can study from: everything
/// that was said, organized, plus what the lecture left out — each addition on its own line
/// behind `addedPrefix`, so what was said and what the AI added never blur together.
///
/// The organize prompt used to forbid adding anything ("be faithful — do NOT add information"),
/// which is why a lecture came back as a tidier transcript rather than notes to learn from. It
/// also sent the whole transcript in one request, and a 75-minute lecture (~15k tokens) doesn't
/// fit an 8k local context: the model silently read part of it. Long input is now split at
/// sentence boundaries into parts sized to the engine, and the parts are joined back up.
enum LectureNotes {
    /// `slides`: the text of a slide deck, which is a lecture's outline without the lecture.
    enum Job { case lecture, slides, complete }

    static let addedPrefix = "> 💡 **Added:** "

    /// Characters of input per request. The context has to hold the prompt, this, and the
    /// notes written from it — which are longer than the input once additions are in.
    static func chunkChars(for mode: AIMode) -> Int {
        switch mode {
        case .onDevice: return 5_000        // ~4k-token context
        case .ollama:   return 9_000        // num_ctx 8192
        default:        return 40_000       // hosted: bounded by the 16k-token answer, not the context
        }
    }

    /// Characters of course material one request reads when the answer is short — questions, a
    /// guide's sections. A hosted engine holds a whole course (120k characters is ~30k tokens,
    /// inside DeepSeek's context as well as GPT's and Claude's); a local one, what fits beside the
    /// prompt. At the old two thirds of `chunkChars` a 10-question quiz on a 94k-character
    /// course was written from about a quarter of it.
    static func readChars(for mode: AIMode) -> Int {
        switch mode {
        case .onDevice, .ollama, .off: return chunkChars(for: mode) * 2 / 3
        case .claude, .openai: return 120_000
        }
    }

    /// A deck, written out for the prompt: each slide under its number, the whole at most
    /// `maxChars` — a lecture's 40 slides are about 12,000 characters.
    static func outline(_ slides: [(number: Int, text: String)], maxChars: Int = 12_000) -> String {
        var out = ""
        for s in slides {
            let piece = "[Slide \(s.number)]\n\(s.text.prefix(600))\n\n"
            guard out.count + piece.count <= maxChars else { break }
            out += piece
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The slide a heading names — "Slide 7 — Gauss's law" → 7 — for the deck beside the note.
    static func slideNumber(inHeading h: String) -> Int? {
        h.firstMatch(of: /^\s*#*\s*[Ss]lides?\s+(\d+)/).flatMap { Int($0.output.1) }
    }

    /// How the student wants their notes: how much of the lecture, in what shape, how much the AI
    /// fills in, and what to stress. The defaults are the notes this always wrote.
    struct Style: Equatable {
        enum Detail: String, CaseIterable, Identifiable { case brief = "Brief", standard = "Standard", full = "Full"; var id: String { rawValue } }
        enum Shape: String, CaseIterable, Identifiable { case notes = "Notes", outline = "Outline", cornell = "Cornell", qa = "Q&A"; var id: String { rawValue } }
        enum FillIn: String, CaseIterable, Identifiable { case none = "None", light = "Light", thorough = "Thorough"; var id: String { rawValue } }
        var detail = Detail.full
        var shape = Shape.notes
        var fillIn = FillIn.thorough
        var focus = ""

        /// The student's last choices (Voice, a note's Study notes, Convert all share them).
        static var saved: Style {
            let d = UserDefaults.standard
            return Style(detail: Detail(rawValue: d.string(forKey: "notesDetail") ?? "") ?? .full,
                         shape: Shape(rawValue: d.string(forKey: "notesShape") ?? "") ?? .notes,
                         fillIn: FillIn(rawValue: d.string(forKey: "notesFillIn") ?? "") ?? .thorough)
        }

        /// What the notes keep of the lecture, in what form.
        func keep(slidesGiven: Bool) -> String {
            let order = slidesGiven ? "under a `## Slide N — <short title>` heading per slide, in slide order" : "under `##` headings in lecture order"
            let amount: String
            switch detail {
            case .full: amount = "Keep everything that was said. Keep every definition, fact, number, date and example — the detail is the point, don't compress it away."
            case .standard: amount = "Keep every definition, formula, number and example, and say the rest once and plainly: one bullet per idea, no repetition, no filler."
            case .brief: amount = "Condense it to what to learn: the main ideas, every definition and formula, and one example per topic — about a page."
            }
            let form: String
            switch shape {
            case .notes: form = "Organize it \(order), with **bold** key terms, bullet points, and a table when things are compared."
            case .outline: form = "Write it as a numbered outline \(order): topics, their points, and sub-points, each one line, **bold** key terms."
            case .cornell: form = "Use the Cornell layout \(order): each section opens with a `**Cues:**` line of 2–4 questions it answers, then its notes as bullets, and ends with a one-line `**Summary:**`."
            case .qa: form = "Write it as questions and answers \(order): each point a `**Q:**` line followed by its answer, so the notes quiz the reader."
            }
            return amount + " " + form
        }

        /// The instruction on adding what the lecture left out.
        func fillIn(_ thorough: String) -> String {
            switch fillIn {
            case .thorough: return thorough
            case .light: return "Fill in only what a student can't follow without: a term used with no definition, a step that is skipped. Put each addition on its own line starting with `\(LectureNotes.addedPrefix)` — a few in all, not one per section."
            case .none: return "Add nothing that wasn't said — no definitions, examples or background of your own."
            }
        }

        var stress: String {
            let f = focus.trimmingCharacters(in: .whitespacesAndNewlines)
            return f.isEmpty ? "" : "\n\nThe student asked the notes to stress: \(f). Give that the most room and care; keep the rest shorter."
        }
    }

    static func system(_ job: Job, part: Int, of total: Int, slides: Bool = false, style: Style = Style()) -> String {
        let fillIn = """
        Fill in what a student needs to learn it: define terms that are used without a definition, \
        finish explanations that stop short, add a short worked example where a method is named but \
        not shown, and give background the material assumes. Put every addition on its own line \
        starting with `\(addedPrefix)` so it can never be mistaken for the original — aim for \
        at least one in every section. Add only what you are sure is correct. For example:

        \(addedPrefix)A Gaussian surface is imaginary: choose it so the field is constant, or \
        parallel to the surface, everywhere on it.
        """
        let format = """
        Write math as LaTeX in $…$. Output ONLY Markdown — no preamble, no code fences, no JSON.

        \(NoteFormat.listRules)
        """
        switch job {
        case .lecture, .slides:
            let scope: String
            if total == 1 {
                scope = "Start with a `#` title for the lecture. End with a `## Review` section: \(reviewSpec)"
            } else {
                scope = "This is part \(part) of \(total) of one lecture; write notes for this part only. "
                    + (part == 1 ? "Start with a `#` title for the lecture. " : "Do not write a `#` title. ")
                    + "Do not write a summary or review section — the parts are joined afterwards. "
                    + "If the lecturer announces homework, readings, a quiz, an exam or a deadline in this part, end it with a `### Announced` list, one per bullet as `What — when, as said`."
            }
            // The default style is word for word what these prompts always said; any other choice
            // swaps in its own instruction (`Style.keep`).
            let keep = style.detail == .full && style.shape == .notes ? (job == .slides
                ? "Slides are terse: turn each slide's points into full explanations, under a `##` heading per slide or topic, in slide order. Keep every definition, fact, number, formula and example on them."
                : slides
                ? "The lecture follows the SLIDES given with it. Organize the notes by slide, in order: a `## Slide N — <short title>` heading for each slide \(total > 1 ? "this part of the lecture talks about" : "the lecture talks about"), holding what was said about it together with what the slide shows. Keep everything that was said, with **bold** key terms and bullet points — every definition, fact, number, date and example. Where the transcription clearly misheard a term, the slide usually has it right."
                : "Keep everything that was said. Organize it under `##` headings in lecture order, with **bold** key terms, bullet points, and a table when things are compared. Keep every definition, fact, number, date and example — the detail is the point, don't compress it away. Where the transcription clearly misheard a term, write the right one.")
                : (job == .slides ? "Slides are terse: explain each slide's points. " : slides ? "The lecture follows the SLIDES given with it; where the transcription misheard a term, the slide usually has it right. " : "Where the transcription clearly misheard a term, write the right one. ")
                    + style.keep(slidesGiven: slides || job == .slides)
            return """
            You turn \(job == .slides ? "the text of a student's lecture slides" : "a student's lecture transcript") into complete study notes they can learn from.

            \(scope)

            1. \(keep)
            2. \(style.fillIn(fillIn))\(job == .lecture ? "\n3. A sentence starting with ⭐ was starred by the student while listening: it matters. Give it a prominent place in **bold**, keep the ⭐, and make it a likely exam question in the review.\n4. A line starting with 📝 is the student's own note, typed at that moment: keep it, word for word with its 📝, where it belongs." : "")\(style.stress)

            \(format)
            """
        case .complete:
            return """
            You complete a student's study notes so they can learn from them.

            Return the notes in full, with their wording, order and formatting unchanged. \(fillIn) \
            Place each addition directly after the line it belongs to. Don't add a summary.\
            \(total > 1 ? " This is part \(part) of \(total) of the notes; complete this part only." : "")

            \(format)
            """
        }
    }

    // "Ask the professor" was here too; a 7B model filled it with "if anything was unclear,
    // ask" on a lecture where nothing was.
    private static let reviewSpec = """
    `### Key takeaways` (3–6 bullets), `### Formulas` (every equation or formula the lecture \
    stated, one per bullet, with what its symbols mean — leave the heading out if there are none), \
    `### Likely exam questions` (3–5 questions about what this lecture covered, each followed by a \
    one-line answer), `### Questions to ask` (1–3 things the lecture left unclear or \
    contradictory, worth asking the professor — leave the heading out if there are none), and \
    `### Announced` (homework, readings, quizzes, exams and deadlines the lecturer announced, one \
    per bullet as `What to do — when, as said`, e.g. `Problem set 4 — due next Friday` or \
    `Read sections 26.3–26.4 — before Monday` — leave the heading out if nothing was announced).
    """

    /// The user turn repeats the one instruction that matters. Small local models weight the
    /// last user message far above the system prompt: on qwen2.5:7b, with it only in the
    /// system prompt, a full lecture came back with no additions at all.
    static func user(_ job: Job, _ text: String, material: String = "", slides: String = "", style: Style = Style()) -> String {
        // The course's own pages, when there are any, so an addition comes from the textbook
        // the exam is set from rather than from general knowledge — and says which page.
        let course = material.isEmpty ? "" : "COURSE MATERIAL — the student's own textbook, slides and notes. "
            + "Prefer it when filling in, and end an addition that uses it with its source in brackets, "
            + "e.g. [Serway, p. 12]:\n\"\"\"\n\(material)\n\"\"\"\n\n"
        switch job {
        case .lecture:
            // The default ask is word for word what it always was; other styles say their own.
            let ask = style == Style()
                ? "Write the study notes for this lecture transcript, keeping every detail\(slides.isEmpty ? "" : ", under a `## Slide N — …` heading per slide"), and fill in what it leaves out on lines starting with `\(addedPrefix)`."
                : "Write \(style.detail == .brief ? "brief" : style.detail == .standard ? "concise" : "full") study notes for this lecture transcript\(style.shape == .notes ? "" : " as \(style.shape == .qa ? "questions and answers" : style.shape == .cornell ? "Cornell notes" : "an outline")")"
                    + (style.fillIn == .none ? ", adding nothing that wasn't said." : ", filling in \(style.fillIn == .light ? "only what can't be followed without" : "what it leaves out") on lines starting with `\(addedPrefix)`.")
                    + (style.focus.isEmpty ? "" : " Stress: \(style.focus).")
            return course + (slides.isEmpty ? "" : "SLIDES — the deck this lecture was given from:\n\"\"\"\n\(slides)\n\"\"\"\n\n")
                + ask + "\n\nTRANSCRIPT:\n\"\"\"\n\(text)\n\"\"\""
        case .slides:
            return course + "Write the study notes these lecture slides outline, keeping every point on them, and fill in "
                + "what they leave out on lines starting with `\(addedPrefix)`.\n\nSLIDES:\n\"\"\"\n\(text)\n\"\"\""
        case .complete:
            return course + "Return these notes in full, unchanged, with lines starting with `\(addedPrefix)` "
                + "filling in what they leave out.\n\nNOTES:\n\"\"\"\n\(text)\n\"\"\""
        }
    }

    /// Paragraph-sized pieces no longer than `maxChars`, cut at line ends, then sentence ends,
    /// then spaces. A live transcript is one long line, so the sentence cut is the usual one.
    static func chunks(_ text: String, maxChars: Int) -> [String] {
        var out: [String] = [], cur = ""
        func flush() { if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }; cur = "" }
        func add(_ piece: String, sep: String) {
            if !cur.isEmpty, cur.count + sep.count + piece.count > maxChars { flush() }
            cur += (cur.isEmpty ? "" : sep) + piece
        }
        for line in text.components(separatedBy: "\n") {
            if line.count <= maxChars { add(line, sep: "\n"); continue }
            var sentences: [String] = []
            (line as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (line as NSString).length),
                                                   options: .bySentences) { s, _, _, _ in
                if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
            }
            for sentence in sentences {
                if sentence.count <= maxChars { add(sentence, sep: " "); continue }
                for word in sentence.split(separator: " ") { add(String(word), sep: " ") }
            }
        }
        flush()
        return out.isEmpty ? [text] : out
    }

    /// Parts joined into one note. A section that runs across a part boundary comes back with
    /// its heading twice, and a later part sometimes writes a title anyway — both are dropped.
    static func stitch(_ parts: [String]) -> String {
        var lines: [String] = []
        var lastH2: String?
        for (i, part) in parts.enumerated() {
            var first = true
            for line in part.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if i > 0, t.hasPrefix("# ") { continue }
                if t.hasPrefix("## ") {
                    let h = t.lowercased()
                    defer { lastH2 = h }
                    if first, i > 0, h == lastH2 { continue }
                }
                if !t.isEmpty { first = false }
                lines.append(line)
            }
            if i < parts.count - 1 { lines.append("") }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the job part by part. `progress` gets the notes so far, and which part is running.
    /// nil if any part fails — the caller still holds the original.
    /// A quarter of each request goes to course material when there is some; the part shrinks to make room.
    static func materialChars(for mode: AIMode) -> Int { chunkChars(for: mode) / 4 }

    /// `slides`: the deck the lecture was given from, which the notes are then organized by.
    static func run(_ text: String, job: Job, provider: AIProvider, mode: AIMode,
                    material: [StudyPassage] = [], slides: [(number: Int, text: String)] = [], style: Style = Style(),
                    progress: @escaping @MainActor (_ notes: String, _ part: Int, _ total: Int) -> Void) async -> String? {
        let limit = chunkChars(for: mode)
        let budget = material.isEmpty ? 0 : materialChars(for: mode)
        let deck = job == .lecture ? outline(slides, maxChars: limit / 4) : ""
        let parts = chunks(text, maxChars: limit - budget - deck.count)
        var done: [String] = []
        for (i, part) in parts.enumerated() {
            guard !Task.isCancelled else { return nil }
            let prior = done
            let out = try? await provider.streamPlain(
                system: system(job, part: i + 1, of: parts.count, slides: !deck.isEmpty, style: style),
                messages: [AIMessage(role: .user, text: user(job, part, material: relevant(material, to: part, budget: budget), slides: deck, style: style))],
                temperature: 0.3) { partial in
                    progress(stitch(prior + [partial]), i + 1, parts.count)
                }
            guard let out, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            done.append(NoteFormat.tidy(MathSupport.normalized(unfenced(out))))
        }
        var notes = stitch(done)

        // A lecture in parts gets its review from the joined notes — or, when those no longer
        // fit, from their headings and key terms.
        if job != .complete, parts.count > 1, !Task.isCancelled {
            let digest = notes.count <= limit ? notes : String(notes.components(separatedBy: "\n")
                .filter { $0.hasPrefix("#") || $0.contains("**") }.joined(separator: "\n").prefix(limit))
            let sys = "Write ONLY a `## Review` section for these lecture notes: \(reviewSpec) Output Markdown only, no preamble."
            if let review = try? await provider.streamPlain(system: sys, messages: [AIMessage(role: .user, text: digest)],
                                                           temperature: 0.3, onReply: { _ in }) {
                notes += "\n\n" + NoteFormat.tidy(MathSupport.normalized(review.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return text.contains("⭐") ? notes : unstarred(notes)
    }

    /// A ⭐ in the notes means the student starred that moment. With nothing starred, a model
    /// still put one on an exam question (gpt-5.6-luna, 2026-10-06) — so none is kept.
    static func unstarred(_ notes: String) -> String {
        notes.replacingOccurrences(of: #"⭐\s?"#, with: "", options: .regularExpression)
    }

    /// The user turn fences the text in `"""`, and a small model sometimes echoes the fence back.
    static func unfenced(_ s: String) -> String {
        var lines = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        while let f = lines.first?.trimmingCharacters(in: .whitespaces), f == "\"\"\"" || f.hasPrefix("```") { lines.removeFirst() }
        while let l = lines.last?.trimmingCharacters(in: .whitespaces), l == "\"\"\"" || l == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The passages that best match this part, as many as fit.
    static func relevant(_ material: [StudyPassage], to part: String, budget: Int) -> String {
        budget > 0 ? StudyMaterial.block(StudyIndex.fitting(part, in: material, chars: budget)) : ""
    }

    /// The additions in a completed note, each with the line it follows (nil at the very top).
    /// Completing a note only ever inserts these — the note itself is never rewritten, so
    /// nothing the model dropped or reworded can be lost, and styling and images stay put.
    static func additions(in completed: String) -> [(after: String?, text: String)] {
        var out: [(String?, String)] = []
        var anchor: String?
        for line in completed.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(addedPrefix.trimmingCharacters(in: .whitespaces)) { out.append((anchor, t)) }
            else if !t.isEmpty { anchor = t }
        }
        return out
    }

    /// Where a line of the model's copy sits in the original: the end of the first line that
    /// matches once list markers, heading marks and spacing are set aside. nil if none does.
    static func insertionPoint(after anchor: String, in original: String) -> Int? {
        func key(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: #"^(#{1,6}\s+|[-*•◦▪]\s+|☐\s+|☑\s+|\d+\.\s+|>\s+)"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            return String(t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
        }
        let want = key(anchor)
        guard !want.isEmpty else { return nil }
        let ns = original as NSString
        var hit: Int?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, r, _, stop in
            if let line, key(line) == want { hit = r.location + r.length; stop.pointee = true }
        }
        return hit
    }
}

// MARK: - A slide's cards

/// Notes made with the slides are written under `## Slide N` headings; a card made from such a
/// note belongs to the slide whose section its words match best — so a slide can list its cards.
enum SlideCards {
    /// Each slide's section of the note: from its heading to the next heading at its level or above.
    static func sections(_ body: String) -> [Int: String] {
        var out: [Int: String] = [:], current: Int?, level = 0
        for line in body.components(separatedBy: .newlines) {
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, let n = LectureNotes.slideNumber(inHeading: line) {
                current = n; level = hashes; out[n, default: ""] += line + "\n"; continue
            }
            if hashes > 0, hashes <= level { current = nil }
            if let c = current { out[c, default: ""] += line + "\n" }
        }
        return out
    }

    /// The note's cards, each under the slide its words match best.
    static func bySlide(_ note: Note, cards: [Flashcard]) -> [Int: [Flashcard]] {
        let secs = sections(note.body)
        guard !secs.isEmpty else { return [:] }
        let passages = secs.map { StudyPassage(title: "\($0.key)", locator: "", text: $0.value) }
        var out: [Int: [Flashcard]] = [:]
        for c in cards where c.origin?.noteID == note.id {
            if let n = StudyIndex.search(c.front + " " + c.back, in: passages, k: 1, meaning: false).first.flatMap({ Int($0.title) }) {
                out[n, default: []].append(c)
            }
        }
        return out
    }
}

// MARK: - Announced in a lecture

/// Homework, readings and deadlines the lecturer announced, read from the notes' `### Announced`
/// list (one per part of a long lecture, so every one counts), to offer as assignments. Dated
/// from the lecture's own day, so "due Friday" is the Friday after that lecture.
enum Announced {
    /// The bullets under every `Announced` heading, once each; "none" and the like aren't items.
    static func items(in body: String) -> [String] {
        var out: [String] = [], inside = false, seen = Set<String>()
        for line in body.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                inside = t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased().hasPrefix("announced")
                continue
            }
            guard inside, let r = t.range(of: #"^(?:[-*•]|\d+[.)])\s+"#, options: .regularExpression) else { continue }
            let item = String(t[r.upperBound...]).replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            let low = item.lowercased()
            guard item.count >= 4, !low.hasPrefix("none"), !low.hasPrefix("nothing"), !low.hasPrefix("no "),
                  seen.insert(key(item)).inserted else { continue }
            out.append(item)
        }
        return out
    }

    /// "Problem set 4 — due next Friday" → ("Problem set 4", "due next Friday").
    static func split(_ item: String) -> (what: String, when: String) {
        for sep in [" — ", " – ", " - ", ": "] {
            if let r = item.range(of: sep) {
                return (String(item[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                        String(item[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (item, item)
    }

    /// The ones not yet in Assignments for the note's course — what the note offers to add.
    static func pending(in note: Note, data: AppData) -> [String] {
        let have = Set(data.assignments.filter { $0.courseID == note.courseID }.map { key($0.title) })
        return items(in: note.body).filter { !have.contains(key(split($0).what)) }
    }

    /// Each pending item as an assignment: its title, the due date read the way quick-add reads
    /// one (from the lecture's day), the note's course, and where it was heard.
    static func assignments(in note: Note, data: AppData) -> [Assignment] {
        pending(in: note, data: data).map { item in
            let (what, when) = split(item)
            var a = Assignment(title: what, courseID: note.courseID,
                               due: QuickParse.parse(when, courses: data.courses, now: note.createdAt).due)
            a.notes = "Announced in “\(note.title.isEmpty ? "a lecture" : note.title)”: \(item)"
            return a
        }
    }

    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
}

// MARK: - Self-test (StudyBar --lecture-selftest)

/// The running notes Voice keeps while a lecture records (`VoiceService.soFar`).
enum LiveSummary {
    struct Stretch: Identifiable, Equatable {
        let id = UUID()
        let minutes: String
        let points: [String]
    }

    static func hosted(_ mode: AIMode) -> Bool { mode == .claude || mode == .openai }

    /// After four minutes with something said, or sooner if a lot was.
    static func due(fresh: Int, since: TimeInterval) -> Bool {
        fresh >= 600 && (since >= 240 || fresh >= 4_000)
    }

    static let system = """
    You keep running notes on a lecture while it is being recorded, for a student who glances at \
    them to catch up. From what was just said — a raw speech-to-text transcript, with its errors — \
    write 1 to 3 short bullets on its main points, covering the whole stretch in the order it was \
    said — what a student who looked away would need. Don't repeat the earlier points. Terse; math as LaTeX in $…$. Reply with only the bullets, or \
    with nothing if nothing of substance was said.
    """

    static func points(_ text: String, earlier: [String], provider: AIProvider) async -> [String] {
        let user = (earlier.isEmpty ? "" : "EARLIER POINTS:\n" + earlier.map { "- \($0)" }.joined(separator: "\n") + "\n\n")
            + "JUST SAID:\n\"\"\"\n\(text.suffix(12_000))\n\"\"\""
        guard let raw = try? await provider.completePlain(system: system, messages: [AIMessage(role: .user, text: user)]) else { return [] }
        return parse(raw)
    }

    /// The bullets, at most three; lines without a marker if the model wrote no bullets.
    static func parse(_ raw: String) -> [String] {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let marked = lines.filter { $0.range(of: #"^(?:[-*•]|\d+[.)])\s+"#, options: .regularExpression) != nil }
        return (marked.isEmpty ? lines : marked)
            .map { $0.replacingOccurrences(of: #"^(?:[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression) }
            .prefix(3).map { $0 }
    }
}

enum LectureNotesSelfTest {
    static func run() -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }

        // Slides: the headings the deck follows, the outline the prompt gets, and a PDF deck read
        // in by slide number.
        check("slide headings: numbered, any way they're written; not prose about slides",
              LectureNotes.slideNumber(inHeading: "## Slide 7 — Gauss's law") == 7 && LectureNotes.slideNumber(inHeading: "Slide 12: Capacitors") == 12
              && LectureNotes.slideNumber(inHeading: "### Slides 3–4") == 3 && LectureNotes.slideNumber(inHeading: "Slideshow notes") == nil
              && LectureNotes.slideNumber(inHeading: "Notes on slide 3") == nil)
        let deck = (1...60).map { (number: $0, text: "Slide \($0) text " + String(repeating: "x", count: 300)) }
        let o = LectureNotes.outline(deck)
        check("slide outline: numbered, and capped", o.hasPrefix("[Slide 1]") && o.count <= 12_000 && o.contains("[Slide 30]") && !o.contains("[Slide 60]"))
        check("notes from a lecture with slides are organized by slide",
              LectureNotes.system(.lecture, part: 1, of: 1, slides: true).contains("## Slide N")
              && LectureNotes.user(.lecture, "transcript", slides: "[Slide 1]\nFlux").contains("SLIDES — the deck")
              && !LectureNotes.system(.lecture, part: 1, of: 1).contains("## Slide N"))
        if let scratch = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"] {
            let pdf = URL(fileURLWithPath: scratch).appendingPathComponent("deck-\(UUID().uuidString.prefix(6)).pdf")
            var box = CGRect(x: 0, y: 0, width: 720, height: 405)
            if let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) {
                for (n, title) in ["Electric flux", "Gauss's law", "Conductors"].enumerated() {
                    ctx.beginPDFPage(nil)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                    NSAttributedString(string: "\(title)\nPoints on slide \(n + 1) of the deck", attributes: [.font: NSFont.systemFont(ofSize: 28)])
                        .draw(in: CGRect(x: 40, y: 200, width: 640, height: 160))
                    NSGraphicsContext.restoreGraphicsState()
                    ctx.endPDFPage()
                }
                ctx.closePDF()
            }
            if let file = StudyMaterial.attach(pdf, courseID: nil) {
                let slides = StudyMaterial.slideOutline(file)
                check("a PDF deck is read in slide by slide", slides.map(\.number) == [1, 2, 3] && slides[1].text.contains("Gauss"), "\(slides.map(\.number))")
                check("…into the throwaway store, not the student's", StudyMaterial.fileURL(file).path.hasPrefix(scratch))
                StudyMaterial.remove(file)
            } else { check("a PDF deck is read in", false) }
            try? FileManager.default.removeItem(at: pdf)
        }

        // The running summary while recording.
        check("live summary: due after four minutes, or sooner after a lot",
              !LiveSummary.due(fresh: 500, since: 600) && !LiveSummary.due(fresh: 2_000, since: 120)
              && LiveSummary.due(fresh: 2_000, since: 250) && LiveSummary.due(fresh: 5_000, since: 60))
        check("live summary: bullets read, at most three, unmarked lines when there are none",
              LiveSummary.parse("Here:\n- Flux is $\\Phi$\n* Gauss\n2. Symmetry\n- Fourth") == ["Flux is $\\Phi$", "Gauss", "Symmetry"]
              && LiveSummary.parse("Flux through a surface\n\nGauss's law") == ["Flux through a surface", "Gauss's law"]
              && LiveSummary.parse("").isEmpty)

        // A live transcript: one line, ~30k characters.
        let sentence = "The flux through a closed surface equals the enclosed charge over epsilon naught. "
        let transcript = String(repeating: sentence, count: 360)
        let parts = LectureNotes.chunks(transcript, maxChars: 9_000)
        check("a long one-line transcript is split", parts.count == 4, "(\(parts.count) parts)")
        check("every part fits", parts.allSatisfy { $0.count <= 9_000 })
        check("cut at sentence ends", parts.allSatisfy { $0.hasSuffix(".") })
        check("nothing lost", parts.joined(separator: " ").split(separator: " ").count == transcript.split(separator: " ").count)
        check("short text is one part", LectureNotes.chunks("A short memo.", maxChars: 9_000) == ["A short memo."])

        let stitched = LectureNotes.stitch(["# Gauss\n## Flux\n- a", "# Gauss again\n## Flux\n- b\n## Symmetry\n- c"])
        check("repeated heading across a boundary is dropped", stitched.components(separatedBy: "## Flux").count == 2, stitched)
        check("later titles are dropped", !stitched.contains("Gauss again"))
        check("content kept", stitched.contains("- a") && stitched.contains("- b") && stitched.contains("## Symmetry"))

        let sys = LectureNotes.system(.lecture, part: 1, of: 1)
        check("lecture prompt asks for additions", sys.contains(LectureNotes.addedPrefix) && !sys.contains("do NOT add"))
        check("single part writes the review", sys.contains("## Review"))
        check("middle part writes no title or review",
              !LectureNotes.system(.lecture, part: 2, of: 3).contains("Start with a `#` title")
              && LectureNotes.system(.lecture, part: 2, of: 3).contains("Do not write a summary"))

        let original = "## Week 3\n• Gauss's law relates flux to charge\n• Use symmetry"
        let completed = "## Week 3\n- Gauss's law relates flux to charge\n> 💡 **Added:** $\\Phi_E = Q/\\varepsilon_0$.\n- Use symmetry\n> 💡 **Added:** Pick a surface where E is constant."
        let adds = LectureNotes.additions(in: completed)
        check("two additions found", adds.count == 2)
        let p1 = adds.first.flatMap { $0.after }.flatMap { LectureNotes.insertionPoint(after: $0, in: original) }
        check("addition anchors past the editor's bullet", p1 == (original as NSString).range(of: "to charge").upperBound)
        check("unknown anchor → nil", LectureNotes.insertionPoint(after: "Nothing like this", in: original) == nil)

        check("echoed fences are stripped", LectureNotes.unfenced("\"\"\"\n# A\n- b\n\"\"\"") == "# A\n- b")
        // The student's choices: the default is the prompt as it always was; each choice says its own.
        do {
            let plain = LectureNotes.system(.lecture, part: 1, of: 1), user = LectureNotes.user(.lecture, "T")
            check("default style keeps the old notes", plain.contains("Keep everything that was said") && plain.contains("aim for \nat least one in every section".replacingOccurrences(of: "\n", with: ""))
                  && user.contains("keeping every detail, and fill in what it leaves out"))
            var brief = LectureNotes.Style(); brief.detail = .brief; brief.shape = .cornell; brief.fillIn = .none; brief.focus = "formulas"
            let b = LectureNotes.system(.lecture, part: 1, of: 1, style: brief), bu = LectureNotes.user(.lecture, "T", style: brief)
            check("brief, Cornell, nothing added, a focus", b.contains("Condense it") && b.contains("**Cues:**") && b.contains("Add nothing that wasn't said")
                  && b.contains("stress: formulas") && !b.contains("Keep everything that was said") && bu.contains("brief study notes") && bu.contains("Cornell")
                  && bu.contains("adding nothing") && bu.contains("Stress: formulas"))
            var light = LectureNotes.Style(); light.fillIn = .light; light.shape = .qa
            let l = LectureNotes.system(.lecture, part: 1, of: 1, slides: true, style: light)
            check("light fill-in, Q&A, by slide", l.contains("a few in all") && l.contains("**Q:**") && l.contains("## Slide N") && !l.contains("aim for at least one"))
        }

        check("no star in the transcript → none in the notes",
              LectureNotes.unstarred("- **⭐ What is the energy density?**\n⭐Starred line") == "- **What is the energy density?**\nStarred line")

        // A slide's cards: each card under the slide its words match.
        do {
            let note = Note(title: "Week 7", body: """
            # Capacitors
            ## Slide 1 — Capacitance
            - **Capacitance** C = Q/V, measured in farads
            ## Slide 2 — Energy
            - Stored energy U = ½CV²
            ### Example
            - A 2 µF capacitor at 10 V stores 100 µJ
            ## Review
            - takeaways
            """)
            let secs = SlideCards.sections(note.body)
            check("slide sections run to the next slide or a heading above them",
                  secs.keys.sorted() == [1, 2] && secs[2]?.contains("100 µJ") == true && secs[2]?.contains("takeaways") == false, "\(secs)")
            var a = Flashcard(deckID: UUID(), front: "Unit of capacitance?", back: "The farad"); a.source = CardSource(noteID: note.id)
            var b = Flashcard(deckID: UUID(), front: "Energy stored in a capacitor?", back: "U = ½CV²"); b.source = CardSource(noteID: note.id)
            let other = Flashcard(deckID: UUID(), front: "Energy stored?", back: "x")
            let map = SlideCards.bySlide(note, cards: [a, b, other])
            check("each card under its slide; another note's cards left out",
                  map[1]?.map(\.id) == [a.id] && map[2]?.map(\.id) == [b.id], "\(map.mapValues { $0.map(\.front) })")
        }

        // Fixing a misheard word: whole words, any case, capitals kept, formatting kept.
        do {
            let t = TermFix.replace("Ferrets store charge. Two ferrets in series; a ferretsville isn't one.", "ferrets", with: "farads")
            check("fix a word: every whole word, any case, a capital kept",
                  t.count == 2 && t.text == "Farads store charge. Two farads in series; a ferretsville isn't one.", t.text)
            check("fix a phrase", TermFix.replace("the I can value of A", "I can value", with: "eigenvalue").text == "the eigenvalue of A")
            let rich = NSMutableAttributedString(string: "Unit: ", attributes: [:])
            rich.append(NSAttributedString(string: "ferrets", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
            TermFix.replace(in: rich, "ferrets", with: "farads")
            check("rich text keeps its formatting", rich.string == "Unit: farads"
                  && (rich.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
            var note = Note(title: "Ferrets and capacitors", body: "ferrets ferrets")
            note.rich = NSAttributedString(string: "ferrets ferrets").rtfdData()
            let fixed = TermFix.fixed(note, "ferrets", with: "farads")
            check("a note: title, text and rich text together",
                  fixed?.count == 3 && fixed?.note.title == "Farads and capacitors" && fixed?.note.body == "farads farads"
                  && fixed?.note.rich.flatMap(NSAttributedString.fromRTFD)?.string == "farads farads")
            check("a note that never says it is left alone", TermFix.fixed(Note(title: "x", body: "y"), "ferrets", with: "farads") == nil)
            var data = AppData()
            let c = Course(name: "Physics 2", code: "PHY2049")
            data.courses = [c]
            TermFix.learn("farads", course: c.id, in: &data); TermFix.learn("Farads", course: c.id, in: &data)
            check("the course learns the word once, and recognition expects it",
                  data.courses[0].words == ["farads"] && CourseVocabulary.terms(course: data.courses[0], data: data).contains("farads"))
        }

        // Announced: read from every Announced list, dated from the lecture's day, offered once.
        do {
            let wed = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10))!   // a Wednesday
            var data = AppData()
            let course = Course(name: "Physics 2", code: "PHY2049")
            data.courses = [course]
            var note = Note(title: "Week 7 — Capacitors", body: """
            ## Capacitance
            - **C = Q/V**
            ### Announced
            - Problem set 4 — due Friday
            - **Read chapter 26** — before next lecture
            ## Dielectrics
            ### Announced
            - Problem set 4 — due Friday
            - Quiz 3: October 16
            ## Review
            ### Announced
            - None announced
            """, courseID: course.id)
            note.createdAt = wed
            check("announced items: every list, once each, not 'none'",
                  Announced.items(in: note.body) == ["Problem set 4 — due Friday", "Read chapter 26 — before next lecture", "Quiz 3: October 16"],
                  "\(Announced.items(in: note.body))")
            let made = Announced.assignments(in: note, data: data)
            let cal = Calendar.current
            check("titles split from when, course kept",
                  made.map(\.title) == ["Problem set 4", "Read chapter 26", "Quiz 3"] && made.allSatisfy { $0.courseID == course.id }, "\(made.map(\.title))")
            check("'due Friday' is the Friday after the lecture; a dateless one has no date",
                  made[0].due.map { cal.component(.day, from: $0) == 9 && cal.component(.month, from: $0) == 10 } == true && made[1].due == nil,
                  "\(String(describing: made[0].due)) \(String(describing: made[1].due))")
            check("a date as written", made[2].due.map { cal.component(.day, from: $0) == 16 } == true, "\(String(describing: made[2].due))")
            data.assignments = [Assignment(title: "problem set 4", courseID: course.id)]
            check("already in Assignments → not offered again", Announced.pending(in: note, data: data).count == 2)
            check("the notes prompt asks for Formulas and Announced",
                  LectureNotes.system(.lecture, part: 1, of: 1).contains("### Formulas") && LectureNotes.system(.lecture, part: 1, of: 1).contains("### Announced")
                  && LectureNotes.system(.lecture, part: 2, of: 3).contains("### Announced"))
        }

        print(fail == 0 ? "LECTURE SELFTEST: ALL PASS" : "LECTURE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
