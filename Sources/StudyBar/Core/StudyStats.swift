import Foundation

/// Derived study metrics for the Today dashboard and Insights.
enum StudyStats {
    private static var cal: Calendar { Calendar.current }

    /// Days (start-of-day) that had any logged study time.
    static func studyDays(_ data: AppData) -> Set<Date> {
        Set(data.timeEntries.map { cal.startOfDay(for: $0.date) })
    }

    /// Consecutive study days ending today or yesterday.
    static func currentStreak(_ data: AppData) -> Int {
        let days = studyDays(data)
        guard !days.isEmpty else { return 0 }
        let today = cal.startOfDay(for: .now)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }
        var cursor = days.contains(today) ? today : (days.contains(yesterday) ? yesterday : nil)
        guard var day = cursor else { return 0 }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        cursor = nil
        return count
    }

    static func longestStreak(_ data: AppData) -> Int {
        let days = studyDays(data).sorted()
        guard !days.isEmpty else { return 0 }
        var best = 1, run = 1
        for i in 1..<days.count {
            if let prev = cal.date(byAdding: .day, value: 1, to: days[i-1]), prev == days[i] {
                run += 1; best = max(best, run)
            } else { run = 1 }
        }
        return best
    }

    static func studiedToday(_ data: AppData) -> Bool {
        studyDays(data).contains(cal.startOfDay(for: .now))
    }

    static func secondsToday(_ data: AppData) -> Int {
        data.timeEntries.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.seconds }
    }

    static func secondsThisWeek(_ data: AppData) -> Int {
        data.timeEntries.filter { isThisWeek($0.date) }.reduce(0) { $0 + $1.seconds }
    }

    static func isThisWeek(_ d: Date) -> Bool {
        cal.isDate(d, equalTo: .now, toGranularity: .weekOfYear)
    }

    /// Seconds per course this week, sorted desc. courseID nil bucketed as "Unassigned".
    static func weekByCourse(_ data: AppData) -> [(courseID: UUID?, seconds: Int)] {
        var dict: [UUID?: Int] = [:]
        for e in data.timeEntries where isThisWeek(e.date) {
            dict[e.courseID, default: 0] += e.seconds
        }
        return dict.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Last 7 days (oldest→newest) study minutes, for a bar chart.
    static func last7Days(_ data: AppData) -> [(day: Date, minutes: Int)] {
        let today = cal.startOfDay(for: .now)
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let secs = data.timeEntries
                .filter { cal.isDate($0.date, inSameDayAs: day) }
                .reduce(0) { $0 + $1.seconds }
            return (day, secs / 60)
        }
    }

    // MARK: - Work finished
    //
    // What the app can honestly say about a week's studying. Time entries only exist if the
    // Pomodoro timer is used; reading stats only if books are tracked. Finishing assignments
    // and writing notes are what actually happen, so they are what gets counted.

    /// Days on which at least one assignment was completed.
    static func completionDays(_ data: AppData) -> Set<Date> {
        Set(data.assignments.compactMap { $0.completedAt }.map { cal.startOfDay(for: $0) })
    }

    static func completedThisWeek(_ data: AppData) -> Int {
        data.assignments.filter { $0.completedAt.map(isThisWeek) ?? false }.count
    }

    static func completedToday(_ data: AppData) -> Int {
        data.assignments.filter { $0.completedAt.map { cal.isDateInToday($0) } ?? false }.count
    }

    /// Consecutive days up to today with a completion. Today not counting yet doesn't break it —
    /// a streak shouldn't die at 00:01.
    static func completionStreak(_ data: AppData) -> Int {
        let days = completionDays(data)
        guard !days.isEmpty else { return 0 }
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var n = 0
        while days.contains(day) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return n
    }

    static func completionsLast7(_ data: AppData) -> [(day: Date, count: Int)] {
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let n = data.assignments.filter { $0.completedAt.map { cal.isDate($0, inSameDayAs: day) } ?? false }.count
            return (day, n)
        }
    }

    static func completedThisWeekByCourse(_ data: AppData) -> [(courseID: UUID?, count: Int)] {
        var tally: [UUID?: Int] = [:]
        for a in data.assignments where a.completedAt.map(isThisWeek) ?? false {
            tally[a.courseID, default: 0] += 1
        }
        return tally.map { (courseID: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// Notes touched this week, and how much was written in them — the other thing that
    /// genuinely happens every week.
    static func notesThisWeek(_ data: AppData) -> (notes: Int, words: Int) {
        let recent = data.notes.filter { isThisWeek($0.updatedAt) }
        let words = recent.reduce(0) { $0 + $1.body.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count }
        return (recent.count, words)
    }

    /// Open work, split the way the assignments list splits it.
    static func workload(_ data: AppData) -> (overdue: Int, week: Int, open: Int) {
        let open = data.assignments.filter(\.isOpen)
        return (open.filter(\.isOverdue).count,
                open.filter { ($0.daysUntilDue ?? 99) >= 0 && ($0.daysUntilDue ?? 99) <= 7 }.count,
                open.count)
    }

    static func pomodorosToday(_ data: AppData) -> Int {
        data.timeEntries.filter { cal.isDateInToday($0.date) && $0.kind == "pomodoro" }.count
    }

    // MARK: Reading

    static func readingDays(_ data: AppData) -> Set<Date> {
        Set(data.readingLog.filter { $0.pages > 0 }.map { cal.startOfDay(for: $0.date) })
    }
    static func readingStreak(_ data: AppData) -> Int {
        let days = readingDays(data)
        guard !days.isEmpty else { return 0 }
        let today = cal.startOfDay(for: .now)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today) else { return 0 }
        guard var day = days.contains(today) ? today : (days.contains(yesterday) ? yesterday : nil) else { return 0 }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }
    static func pagesThisWeek(_ data: AppData) -> Int {
        data.readingLog.filter { isThisWeek($0.date) && $0.pages > 0 }.reduce(0) { $0 + $1.pages }
    }
    static func pagesToday(_ data: AppData) -> Int {
        data.readingLog.filter { cal.isDateInToday($0.date) && $0.pages > 0 }.reduce(0) { $0 + $1.pages }
    }
    static func booksThisYear(_ data: AppData) -> Int {
        data.reading.filter { $0.done && ($0.finishedAt.map { cal.isDate($0, equalTo: .now, toGranularity: .year) } ?? false) }.count
    }
    /// Average pages/day for a book over the last `days` (0 if no data).
    static func avgPace(_ data: AppData, itemID: UUID, days: Int = 14) -> Double {
        let since = cal.date(byAdding: .day, value: -days, to: .now) ?? .now
        let pages = data.readingLog.filter { $0.itemID == itemID && $0.date >= since && $0.pages > 0 }.reduce(0) { $0 + $1.pages }
        guard pages > 0 else { return 0 }
        let activeDays = Set(data.readingLog.filter { $0.itemID == itemID && $0.date >= since && $0.pages > 0 }.map { cal.startOfDay(for: $0.date) }).count
        return Double(pages) / Double(max(1, activeDays))
    }
    static func estimatedFinish(_ item: ReadingItem, _ data: AppData) -> Date? {
        guard !item.done, item.pagesLeft > 0 else { return nil }
        let pace = avgPace(data, itemID: item.id)
        guard pace > 0 else { return nil }
        let days = Int(ceil(Double(item.pagesLeft) / pace))
        return cal.date(byAdding: .day, value: days, to: .now)
    }

    // MARK: Flashcards

    /// Lifetime retention across all cards: successful reviews / total reviews.
    /// nil until at least one review is logged.
    static func flashcardRetention(_ data: AppData) -> Double? {
        let reviews = data.flashcards.reduce(0) { $0 + $1.reviews }
        guard reviews > 0 else { return nil }
        let lapses = data.flashcards.reduce(0) { $0 + $1.lapses }
        return Double(reviews - lapses) / Double(reviews)
    }
    /// Cards whose next review is due now.
    static func cardsDueToday(_ data: AppData) -> Int {
        data.flashcards.filter { $0.isDue }.count
    }
    /// Cards that have graduated to a long interval (learned).
    static func matureCards(_ data: AppData) -> Int {
        data.flashcards.filter { $0.interval >= 21 }.count
    }
}
