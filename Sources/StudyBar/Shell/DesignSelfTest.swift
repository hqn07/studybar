import Foundation

/// `StudyBar --design-selftest`: the layout decisions that are logic rather than looks — which
/// sidebar groups get a header, what a course card says. Looks are checked by the module audit.
enum DesignSelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            let ok = got == want
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)")
            if !ok { print("       want \(want)\n       got  \(got)") }
        }
        print("Design self-test")

        // The sidebar: groups, and headers only where they help.
        func M(_ ids: [String]) -> [ModuleInfo] { ModuleRegistry.all.filter { ids.contains($0.id) } }
        let starter = ["today", "assignments", "notes", "study", "schedule", "flashcards", "settings"]
        check("1 starter set has no headers",
              SidebarLayout.sections(visible: M(starter), favorites: [], flat: false),
              [.init(title: nil, ids: ["today", "assignments", "schedule"]), .init(title: nil, ids: ["notes"]),
               .init(title: nil, ids: ["study", "flashcards"])])
        let all = ModuleRegistry.all.map(\.id)
        check("2 everything shown", SidebarLayout.sections(visible: M(all), favorites: [], flat: false),
              [.init(title: nil, ids: ["today", "insights", "assignments", "schedule", "calendar", "board", "courses"]),
               .init(title: "Capture", ids: ["notes", "voice", "snippets"]),
               .init(title: "Study", ids: ["study", "flashcards", "reading", "library", "timefocus"]),
               .init(title: "Tools", ids: ["citations", "wordcount", "math", "convert"])])
        check("3 favorites head the list and Plan gets a header",
              SidebarLayout.sections(visible: M(all), favorites: ["notes", "study"], flat: false).map(\.title),
              ["Favorites", "Plan", nil, "Study", "Tools"])
        check("4 a two-item group has no header",
              SidebarLayout.sections(visible: M(all), favorites: ["notes", "study"], flat: false)[2],
              .init(title: nil, ids: ["voice", "snippets"]))
        check("5 flat order is one untitled section",
              SidebarLayout.sections(visible: M(all), favorites: [], flat: true),
              [.init(title: nil, ids: all.filter { $0 != "settings" })])
        check("6 everything starred", SidebarLayout.sections(visible: M(all), favorites: all, flat: false),
              [.init(title: "Favorites", ids: all.filter { $0 != "settings" })])
        // A 2.8.1 order still holds "Capture" and "Study"; keeping those ahead of the new groups
        // would sink Today to third place for everyone who upgrades.
        check("7 an order saved with old category names gives way to the default",
              ModulePrefs.completedCategories(["Overview", "Research", "Capture", "Study"]), ["Plan", "Capture", "Study", "Tools", "System"])
        check("8 an order of current names is kept",
              ModulePrefs.completedCategories(["Study", "Plan"]), ["Study", "Plan", "Capture", "Tools", "System"])

        // A course card's one fact. Thursday 2026-10-08, 12:15.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12, minute: 15))!
        check("c1 graded course leads with its class",
              CourseSummary.make(grade: "B+", nextClass: "Fri 12:50 PM", nextDue: nil, overdue: 0, dueSoon: 3, notes: 8, now: now),
              .init(grade: "B+", fact: "Class Fri 12:50 PM", factIsAlert: false, quiet: "3 due · 8 notes"))
        check("c2 ungraded course leads with what's next",
              CourseSummary.make(grade: nil, nextClass: "today 2:00 PM", nextDue: ("Lab report 4", now.addingTimeInterval(4 * 86_400)),
                                 overdue: 0, dueSoon: 2, notes: 5, now: now),
              .init(grade: nil, fact: "Next: Lab report 4 · Mon", factIsAlert: false, quiet: "Class today 2:00 PM · 5 notes"))
        check("c3 overdue wins",
              CourseSummary.make(grade: "A−", nextClass: "Tue 9:35 AM", nextDue: nil, overdue: 2, dueSoon: 0, notes: 0, now: now),
              .init(grade: "A−", fact: "2 overdue", factIsAlert: true, quiet: "Class Tue 9:35 AM"))
        check("c4 a course with nothing",
              CourseSummary.make(grade: nil, nextClass: nil, nextDue: nil, overdue: 0, dueSoon: 0, notes: 0, now: now),
              .init(grade: nil, fact: "Nothing due this week", factIsAlert: false, quiet: ""))
        check("c5 due tomorrow",
              CourseSummary.make(grade: nil, nextClass: nil, nextDue: ("Quiz 3", now.addingTimeInterval(86_400)), overdue: 0, dueSoon: 1, notes: 0, now: now).fact,
              "Next: Quiz 3 · tomorrow")

        print(failures == 0 ? "All passed." : "\(failures) failed.")
        return Int32(failures)
    }
}
