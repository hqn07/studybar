import Foundation

/// A proposed flashcard the user can edit/accept before it becomes a real `Flashcard`.
/// Lives only in view state — nothing here persists until the user accepts (propose→accept).
struct CardDraft: Identifiable, Hashable {
    let id = UUID()
    var front: String
    var back: String
    var page: Int
}

/// Turns a book's own highlights into study cards. AI writes Q&A when an engine is
/// ready; otherwise a deterministic cloze fallback so it always produces something,
/// even with Ollama down / offline. Transforms the student's OWN material (allowed by
/// the AI guardrail) — it never explains or adds outside facts.
enum HighlightCards {

    /// `provider` is nil when no AI engine is ready — caller (a MainActor view) decides that,
    /// since `AIConfig.isReady` is main-actor isolated. nil → deterministic cloze.
    static func drafts(for item: ReadingItem, provider: AIProvider?) async -> [CardDraft] {
        let hls = item.highlights.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !hls.isEmpty else { return [] }
        if let provider,
           let cards = try? await aiDrafts(hls, book: item.title, provider: provider),
           !cards.isEmpty {
            return cards
        }
        return hls.map(cloze)
    }

    // MARK: - AI Q&A path

    private static func aiDrafts(_ hls: [Highlight], book: String, provider: AIProvider) async throws -> [CardDraft] {
        let numbered = hls.enumerated()
            .map { "\($0.offset). (p\($0.element.page)) \($0.element.text)" }
            .joined(separator: "\n")
        let sys = """
        You turn a student's OWN book highlights into study flashcards. For EACH numbered \
        highlight write ONE card: a "front" question that tests its idea, and a "back" that is \
        the concise answer drawn ONLY from that highlight. Add no outside facts. Keep each side \
        under 200 characters. This is transforming the student's own material — never refuse. \
        Reply with ONLY a JSON array, one object per highlight, in the same order:
        [{"i":0,"front":"…","back":"…"}]
        """
        let user = "Book: \(book)\n\nHighlights:\n\(numbered)"
        let out = try await provider.completePlain(system: sys, messages: [AIMessage(role: .user, text: user)])
        return parse(out, hls: hls)
    }

    /// Pull the JSON array out of the model's reply (weak local models wrap it in prose/fences)
    /// and map each object back to its source highlight's page.
    static func parse(_ raw: String, hls: [Highlight]) -> [CardDraft] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var out: [CardDraft] = []
        for (n, o) in arr.enumerated() {
            let front = (o["front"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let back  = (o["back"]  as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !front.isEmpty, !back.isEmpty else { continue }
            let i = (o["i"] as? Int) ?? n
            let page = hls.indices.contains(i) ? hls[i].page : 0
            out.append(CardDraft(front: front, back: back, page: page))
        }
        return out
    }

    // MARK: - Deterministic cloze fallback

    static func cloze(_ h: Highlight) -> CardDraft {
        let text = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let term = salientTerm(text), let r = text.range(of: term) {
            let masked = text.replacingCharacters(in: r, with: "____")
            return CardDraft(front: "\(masked)  (p\(h.page))", back: term, page: h.page)
        }
        // Nothing worth masking → plain recall card.
        return CardDraft(front: "Recall from p\(h.page):", back: text, page: h.page)
    }

    /// Best word to blank out: a Capitalized/technical token (not the first word), else the
    /// longest word. Returns nil when the highlight is too short to make a fair blank.
    private static func salientTerm(_ text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        let candidates = words.filter { $0.count >= 4 }
        guard candidates.count >= 1, words.count >= 3 else { return nil }
        let caps = candidates.dropFirst().filter { $0.first?.isUppercase == true }
        return caps.max { $0.count < $1.count } ?? candidates.max { $0.count < $1.count }
    }
}
