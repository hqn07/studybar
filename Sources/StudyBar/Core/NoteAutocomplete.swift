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
    /// What a suggestion attempt produced — so the editor can show real status instead
    /// of failing silently (the old `String?` hid "Ollama is down" as "no suggestion").
    enum Outcome: Equatable {
        case suggestion(String)   // show it as ghost text
        case none                 // ran fine, nothing worth suggesting
        case unavailable(String)  // couldn't reach / run the model — human-readable reason
    }

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

    /// A short continuation for `prefix` — or a reason it couldn't produce one, so the
    /// editor can surface "Ollama not reachable" instead of a silent no-op.
    @MainActor static func suggest(prefix: String) async -> Outcome {
        guard enabled else { return .unavailable("Autocomplete needs the Ollama engine") }
        let trimmed = String(prefix.suffix(600))   // enough recent context; keeps it fast
        guard trimmed.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6 else { return .none }

        let base = AIConfig.ollamaHost.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let ollamaModel = AIConfig.ollamaModel
        guard let url = URL(string: "\(base)/api/generate") else { return .unavailable("Bad Ollama server URL") }
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
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return .none }
        req.httpBody = payload

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch {
            if Task.isCancelled { return .none }
            return .unavailable("Ollama not reachable — is it running?")
        }
        if Task.isCancelled { return .none }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 { return .unavailable("Model “\(ollamaModel)” not pulled") }
            return .unavailable("Ollama error \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["response"] as? String else { return .none }
        return clean(raw, prefix: trimmed).map { .suggestion($0) } ?? .none
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
