import Foundation
import SwiftUI

// MARK: - Course (feeds every module that has a course picker)

struct Course: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var code: String = ""
    var instructor: String = ""
    var room: String = ""
    var credits: Double = 3
    var grade: String = ""          // letter grade, e.g. "A-", for GPA
    var colorHex: String = "#4F8DFD"
    var canvasID: Int? = nil        // Canvas course id (for sync dedup)
    var term: String = ""           // e.g. "Fall 2026"; empty = current term (decode-safe)
    var createdAt: Date = .now

    var color: Color { Color(hex: colorHex) ?? .accentColor }
    var gradePoints: Double? { GradeScale.points(grade) }
}

/// US 4.0 letter-grade scale for GPA.
enum GradeScale {
    static let letters = ["A", "A-", "B+", "B", "B-", "C+", "C", "C-", "D+", "D", "D-", "F"]
    static func points(_ g: String) -> Double? {
        switch g.uppercased() {
        case "A+", "A": return 4.0
        case "A-": return 3.7
        case "B+": return 3.3
        case "B": return 3.0
        case "B-": return 2.7
        case "C+": return 2.3
        case "C": return 2.0
        case "C-": return 1.7
        case "D+": return 1.3
        case "D": return 1.0
        case "D-": return 0.7
        case "F": return 0.0
        default: return nil
        }
    }
}

// MARK: - Notes (1) & Scratchpad (2)

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var body: String = ""           // plaintext mirror (search / AI / Spotlight / preview)
    var rich: Data? = nil           // (E2) RTFD: bold/italic/color/images — source of truth when present
    var courseID: UUID? = nil
    var assignmentID: UUID? = nil
    var tags: [String] = []
    var pinned: Bool = false
    var imagePath: String = ""      // (4) screenshot attachment, filename in App Support/Screenshots
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

// MARK: - Clipboard history (5)

struct ClipItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var pinned: Bool = false
    var copiedAt: Date = .now
}

// MARK: - Snippets (6)

struct Snippet: Identifiable, Codable, Hashable {
    var id = UUID()
    var keyword: String = ""
    var title: String = ""
    var body: String = ""
    var uses: Int = 0
    var category: String = ""       // free-text group; "" shown as "General"
}

// MARK: - Assignments (7,8,9,12,13,14)

enum AssignmentStatus: String, Codable, CaseIterable {
    case todo = "To Do"
    case inProgress = "In Progress"
    case done = "Done"
}

struct ChecklistItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var done: Bool = false
}

struct Assignment: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var courseID: UUID? = nil
    var due: Date? = nil
    var link: String = ""
    var notes: String = ""
    var status: AssignmentStatus = .todo
    var checklist: [ChecklistItem] = []
    var recurring: Bool = false
    var canvasID: Int? = nil        // Canvas assignment id (for sync dedup)
    var sourceUID: String? = nil    // .ics feed UID (Canvas Calendar Feed import dedup; decode-safe)
    var sourceFeedID: UUID? = nil   // which ICSFeed imported it (per-feed counts + cleanup; decode-safe)
    var sourceCourseTag: String? = nil  // Canvas [CODE] tag from the feed, for classifying (decode-safe)
    var submitted: Bool = false     // from Canvas submission state
    var points: Double? = nil       // points possible
    var urgency: Int? = nil         // AI triage: 0 later · 1 this week · 2 now (nil = unranked)
    var createdAt: Date = .now

    var isOverdue: Bool {
        guard let due, status != .done else { return false }
        return due < .now
    }
    var daysUntilDue: Int? {
        guard let due else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: due)).day
    }
}

// MARK: - To-do (43)

struct TodoItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var done: Bool = false
    var priority: Int = 1        // 0 low, 1 normal, 2 high
    var courseID: UUID? = nil
    var due: Date? = nil
    var notes: String = ""
    var createdAt: Date = .now

    var isOverdue: Bool {
        guard !done, let due else { return false }
        return due < Calendar.current.startOfDay(for: .now)
    }
}

// MARK: - Quick Links (21) & per-course groups (22)

struct QuickLink: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var courseID: UUID? = nil
    var symbol: String = "link"
    var pinned: Bool = false
}

// MARK: - Time log (17) & Pomodoro sessions (15)

struct TimeEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseID: UUID? = nil
    var assignmentID: UUID? = nil
    var label: String = ""
    var seconds: Int
    var date: Date = .now
    var kind: String = "pomodoro"   // pomodoro | stopwatch | focus
}

// MARK: - Citations / Bibliography (26, 27)

enum RefType: String, Codable, CaseIterable {
    case article = "Journal Article"
    case book = "Book"
    case website = "Website"
}

struct Reference: Identifiable, Codable, Hashable {
    var id = UUID()
    var type: RefType = .website
    var authors: [String] = []       // "Last, First"
    var title: String = ""
    var year: String = ""
    var container: String = ""       // journal / publisher / site name
    var volume: String = ""
    var issue: String = ""
    var pages: String = ""
    var url: String = ""
    var doi: String = ""
    var courseID: UUID? = nil
    var addedAt: Date = .now
}

// MARK: - Flashcards & Quiz (35, 36)

struct Deck: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var courseID: UUID? = nil
    var createdAt: Date = .now
}

struct Flashcard: Identifiable, Codable, Hashable {
    var id = UUID()
    var deckID: UUID
    var front: String = ""
    var back: String = ""
    var tags: [String] = []
    // SM-2 spaced repetition
    var ease: Double = 2.5
    var interval: Int = 0            // days
    var reps: Int = 0
    var due: Date = .now
    // Retention tracking
    var reviews: Int = 0
    var lapses: Int = 0
    // FSRS-4.5 scheduler state (decode-safe; 0 = not yet scheduled by FSRS)
    var stability: Double = 0
    var difficulty: Double = 0
    var lastReview: Date? = nil

    var isDue: Bool { due <= .now }
    /// A card whose front uses Anki-style {{cloze}} syntax.
    var isCloze: Bool { front.contains("{{") && front.contains("}}") }
}

// MARK: - Reading tracker (39)

struct Highlight: Identifiable, Codable, Hashable {
    var id = UUID()
    var page: Int = 0
    var text: String = ""
    var addedAt: Date = .now
}

/// A chapter / topic / section for academic reading tracked by unit, not page.
struct ReadingUnit: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var done: Bool = false
}

struct ReadingItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var author: String = ""
    var isbn: String = ""
    var publisher: String = ""
    var year: String = ""
    var coverPath: String = ""       // filename in App Support/Covers
    var courseID: UUID? = nil
    var tags: [String] = []
    var currentPage: Int = 0
    var totalPages: Int = 0
    var units: [ReadingUnit] = []      // chapters / topics
    var url: String = ""
    var notes: String = ""
    var highlights: [Highlight] = []
    var rating: Int = 0              // 0–5 stars (once finished)
    var targetDate: Date? = nil
    var done: Bool = false
    var timesRead: Int = 0
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var updatedAt: Date = .now

    var usesUnits: Bool { !units.isEmpty }
    var unitsDone: Int { units.filter { $0.done }.count }
    var progress: Double {
        if usesUnits { return units.isEmpty ? 0 : Double(unitsDone) / Double(units.count) }
        guard totalPages > 0 else { return done ? 1 : 0 }
        return min(1, Double(currentPage) / Double(totalPages))
    }
    var pagesLeft: Int { max(0, totalPages - currentPage) }
    /// To-read (untouched) · Reading (started) · Finished.
    var shelf: Int {
        if done { return 2 }
        let started = usesUnits ? unitsDone > 0 : currentPage > 0
        return started ? 1 : 0
    }
}

/// A day's pages-read event, for streaks and pace.
struct ReadEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var itemID: UUID
    var pages: Int
    var date: Date = .now
}

// MARK: - Class schedule (19)

struct ClassSession: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseID: UUID? = nil
    var title: String = ""            // e.g. "Lecture", "Lab"
    var weekday: Int = 2              // 1=Sun … 7=Sat (Calendar convention)
    var startMinutes: Int = 9 * 60   // minutes from midnight
    var endMinutes: Int = 10 * 60
    var room: String = ""
    var link: String = ""            // zoom/meet link for the class

    var startString: String { Self.hm(startMinutes) }
    var endString: String { Self.hm(endMinutes) }
    static func hm(_ m: Int) -> String {
        let h = m / 60, mm = m % 60
        let ampm = h < 12 ? "AM" : "PM"
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, mm, ampm)
    }
}

// MARK: - Reading list (23) — read-later links (distinct from Reading progress tracker)

struct ReadingListItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var url: String = ""
    var courseID: UUID? = nil
    var read: Bool = false
    var addedAt: Date = .now
}

// MARK: - iCal feeds (11) — Canvas/LMS/Google calendar subscriptions

struct ICSFeed: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var url: String = ""
    var courseID: UUID? = nil
    var lastSynced: Date? = nil     // last successful assignment import (decode-safe)
    var lastImported: Int? = nil    // assignments created+updated on that sync (decode-safe)
}

// MARK: - Folder bookmark (25 recent files, 32 PDF search)

struct FolderRef: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String = ""
    var bookmark: Data = Data()      // security-scoped bookmark
}

/// A pinned individual file, organized into a named (collapsible) group that
/// doubles as a quick-access tag.
struct FileRef: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String = ""
    var bookmark: Data = Data()      // security-scoped bookmark
    var group: String = ""           // collapsible group / tag ("" = Ungrouped)
    var addedAt: Date = .now
}

// MARK: - RSS / Atom feed subscription (news, journal TOC, professor blogs)

struct RSSFeed: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var url: String = ""
    var courseID: UUID? = nil
}

// MARK: - Grade "what-if" calculator

/// One weighted grade component for a course (e.g. "Midterm — 25% — 88").
struct GradeItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var courseID: UUID? = nil
    var name: String = ""
    var weight: Double = 0     // percent of the final grade
    var score: Double = 0      // percent earned, 0–100
    var graded: Bool = true    // false = not taken yet (a target/unknown)
}

// MARK: - Root persisted document

struct AppData: Codable {
    var courses: [Course] = []
    var notes: [Note] = []
    var scratchpad: String = ""
    var clips: [ClipItem] = []
    var snippets: [Snippet] = []
    var assignments: [Assignment] = []
    var todos: [TodoItem] = []
    var links: [QuickLink] = []
    var timeEntries: [TimeEntry] = []
    var references: [Reference] = []
    var decks: [Deck] = []
    var flashcards: [Flashcard] = []
    var reading: [ReadingItem] = []
    var readingLog: [ReadEvent] = []
    var classes: [ClassSession] = []
    var readingList: [ReadingListItem] = []
    var icsFeeds: [ICSFeed] = []
    var folders: [FolderRef] = []
    // Semester (42)
    var termName: String = ""
    var termStart: Date? = nil
    var termEnd: Date? = nil
    // Grade what-if calculator (optional → tolerant of older data files)
    var gradeItems: [GradeItem]? = nil
    var rssFeeds: [RSSFeed]? = nil
    var fileRefs: [FileRef]? = nil     // pinned files grouped into collapsible tags
}
