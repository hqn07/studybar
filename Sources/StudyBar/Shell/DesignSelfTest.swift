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

        print(failures == 0 ? "All passed." : "\(failures) failed.")
        return Int32(failures)
    }
}
