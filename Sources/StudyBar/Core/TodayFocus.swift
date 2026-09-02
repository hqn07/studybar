import Foundation

/// The intelligence behind the Today hero: rank open work by how much it actually deserves
/// a head start — so a heavy project a week out beats a trivial task due tomorrow.
///
/// The ranking is a deterministic heuristic (works offline, no model needed). When an AI
/// engine is configured, `aiLine` writes the hero's one-liner on top; the heuristic
/// `reason` is the always-available fallback.
enum TodayFocus {
    // Title keywords that signal a heavy, plan-ahead deliverable vs. a quick check-the-box item.
    private static let heavy = ["project", "essay", "paper", "thesis", "exam", "midterm",
                                "final", "presentation", "portfolio", "research", "report",
                                "capstone", "proposal", "draft", "lab report", "dissertation"]
    private static let lightWords = ["quiz", "reading", "attendance", "survey", "check-in",
                                     "checkin", "participation", "watch", "video", "discussion",
                                     "warmup", "warm-up", "icebreaker", "syllabus", "poll"]

    /// 0.2 (trivial) · 0.45 (default) · 0.9 (heavy) — the dominant term in the score.
    static func weight(_ title: String) -> Double {
        let t = title.lowercased()
        if heavy.contains(where: { t.contains($0) }) { return 0.9 }
        if lightWords.contains(where: { t.contains($0) }) { return 0.2 }
        return 0.45
    }

    /// How much this item deserves attention now. Size dominates; urgency is scaled by size
    /// so a big-but-later item outranks a trivial-but-imminent one — the whole point.
    static func importance(_ a: Assignment) -> Double {
        let base = weight(a.title)
        let points = a.points.map { min(0.6, $0 / 100 * 0.6) } ?? 0
        let days = a.daysUntilDue ?? 99
        let proximity = days < 0 ? 0.6 : max(0, (14.0 - Double(days)) / 14.0) * 0.8
        return base * 2 + points + base * proximity
    }

    /// The single most-important open item worth featuring (due within three weeks, or overdue).
    static func top(_ data: AppData) -> Assignment? {
        data.assignments
            .filter { $0.status != .done && ($0.daysUntilDue ?? 999) <= 21 }
            .max { importance($0) < importance($1) }
    }

    /// Deterministic one-liner for the hero — used offline and as the AI fallback.
    static func reason(_ a: Assignment) -> String {
        let w = weight(a.title)
        let days = a.daysUntilDue ?? 99
        let due = days < 0 ? "\(-days) day\(days == -1 ? "" : "s") overdue"
                : days == 0 ? "due today"
                : days == 1 ? "due tomorrow"
                : "due in \(days) days"
        if w >= 0.9 {
            return days >= 2
                ? "A heavy one, and the rest of your week is lighter — start it now so it doesn't loom (\(due))."
                : "A big task and it's \(due) — protect real time for this."
        }
        if days < 0 { return "Past due — clear it before it stacks up (\(due))." }
        if days == 0 { return "Due today — worth knocking out first." }
        return "Next up on your plate, \(due)."
    }

    /// Open-work count per day for the next `days` days (index 0 = today) — the week-load strip.
    static func load(_ data: AppData, days: Int = 7) -> [Int] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: .now)
        var buckets = Array(repeating: 0, count: days)
        for a in data.assignments where a.status != .done {
            guard let due = a.due else { continue }
            let d = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: due)).day ?? -1
            if d >= 0 && d < days { buckets[d] += 1 }
        }
        return buckets
    }

    /// AI-written hero line (1–2 sentences). Returns nil when no engine is configured or the
    /// call fails — the caller falls back to `reason`. Never throws.
    @MainActor
    static func aiLine(for a: Assignment, data: AppData) async -> String? {
        guard AIConfig.isReady, let provider = AIService.makeProvider() else { return nil }
        let days = a.daysUntilDue ?? 99
        let dueStr = days == 0 ? "due today" : days < 0 ? "\(-days) days overdue" : "due in \(days) days"
        let system = """
        You are a calm study assistant inside a student app. In ONE or TWO short sentences, \
        tell the student why this item deserves attention now and nudge them to start. Be \
        specific and warm, not generic. No preamble, no lists, no markdown, under 220 characters.
        """
        let user = """
        Feature this item: "\(a.title)" — \(dueStr)\(a.points.map { ", \(Int($0)) points" } ?? "").
        My wider week for context:
        \(DailyPlan.brief(data))
        """
        // completePlain, not complete: Ollama's complete forces format:json and would return a
        // `{}` blob instead of a sentence.
        let text = try? await provider.completePlain(system: system, messages: [AIMessage(role: .user, text: user)])
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        // Defense in depth: if a model ignores the prose instruction (or a stray grammar
        // constraint) and emits a JSON blob, never show it in the hero — fall back to `reason`.
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return nil }
        return trimmed
    }
}
