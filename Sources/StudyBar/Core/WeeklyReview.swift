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
