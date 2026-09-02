import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Engine selection
//
// StudyBar's AI is an *operator over your own study data*, never a tutor. It maps
// plain-English intent onto StudyBar actions (organize assignments, plan sessions,
// make flashcards from your own notes). It runs on one of three engines chosen by the
// user — all pay-your-own-way / local-first, no StudyBar backend:
//   • on-device  — Apple Foundation Models (macOS 26+). Free, private, offline. Default.
//   • claude     — Anthropic API with the user's own key (Keychain).
//   • openai     — OpenAI API with the user's own key (Keychain).

enum AIMode: String, CaseIterable, Identifiable {
    case off, onDevice, ollama, claude, openai
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:      return "Off"
        case .onDevice: return "On-device"
        case .ollama:   return "Ollama"
        case .claude:   return "Claude"
        case .openai:   return "ChatGPT"
        }
    }
    var subtitle: String {
        switch self {
        case .off:      return "The assistant is disabled."
        case .onDevice: return "Apple on-device model. Free, private, works offline. Nothing leaves your Mac."
        case .ollama:   return "Free local models via Ollama on your Mac (any age/chip). Runs on localhost, no key. Install from ollama.com."
        case .claude:   return "Anthropic API with your own key. Strongest for big planning jobs. Metered to your account."
        case .openai:   return "OpenAI API with your own key. Same organizing power — pick whichever you already pay for."
        }
    }
    var needsKey: Bool { self == .claude || self == .openai }
    /// Engines that take a user-set model name (but not a key).
    var needsModel: Bool { self == .ollama || self == .claude || self == .openai }
    var keyAccount: String? {
        switch self {
        case .claude: return AIConfig.claudeKeyAccount
        case .openai: return AIConfig.openaiKeyAccount
        default:      return nil
        }
    }
}

/// Persisted engine config. Keys live in the Keychain (never in the data file),
/// mode + model names in UserDefaults — same split the Canvas integration uses.
@MainActor
enum AIConfig {
    nonisolated static let claudeKeyAccount = "anthropicKey"
    nonisolated static let openaiKeyAccount = "openaiKey"

    static var mode: AIMode {
        // When the user hasn't chosen yet, default to Apple's on-device model on Macs that
        // have it (same engine as Writing Tools / Siri — free, private, and far better than a
        // small Ollama model for these tasks). Falls back to Off elsewhere. An explicit choice
        // (including Off) is always honored.
        get {
            if let raw = UserDefaults.standard.string(forKey: "aiMode"), let m = AIMode(rawValue: raw) { return m }
            return onDeviceAvailable ? .onDevice : .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiMode") }
    }
    /// Model switcher (user-overridable). Sonnet default per user preference; any valid id works.
    static var claudeModel: String {
        get { UserDefaults.standard.string(forKey: "aiClaudeModel").flatMap { $0.isEmpty ? nil : $0 } ?? "claude-sonnet-5" }
        set { UserDefaults.standard.set(newValue, forKey: "aiClaudeModel") }
    }
    static var openaiModel: String {
        get { UserDefaults.standard.string(forKey: "aiOpenAIModel").flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-4o" }
        set { UserDefaults.standard.set(newValue, forKey: "aiOpenAIModel") }
    }
    static var ollamaModel: String {
        get { UserDefaults.standard.string(forKey: "aiOllamaModel").flatMap { $0.isEmpty ? nil : $0 } ?? "qwen2.5:7b" }
        set { UserDefaults.standard.set(newValue, forKey: "aiOllamaModel") }
    }
    static var ollamaHost: String {
        get { UserDefaults.standard.string(forKey: "aiOllamaHost").flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:11434" }
        set { UserDefaults.standard.set(newValue, forKey: "aiOllamaHost") }
    }

    static func hasKey(_ mode: AIMode) -> Bool {
        guard let acct = mode.keyAccount else { return false }
        return Keychain.get(account: acct).map { !$0.isEmpty } ?? false
    }

    static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            default:         return false
            }
        }
        #endif
        return false
    }

    /// Whether the current mode is usable right now (key present / model available).
    static var isReady: Bool {
        switch mode {
        case .off:      return false
        case .onDevice: return onDeviceAvailable
        case .ollama:   return true          // optimistic; Test connection confirms the server is up
        case .claude, .openai: return hasKey(mode)
        }
    }
}

// MARK: - Messages, providers

struct AIMessage {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

enum AIError: LocalizedError {
    case notConfigured
    case unavailable(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return "Pick an engine (and add a key) in Settings ▸ Intelligence first."
        case .unavailable(let s): return s
        case .http(let code, let body):
            let detail = body.isEmpty ? "" : " — \(body.prefix(160))"
            return "Request failed (\(code))\(detail)"
        case .badResponse:        return "The model returned an empty or unreadable response."
        }
    }
}

/// A single completion. Providers are plain value types doing async HTTP / on-device calls.
protocol AIProvider {
    func complete(system: String, messages: [AIMessage]) async throws -> String
}

extension AIProvider {
    /// Free-form prose completion (NOT the JSON tool-protocol). Defaults to `complete` —
    /// cloud providers already return prose. Ollama overrides it to drop the `format:json`
    /// grammar constraint, which would otherwise force a JSON blob (e.g. reshaping a
    /// transcript into markdown notes came back as `{…}` garbage and destroyed the note).
    func completePlain(system: String, messages: [AIMessage]) async throws -> String {
        try await complete(system: system, messages: messages)
    }
}

struct AnthropicProvider: AIProvider {
    let apiKey: String
    let model: String

    func complete(system: String, messages: [AIMessage]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, errorText(data)) }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let blocks = obj?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }

    private func errorText(_ data: Data) -> String {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        return (err?["message"] as? String) ?? (String(data: data, encoding: .utf8) ?? "")
    }
}

struct OpenAIProvider: AIProvider {
    let apiKey: String
    let model: String

    func complete(system: String, messages: [AIMessage]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = ["model": model, "max_tokens": 2048, "messages": msgs]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, errorText(data)) }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = obj?["choices"] as? [[String: Any]] ?? []
        let text = (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }

    private func errorText(_ data: Data) -> String {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        return (err?["message"] as? String) ?? (String(data: data, encoding: .utf8) ?? "")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct OnDeviceProvider: AIProvider {
    func complete(system: String, messages: [AIMessage]) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        // Foundation Models is single-prompt; fold the short chat history into one prompt.
        let prompt = messages
            .map { "\($0.role == .user ? "Student" : "Assistant"): \($0.text)" }
            .joined(separator: "\n\n")
        let response = try await session.respond(to: prompt)
        let text = response.content
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }
}
#endif

/// Local models via Ollama (http://localhost:11434). Free, no key, no cloud.
struct OllamaProvider: AIProvider {
    let host: String
    let model: String

    func complete(system: String, messages: [AIMessage]) async throws -> String {
        let base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/chat") else { throw AIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        // format:json constrains Ollama's grammar to a single valid JSON object — this
        // is what makes weak local models reliable (no prose prefixes, no malformed
        // braces). Low temperature keeps the structured output stable.
        let body: [String: Any] = [
            "model": model, "messages": msgs, "stream": false,
            "format": "json",
            // num_ctx 8192: the default 4096 truncates StudyBar's full system prompt
            // (tool catalogs + the student's course context), which makes weak models
            // lose the format rules and invent tools. 8192 fixed it (3/3 vs 2/3).
            "options": ["temperature": 0.3, "num_ctx": 8192],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(code, msg.isEmpty ? "Is Ollama running? Start it, then `ollama pull \(model)`." : msg)
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (obj?["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }

    /// Streaming variant: same request with `stream:true`, feeding the growing `reply`
    /// field to `onReply` as tokens arrive. Returns the full accumulated JSON to parse.
    func completeStreaming(system: String, messages: [AIMessage],
                           onReply: @MainActor @escaping (String) -> Void) async throws -> String {
        let base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/chat") else { throw AIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = [
            "model": model, "messages": msgs, "stream": true, "format": "json",
            "options": ["temperature": 0.3, "num_ctx": 8192],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw AIError.http(code, "Is Ollama running? Start it, then `ollama pull \(model)`.")
        }
        var raw = ""; var lastSent = ""
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let chunk = (obj["message"] as? [String: Any])?["content"] as? String { raw += chunk }
            if let r = AIProtocol.replySoFar(raw), r != lastSent { lastSent = r; await onReply(r) }
            if (obj["done"] as? Bool) == true { break }
        }
        guard !raw.isEmpty else { throw AIError.badResponse }
        return raw
    }

    /// Free-form completion — same request WITHOUT `format:json`, so the model returns
    /// prose/markdown instead of a JSON object. Used for organizing a transcript into notes.
    func completePlain(system: String, messages: [AIMessage]) async throws -> String {
        try await completePlainStreaming(system: system, messages: messages) { _ in }
    }

    /// Streaming free-form variant (no `format:json`): feeds the growing text to `onReply`
    /// as tokens arrive, so the UI can show notes forming instead of a blind spinner.
    func completePlainStreaming(system: String, messages: [AIMessage],
                                onReply: @MainActor @escaping (String) -> Void) async throws -> String {
        let base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/api/chat") else { throw AIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let body: [String: Any] = [
            "model": model, "messages": msgs, "stream": true,
            "options": ["temperature": 0.3, "num_ctx": 8192],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw AIError.http(code, "Is Ollama running? Start it, then `ollama pull \(model)`.")
        }
        var raw = ""
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let chunk = (obj["message"] as? [String: Any])?["content"] as? String {
                raw += chunk; await onReply(raw)
            }
            if (obj["done"] as? Bool) == true { break }
        }
        guard !raw.isEmpty else { throw AIError.badResponse }
        return raw
    }
}

// MARK: - Proposed actions (tool schema)
//
// The model never writes to the store. It proposes actions as JSON; StudyBar renders
// each as a ConfirmCard and only mutates on the user's tap (AIActionRunner.apply).

struct AIAction: Identifiable {
    let id = UUID()
    let tool: String
    let label: String            // human-readable confirm label
    let args: [String: Any]      // parsed JSON args

    func str(_ k: String) -> String? { args[k] as? String }
    func int(_ k: String) -> Int? {
        if let i = args[k] as? Int { return i }
        if let d = args[k] as? Double { return Int(d) }
        if let s = args[k] as? String { return Int(s) }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let d = args[k] as? Double { return d }
        if let i = args[k] as? Int { return Double(i) }
        if let s = args[k] as? String { return Double(s) }
        return nil
    }

    /// A human-readable label derived from tool + args, for when the model omits "label".
    var autoLabel: String {
        func t(_ k: String) -> String { String((str(k) ?? "").trimmingCharacters(in: .whitespaces).prefix(48)) }
        func count(_ k: String) -> Int { (args[k] as? [Any])?.count ?? 0 }
        switch tool {
        case "add_task":              return "Add task: \(t("text"))"
        case "add_note":              return "Save note: \(t("title").isEmpty ? t("text") : t("title"))"
        case "create_assignment":     return "Add assignment: \(t("title"))"
        case "complete_assignment":   return "Mark done: \(t("title"))"
        case "update_assignment":     return "Update: \(t("title"))"
        case "prioritize_assignments":return "Rank assignments by urgency"
        case "plan_study_block":      let n = count("sessions"); return "Add \(n) study block\(n == 1 ? "" : "s")"
        case "make_flashcards":       let n = count("cards"); return "Add \(n) flashcard\(n == 1 ? "" : "s")" + (str("deck").map { " to \($0)" } ?? "")
        case "start_pomodoro":        return "Start a focus session"
        case "add_reading":           return "Add to Reading: \(t("title"))"
        case "log_reading":           return "Log reading: \(t("title"))"
        case "add_citation":          return "Add citation: \(t("title"))"
        case "add_link":              return "Add link: \(t("title"))"
        case "add_snippet":           return "Add snippet: \(t("title"))"
        case "add_class":             return "Add class: \(t("title"))"
        case "add_grade_item":        return "Add grade item: \(t("name"))"
        case "create_course":         return "Create course: \(t("name"))"
        default:                      return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// A single assistant turn: prose to show + proposed write actions + optional
/// read requests (executed immediately, results fed back for another round).
struct AITurn {
    let reply: String
    let actions: [AIAction]
    var reads: [AIAction] = []
    /// True when the model clearly *tried* to emit the JSON envelope but produced
    /// something unparseable even after repair — so we show a friendly message
    /// instead of leaking raw braces into the chat.
    var parseFailed: Bool = false
}

// MARK: - Orchestrator

@MainActor
enum AIService {

    static var enabled: Bool { AIConfig.mode != .off }

    /// Build the provider for the current mode, or nil if not configured/available.
    static func makeProvider() -> AIProvider? {
        switch AIConfig.mode {
        case .off:
            return nil
        case .onDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), AIConfig.onDeviceAvailable { return OnDeviceProvider() }
            #endif
            return nil
        case .claude:
            guard let key = Keychain.get(account: AIConfig.claudeKeyAccount), !key.isEmpty else { return nil }
            return AnthropicProvider(apiKey: key, model: AIConfig.claudeModel)
        case .openai:
            guard let key = Keychain.get(account: AIConfig.openaiKeyAccount), !key.isEmpty else { return nil }
            return OpenAIProvider(apiKey: key, model: AIConfig.openaiModel)
        case .ollama:
            return OllamaProvider(host: AIConfig.ollamaHost, model: AIConfig.ollamaModel)
        }
    }

    /// Connectivity/health check for Settings ▸ Intelligence.
    static func test() async -> String {
        guard let provider = makeProvider() else { return AIError.notConfigured.localizedDescription }
        do {
            let reply = try await provider.complete(
                system: "You are a connectivity check for a study app. Reply with exactly: StudyBar connected.",
                messages: [.init(role: .user, text: "ping")])
            return "✓ " + reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        } catch {
            return "✗ " + error.localizedDescription
        }
    }

    /// Max model round-trips per turn (reads are allowed in all but the last).
    private static let maxRounds = 4

    /// Run one assistant turn. The model may first request read-only data (which we
    /// execute and feed back) before returning its final reply + write actions.
    static func send(history: [AIMessage], state: AppState,
                     onReplyDelta: (@MainActor (String) -> Void)? = nil) async throws -> AITurn {
        guard let provider = makeProvider() else { throw AIError.notConfigured }
        // Cloud engines use the provider's native tool-calling API (structured, reliable)
        // instead of the JSON-in-prompt protocol; local engines keep the JSON path.
        if let anthropic = provider as? AnthropicProvider {
            return try await sendWithTools(provider: anthropic, history: history, state: state)
        }
        if let openai = provider as? OpenAIProvider {
            return try await sendWithToolsOpenAI(provider: openai, history: history, state: state)
        }
        let system = systemPrompt(state: state)
        var convo = history
        var last = AITurn(reply: "", actions: [])

        for round in 0..<maxRounds {
            // Stream on the local Ollama path so the reply types out live; the reads round
            // has an empty reply so nothing shows until the final answer round.
            let raw: String
            if let ollama = provider as? OllamaProvider, let onReplyDelta {
                raw = try await ollama.completeStreaming(system: system, messages: convo, onReply: onReplyDelta)
            } else {
                raw = try await provider.complete(system: system, messages: convo)
            }
            let turn = AIProtocol.parse(raw)
            last = turn
            // If it asked for data and rounds remain, fetch it and continue.
            if !turn.reads.isEmpty && round < maxRounds - 1 {
                let results = AIReader.run(turn.reads, state: state)
                convo.append(.init(role: .assistant, text: raw))
                convo.append(.init(role: .user,
                    text: "DATA (results of your reads — use these to answer; only read again if truly necessary):\n\(results)"))
                continue
            }
            // Unparseable envelope → give the model one corrective retry instead of
            // surfacing a garbled failure.
            if turn.parseFailed && round < maxRounds - 1 {
                convo.append(.init(role: .assistant, text: raw))
                convo.append(.init(role: .user, text:
                    "Your last message was not valid JSON. Reply with ONLY one JSON object and nothing else — no prose, no code fences: {\"reads\":[],\"reply\":\"...\",\"actions\":[...]}."))
                continue
            }
            return present(turn)
        }
        return present(last)
    }

    private static func present(_ turn: AITurn) -> AITurn {
        if turn.parseFailed {
            return AITurn(reply: "⚠️ I got a garbled response from the model. Try rephrasing, or ask for fewer changes at once.", actions: [])
        }
        let reply = turn.reply.isEmpty ? (turn.actions.isEmpty ? "Done." : "Here's what I can set up:") : turn.reply
        return AITurn(reply: reply, actions: turn.actions)
    }

    // MARK: System prompt (guardrail + protocol + scoped context)

    static func systemPrompt(state: AppState) -> String {
        """
        You are StudyBar Copilot, an assistant built into a macOS menu-bar study app.

        YOUR JOB: organize the student's own study data and help them operate StudyBar
        efficiently — rank and schedule assignments, plan focus sessions, turn the
        student's own notes into flashcards, triage a pasted syllabus, tidy tasks.

        HARD RULE — you do NOT tutor. Never produce NEW subject-matter explanations or
        answers from your own knowledge, solve problems, or write essays/assignments for
        the student. If asked to teach or answer, briefly decline and offer to organize.

        BUT reshaping the student's OWN material IS organizing, not tutoring — always allowed,
        even for academic content: turning a note or text they give you into flashcards,
        condensing their note into a summary, tagging, or building tasks/a schedule from it.
        Rule of thumb: transform what they give you = YES; teach them something new = NO.
        So "make flashcards from this note: …" should always produce make_flashcards — never
        a refusal.

        HOW TO REPLY: respond with ONE JSON object and nothing else — with these exact keys
        "reads", "reply", "actions" — using REAL tool names from the lists below (never the
        literal words "read"/"write"/placeholders).

        Two-step pattern. If you need the student's data, FIRST return only reads:
          {"reads":[{"tool":"get_note","args":{"query":"Cell Biology"}}],"reply":"","actions":[]}
        You'll receive the data, THEN respond with the result and any write actions:
          {"reads":[],"reply":"Made cards from your note.","actions":[{"tool":"make_flashcards","label":"Add 3 cards","args":{"cards":[{"front":"What makes ATP?","back":"Mitochondria"}]}}]}

        Once you have what you need, set "reads":[]. Reads run instantly and privately;
        every write action is confirmed by the student. Never invent data you didn't read
        or the student didn't give you.

        IMPORTANT:
        - If the student included the material in their message (e.g. "summarize this note: …",
          "make flashcards from: …"), act on it DIRECTLY — do NOT use reads. Only read when you
          genuinely need data they did not provide.
        - When the student asks you to save / add / make / summarize / rank something, you MUST
          return at least one action — never reply with empty "actions" and an empty "reply".
        - "reads" is a list of {"tool","args"} objects using ONLY the read tools above, or []. NEVER
          put note text, prose, or anything else in "reads".
        - Use ONLY the exact tool names listed. NEVER invent a tool (no "error", "unknown", etc.).
          If you truly cannot help with these tools, return "actions":[] and a one-sentence "reply".

        READ TOOLS (free, no confirmation — use these to look things up):
        \(AIProtocol.readCatalog)

        WRITE TOOLS (proposed as confirm cards):
        \(AIProtocol.toolCatalog)

        CURRENT STATE (a summary — use reads for detail):
        \(StudyContext.snapshot(state: state))
        """
    }
}

// MARK: - Wire protocol (parse the model's JSON)

enum AIProtocol {
    static let readCatalog = """
    - get_note            args: { "query": string }   → title + body of the best-matching note
    - list_notes          args: {}                      → all note titles
    - list_assignments    args: { "include"?: "done" }  → assignments w/ status, due, urgency
    - list_todos          args: {}                      → open to-dos
    - list_reading        args: {}                      → books with page progress
    - list_decks          args: {}                      → flashcard decks + card counts
    - list_citations      args: {}                      → saved references
    - list_classes        args: {}                      → weekly class schedule
    - list_links          args: {}                      → quick links
    - get_grades          args: { "course"?: string }   → GPA + current standing / what-if
    - get_study_stats     args: {}                      → time studied today/week, by course, streak, pomodoros, retention
    - get_course          args: { "course": string }    → one course's grade, assignments, notes, hours logged, classes
    - get_semester        args: {}                      → term name, week number, % through
    - list_snippets       args: {}                      → saved snippet keywords
    - get_scratchpad      args: {}                      → the scratchpad contents
    - search              args: { "query": string }     → matches across notes, tasks, reading, citations
    """

    static let toolCatalog = """
    - add_task            args: { "text": string, "course"?: string, "dueInDays"?: int }
    - add_note            args: { "title"?: string, "text": string, "course"?: string }
    - create_assignment   args: { "title": string, "course"?: string, "dueInDays"?: int, "points"?: number }
    - complete_assignment args: { "title": string }
    - update_assignment   args: { "title": string, "dueInDays"?: int, "submitted"?: bool, "done"?: bool }
    - prioritize_assignments args: {}   (StudyBar computes urgency from due × weight × course grade × effort — don't guess ranks)
    - plan_study_block    args: { "sessions": [ { "title": string, "dueInDays": int, "minutes"?: int, "course"?: string } ] }
    - make_flashcards     args: { "deck"?: string, "course"?: string, "cards": [ { "front": string, "back": string } ] }
    - start_pomodoro      args: { "minutes"?: int, "label"?: string }
    - add_reading         args: { "title": string, "author"?: string, "totalPages"?: int, "course"?: string }
    - log_reading         args: { "title": string, "toPage": int }
    - add_citation        args: { "title": string, "authors"?: [string], "year"?: string, "doi"?: string, "url"?: string, "container"?: string }
    - add_link            args: { "title": string, "url": string, "course"?: string }
    - add_snippet         args: { "keyword": string, "title": string, "body": string }
    - add_class           args: { "title": string, "weekday": int(1=Sun..7=Sat), "start": "HH:MM", "end": "HH:MM", "course"?: string, "room"?: string }
    - add_grade_item      args: { "course": string, "name": string, "weight": number, "score"?: number, "graded"?: bool }
    - create_course       args: { "name": string, "code"?: string }
    """

    /// Extract the model's JSON object (tolerating prose or ``` fences around it).
    /// Tool names the app actually understands — anything else the model invents
    /// (e.g. a bogus "error" tool) is dropped rather than rendered as an action card.
    static let writeTools: Set<String> = [
        "add_task", "add_note", "create_assignment", "complete_assignment", "update_assignment",
        "prioritize_assignments", "plan_study_block", "make_flashcards", "start_pomodoro",
        "add_reading", "log_reading", "add_citation", "add_link", "add_snippet",
        "add_class", "add_grade_item", "create_course",
    ]
    static let readTools: Set<String> = [
        "get_note", "list_notes", "list_assignments", "list_todos", "list_reading",
        "list_decks", "list_citations", "list_classes", "list_links", "get_grades", "search",
        "get_study_stats", "get_course", "get_semester", "list_snippets", "get_scratchpad",
    ]

    /// Extract the growing value of the `"reply"` field from a partial JSON envelope,
    /// for live streaming. The envelope order is reads → reply → actions and `reads` is
    /// empty on the final round, so `reply` starts almost immediately; we return whatever
    /// of it has arrived (stopping at the closing quote once complete). nil until it starts.
    static func replySoFar(_ raw: String) -> String? {
        guard let key = raw.range(of: "\"reply\"") else { return nil }
        let after = raw[key.upperBound...]
        guard let colon = after.firstIndex(of: ":") else { return nil }
        var i = after.index(after: colon)
        while i < after.endIndex, after[i] == " " { i = after.index(after: i) }
        guard i < after.endIndex, after[i] == "\"" else { return nil }
        i = after.index(after: i)
        var out = ""; var esc = false
        while i < after.endIndex {
            let c = after[i]
            if esc {
                switch c { case "n": out += "\n"; case "t": out += "\t"; case "r": break
                           case "\"": out += "\""; case "\\": out += "\\"; default: out.append(c) }
                esc = false
            } else if c == "\\" { esc = true }
            else if c == "\"" { break }               // closing quote → reply complete
            else { out.append(c) }
            i = after.index(after: i)
        }
        return out
    }

    static func parse(_ raw: String) -> AITurn {
        if let obj = jsonEnvelope(raw) {
            let reply = (obj["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Accept read/write tools in either field, then sort them correctly — small
            // models sometimes misplace a write action into "reads".
            let inReads = actions(obj["reads"], valid: readTools.union(writeTools))
            var acts = actions(obj["actions"], valid: writeTools)
            acts += inReads.filter { writeTools.contains($0.tool) }
            let reads = inReads.filter { readTools.contains($0.tool) }
            return AITurn(reply: reply, actions: acts, reads: reads)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model tried to emit the JSON envelope but produced something unparseable
        // even after repair — flag it so the UI shows a friendly retry, not raw braces.
        if looksLikeEnvelope(trimmed) {
            return AITurn(reply: "", actions: [], reads: [], parseFailed: true)
        }
        // Genuine plain-prose reply (model chatted off-protocol) — show it as-is.
        return AITurn(reply: trimmed, actions: [])
    }

    /// True if the string is clearly an attempted action-envelope (so a parse
    /// failure should be hidden, not dumped to the user as raw text).
    private static func looksLikeEnvelope(_ s: String) -> Bool {
        guard s.hasPrefix("{") else { return false }
        return s.contains("\"actions\"") || s.contains("\"reply\"") || s.contains("\"reads\"")
    }

    /// Extract the JSON envelope from a raw model response. Tries the clean
    /// balanced-object first; on failure, repairs common small-model mistakes
    /// (missing/extra/swapped closers, trailing commas) and retries.
    private static func jsonEnvelope(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        if let clean = extractJSONObject(raw),
           let obj = try? JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [String: Any] {
            return obj
        }
        let repaired = sanitizeJSON(String(raw[start...]))
        return try? JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
    }

    /// Best-effort JSON repair for weak local models. Walks the text tracking a
    /// bracket/brace stack (ignoring string contents): drops stray closers,
    /// rewrites a closer to match what it actually closes (fixes `]` written as
    /// `}` and vice-versa), and appends any missing closers for a truncated
    /// response. Finally strips trailing commas before a closer.
    static func sanitizeJSON(_ s: String) -> String {
        var out = ""
        var stack: [Character] = []
        var inString = false, escaped = false
        for c in s {
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{", "[": stack.append(c); out.append(c)
            case "}", "]":
                guard let top = stack.popLast() else { continue } // drop stray closer
                out.append(top == "{" ? "}" : "]")               // match the opener
            default: out.append(c)
            }
        }
        if inString { out.append("\"") }   // close a value cut off mid-string (truncation)
        while let top = stack.popLast() { out.append(top == "{" ? "}" : "]") }
        return out.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1",
                                        options: .regularExpression)
    }

    private static func actions(_ value: Any?, valid: Set<String>) -> [AIAction] {
        (value as? [[String: Any]] ?? []).compactMap { a in
            guard let tool = a["tool"] as? String, valid.contains(tool) else { return nil }
            var args = (a["args"] as? [String: Any]) ?? [:]
            // Some models (esp. small local ones) flatten params to the top level
            // instead of nesting them under "args" — accept that too.
            if args.isEmpty { args = a.filter { !["tool", "label", "args"].contains($0.key) } }
            let provided = (a["label"] as? String)?.trimmingCharacters(in: .whitespaces)
            // Derive a readable label when the model omits one (or echoes the tool name).
            let base = AIAction(tool: tool, label: "", args: args)
            let label = (provided?.isEmpty == false && provided != tool) ? provided! : base.autoLabel
            return AIAction(tool: tool, label: label, args: args)
        }
    }

    /// First balanced { … } run in the string.
    private static func extractJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

// MARK: - Scoped read-only context

@MainActor
enum StudyContext {
    static func snapshot(state: AppState) -> String {
        let d = state.data
        var lines: [String] = []
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        lines.append("Today: \(today).")

        if d.courses.isEmpty {
            lines.append("Courses: none yet.")
        } else {
            let cs = d.courses.prefix(12).map { c -> String in
                var s = c.code.isEmpty ? c.name : "\(c.name) [\(c.code)]"
                if !c.grade.isEmpty { s += " grade \(c.grade)" }
                return s
            }
            lines.append("Courses: " + cs.joined(separator: "; ") + ".")
        }

        let open = d.assignments.filter { $0.status != .done }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        if open.isEmpty {
            lines.append("Open assignments: none.")
        } else {
            lines.append("Open assignments (\(open.count)):")
            for a in open.prefix(25) {
                let course = state.course(a.courseID)?.code ?? state.course(a.courseID)?.name ?? "—"
                let due = a.daysUntilDue.map { $0 == 0 ? "due today" : ($0 < 0 ? "\(-$0)d overdue" : "in \($0)d") } ?? "no due date"
                let pts = a.points.map { ", \(Int($0)) pts" } ?? ""
                let sub = a.submitted ? ", submitted" : ""
                lines.append("  • \(a.title) (\(course), \(due)\(pts)\(sub))")
            }
        }

        if let next = state.nextClassToday {
            let cc = state.course(next.session.courseID)?.code ?? ""
            lines.append("Next class today: \(cc.isEmpty ? next.session.title : cc) in \(next.minutesUntil)m.")
        }
        lines.append("Library: \(d.notes.count) notes, \(d.decks.count) decks, \(d.flashcards.count) cards, \(d.reading.count) books, \(d.todos.filter { !$0.done }.count) open to-dos.")

        // Effort + standing + term — so the assistant can plan realistically without a read.
        let sm = StudyStats.secondsToday(d) / 60, sw = StudyStats.secondsThisWeek(d) / 60
        lines.append("Studied today \(sm)m; this week \(sw/60)h\(sw%60)m; streak \(StudyStats.currentStreak(d))d.")
        let graded = d.courses.filter { $0.gradePoints != nil }
        let den = graded.reduce(0.0) { $0 + $1.credits }
        if den > 0 {
            let num = graded.reduce(0.0) { $0 + ($1.gradePoints ?? 0) * $1.credits }
            lines.append(String(format: "Projected GPA: %.2f.", num / den))
        }
        if !d.termName.isEmpty, let start = d.termStart {
            lines.append("Term: \(d.termName), week \(max(1, Int(Date().timeIntervalSince(start) / (7 * 86400)) + 1)).")
        }
        lines.append("(Deeper detail: get_study_stats, get_course, get_semester, and the list_/get_ read tools.)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Read tools (run immediately, no confirmation — read-only)

@MainActor
enum AIReader {
    static func run(_ reads: [AIAction], state: AppState) -> String {
        reads.map { one($0, state: state) }.joined(separator: "\n")
    }

    static func one(_ r: AIAction, state: AppState) -> String {
        let d = state.data
        switch r.tool {
        case "get_note":
            let q = (r.str("query") ?? r.str("title") ?? "").trimmingCharacters(in: .whitespaces)
            let hit = d.notes.first { $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q) }
                ?? (q.isEmpty ? d.notes.sorted { $0.updatedAt > $1.updatedAt }.first : nil)
            guard let n = hit else { return "get_note: no matching note." }
            return "NOTE “\(n.title)”: \(n.body.prefix(1600))"

        case "list_notes":
            return "NOTES: " + (d.notes.isEmpty ? "none" : d.notes.prefix(50).map { $0.title.isEmpty ? "(untitled)" : $0.title }.joined(separator: "; "))

        case "list_assignments":
            let includeDone = (r.str("include") ?? "").localizedCaseInsensitiveContains("done")
            let list = d.assignments.filter { includeDone || $0.status != .done }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            return "ASSIGNMENTS: " + (list.isEmpty ? "none" : list.prefix(40).map { a in
                let due = a.due.map { " due \($0.dayMonth)" } ?? ""
                let u = a.urgencyLabel.map { " · \($0)" } ?? ""
                return "\(a.title) [\(a.status.rawValue)]\(due)\(a.submitted ? " · submitted" : "")\(u)"
            }.joined(separator: "; "))

        case "list_todos":
            let open = d.todos.filter { !$0.done }
            return "OPEN TODOS: " + (open.isEmpty ? "none" : open.map { t in t.text + (t.due.map { " (due \($0.dayMonth))" } ?? "") }.joined(separator: "; "))

        case "list_reading":
            return "READING: " + (d.reading.isEmpty ? "none" : d.reading.map { b in
                "\(b.title)\(b.author.isEmpty ? "" : " by \(b.author)") — \(b.currentPage)/\(b.totalPages)p\(b.done ? " ✓" : "")"
            }.joined(separator: "; "))

        case "list_decks":
            return "DECKS: " + (d.decks.isEmpty ? "none" : d.decks.map { dk in "\(dk.name) (\(d.flashcards.filter { $0.deckID == dk.id }.count) cards)" }.joined(separator: "; "))

        case "list_citations":
            return "CITATIONS: " + (d.references.isEmpty ? "none" : d.references.prefix(40).map { $0.title }.joined(separator: "; "))

        case "list_classes":
            let cs = d.classes.sorted { ($0.weekdays.first ?? 0, $0.startMinutes) < ($1.weekdays.first ?? 0, $1.startMinutes) }
            return "CLASSES: " + (cs.isEmpty ? "none" : cs.map { c in
                "\(c.daysShort) \(c.startString) \(state.course(c.courseID)?.code ?? (c.title.isEmpty ? "Class" : c.title))\(c.room.isEmpty ? "" : " @\(c.room)")"
            }.joined(separator: "; "))

        case "list_links":
            return "LINKS: " + (d.links.isEmpty ? "none" : d.links.prefix(40).map { "\($0.title) → \($0.url)" }.joined(separator: "; "))

        case "get_grades":
            return grades(state, courseQuery: r.str("course"))

        case "get_study_stats":
            return studyStats(state)

        case "get_course":
            return courseDetail(state, query: r.str("course") ?? r.str("name"))

        case "get_semester":
            return semester(state)

        case "list_snippets":
            return "SNIPPETS: " + (d.snippets.isEmpty ? "none" : d.snippets.prefix(60).map {
                $0.keyword.isEmpty ? ($0.title.isEmpty ? "(untitled)" : $0.title) : $0.keyword
            }.joined(separator: "; "))

        case "get_scratchpad":
            return d.scratchpad.isEmpty ? "SCRATCHPAD: empty."
                                        : "SCRATCHPAD: \(d.scratchpad.prefix(1600))"

        case "search":
            return search(r.str("query") ?? "", state: state)

        default:
            return "\(r.tool): unknown read tool."
        }
    }

    /// Effort/time across the app — the piece the assistant needs to plan realistically.
    static func studyStats(_ state: AppState) -> String {
        let d = state.data
        let today = StudyStats.secondsToday(d) / 60
        let week = StudyStats.secondsThisWeek(d) / 60
        var lines = ["Studied today \(today)m; this week \(week/60)h\(week%60)m; streak \(StudyStats.currentStreak(d))d; pomodoros today \(StudyStats.pomodorosToday(d))."]
        let byCourse = StudyStats.weekByCourse(d).filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
        if !byCourse.isEmpty {
            lines.append("This week by course: " + byCourse.prefix(8).map {
                "\(state.course($0.courseID)?.code ?? state.course($0.courseID)?.name ?? "Unlabeled") \($0.seconds/60)m"
            }.joined(separator: ", ") + ".")
        }
        if let ret = StudyStats.flashcardRetention(d) {
            lines.append("Flashcards: \(StudyStats.cardsDueToday(d)) due today, \(Int(ret*100))% retention.")
        }
        return "STUDY STATS — " + lines.joined(separator: " ")
    }

    /// Everything linked to one course — the cross-module join ("ecosystem" view).
    static func courseDetail(_ state: AppState, query: String?) -> String {
        let d = state.data
        guard let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty,
              let c = d.courses.first(where: { $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q) })
        else { return "get_course: name the course by code or title." }
        let open = d.assignments.filter { $0.courseID == c.id && $0.status != .done }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let done = d.assignments.filter { $0.courseID == c.id && $0.status == .done }.count
        let notes = d.notes.filter { $0.courseID == c.id }.count
        let mins = d.timeEntries.filter { $0.courseID == c.id }.reduce(0) { $0 + $1.seconds } / 60
        let classes = d.classes.filter { $0.courseID == c.id }.count
        var lines = ["COURSE \(c.name)\(c.code.isEmpty ? "" : " [\(c.code)]") — \(Int(c.credits)) cr\(c.grade.isEmpty ? "" : ", grade \(c.grade)")\(c.instructor.isEmpty ? "" : ", \(c.instructor)")."]
        if let next = open.first {
            let due = next.daysUntilDue.map { $0 == 0 ? "due today" : ($0 < 0 ? "\(-$0)d overdue" : "in \($0)d") } ?? "no due date"
            lines.append("\(open.count) open assignment(s); next: \(next.title) (\(due)). \(done) done.")
        } else { lines.append("No open assignments; \(done) done.") }
        lines.append("\(notes) notes, \(mins)m logged, \(classes) weekly class(es).")
        let g = state.gradeItems.filter { $0.courseID == c.id && $0.graded }
        let gw = g.reduce(0.0) { $0 + $1.weight }
        if gw > 0 {
            let earned = g.reduce(0.0) { $0 + $1.weight * $1.score / 100 }
            lines.append(String(format: "Grade so far: %.1f%% on %d%% graded.", earned / gw * 100, Int(gw)))
        }
        return lines.joined(separator: " ")
    }

    static func semester(_ state: AppState) -> String {
        let d = state.data
        let name = d.termName.isEmpty ? "current term" : d.termName
        guard let start = d.termStart, let end = d.termEnd else { return "SEMESTER: \(name) (no dates set)." }
        let total = end.timeIntervalSince(start), elapsed = Date().timeIntervalSince(start)
        let pct = total > 0 ? max(0, min(100, Int(elapsed / total * 100))) : 0
        let wk = max(1, Int(elapsed / (7 * 86400)) + 1)
        return "SEMESTER \(name): week \(wk), \(pct)% through (\(start.dayMonth)–\(end.dayMonth))."
    }

    static func grades(_ state: AppState, courseQuery: String?) -> String {
        let graded = state.data.courses.filter { $0.gradePoints != nil }
        var parts: [String] = []
        if graded.isEmpty {
            parts.append("GPA: n/a (no letter grades set on courses)")
        } else {
            let num = graded.reduce(0.0) { $0 + ($1.gradePoints ?? 0) * $1.credits }
            let den = graded.reduce(0.0) { $0 + $1.credits }
            parts.append(den > 0 ? String(format: "GPA: %.2f", num / den) : "GPA: n/a")
        }
        if let q = courseQuery,
           let c = state.data.courses.first(where: { $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q) }) {
            let items = state.gradeItems.filter { $0.courseID == c.id && $0.graded }
            let gw = items.reduce(0.0) { $0 + $1.weight }
            let earned = items.reduce(0.0) { $0 + $1.weight * $1.score / 100 }
            if gw > 0 { parts.append("\(c.code.isEmpty ? c.name : c.code): \(String(format: "%.1f%%", earned / gw * 100)) on \(Int(gw))% graded") }
        }
        return parts.joined(separator: "; ")
    }

    static func search(_ query: String, state: AppState) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return "search: empty query." }
        let d = state.data
        var hits: [String] = []
        for n in d.notes where n.title.localizedCaseInsensitiveContains(q) || n.body.localizedCaseInsensitiveContains(q) { hits.append("note: \(n.title)") }
        for a in d.assignments where a.title.localizedCaseInsensitiveContains(q) { hits.append("assignment: \(a.title)") }
        for t in d.todos where t.text.localizedCaseInsensitiveContains(q) { hits.append("todo: \(t.text)") }
        for b in d.reading where b.title.localizedCaseInsensitiveContains(q) { hits.append("book: \(b.title)") }
        for c in d.references where c.title.localizedCaseInsensitiveContains(q) { hits.append("citation: \(c.title)") }
        return "SEARCH “\(q)”: " + (hits.isEmpty ? "no matches" : hits.prefix(20).joined(separator: "; "))
    }

    static func weekday(_ w: Int) -> String {
        ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][safe: w] ?? "Day\(w)"
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Apply proposed actions (only on user confirmation)

@MainActor
enum AIActionRunner {

    /// Human-readable one-liner for the confirm card, falling back to the model's label.
    static func summary(_ a: AIAction) -> String { a.label }

    /// Apply one action to the store. Returns a short result string for the chat log.
    @discardableResult
    static func apply(_ a: AIAction, state: AppState) -> String {
        switch a.tool {
        case "add_task":
            guard let text = a.str("text"), !text.isEmpty else { return "Skipped: empty task." }
            AppActions.addTask(text, course: a.str("course"), dueInDays: a.int("dueInDays"))
            return "Added task “\(text.prefix(40))”."

        case "add_note":
            guard let text = a.str("text"), !text.isEmpty else { return "Skipped: empty note." }
            let title = a.str("title") ?? String(text.prefix(60))
            var note = Note(title: title, body: text, courseID: AppActions.courseID(named: a.str("course")))
            note.updatedAt = .now
            state.data.notes.append(note)
            return "Saved note “\(title.prefix(40))”."

        case "create_assignment":
            guard let title = a.str("title"), !title.isEmpty else { return "Skipped: no title." }
            var asg = Assignment(title: title, courseID: AppActions.courseID(named: a.str("course")))
            if let d = a.int("dueInDays") { asg.due = Calendar.current.date(byAdding: .day, value: d, to: .now) }
            asg.points = a.double("points")
            state.data.assignments.append(asg)
            return "Created assignment “\(title.prefix(40))”."

        case "prioritize_assignments":
            let n = prioritize(state: state)
            return "Set urgency on \(n) assignment\(n == 1 ? "" : "s")."

        case "plan_study_block":
            let sessions = a.args["sessions"] as? [[String: Any]] ?? []
            var made = 0
            for s in sessions {
                guard let title = s["title"] as? String, !title.isEmpty else { continue }
                var a = Assignment(task: title, courseID: AppActions.courseID(named: s["course"] as? String))
                if let d = (s["dueInDays"] as? Int) ?? (s["dueInDays"] as? Double).map({ Int($0) }) {
                    a.due = Calendar.current.date(byAdding: .day, value: d, to: .now)
                }
                a.urgency = 2
                state.data.assignments.append(a)
                made += 1
            }
            return "Scheduled \(made) study block\(made == 1 ? "" : "s")."

        case "make_flashcards":
            let cards = a.args["cards"] as? [[String: Any]] ?? []
            guard !cards.isEmpty else { return "Skipped: no cards." }
            let deckName = a.str("deck") ?? "AI Cards"
            let courseID = AppActions.courseID(named: a.str("course"))
            let deck: Deck
            if let existing = state.data.decks.first(where: { $0.name.caseInsensitiveCompare(deckName) == .orderedSame }) {
                deck = existing
            } else {
                deck = Deck(name: deckName, courseID: courseID)
                state.data.decks.append(deck)
            }
            var added = 0
            for c in cards {
                guard let front = c["front"] as? String, let back = c["back"] as? String,
                      !front.isEmpty, !back.isEmpty else { continue }
                state.data.flashcards.append(Flashcard(deckID: deck.id, front: front, back: back))
                added += 1
            }
            return "Added \(added) card\(added == 1 ? "" : "s") to “\(deckName)”."

        case "start_pomodoro":
            AppActions.startFocus(minutes: a.int("minutes"), label: a.str("label"))
            return "Started a focus session."

        case "complete_assignment":
            guard let i = matchAssignment(a.str("title"), state) else { return "No matching assignment." }
            AppActions.completeAssignment(id: state.data.assignments[i].id)
            return "Marked “\(state.data.assignments[i].title)” done."

        case "update_assignment":
            guard let i = matchAssignment(a.str("title"), state) else { return "No matching assignment." }
            if let d = a.int("dueInDays") { state.data.assignments[i].due = Calendar.current.date(byAdding: .day, value: d, to: .now) }
            if let sub = a.args["submitted"] as? Bool { state.data.assignments[i].submitted = sub }
            if let done = a.args["done"] as? Bool { state.data.assignments[i].status = done ? .done : .todo }
            return "Updated “\(state.data.assignments[i].title)”."

        case "add_reading":
            guard let title = a.str("title"), !title.isEmpty else { return "Skipped: no title." }
            var item = ReadingItem(title: title, courseID: AppActions.courseID(named: a.str("course")))
            item.author = a.str("author") ?? ""
            item.totalPages = a.int("totalPages") ?? 0
            state.data.reading.append(item)
            return "Added “\(title)” to Reading."

        case "log_reading":
            guard let i = state.data.reading.firstIndex(where: { $0.title.localizedCaseInsensitiveContains(a.str("title") ?? "\u{0}") }) else { return "No matching book." }
            if let page = a.int("toPage") { state.setReadingPage(state.data.reading[i].id, to: page) }
            return "Logged reading for “\(state.data.reading[i].title)”."

        case "add_citation":
            guard let title = a.str("title"), !title.isEmpty else { return "Skipped: no title." }
            var ref = Reference(type: .article, title: title, year: a.str("year") ?? "")
            ref.authors = (a.args["authors"] as? [String]) ?? []
            ref.doi = a.str("doi") ?? ""
            ref.url = a.str("url") ?? ""
            ref.container = a.str("container") ?? ""
            state.data.references.append(ref)
            return "Added citation “\(title.prefix(40))”."

        case "add_link":
            guard let title = a.str("title"), let url = a.str("url"), !url.isEmpty else { return "Skipped: need title + url." }
            state.data.links.append(QuickLink(title: title, url: url, courseID: AppActions.courseID(named: a.str("course"))))
            return "Added link “\(title)”."

        case "add_snippet":
            guard let title = a.str("title"), let body = a.str("body"), !body.isEmpty else { return "Skipped: need title + body." }
            state.data.snippets.append(Snippet(keyword: a.str("keyword") ?? "", title: title, body: body))
            return "Added snippet “\(title)”."

        case "add_class":
            guard let title = a.str("title") else { return "Skipped: no title." }
            var cls = ClassSession(courseID: AppActions.courseID(named: a.str("course")))
            cls.title = title
            cls.weekday = min(7, max(1, a.int("weekday") ?? 2))
            cls.startMinutes = minutes(a.str("start")) ?? 9 * 60
            cls.endMinutes = minutes(a.str("end")) ?? (cls.startMinutes + 60)
            cls.room = a.str("room") ?? ""
            state.data.classes.append(cls)
            return "Added class “\(title)”."

        case "add_grade_item":
            guard let name = a.str("name"), let cid = AppActions.courseID(named: a.str("course")) else { return "Skipped: need course + name." }
            var g = GradeItem(courseID: cid, name: name, weight: a.double("weight") ?? 0)
            g.score = a.double("score") ?? 0
            g.graded = (a.args["graded"] as? Bool) ?? (a.double("score") != nil)
            state.gradeItems.append(g)
            return "Added grade component “\(name)”."

        case "create_course":
            guard let name = a.str("name"), !name.isEmpty else { return "Skipped: no name." }
            state.data.courses.append(Course(name: name, code: a.str("code") ?? ""))
            return "Created course “\(name)”."

        default:
            return "Unknown action “\(a.tool)”."
        }
    }

    /// Find the index of the best-matching open-or-any assignment by title.
    private static func matchAssignment(_ title: String?, _ state: AppState) -> Int? {
        guard let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return state.data.assignments.firstIndex { $0.title.localizedCaseInsensitiveContains(t) }
    }

    /// Parse "HH:MM" → minutes from midnight.
    private static func minutes(_ s: String?) -> Int? {
        guard let s, s.contains(":") else { return s.flatMap { Int($0).map { $0 * 60 } } }
        let p = s.split(separator: ":")
        guard let h = Int(p[0]), let m = Int(p.count > 1 ? p[1] : "0") else { return nil }
        return h * 60 + m
    }

    /// Deterministic urgency ranking — StudyBar computes it, the model never guesses.
    /// Score blends days-until-due (dominant), assignment weight, and a `riskBump` from
    /// the course's standing (low grade / neglected this week) → urgency 0/1/2.
    /// Imminent (≤3 days, incl. today/overdue) is "Now" regardless of the rest.
    static func urgencyScore(days: Int, points: Double?, riskBump: Double = 0) -> Int {
        var score = 0.0
        if days <= 3 { score += 3 }          // overdue … due in 3 days → Now baseline
        else if days <= 7 { score += 1.5 }   // this week
        else if days <= 14 { score += 0.5 }  // next couple weeks
        if let p = points { if p >= 50 { score += 1 } else if p >= 20 { score += 0.5 } }
        score += riskBump
        return score >= 3 ? 2 : (score >= 1.5 ? 1 : 0)   // 2 Now · 1 This week · 0 Later
    }

    @discardableResult
    static func prioritize(state: AppState) -> Int {
        let data = state.data
        // Minutes studied per course this week — a course at 0 is being neglected.
        var weekByCourse: [UUID: Int] = [:]
        for r in StudyStats.weekByCourse(data) { if let id = r.courseID { weekByCourse[id] = r.seconds / 60 } }
        var count = 0
        for i in state.data.assignments.indices {
            let a = state.data.assignments[i]
            guard a.status != .done, !a.submitted else {
                state.data.assignments[i].urgency = 0     // done/submitted → lowest
                continue
            }
            // Ecosystem bump: work in a struggling or neglected course is more at risk.
            var bump = 0.0
            if let c = data.courses.first(where: { $0.id == a.courseID }) {
                if let gp = c.gradePoints { if gp < 2.7 { bump += 1.0 } else if gp < 3.3 { bump += 0.5 } }
                if (weekByCourse[c.id] ?? 0) == 0 { bump += 0.5 }
            }
            state.data.assignments[i].urgency = urgencyScore(days: a.daysUntilDue ?? 999, points: a.points, riskBump: bump)
            count += 1
        }
        return count
    }
}

// MARK: - Chat view-model (owned by AppState, drives the Assistant module)

@MainActor
final class AIChat: ObservableObject {
    struct Msg: Identifiable {
        let id = UUID()
        enum Role { case user, assistant }
        let role: Role
        var text: String
        var actions: [AIAction] = []
        var results: [UUID: String] = [:]     // action.id → applied result
        var skipped: Set<UUID> = []
        var isError = false
    }

    @Published var messages: [Msg] = []
    @Published var sending = false
    /// Rough token estimate of the conversation actually sent to the model
    /// (system prompt + non-error history), refreshed each turn. ~chars/4.
    @Published var approxTokens = 0

    var isEmpty: Bool { messages.isEmpty }

    func clear() { messages.removeAll(); approxTokens = 0 }

    func send(_ text: String, state: AppState) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        messages.append(Msg(role: .user, text: t))
        sending = true
        // History excludes error bubbles so a failed turn doesn't poison context.
        let history = messages.filter { !$0.isError }
            .map { AIMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
        approxTokens = (AIService.systemPrompt(state: state).count
                        + history.reduce(0) { $0 + $1.text.count }) / 4
        do {
            // A placeholder the reply streams into (Ollama); finalized with the actions.
            let placeholder = Msg(role: .assistant, text: "")
            messages.append(placeholder)
            let pid = placeholder.id
            let turn = try await AIService.send(history: history, state: state) { [weak self] partial in
                guard let self, let i = self.messages.firstIndex(where: { $0.id == pid }) else { return }
                self.messages[i].text = partial
            }
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                messages[i].text = turn.reply
                messages[i].actions = turn.actions
            }
        } catch {
            // Drop the empty placeholder (if it never received a delta) and show the error.
            if let last = messages.last, last.role == .assistant, last.text.isEmpty, last.actions.isEmpty {
                messages.removeLast()
            }
            messages.append(Msg(role: .assistant, text: error.localizedDescription, isError: true))
        }
        sending = false
    }

    func apply(_ action: AIAction, messageID: UUID, state: AppState) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].results[action.id] = AIActionRunner.apply(action, state: state)
    }
    func skip(_ action: AIAction, messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].skipped.insert(action.id)
    }
    func applyAll(messageID: UUID, state: AppState) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        for a in messages[i].actions where messages[i].results[a.id] == nil && !messages[i].skipped.contains(a.id) {
            messages[i].results[a.id] = AIActionRunner.apply(a, state: state)
        }
    }
}

// MARK: - Context-aware starter prompts (empty-state suggestions)

struct StarterPrompt: Identifiable {
    let id = UUID()
    let title: String       // shown on the chip
    let detail: String      // small subtitle
    let prompt: String      // the message sent when tapped
    let symbol: String
    let contextTag: String? // e.g. "Canvas"
    var featured = false
}

@MainActor
enum Starters {
    static func suggestions(state: AppState) -> [StarterPrompt] {
        var out: [StarterPrompt] = []
        let d = state.data
        let openAssignments = d.assignments.filter { $0.status != .done }

        if CanvasService.hasToken && !openAssignments.isEmpty {
            out.append(StarterPrompt(
                title: "Organize my assignments & rank each by urgency",
                detail: "\(openAssignments.count) open · sorts Now / This week / Later",
                prompt: "Organize my open assignments and rank each one by urgency (Now, This week, Later), then set the urgency on them.",
                symbol: "list.bullet.indent", contextTag: "Canvas", featured: true))
        }
        if !openAssignments.isEmpty {
            out.append(StarterPrompt(
                title: "What should I work on right now?",
                detail: "Picks the single next task from deadlines",
                prompt: "Given my open assignments and deadlines, what is the single most important thing to work on right now, and why?",
                symbol: "clock", contextTag: nil))
            let examSoon = openAssignments.contains { a in
                let soon = (a.daysUntilDue ?? 99) <= 7
                let isExam = a.title.localizedCaseInsensitiveContains("exam")
                    || a.title.localizedCaseInsensitiveContains("midterm")
                    || a.title.localizedCaseInsensitiveContains("final")
                return soon && isExam
            }
            if examSoon {
                out.append(StarterPrompt(
                    title: "Plan study blocks before my next exam",
                    detail: "Fits focus sessions around your deadlines",
                    prompt: "Plan a set of study blocks leading up to my next exam and schedule them.",
                    symbol: "calendar", contextTag: nil))
            }
        }
        if let latest = d.notes.sorted(by: { $0.updatedAt > $1.updatedAt }).first, !latest.body.isEmpty {
            out.append(StarterPrompt(
                title: "Turn my latest note into flashcards",
                detail: "“\(latest.title.prefix(28))”",
                prompt: "Make flashcards from my note titled \"\(latest.title)\".",
                symbol: "rectangle.on.rectangle.angled", contextTag: nil))
        }
        out.append(StarterPrompt(
            title: "Triage a syllabus I'll paste",
            detail: "Extracts assignments + dates into StudyBar",
            prompt: "I'll paste a course syllabus. Extract the assignments, due dates and readings and add them to StudyBar.",
            symbol: "doc.text.magnifyingglass", contextTag: nil))
        return out
    }
}

// MARK: - Assignment urgency label (for UI badges)

extension Assignment {
    var urgencyLabel: String? {
        switch urgency {
        case 2: return "Now"
        case 1: return "This week"
        case 0: return "Later"
        default: return nil
        }
    }
}

// MARK: - Native tool-use (cloud engines)
//
// Cloud providers expose a real tool-calling API, so instead of asking the model to
// emit a JSON envelope in text (fragile on weak models) we hand it typed tools. Read
// tools run in-loop and their results are fed back as tool_result; write tools are NOT
// executed — they're surfaced as proposed AIActions (StudyBar never auto-writes), which
// terminates the turn. Output is the same AITurn the UI already renders.

/// One tool exposed to a provider's native tool-calling API.
struct AITool {
    let name: String
    let description: String
    let schema: [String: Any]   // JSON Schema for the input object
}

enum AIToolCatalog {
    // Schema primitives.
    private static let S: [String: Any] = ["type": "string"]
    private static let I: [String: Any] = ["type": "integer"]
    private static let N: [String: Any] = ["type": "number"]
    private static let B: [String: Any] = ["type": "boolean"]
    private static func arr(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    private static func obj(_ props: [(String, [String: Any])], _ required: [String] = []) -> [String: Any] {
        var p: [String: Any] = [:]; for (k, v) in props { p[k] = v }
        return ["type": "object", "properties": p, "required": required]
    }
    private static func tool(_ name: String, _ desc: String,
                             _ props: [(String, [String: Any])] = [], _ required: [String] = []) -> AITool {
        AITool(name: name, description: desc, schema: obj(props, required))
    }

    static let reads: [AITool] = [
        tool("get_note", "Return the title and body of the best-matching note.", [("query", S)], ["query"]),
        tool("list_notes", "List all note titles."),
        tool("list_assignments", "List assignments with status, due date and urgency. Set include='done' to include completed ones.", [("include", S)]),
        tool("list_todos", "List open to-dos."),
        tool("list_reading", "List books with page progress."),
        tool("list_decks", "List flashcard decks with card counts."),
        tool("list_citations", "List saved references/citations."),
        tool("list_classes", "List the weekly class schedule."),
        tool("list_links", "List saved quick links."),
        tool("get_grades", "GPA and current standing; pass a course for its what-if breakdown.", [("course", S)]),
        tool("get_study_stats", "Time studied today and this week, by course, study streak, pomodoros, and flashcard retention."),
        tool("get_course", "Everything for one course: grade, open/done assignments, notes, hours logged, classes.", [("course", S)], ["course"]),
        tool("get_semester", "The current term's name, week number and percent complete."),
        tool("list_snippets", "Saved text-snippet keywords."),
        tool("get_scratchpad", "The scratchpad contents."),
        tool("search", "Search across notes, tasks, reading and citations.", [("query", S)], ["query"]),
    ]

    static let writes: [AITool] = [
        tool("add_task", "Add a task or assignment (a task is one with no due date).", [("text", S), ("course", S), ("dueInDays", I)], ["text"]),
        tool("add_note", "Save a note.", [("title", S), ("text", S), ("course", S)], ["text"]),
        tool("create_assignment", "Add an assignment.", [("title", S), ("course", S), ("dueInDays", I), ("points", N)], ["title"]),
        tool("complete_assignment", "Mark an assignment done by title.", [("title", S)], ["title"]),
        tool("update_assignment", "Update an assignment by title.", [("title", S), ("dueInDays", I), ("submitted", B), ("done", B)], ["title"]),
        tool("prioritize_assignments", "Rank assignments by urgency (StudyBar computes the ranking — don't guess)."),
        tool("plan_study_block", "Propose study sessions.", [("sessions", arr(obj([("title", S), ("dueInDays", I), ("minutes", I), ("course", S)], ["title", "dueInDays"])))], ["sessions"]),
        tool("make_flashcards", "Make flashcards from the student's material.", [("deck", S), ("course", S), ("cards", arr(obj([("front", S), ("back", S)], ["front", "back"])))], ["cards"]),
        tool("start_pomodoro", "Start a focus session.", [("minutes", I), ("label", S)]),
        tool("add_reading", "Add a book to the reading tracker.", [("title", S), ("author", S), ("totalPages", I), ("course", S)], ["title"]),
        tool("log_reading", "Log reading progress to a page.", [("title", S), ("toPage", I)], ["title", "toPage"]),
        tool("add_citation", "Add a citation/reference.", [("title", S), ("authors", arr(S)), ("year", S), ("doi", S), ("url", S), ("container", S)], ["title"]),
        tool("add_link", "Add a quick link.", [("title", S), ("url", S), ("course", S)], ["title", "url"]),
        tool("add_snippet", "Add a text snippet.", [("keyword", S), ("title", S), ("body", S)], ["keyword", "title", "body"]),
        tool("add_class", "Add a weekly class session.", [("title", S), ("weekday", I), ("start", S), ("end", S), ("course", S), ("room", S)], ["title", "weekday", "start", "end"]),
        tool("add_grade_item", "Add a weighted grade component to a course.", [("course", S), ("name", S), ("weight", N), ("score", N), ("graded", B)], ["course", "name", "weight"]),
        tool("create_course", "Create a course.", [("name", S), ("code", S)], ["name"]),
    ]

    static let all: [AITool] = reads + writes
    static var byName: [String: AITool] { Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }) }

    /// Anthropic `tools` payload.
    static var anthropic: [[String: Any]] {
        all.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
    }
    /// OpenAI `tools` payload (function-calling shape).
    static var openai: [[String: Any]] {
        all.map { ["type": "function",
                   "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] }
    }
}

extension AnthropicProvider {
    struct ToolUse { let id: String; let name: String; let input: [String: Any] }

    /// One tool-enabled round-trip. `messages` are Anthropic content-block messages.
    func completeTools(system: String, messages: [[String: Any]],
                       tools: [[String: Any]]) async throws -> (text: String, toolUses: [ToolUse]) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model, "max_tokens": 2048, "system": system,
            "tools": tools, "messages": messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (o?["error"] as? [String: Any])?["message"] as? String
            throw AIError.http(code, msg ?? (String(data: data, encoding: .utf8) ?? ""))
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return AnthropicProvider.parseContent(obj?["content"] as? [[String: Any]] ?? [])
    }

    /// Pure extraction of text + tool_use blocks from an Anthropic `content` array.
    static func parseContent(_ blocks: [[String: Any]]) -> (text: String, toolUses: [ToolUse]) {
        var text = ""
        var uses: [ToolUse] = []
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String { text += (text.isEmpty ? "" : "\n") + t }
            case "tool_use":
                if let id = b["id"] as? String, let name = b["name"] as? String {
                    uses.append(ToolUse(id: id, name: name, input: b["input"] as? [String: Any] ?? [:]))
                }
            default: break
            }
        }
        return (text, uses)
    }
}

extension OpenAIProvider {
    struct ToolUse { let id: String; let name: String; let input: [String: Any] }

    /// One tool-enabled round-trip. `messages` are OpenAI chat messages. Returns the raw
    /// assistant message (to replay verbatim), its text, and any tool calls.
    func completeTools(messages: [[String: Any]],
                       tools: [[String: Any]]) async throws -> (assistant: [String: Any], text: String, toolUses: [ToolUse]) {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "max_tokens": 2048, "messages": messages, "tools": tools]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw AIError.http(code, ((o?["error"] as? [String: Any])?["message"] as? String) ?? (String(data: data, encoding: .utf8) ?? ""))
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        let text = msg["content"] as? String ?? ""
        var uses: [ToolUse] = []
        for tc in (msg["tool_calls"] as? [[String: Any]] ?? []) {
            guard let id = tc["id"] as? String,
                  let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
            let argStr = fn["arguments"] as? String ?? "{}"
            let input = (try? JSONSerialization.jsonObject(with: Data(argStr.utf8))) as? [String: Any] ?? [:]
            uses.append(ToolUse(id: id, name: name, input: input))
        }
        return (msg, text, uses)
    }
}

extension AIService {
    /// Cloud tool-use loop: reads execute + feed back; writes become proposed actions.
    static func sendWithTools(provider: AnthropicProvider, history: [AIMessage], state: AppState) async throws -> AITurn {
        let system = toolSystemPrompt(state: state)
        let tools = AIToolCatalog.anthropic
        var messages: [[String: Any]] = history.map {
            ["role": $0.role.rawValue, "content": [["type": "text", "text": $0.text]]]
        }
        var replyText = ""
        for _ in 0..<maxRoundsTool {
            let (text, toolUses) = try await provider.completeTools(system: system, messages: messages, tools: tools)
            if !text.isEmpty { replyText = text }
            let writes = toolUses.filter { AIProtocol.writeTools.contains($0.name) }
            let reads  = toolUses.filter { AIProtocol.readTools.contains($0.name) }
            // Writes proposed, or nothing left to read → terminal.
            if !writes.isEmpty || reads.isEmpty {
                return present(AITurn(reply: replyText, actions: writes.map { proposedAction($0.name, $0.input) }))
            }
            // Reads only → replay the assistant turn, run them, feed tool_result, continue.
            var assistant: [[String: Any]] = []
            if !text.isEmpty { assistant.append(["type": "text", "text": text]) }
            assistant += toolUses.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] }
            messages.append(["role": "assistant", "content": assistant])
            let results: [[String: Any]] = reads.map { tu in
                ["type": "tool_result", "tool_use_id": tu.id,
                 "content": AIReader.one(AIAction(tool: tu.name, label: "", args: tu.input), state: state)]
            }
            messages.append(["role": "user", "content": results])
        }
        return present(AITurn(reply: replyText, actions: []))
    }

    /// OpenAI variant of the tool-use loop (same guarantees; OpenAI message shape).
    static func sendWithToolsOpenAI(provider: OpenAIProvider, history: [AIMessage], state: AppState) async throws -> AITurn {
        let tools = AIToolCatalog.openai
        var messages: [[String: Any]] = [["role": "system", "content": toolSystemPrompt(state: state)]]
        messages += history.map { ["role": $0.role.rawValue, "content": $0.text] }
        var replyText = ""
        for _ in 0..<maxRoundsTool {
            let (assistant, text, toolUses) = try await provider.completeTools(messages: messages, tools: tools)
            if !text.isEmpty { replyText = text }
            let writes = toolUses.filter { AIProtocol.writeTools.contains($0.name) }
            let reads  = toolUses.filter { AIProtocol.readTools.contains($0.name) }
            if !writes.isEmpty || reads.isEmpty {
                return present(AITurn(reply: replyText, actions: writes.map { proposedAction($0.name, $0.input) }))
            }
            messages.append(assistant)   // replay the assistant turn (carries the tool_calls)
            for tu in reads {
                messages.append(["role": "tool", "tool_call_id": tu.id,
                                 "content": AIReader.one(AIAction(tool: tu.name, label: "", args: tu.input), state: state)])
            }
        }
        return present(AITurn(reply: replyText, actions: []))
    }

    static var maxRoundsTool: Int { 5 }

    /// Build a proposed write action from a tool call, with a human label.
    static func proposedAction(_ tool: String, _ input: [String: Any]) -> AIAction {
        AIAction(tool: tool, label: AIAction(tool: tool, label: "", args: input).autoLabel, args: input)
    }

    /// System prompt for the native-tool path — same guardrail as the JSON prompt, but
    /// the tools carry their own schemas so there's no JSON-envelope protocol to explain.
    static func toolSystemPrompt(state: AppState) -> String {
        """
        You are StudyBar Copilot, an assistant built into a macOS menu-bar study app.

        YOUR JOB: organize the student's own study data and help them operate StudyBar —
        rank and schedule assignments, plan focus sessions, turn the student's own notes
        into flashcards, triage a pasted syllabus, tidy tasks.

        HARD RULE — you do NOT tutor. Never produce NEW subject-matter explanations or
        answers from your own knowledge, solve problems, or write essays/assignments. If
        asked to teach or answer, briefly decline and offer to organize instead.

        BUT reshaping the student's OWN material IS organizing, not tutoring — always
        allowed, even for academic content: turning a note/text they give you into
        flashcards, summarizing their note, tagging, or building tasks/a schedule from it.
        Transform what they give you = YES; teach them something new = NO.

        HOW YOU WORK — use your tools, don't describe them:
        - Read tools (get_/list_/search) look things up instantly and privately, no confirmation.
        - Write tools (add_/create_/make_/plan_/…) PROPOSE a change: each is shown to the
          student as a confirm card and only applied on their tap. Call the tool; don't
          paste the change as prose.
        - If the student included the material in their message, act on it directly — don't
          look it up. Only read when you genuinely need data they didn't provide.
        - When they ask to save / add / make / summarize / rank, call at least one write tool.
        - Never invent data you didn't read or the student didn't give you.

        CURRENT STATE (a summary — use the read tools for detail):
        \(StudyContext.snapshot(state: state))
        """
    }
}

// MARK: - Headless self-test for native tool-use (StudyBar --ai-selftest)

enum AIToolSelfTest {
    @MainActor static func run() -> Int32 {
        var fail = 0
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "  ok   " : "FAIL   ") + name); if !cond { fail += 1 }
        }

        // 1. Catalog covers exactly the read + write tools the app understands.
        let names = Set(AIToolCatalog.all.map { $0.name })
        check("catalog = read+write tools", names == AIProtocol.readTools.union(AIProtocol.writeTools))
        check("catalog count 33", AIToolCatalog.all.count == 33)

        // 2. Every tool has a non-empty description and an object schema.
        check("all tools have description", AIToolCatalog.all.allSatisfy { !$0.description.isEmpty })
        check("all schemas are objects", AIToolCatalog.all.allSatisfy { ($0.schema["type"] as? String) == "object" })

        // 3. Anthropic payload shape.
        let ap = AIToolCatalog.anthropic
        check("anthropic payload count", ap.count == 33)
        check("anthropic payload keys", ap.allSatisfy { $0["name"] != nil && $0["description"] != nil && $0["input_schema"] != nil })

        // 4. A required-arg schema is right (create_course requires name).
        if let cc = AIToolCatalog.byName["create_course"] {
            check("create_course requires name", (cc.schema["required"] as? [String]) == ["name"])
        } else { check("create_course present", false) }

        // 5. parseContent extracts interleaved text + tool_use.
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "Sure — adding that."],
            ["type": "tool_use", "id": "tu_1", "name": "add_task", "input": ["text": "read chapter 3", "dueInDays": 2]],
        ]
        let parsed = AnthropicProvider.parseContent(blocks)
        check("parseContent text", parsed.text == "Sure — adding that.")
        check("parseContent one tool_use", parsed.toolUses.count == 1 && parsed.toolUses.first?.name == "add_task")
        check("parseContent input carried", (parsed.toolUses.first?.input["text"] as? String) == "read chapter 3")

        // 5b. OpenAI payload shape (function-calling).
        let op = AIToolCatalog.openai
        check("openai payload count", op.count == 33)
        check("openai payload shape", op.allSatisfy {
            ($0["type"] as? String) == "function"
            && (($0["function"] as? [String: Any])?["name"]) != nil
            && (($0["function"] as? [String: Any])?["parameters"]) != nil
        })

        // 6. A write tool_use maps to a proposed action with a real label.
        let a = AIService.proposedAction("create_assignment", ["title": "Lab report"])
        check("proposedAction label", a.label == "Add assignment: Lab report")
        check("proposedAction args", (a.args["title"] as? String) == "Lab report")

        // 7. Read/write partition (routing used by the loop).
        check("add_task is a write", AIProtocol.writeTools.contains("add_task"))
        check("get_note is a read", AIProtocol.readTools.contains("get_note"))

        // 7b. Urgency ranking factors the ecosystem risk bump (low grade / neglected course).
        check("urgency: far due, no risk → Later", AIActionRunner.urgencyScore(days: 10, points: nil) == 0)
        check("urgency: far due + risk bump → This week", AIActionRunner.urgencyScore(days: 10, points: nil, riskBump: 1.5) == 1)
        check("urgency: imminent → Now", AIActionRunner.urgencyScore(days: 1, points: nil) == 2)

        // 8. Streaming reply extraction from a partial JSON envelope.
        check("replySoFar mid-stream", AIProtocol.replySoFar("{\"reads\":[],\"reply\":\"Made 3 cards.") == "Made 3 cards.")
        check("replySoFar complete", AIProtocol.replySoFar("{\"reads\":[],\"reply\":\"Done.\",\"actions\":[]}") == "Done.")
        check("replySoFar escapes", AIProtocol.replySoFar("{\"reply\":\"a \\\"b\\\" c\\nd\"}") == "a \"b\" c\nd")
        check("replySoFar not started", AIProtocol.replySoFar("{\"reads\":[{\"tool\":\"get_note\"") == nil)

        // 9. Ship-minimal starter set: long tail hidden, core + locked shown.
        let starterHidden = ModulePrefs.starterHidden()
        check("starter hides the long tail (insights)", starterHidden.contains("insights"))
        check("starter shows a core module (assignments)", !starterHidden.contains("assignments"))
        check("starter never hides today/settings", !starterHidden.contains("today") && !starterHidden.contains("settings"))

        print(fail == 0 ? "AI TOOL SELFTEST: ALL PASS" : "AI TOOL SELFTEST: \(fail) FAILURE(S)")
        return fail == 0 ? 0 : 1
    }
}

/// End-to-end assistant harness (StudyBar --ai-ask "question"). Runs the full pipeline
/// against the active engine + the real data — proving the reads/context work live.
enum AIAskTest {
    @MainActor static func run(_ q: String, state: AppState) async -> Int32 {
        print("ENGINE: \(AIConfig.mode.title)\nQ: \(q)\n")
        do {
            let turn = try await AIService.send(history: [AIMessage(role: .user, text: q)], state: state) { p in
                print("  …\(p)")
            }
            print("\nREPLY: \(turn.reply)")
            if !turn.actions.isEmpty { print("ACTIONS: " + turn.actions.map { $0.label }.joined(separator: " | ")) }
            return 0
        } catch {
            print("ERROR: \(error.localizedDescription)"); return 1
        }
    }
}

/// Prints the deterministic daily brief, then runs "plan my day" through the live engine
/// against the real data (StudyBar --ai-plan).
enum AIPlanTest {
    @MainActor static func run(state: AppState) async -> Int32 {
        print("=== DAILY BRIEF (deterministic) ===\n\(DailyPlan.brief(state.data))\n")
        print("=== PLAN (\(AIConfig.mode.title)) ===")
        do {
            let turn = try await AIService.send(history: [AIMessage(role: .user, text: DailyPlan.prompt(state.data))],
                                                state: state) { p in print("  …\(p)") }
            print("\nREPLY: \(turn.reply)")
            if !turn.actions.isEmpty { print("ACTIONS: " + turn.actions.map { $0.label }.joined(separator: " | ")) }
            return 0
        } catch { print("ERROR: \(error.localizedDescription)"); return 1 }
    }
}

/// Live smoke test for Ollama streaming (StudyBar --ollama-stream-test). Needs Ollama up.
enum OllamaStreamTest {
    @MainActor static func run() async -> Int32 {
        let p = OllamaProvider(host: AIConfig.ollamaHost, model: AIConfig.ollamaModel)
        let sys = "You are a test. Reply with ONLY one JSON object and nothing else: {\"reads\":[],\"reply\":\"<a one-sentence greeting>\",\"actions\":[]}"
        print("streaming from Ollama (\(AIConfig.ollamaModel))…")
        var deltas = 0
        do {
            let raw = try await p.completeStreaming(system: sys, messages: [AIMessage(role: .user, text: "say hi")]) { partial in
                deltas += 1
                print("  delta \(deltas): \(partial)")
            }
            print("PARSED REPLY: \(AIProtocol.parse(raw).reply)")
            print(deltas > 1 ? "OLLAMA STREAM TEST: PASS (\(deltas) deltas)" : "OLLAMA STREAM TEST: WARN (\(deltas) delta)")
            return deltas >= 1 ? 0 : 1
        } catch {
            print("OLLAMA STREAM TEST: FAIL — \(error.localizedDescription)")
            return 1
        }
    }
}
