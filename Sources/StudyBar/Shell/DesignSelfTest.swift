import Foundation

/// `StudyBar --design-selftest`: the layout decisions that are logic rather than looks — which
/// sidebar groups get a header, what a course card says. Looks are checked by the module audit.
enum DesignSelfTest {
    @MainActor
    static func run() -> Int32 {
        // It writes preferences (check 9), and by the time any flag is read the app has built
        // its state from the real data file and preferences: only ever from a test copy.
        guard Bundle.main.bundleIdentifier == "com.studybar.StudyBar.test" else {
            print("Run this through scripts/test-copy.sh --design-selftest — never on the Debug build, which shares the installed app's preferences.")
            return 2
        }
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
        // 2.8.1 and this build can share a preferences domain (the installed app and a Debug
        // build): the new groups must not overwrite the order the old app reads.
        let d = UserDefaults.standard
        d.set(["Overview", "Research"], forKey: "categoryOrder")
        let prefs = ModulePrefs()
        prefs.categoryOrder = ["Study", "Plan", "Capture", "Tools", "System"]
        check("9 the new group order leaves 2.8.1's categoryOrder alone",
              d.stringArray(forKey: "categoryOrder") ?? [], ["Overview", "Research"])
        check("9b and is kept under its own key",
              d.stringArray(forKey: "sidebarGroupOrder") ?? [], ["Study", "Plan", "Capture", "Tools", "System"])

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

        // The audit replaces the store it runs on: it must never run on a real one. An empty
        // STUDYBAR_DATA_DIR counts as unset (AppState then opens the real store).
        check("a1 audit refuses without a data folder",
              ModuleAudit.mayRun(env: [:], bundleID: "com.studybar.StudyBar.test"), false)
        check("a2 audit refuses an empty data folder",
              ModuleAudit.mayRun(env: ["STUDYBAR_DATA_DIR": ""], bundleID: "com.studybar.StudyBar.test"), false)
        check("a3 audit refuses the real app",
              ModuleAudit.mayRun(env: ["STUDYBAR_DATA_DIR": "/tmp/x"], bundleID: "com.studybar.StudyBar"), false)
        check("a4 audit runs from a test copy with a data folder",
              ModuleAudit.mayRun(env: ["STUDYBAR_DATA_DIR": "/tmp/x"], bundleID: "com.studybar.StudyBar.test"), true)

        // The term summary: no "0 courses" once every course is in a past term.
        check("t1 no current courses shows no count",
              CoursesView.termStats(gpa: nil, courses: 0, credits: 0, weeksLeft: nil).filter { !$0.isEmpty }.map(\.label), [])
        check("t2 a term in progress",
              CoursesView.termStats(gpa: 3.5, courses: 6, credits: 20, weeksLeft: 9).filter { !$0.isEmpty }.map(\.value),
              ["3.50", "6", "20", "9"])

        // Pages pushed inside a capped module: a form keeps to its width, nothing outgrows the cap,
        // and with no cap (the popover, a spatial module) a page is left alone.
        check("w1 a form in a capped module", ModuleColumn.width(DS.Width.form, cap: DS.Width.content), DS.Width.form)
        check("w2 a page in a capped module", ModuleColumn.width(nil, cap: DS.Width.content), DS.Width.content)
        check("w3 no cap, no limit", ModuleColumn.width(DS.Width.form, cap: nil), nil)

        // The glance strip: a filter with nothing in it is left out — unless it's the one selected,
        // or the strip would hide where you are.
        func item(_ id: String, _ n: Int, _ sel: Bool = false) -> GlanceFilter.Item {
            .init(id: id, count: n, label: id, help: "", selected: sel, action: {})
        }
        check("g1 empty filters are left out",
              GlanceFilter.shown([item("week", 12, true), item("overdue", 0), item("all", 34), item("archived", 0)]).map(\.id),
              ["week", "all"])
        check("g2 the selected filter stays even at zero",
              GlanceFilter.shown([item("week", 0), item("overdue", 0, true)]).map(\.id), ["overdue"])

        // Today's brief: four glance tiles, each left out when it has nothing to say.
        check("t1 all tiles", TodayBrief.tiles(nextClass: ("12:50", "PHY2049 · in 35 min"), dueWeek: 12, dueToday: 3, cardsDue: 24,
                                               focusSeconds: 4800).map(\.value),
              ["12:50", "12", "24", "1h 20m"])
        check("t2 zeros drop", TodayBrief.tiles(nextClass: nil, dueWeek: 12, dueToday: 0, cardsDue: 0, focusSeconds: 0).map(\.label),
              ["due this week"])
        check("t3 nothing at all", TodayBrief.tiles(nextClass: nil, dueWeek: 0, dueToday: 0, cardsDue: 0, focusSeconds: 0).count, 0)
        check("t4 short focus", TodayBrief.tiles(nextClass: nil, dueWeek: 0, dueToday: 0, cardsDue: 0, focusSeconds: 2700).map(\.value), ["45m"])

        // Plan my day: a fresh plan would throw away the drafts on screen and ask the AI again.
        check("p1 plan when there's work", TodayBrief.canPlan(loading: false, hasDrafts: false, hasWork: true), true)
        check("p2 not while drafts are open", TodayBrief.canPlan(loading: false, hasDrafts: true, hasWork: true), false)
        check("p3 not while planning", TodayBrief.canPlan(loading: true, hasDrafts: false, hasWork: true), false)
        check("p4 not with nothing to plan", TodayBrief.canPlan(loading: false, hasDrafts: false, hasWork: false), false)

        print(failures == 0 ? "All passed." : "\(failures) failed.")
        return Int32(failures)
    }
}
