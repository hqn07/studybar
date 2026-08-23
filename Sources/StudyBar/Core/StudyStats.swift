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

    static func completedThisWeek(_ data: AppData) -> Int {
        data.assignments.filter { $0.status == .done }.count // approx: no completion date stored
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
}
