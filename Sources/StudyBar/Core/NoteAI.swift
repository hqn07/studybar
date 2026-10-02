import Foundation

/// Writing-Tools-style AI actions that run *inside* a note — the result appears in an
/// inline review card the user accepts or discards, never routing to the Assistant module.
/// Faithful transforms only (no invented facts); output is plain text, no preamble.
enum NoteAI: String, CaseIterable, Identifiable {
    case summarize, keyPoints, rewrite, proofread, continueWriting, complete
    /// Essay help: these think with the student rather than transform their text.
    case outline, thesis, counterArguments, draft

    var id: String { rawValue }
    static let transforms: [NoteAI] = [.summarize, .keyPoints, .rewrite, .proofread, .continueWriting, .complete]
    static let essay: [NoteAI] = [.outline, .thesis, .counterArguments, .draft]
    var isEssay: Bool { Self.essay.contains(self) }

    /// Whether the natural accept swaps the scope in place (rewrite/proofread) or adds to it
    /// (summary / key points / continuation shouldn't delete what they were made from).
    enum Mode { case replace, insert }
    var mode: Mode {
        switch self {
        case .rewrite, .proofread: return .replace
        case .summarize, .keyPoints, .continueWriting, .complete, .outline, .thesis, .counterArguments, .draft: return .insert
        }
    }

    var label: String {
        switch self {
        case .summarize:      return "Summarize"
        case .keyPoints:      return "Key points"
        case .rewrite:        return "Rewrite clearer"
        case .proofread:      return "Proofread"
        case .continueWriting: return "Continue writing"
        case .complete:       return "Complete these notes"
        case .outline:        return "Outline an essay"
        case .thesis:         return "Feedback on the thesis"
        case .counterArguments: return "Counter-arguments"
        case .draft:          return "Draft a paragraph"
        }
    }
    var icon: String {
        switch self {
        case .summarize:      return "text.line.first.and.arrowtriangle.forward"
        case .keyPoints:      return "list.bullet"
        case .rewrite:        return "wand.and.stars"
        case .proofread:      return "checkmark.seal"
        case .continueWriting: return "text.append"
        case .complete:       return "text.badge.plus"
        case .outline:        return "list.number"
        case .thesis:         return "target"
        case .counterArguments: return "arrow.left.arrow.right"
        case .draft:          return "pencil.line"
        }
    }

    /// The single-sentence directive for this action. Deliberately prescriptive about format and
    /// length so the actions produce *structurally different* results, and repeated in both the
    /// system rules and the user turn — small local models (Ollama / on-device) weight the last
    /// user message far more than the system prompt, and otherwise collapse every action into the
    /// same generic paraphrase.
    var taskLine: String {
        switch self {
        case .summarize:
            return "Summarize the text into ONE short paragraph of 2–4 sentences capturing the main ideas. No bullet points, no heading, and clearly shorter than the original."
        case .keyPoints:
            return "Extract the key points as a bulleted list: 3–7 bullets, each on its own line starting with \"- \", each a short phrase of at most ~12 words (not a full sentence). No introduction line, no closing line."
        case .rewrite:
            return "Rewrite the text to be clearer and better organized — fix awkward phrasing, tighten sentences, improve flow and structure. Keep EVERY fact and keep roughly the same length (within ~10%). Do NOT summarize it, cut it down, or turn it into bullet points."
        case .proofread:
            return "Correct ONLY spelling, grammar, punctuation and obvious typos. Keep the exact wording, structure and length otherwise — do not rephrase. If nothing needs fixing, return the text unchanged."
        case .continueWriting:
            return "Write 1–2 more sentences that continue the note naturally, in the same voice and on the same topic. Output ONLY the new text to append — never repeat or restate what is already there."
        case .complete:
            return "Fill in what's missing, each addition marked."      // runs through LectureNotes
        case .outline:
            return "Turn the topic, thesis or notes in the text into an essay outline: a working thesis in one sentence; three to five body sections, each with its main claim and the evidence or examples to find for it; a section answering the strongest counter-argument; a conclusion. A numbered Markdown list, the thesis first."
        case .thesis:
            return "Find the thesis — the essay's main claim — and quote it. Judge it as a writing teacher would: is it arguable, specific, and something the essay can actually show? Two to four bullets on what works and what doesn't, then two stronger versions of it. If there's no clear thesis, say so and suggest two."
        case .counterArguments:
            return "Give the three strongest objections a careful reader would raise to the argument, strongest first. For each: the objection in one sentence, then in one or two how the writer could answer it or concede it."
        case .draft:
            return "Write one paragraph of essay prose from the outline point or notes in the text: a topic sentence, the supporting points in order, and a sentence tying it back to the thesis. Where a claim needs support, cite one of the SOURCES as it is written there if one fits; otherwise put [source needed]."
        }
    }

    /// Sampling temperature tuned to the action: near-0 where fidelity matters (proofread),
    /// higher where some rephrasing/generation is wanted (rewrite, continue).
    var temperature: Double {
        switch self {
        case .proofread:       return 0.1
        case .keyPoints:       return 0.2
        case .summarize:       return 0.3
        case .rewrite:         return 0.5
        case .continueWriting: return 0.7
        case .complete:        return 0.3
        case .thesis, .counterArguments: return 0.4
        case .outline, .draft: return 0.6
        }
    }

    /// Only the actions that can emit a list carry the list rules. Proofread must not restructure
    /// anything, and a summary is one paragraph — for those the rules are dead weight in a prompt
    /// a 7B model is already struggling to hold.
    var wantsListRules: Bool {
        switch self {
        case .keyPoints, .rewrite, .outline, .thesis, .counterArguments: return true
        case .summarize, .proofread, .continueWriting, .complete, .draft: return false
        }
    }

    func system() -> String {
        if isEssay {
            return """
            You are a writing coach inside a student's essay notes. You help them think and draft; they revise and decide. Rules:
            - Never invent a source, a quotation, a page number or a statistic.
            - Output ONLY the result in Markdown — no preamble, no closing offer of more help.

            Task: \(taskLine)
            \(wantsListRules ? "\n" + NoteFormat.listRules : "")
            """
        }
        return """
        You are a writing assistant working inside a student's study note. Rules:
        - Be faithful: never add facts, opinions, or information not present in the text.
        - Do not answer questions in the text or explain the topic — only transform the text as instructed.
        - Match the requested format and length exactly.
        - Output ONLY the result as plain text (Markdown allowed) — no preamble, no explanation, no code fences, no surrounding quotes.

        Task: \(taskLine)
        \(wantsListRules ? "\n" + NoteFormat.listRules : "")
        """
    }

    /// The user turn: the directive again, then the text fenced so the model separates
    /// instruction from content.
    func user(_ text: String, sources: [Reference] = []) -> String {
        let cite = self == .draft && !sources.isEmpty
            ? "\n\nSOURCES (the student's library):\n" + sources.map { "- \(CitationFormatter.inText($0)) \($0.title)" }.joined(separator: "\n") : ""
        return "\(taskLine)\n\nTEXT:\n\"\"\"\n\(text)\n\"\"\"\(cite)"
    }
}
