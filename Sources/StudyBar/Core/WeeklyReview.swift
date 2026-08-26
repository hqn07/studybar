import Foundation

/// Builds a weekly-review prompt for the assistant from real StudyBar data —
/// study time, streak, time-by-course, assignments, flashcard retention, reading.
/// The facts are computed deterministically here; the model only narrates + plans.
enum WeeklyReview {

    /// Human-readable, model-friendly summary of the past week.
    static func summary(_ data: AppData) -> String {
        var lines: [String] = []

        let wkMin = StudyStats.secondsThisWeek(data) / 60
        let last7 = StudyStats.last7Days(data)
        let daysStudied = last7.filter { $0.minutes > 0 }.count
        lines.append("Study time this week: \(fmt(wkMin)) across \(daysStudied)/7 days.")
        lines.append("Last 7 days, minutes/day (oldest→newest): " + last7.map { "\($0.minutes)" }.joined(separator: ", ") + ".")
        lines.append("Study streak: \(StudyStats.currentStreak(data)) days (longest \(StudyStats.longestStreak(data))).")

        let byCourse = StudyStats.weekByCourse(data)
        if !byCourse.isEmpty {
            let parts = byCourse.prefix(6).map { row in
                "\(courseName(row.courseID, data)) \(fmt(row.seconds / 60))"
            }
            lines.append("Time by course this week: " + parts.joined(separator: "; ") + ".")
        }

        let open = data.assignments.filter { $0.status != .done }
        let overdue = open.filter { $0.isOverdue }.count
        lines.append("Assignments: \(open.count) open, \(overdue) overdue.")
        let next7 = open.compactMap { a -> (Date, String)? in
            guard let d = a.daysUntilDue, d >= 0, d <= 7, let due = a.due else { return nil }
            let code = data.courses.first { $0.id == a.courseID }?.code ?? ""
            let title = a.title.isEmpty ? "Untitled" : a.title
            return (due, "\(title)\(code.isEmpty ? "" : " [\(code)]") due \(due.dayMonth)")
        }.sorted { $0.0 < $1.0 }.map(\.1)
        if !next7.isEmpty {
            lines.append("Due in the next 7 days: " + next7.prefix(10).joined(separator: "; ") + ".")
        }

        if let ret = StudyStats.flashcardRetention(data) {
            lines.append("Flashcards: \(Int((ret * 100).rounded()))% retention, \(StudyStats.cardsDueToday(data)) due now, \(data.flashcards.count) cards total.")
        }
        if !data.reading.isEmpty {
            lines.append("Reading: \(StudyStats.pagesThisWeek(data)) pages this week, reading streak \(StudyStats.readingStreak(data)) days.")
        }

        return lines.joined(separator: "\n")
    }

    /// Full prompt: facts + the retrospective/plan instruction.
    static func prompt(_ data: AppData) -> String {
        """
        Here is my study week from StudyBar:
        \(summary(data))

        Give me a weekly review: 2–3 honest but encouraging sentences on how the \
        week went — call out wins and any slippage (missed days, under-studied \
        courses, overdue work). Then a short, prioritized plan for next week that \
        focuses on what's overdue or due soon. Propose a few concrete study blocks \
        or tasks I can add.
        """
    }

    private static func courseName(_ id: UUID?, _ data: AppData) -> String {
        data.courses.first { $0.id == id }?.name ?? "Unassigned"
    }
    private static func fmt(_ min: Int) -> String { min >= 60 ? "\(min / 60)h \(min % 60)m" : "\(min)m" }
}

/// Builds a "plan my day" prompt from real data — the facts (deadlines, each item's
/// course grade + how much that course was studied this week, effort so far, GPA) are
/// computed here so the model prioritizes by *risk*, not just the nearest deadline.
enum DailyPlan {
    static func brief(_ data: AppData) -> String {
        var lines: [String] = []
        let now = Date()
        lines.append("Today: \(now.formatted(.dateTime.weekday(.wide).month().day())).")

        let todayMin = StudyStats.secondsToday(data) / 60
        let weekMin = StudyStats.secondsThisWeek(data) / 60
        lines.append("Studied today \(fmt(todayMin)); this week \(fmt(weekMin)); streak \(StudyStats.currentStreak(data))d.")

        let graded = data.courses.filter { $0.gradePoints != nil }
        let den = graded.reduce(0.0) { $0 + $1.credits }
        if den > 0 {
            let num = graded.reduce(0.0) { $0 + ($1.gradePoints ?? 0) * $1.credits }
            lines.append(String(format: "Projected GPA: %.2f.", num / den))
        }
        if StudyStats.cardsDueToday(data) > 0 { lines.append("Flashcards due today: \(StudyStats.cardsDueToday(data)).") }

        // Minutes-per-course this week, for the neglect signal.
        var weekByCourse: [UUID: Int] = [:]
        for row in StudyStats.weekByCourse(data) { if let id = row.courseID { weekByCourse[id] = row.seconds / 60 } }

        // Open work due within ~10 days (plus anything overdue): overdue first, then soonest.
        let candidates = data.assignments.filter { $0.status != .done }
            .filter { ($0.daysUntilDue ?? 99) <= 10 }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        if candidates.isEmpty {
            lines.append("No assignments due in the next 10 days.")
        } else {
            lines.append("Open work (soonest first) — with each course's grade + minutes studied this week:")
            for a in candidates.prefix(12) {
                let c = data.courses.first { $0.id == a.courseID }
                let code = c?.code.isEmpty == false ? c!.code : (c?.name ?? "—")
                let grade = c.flatMap { $0.grade.isEmpty ? nil : "grade \($0.grade)" } ?? "no grade yet"
                let due = a.daysUntilDue.map { $0 == 0 ? "due today" : ($0 < 0 ? "\(-$0)d overdue" : "in \($0)d") } ?? "no due date"
                let effort = c.map { "studied \(weekByCourse[$0.id] ?? 0)m this week" } ?? ""
                let pts = a.points.map { ", \(Int($0))pts" } ?? ""
                lines.append("  • \(a.title.isEmpty ? "Untitled" : a.title) [\(code), \(grade)] — \(due)\(pts); \(effort)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func prompt(_ data: AppData) -> String {
        """
        Here's my day from StudyBar:
        \(brief(data))

        Give me a short, prioritized plan for TODAY. Lead with what's most at risk — \
        overdue first, then soonest due, weighting harder toward courses where my grade \
        is lower or I've studied less this week. Then propose 2–4 concrete study blocks or \
        tasks I can add. Keep it tight and specific to these items.
        """
    }

    private static func fmt(_ min: Int) -> String { min >= 60 ? "\(min / 60)h \(min % 60)m" : "\(min)m" }
}
