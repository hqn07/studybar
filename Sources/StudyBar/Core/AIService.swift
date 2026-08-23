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
        get { AIMode(rawValue: UserDefaults.standard.string(forKey: "aiMode") ?? "") ?? .off }
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
        get { UserDefaults.standard.string(forKey: "aiOllamaModel").flatMap { $0.isEmpty ? nil : $0 } ?? "llama3.1" }
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
        let body: [String: Any] = ["model": model, "messages": msgs, "stream": false]
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
}

/// A single assistant turn: prose to show + zero or more proposed actions.
struct AITurn {
    let reply: String
    let actions: [AIAction]
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

    /// Run one assistant turn over the current conversation.
    static func send(history: [AIMessage], state: AppState) async throws -> AITurn {
        guard let provider = makeProvider() else { throw AIError.notConfigured }
        let system = systemPrompt(state: state)
        let raw = try await provider.complete(system: system, messages: history)
        return AIProtocol.parse(raw)
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

        HOW TO REPLY: Always answer with a single JSON object and nothing else:
        {
          "reply": "one or two short sentences to show the student",
          "actions": [ { "tool": "<name>", "label": "<what tapping this will do>", "args": { ... } } ]
        }
        Use "actions" for anything that changes StudyBar; leave it [] for a plain answer.
        The student confirms every action before it happens, so propose freely but keep
        each action's "label" concrete. Never invent data you weren't given.

        TOOLS:
        \(AIProtocol.toolCatalog)

        CURRENT STUDYBAR STATE (read-only context):
        \(StudyContext.snapshot(state: state))
        """
    }
}

// MARK: - Wire protocol (parse the model's JSON)

enum AIProtocol {
    static let toolCatalog = """
    - add_task        args: { "text": string, "course"?: string, "dueInDays"?: int }
    - add_note        args: { "title"?: string, "text": string, "course"?: string }
    - create_assignment args: { "title": string, "course"?: string, "dueInDays"?: int, "points"?: number }
    - prioritize_assignments  args: {}   (StudyBar computes urgency from due date × weight × submission — do not guess ranks)
    - plan_study_block  args: { "sessions": [ { "title": string, "dueInDays": int, "minutes"?: int, "course"?: string } ] }
    - make_flashcards args: { "deck"?: string, "course"?: string, "cards": [ { "front": string, "back": string } ] }
    - start_pomodoro  args: { "minutes"?: int, "label"?: string }
    """

    /// Extract the model's JSON object (tolerating prose or ``` fences around it).
    static func parse(_ raw: String) -> AITurn {
        guard let json = extractJSONObject(raw),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return AITurn(reply: raw.trimmingCharacters(in: .whitespacesAndNewlines), actions: [])
        }
        let reply = (obj["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawActions = obj["actions"] as? [[String: Any]] ?? []
        let actions: [AIAction] = rawActions.compactMap { a in
            guard let tool = a["tool"] as? String else { return nil }
            let label = (a["label"] as? String) ?? tool
            let args = (a["args"] as? [String: Any]) ?? [:]
            return AIAction(tool: tool, label: label, args: args)
        }
        return AITurn(reply: reply.isEmpty ? "Done." : reply, actions: actions)
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
        return lines.joined(separator: "\n")
    }
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
                var todo = TodoItem(text: title, courseID: AppActions.courseID(named: s["course"] as? String))
                if let d = (s["dueInDays"] as? Int) ?? (s["dueInDays"] as? Double).map({ Int($0) }) {
                    todo.due = Calendar.current.date(byAdding: .day, value: d, to: .now)
                }
                todo.priority = 2
                state.data.todos.append(todo)
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

        default:
            return "Unknown action “\(a.tool)”."
        }
    }

    /// Deterministic urgency ranking — StudyBar computes it, the model never guesses.
    /// Score blends days-until-due (dominant) with grade weight → urgency 0/1/2.
    /// Imminent (≤3 days, incl. today/overdue) is "Now" regardless of weight.
    static func urgencyScore(days: Int, points: Double?) -> Int {
        var score = 0.0
        if days <= 3 { score += 3 }          // overdue … due in 3 days → Now baseline
        else if days <= 7 { score += 1.5 }   // this week
        else if days <= 14 { score += 0.5 }  // next couple weeks
        if let p = points { if p >= 50 { score += 1 } else if p >= 20 { score += 0.5 } }
        return score >= 3 ? 2 : (score >= 1.5 ? 1 : 0)   // 2 Now · 1 This week · 0 Later
    }

    @discardableResult
    static func prioritize(state: AppState) -> Int {
        var count = 0
        for i in state.data.assignments.indices {
            let a = state.data.assignments[i]
            guard a.status != .done, !a.submitted else {
                state.data.assignments[i].urgency = 0     // done/submitted → lowest
                continue
            }
            state.data.assignments[i].urgency = urgencyScore(days: a.daysUntilDue ?? 999, points: a.points)
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

    var isEmpty: Bool { messages.isEmpty }

    func clear() { messages.removeAll() }

    func send(_ text: String, state: AppState) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        messages.append(Msg(role: .user, text: t))
        sending = true
        // History excludes error bubbles so a failed turn doesn't poison context.
        let history = messages.filter { !$0.isError }
            .map { AIMessage(role: $0.role == .user ? .user : .assistant, text: $0.text) }
        do {
            let turn = try await AIService.send(history: history, state: state)
            messages.append(Msg(role: .assistant, text: turn.reply, actions: turn.actions))
        } catch {
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
