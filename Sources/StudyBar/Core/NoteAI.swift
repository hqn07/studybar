import Foundation

/// Writing-Tools-style AI actions that run *inside* a note — the result appears in an
/// inline review card the user accepts or discards, never routing to the Assistant module.
/// Faithful transforms only (no invented facts); output is plain text, no preamble.
enum NoteAI: String, CaseIterable, Identifiable {
    case summarize, keyPoints, rewrite, proofread, continueWriting

    var id: String { rawValue }

    /// Whether the natural accept swaps the scope in place (rewrite/proofread) or adds to it
    /// (summary / key points / continuation shouldn't delete what they were made from).
    enum Mode { case replace, insert }
    var mode: Mode {
        switch self {
        case .rewrite, .proofread: return .replace
        case .summarize, .keyPoints, .continueWriting: return .insert
        }
    }

    var label: String {
        switch self {
        case .summarize:      return "Summarize"
        case .keyPoints:      return "Key points"
        case .rewrite:        return "Rewrite clearer"
        case .proofread:      return "Proofread"
        case .continueWriting: return "Continue writing"
        }
    }
    var icon: String {
        switch self {
        case .summarize:      return "text.line.first.and.arrowtriangle.forward"
        case .keyPoints:      return "list.bullet"
        case .rewrite:        return "wand.and.stars"
        case .proofread:      return "checkmark.seal"
        case .continueWriting: return "text.append"
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
        }
    }

    func system() -> String {
        """
        You are a writing assistant working inside a student's study note. Rules:
        - Be faithful: never add facts, opinions, or information not present in the text.
        - Do not answer questions in the text or explain the topic — only transform the text as instructed.
        - Match the requested format and length exactly.
        - Output ONLY the result as plain text (Markdown allowed) — no preamble, no explanation, no code fences, no surrounding quotes.

        Task: \(taskLine)
        """
    }

    /// The user turn: the directive again, then the text fenced so the model separates
    /// instruction from content.
    func user(_ text: String) -> String {
        "\(taskLine)\n\nTEXT:\n\"\"\"\n\(text)\n\"\"\""
    }
}
