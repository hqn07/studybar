import Foundation

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

    static func system(_ job: Job, part: Int, of total: Int) -> String {
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
                    + "Do not write a summary or review section — the parts are joined afterwards."
            }
            let keep = job == .slides
                ? "Slides are terse: turn each slide's points into full explanations, under a `##` heading per slide or topic, in slide order. Keep every definition, fact, number, formula and example on them."
                : "Keep everything that was said. Organize it under `##` headings in lecture order, with **bold** key terms, bullet points, and a table when things are compared. Keep every definition, fact, number, date and example — the detail is the point, don't compress it away. Where the transcription clearly misheard a term, write the right one."
            return """
            You turn \(job == .slides ? "the text of a student's lecture slides" : "a student's lecture transcript") into complete study notes they can learn from.

            \(scope)

            1. \(keep)
            2. \(fillIn)\(job == .lecture ? "\n3. A sentence starting with ⭐ was starred by the student while listening: it matters. Give it a prominent place in **bold**, keep the ⭐, and make it a likely exam question in the review." : "")

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
    `### Key takeaways` (3–6 bullets), `### Likely exam questions` (3–5 questions about \
    what this lecture covered, each followed by a one-line answer), and `### Questions to ask` \
    (1–3 things the lecture left unclear or contradictory, worth asking the professor — leave \
    the heading out if there are none).
    """

    /// The user turn repeats the one instruction that matters. Small local models weight the
    /// last user message far above the system prompt: on qwen2.5:7b, with it only in the
    /// system prompt, a full lecture came back with no additions at all.
    static func user(_ job: Job, _ text: String, material: String = "") -> String {
        // The course's own pages, when there are any, so an addition comes from the textbook
        // the exam is set from rather than from general knowledge — and says which page.
        let course = material.isEmpty ? "" : "COURSE MATERIAL — the student's own textbook, slides and notes. "
            + "Prefer it when filling in, and end an addition that uses it with its source in brackets, "
            + "e.g. [Serway, p. 12]:\n\"\"\"\n\(material)\n\"\"\"\n\n"
        switch job {
        case .lecture:
            return course + "Write the study notes for this lecture transcript, keeping every detail, and fill in "
                + "what it leaves out on lines starting with `\(addedPrefix)`.\n\nTRANSCRIPT:\n\"\"\"\n\(text)\n\"\"\""
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

    static func run(_ text: String, job: Job, provider: AIProvider, mode: AIMode,
                    material: [StudyPassage] = [],
                    progress: @escaping @MainActor (_ notes: String, _ part: Int, _ total: Int) -> Void) async -> String? {
        let limit = chunkChars(for: mode)
        let budget = material.isEmpty ? 0 : materialChars(for: mode)
        let parts = chunks(text, maxChars: limit - budget)
        var done: [String] = []
        for (i, part) in parts.enumerated() {
            guard !Task.isCancelled else { return nil }
            let prior = done
            let out = try? await provider.streamPlain(
                system: system(job, part: i + 1, of: parts.count),
                messages: [AIMessage(role: .user, text: user(job, part, material: relevant(material, to: part, budget: budget)))],
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
        return notes
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
        guard budget > 0 else { return "" }
        var picked: [StudyPassage] = [], used = 0
        for p in StudyIndex.search(part, in: material, k: 8) where used + p.text.count <= budget {
            picked.append(p); used += p.text.count + p.cite.count + 4
        }
        return StudyMaterial.block(picked)
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

// MARK: - Self-test (StudyBar --lecture-selftest)

enum LectureNotesSelfTest {
    static func run() -> Int32 {
        var fail = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") { print("  \(ok ? "ok  " : "FAIL") \(n) \(d)"); if !ok { fail += 1 } }

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
        print(fail == 0 ? "LECTURE SELFTEST: ALL PASS" : "LECTURE SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
