import SwiftUI

/// The sidebar's groups. Four, so a group is worth a header (see SidebarLayout); Settings is
/// `system` and sits at the bottom of the sidebar, outside the groups.
enum ModuleCategory: String, CaseIterable {
    case plan    = "Plan"
    case capture = "Capture"
    case study   = "Study"
    case tools   = "Tools"
    case system  = "System"
}

struct ModuleInfo: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let category: ModuleCategory
    /// Spatial modules (two-pane editors, calendars, boards) fill the pane; every other
    /// module's content sits in a column capped at `DS.Width.content`. The header spans
    /// either way (see RootView.pane and ModulePane).
    var wide: Bool = false
    let make: () -> AnyView
}

enum ModuleRegistry {
    /// v1 modules. Order defines sidebar order within a category.
    static let all: [ModuleInfo] = [
        // Plan
        .init(id: "today", title: "Today", symbol: "sun.max",
              category: .plan) { AnyView(TodayView()) },
        .init(id: "insights", title: "Insights", symbol: "chart.bar.xaxis",
              category: .plan) { AnyView(InsightsView()) },
        // NOTE: the Assistant is no longer a sidebar module — it's a summoned floating panel
        // (AssistantPanel, opened via ⌘K / AppActions.assistant). Cross-object AI jobs live
        // there; inline edits stay on the object (the ✨ menus). AssistantView/Chat is reused.
        .init(id: "assignments", title: "Assignments", symbol: "checklist",
              category: .plan) { AnyView(AssignmentsView()) },
        .init(id: "schedule", title: "Schedule", symbol: "calendar.day.timeline.left",
              category: .plan, wide: true) { AnyView(ScheduleView()) },
        .init(id: "calendar", title: "Calendar", symbol: "calendar",
              category: .plan, wide: true) { AnyView(CalendarView()) },
        .init(id: "board", title: "Board", symbol: "rectangle.split.3x1",
              category: .plan, wide: true) { AnyView(KanbanView()) },
        .init(id: "courses", title: "Courses", symbol: "graduationcap",
              category: .plan) { AnyView(CoursesView()) },

        // Capture
        .init(id: "notes", title: "Notes", symbol: "note.text",
              category: .capture, wide: true) { AnyView(NotesView()) },
        .init(id: "voice", title: "Voice Note", symbol: "mic",
              category: .capture) { AnyView(VoiceView()) },
        // Snippets — managed from Settings ▸ Snippets; kept off the starter sidebar. The
        // expansion engine (keyword typing + system Services) runs regardless.
        .init(id: "snippets", title: "Snippets", symbol: "text.badge.plus",
              category: .capture) { AnyView(SnippetsView()) },

        // Study
        .init(id: "study", title: "Study", symbol: "brain.head.profile",
              category: .study, wide: true) { AnyView(StudyModuleView()) },
        .init(id: "flashcards", title: "Flashcards", symbol: "rectangle.on.rectangle.angled",
              category: .study) { AnyView(FlashcardsView()) },
        .init(id: "reading", title: "Reading", symbol: "book",
              category: .study) { AnyView(ReadingView()) },
        .init(id: "library", title: "Library", symbol: "books.vertical",
              category: .study) { AnyView(LibraryView()) },
        // Time & Focus (unified: Pomodoro · Stopwatch · Focus · History + ambient noise)
        .init(id: "timefocus", title: "Time & Focus", symbol: "timer",
              category: .study) { AnyView(TimeFocusView()) },

        // Tools
        .init(id: "citations", title: "Citations", symbol: "quote.opening",
              category: .tools) { AnyView(CitationsView()) },
        .init(id: "wordcount", title: "Word Count", symbol: "textformat",
              category: .tools) { AnyView(WordCountView()) },
        .init(id: "math", title: "Math", symbol: "function",
              category: .tools) { AnyView(MathView()) },
        .init(id: "convert", title: "Convert", symbol: "arrow.triangle.2.circlepath.doc.on.clipboard",
              category: .tools) { AnyView(ConvertView()) },

        // System — pinned to the bottom of the sidebar, not listed in a group
        .init(id: "settings", title: "Settings", symbol: "gearshape",
              category: .system, wide: true) { AnyView(SettingsView()) },
    ]

    static func info(_ id: String) -> ModuleInfo? { all.first { $0.id == id } }

    static var byCategory: [(ModuleCategory, [ModuleInfo])] {
        ModuleCategory.allCases.compactMap { cat in
            let items = all.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }
}
