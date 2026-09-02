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

    func system() -> String {
        let base = "You are a writing assistant working inside a student's study note. Be faithful — never add facts that aren't in the text, don't answer questions or editorialize. Output ONLY the result as plain text (markdown allowed) — no preamble, no code fences, no quotes around it."
        let task: String
        switch self {
        case .summarize:
            task = "Summarize the note into a short paragraph (2–4 sentences) capturing the key ideas."
        case .keyPoints:
            task = "Distill the note into a concise bulleted list of the key points, one per line starting with \"- \"."
        case .rewrite:
            task = "Rewrite the text to be clearer and better organized. Keep the same meaning, facts, and roughly the same length."
        case .proofread:
            task = "Fix spelling, grammar, and punctuation. Preserve the wording and meaning as much as possible."
        case .continueWriting:
            task = "Continue the note naturally for a sentence or two in the same voice. Output ONLY the new text to append, not a repeat of what's there."
        }
        return base + "\n\nTask: " + task
    }
}
