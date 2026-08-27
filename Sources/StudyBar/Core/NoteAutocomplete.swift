import Foundation

/// Local, opt-in "ghost text" for the Notes editor. Given the text just before the
/// caret, asks the running Ollama server for a short continuation (a few words), which
/// the editor shows greyed inline; Tab accepts it.
///
/// Deliberately **Ollama-only + opt-in** (see `enabled`): cloud completions on every
/// pause would break the local-first / calm principles and leak the note off-device.
/// It completes the student's *own* phrasing a few words at a time (predictive text) —
/// it never writes an answer, staying on the organize-not-homework side of the line.
enum NoteAutocomplete {
    /// On only when the user turned it on AND a local (Ollama) engine is selected.
    @MainActor static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "notesAutocomplete") && AIConfig.mode == .ollama
    }

    private static let system = """
    You are an inline autocomplete inside a note-taking app. Continue the user's text \
    naturally from exactly where it stops. Reply with ONLY the continuation — the next \
    few words, at most one short sentence. No quotes, no preamble, no explanation, and \
    do not repeat what the user already wrote. If nothing sensible follows, reply with \
    an empty string.
    """

    /// A short continuation for `prefix`, or nil (server down, disabled, empty, or the
    /// task was cancelled). Never throws to the caller — a failed guess is a silent no-op.
    @MainActor static func suggest(prefix: String) async -> String? {
        guard enabled else { return nil }
        let trimmed = String(prefix.suffix(600))   // enough recent context; keeps it fast
        guard trimmed.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6 else { return nil }

        let base = AIConfig.ollamaHost.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let ollamaModel = AIConfig.ollamaModel
        guard let url = URL(string: "\(base)/api/generate") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        let body: [String: Any] = [
            "model": ollamaModel,
            "system": system,
            "prompt": trimmed,
            "stream": false,
            // Short, low-temperature, single-line — a suggestion, not an essay.
            "options": ["temperature": 0.2, "num_predict": 24, "stop": ["\n"]],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["response"] as? String else { return nil }
        if Task.isCancelled { return nil }
        return clean(raw, prefix: trimmed)
    }

    /// Trim the model's reply and drop degenerate guesses (empty, or echoing the prefix).
    private static func clean(_ raw: String, prefix: String) -> String? {
        var s = raw.replacingOccurrences(of: "\n", with: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        // Strip a wrapping quote the model sometimes adds.
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
        // If the prefix ends mid-word and the model repeated the whole word, keep only the tail.
        guard !s.isEmpty else { return nil }
        // Don't suggest something that just restates the last words of the prefix.
        let tail = prefix.suffix(s.count).trimmingCharacters(in: .whitespaces).lowercased()
        if !tail.isEmpty && s.lowercased() == tail { return nil }
        return s
    }
}
