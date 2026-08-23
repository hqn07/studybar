import SwiftUI

enum ModuleCategory: String, CaseIterable {
    case overview    = "Overview"
    case assignments = "Assignments"
    case capture     = "Capture"
    case time        = "Time & Focus"
    case schedule    = "Schedule & Calendar"
    case links       = "Links & Resources"
    case research    = "Research"
    case study       = "Study"
    case organize    = "Organize"
    case system      = "System"
}

struct ModuleInfo: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let category: ModuleCategory
    let make: () -> AnyView
}

enum ModuleRegistry {
    /// v1 modules. Order defines sidebar order within a category.
    static let all: [ModuleInfo] = [
        // Overview
        .init(id: "today", title: "Today", symbol: "sun.max",
              category: .overview) { AnyView(TodayView()) },
        .init(id: "insights", title: "Insights", symbol: "chart.bar.xaxis",
              category: .overview) { AnyView(InsightsView()) },
        .init(id: "assistant", title: "Assistant", symbol: "sparkles",
              category: .overview) { AnyView(AssistantView()) },

        // Assignments
        .init(id: "assignments", title: "Assignments", symbol: "checklist",
              category: .assignments) { AnyView(AssignmentsView()) },

        // Capture
        .init(id: "notes", title: "Notes", symbol: "note.text",
              category: .capture) { AnyView(NotesView()) },
        .init(id: "scratchpad", title: "Scratchpad", symbol: "pencil.and.scribble",
              category: .capture) { AnyView(ScratchpadView()) },
        .init(id: "voice", title: "Voice Note", symbol: "mic",
              category: .capture) { AnyView(VoiceView()) },
        .init(id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard",
              category: .capture) { AnyView(ClipboardView()) },
        .init(id: "snippets", title: "Snippets", symbol: "text.badge.plus",
              category: .capture) { AnyView(SnippetsView()) },

        // Time & Focus
        .init(id: "pomodoro", title: "Pomodoro", symbol: "timer",
              category: .time) { AnyView(PomodoroView()) },
        .init(id: "stopwatch", title: "Stopwatch", symbol: "stopwatch",
              category: .time) { AnyView(StopwatchView()) },
        .init(id: "focus", title: "Focus", symbol: "moon.stars",
              category: .time) { AnyView(FocusView()) },
        .init(id: "sessions", title: "Sessions", symbol: "clock.arrow.circlepath",
              category: .time) { AnyView(SessionsView()) },

        // Schedule & Calendar
        .init(id: "schedule", title: "Schedule", symbol: "calendar.day.timeline.left",
              category: .schedule) { AnyView(ScheduleView()) },
        .init(id: "calendar", title: "Calendar", symbol: "calendar",
              category: .schedule) { AnyView(CalendarView()) },

        // Links
        .init(id: "links", title: "Quick Links", symbol: "link",
              category: .links) { AnyView(LinksView()) },
        .init(id: "readinglist", title: "Reading List", symbol: "books.vertical",
              category: .links) { AnyView(ReadingListView()) },
        .init(id: "files", title: "Files", symbol: "folder",
              category: .links) { AnyView(FilesView()) },
        .init(id: "news", title: "News", symbol: "dot.radiowaves.left.and.right",
              category: .links) { AnyView(RSSView()) },

        // Research
        .init(id: "citations", title: "Citations", symbol: "quote.opening",
              category: .research) { AnyView(CitationsView()) },
        .init(id: "wordcount", title: "Word Count", symbol: "textformat",
              category: .research) { AnyView(WordCountView()) },
        .init(id: "dictionary", title: "Dictionary", symbol: "character.book.closed",
              category: .research) { AnyView(DictionaryView()) },
        .init(id: "lookup", title: "Lookup", symbol: "magnifyingglass",
              category: .research) { AnyView(LookupView()) },

        // Study
        .init(id: "flashcards", title: "Flashcards", symbol: "rectangle.on.rectangle.angled",
              category: .study) { AnyView(FlashcardsView()) },
        .init(id: "reading", title: "Reading", symbol: "book",
              category: .study) { AnyView(ReadingView()) },

        // Organize
        .init(id: "todos", title: "To-Do", symbol: "checkmark.circle",
              category: .organize) { AnyView(TodosView()) },
        .init(id: "board", title: "Board", symbol: "rectangle.split.3x1",
              category: .organize) { AnyView(KanbanView()) },
        .init(id: "semester", title: "Semester", symbol: "calendar.badge.clock",
              category: .organize) { AnyView(SemesterView()) },
        .init(id: "gradecalc", title: "Grade Calc", symbol: "percent",
              category: .organize) { AnyView(GradeCalcView()) },
        .init(id: "courses", title: "Courses", symbol: "graduationcap",
              category: .organize) { AnyView(CoursesView()) },

        // System
        .init(id: "settings", title: "Settings", symbol: "gearshape",
              category: .system) { AnyView(SettingsView()) },
    ]

    static func info(_ id: String) -> ModuleInfo? { all.first { $0.id == id } }

    static var byCategory: [(ModuleCategory, [ModuleInfo])] {
        ModuleCategory.allCases.compactMap { cat in
            let items = all.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }
}
