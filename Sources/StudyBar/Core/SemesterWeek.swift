import Foundation

/// Which week of the term a date falls in.
///
/// Lecture notes are kept per class session, and the title people reach for is "Week 3 — …"
/// (three of the notes in the store are named exactly that, by hand). The term already knows
/// when it started, so the week number is derivable rather than something to retype.
enum SemesterWeek {

    /// 1-based week of the term, counting from the day it started. Nil when the term has no
    /// start date, or the date falls before it — a note written over the summer isn't
    /// "week -2", it just has no week.
    static func number(for date: Date, termStart: Date?) -> Int? {
        guard let termStart else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: termStart)
        let day = cal.startOfDay(for: date)
        guard day >= start else { return nil }
        guard let days = cal.dateComponents([.day], from: start, to: day).day else { return nil }
        return days / 7 + 1
    }

    static func label(for date: Date, termStart: Date?) -> String? {
        number(for: date, termStart: termStart).map { "Week \($0)" }
    }

    /// The title a new note in a course starts with, so the week and the dash are already
    /// typed: "Week 3 — ". Nil outside a term, where there is no week to name.
    static func noteTitlePrefix(for date: Date = .now, termStart: Date?) -> String? {
        label(for: date, termStart: termStart).map { "\($0) — " }
    }

    /// True for a title that is only the generated prefix — i.e. the user opened a new note
    /// and typed nothing. Lets the editor still discard it as blank.
    static func isBarePrefix(_ title: String) -> Bool {
        title.range(of: #"^Week \d+ — ?$"#, options: .regularExpression) != nil
    }
}

// MARK: - Self-test (StudyBar --week-selftest)

enum WeekSelfTest {
    static func run() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ got: Int?, _ want: Int?) {
            if got == want { print("  ok   \(name)"); pass += 1 }
            else { print("  FAIL \(name): got \(String(describing: got)) want \(String(describing: want))"); fail += 1 }
        }
        let cal = Calendar.current
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: day))!
        }
        // The real term in the store: Fall 2026 started Aug 21, and the notes the user titled
        // "Week 3" by hand were written Sep 4-6.
        let start = d(2026, 8, 21)
        check("first day is week 1", SemesterWeek.number(for: start, termStart: start), 1)
        check("day 6 is still week 1", SemesterWeek.number(for: d(2026, 8, 27), termStart: start), 1)
        check("day 7 rolls to week 2", SemesterWeek.number(for: d(2026, 8, 28), termStart: start), 2)
        check("Sep 4 is week 3", SemesterWeek.number(for: d(2026, 9, 4), termStart: start), 3)
        check("Sep 6 is week 3", SemesterWeek.number(for: d(2026, 9, 6), termStart: start), 3)
        check("before the term has no week", SemesterWeek.number(for: d(2026, 8, 1), termStart: start), nil)
        check("no term start, no week", SemesterWeek.number(for: start, termStart: nil), nil)

        func checkS(_ name: String, _ got: String?, _ want: String?) {
            if got == want { print("  ok   \(name)"); pass += 1 }
            else { print("  FAIL \(name): got \(String(describing: got)) want \(String(describing: want))"); fail += 1 }
        }
        checkS("title prefix", SemesterWeek.noteTitlePrefix(for: d(2026, 9, 6), termStart: start), "Week 3 — ")
        checkS("no prefix outside a term", SemesterWeek.noteTitlePrefix(for: d(2026, 9, 6), termStart: nil), nil)

        func checkB(_ name: String, _ got: Bool, _ want: Bool) {
            if got == want { print("  ok   \(name)"); pass += 1 }
            else { print("  FAIL \(name)"); fail += 1 }
        }
        checkB("bare prefix is blank", SemesterWeek.isBarePrefix("Week 3 — "), true)
        checkB("bare prefix without the space", SemesterWeek.isBarePrefix("Week 12 —"), true)
        checkB("a real title is not blank", SemesterWeek.isBarePrefix("Week 3 — Present Value"), false)
        checkB("unrelated title is not blank", SemesterWeek.isBarePrefix("Gauss's Law"), false)

        print(fail == 0 ? "WEEK SELFTEST: ALL PASS (\(pass))" : "WEEK SELFTEST: \(fail) FAILED")
        return fail == 0 ? 0 : 1
    }
}
