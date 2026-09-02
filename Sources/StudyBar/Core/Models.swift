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

extension Note {
    /// The plaintext `body` cleaned of editor markup for list rows / previews: fold and
    /// divider markers removed, `[[link]]`→link, `$math$`→its source, list markers tidied.
    var previewText: String {
        var s = body
        for (re, tmpl) in Note.previewSubstitutions {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tmpl)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Precompiled once (was 6 regex compiles per call, per visible list row, per render).
    private static let previewSubstitutions: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"(?m)^\s*\[\[/?fold:?[^\]]*\]\]\s*$"#), ""),
        (try! NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#), "$1"),        // wikilinks
        (try! NSRegularExpression(pattern: #"\$\$?([^$]+?)\$\$?"#), "$1"),      // math → source
        (try! NSRegularExpression(pattern: #"─{3,}"#), ""),                    // dividers
        (try! NSRegularExpression(pattern: #"(?m)^\s*[☐☑]\s*"#), "○ "),        // checkboxes
        (try! NSRegularExpression(pattern: #"(?m)^\s*\d+\.\s+"#), ""),          // numbered
    ]
    /// The row title: the note's title, or its first non-empty preview line.
    var listTitle: String {
        if !title.isEmpty { return title }
        return previewText.split(separator: "\n").first.map(String.init) ?? "Untitled"
    }
    /// Word count of the cleaned text (for the editor's metadata line).
    var wordCount: Int { previewText.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count }
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

extension Assignment {
    /// A plain task — a title with no due date. The lightweight capture that used to be a
    /// separate To-Do now lives as an Assignment (see the Todo→Assignment merge).
    init(task title: String, courseID: UUID? = nil) {
        self.init(title: title, courseID: courseID)
    }

    /// Migrate a legacy `TodoItem` into an Assignment. Done → `.done`; a high-priority
    /// todo becomes urgency "now" (2) so it still surfaces; normal/low stay unranked.
    init(migrating t: TodoItem) {
        self.init(title: t.text, courseID: t.courseID, due: t.due, notes: t.notes,
                  status: t.done ? .done : .todo)
        urgency = t.priority >= 2 ? 2 : nil
        createdAt = t.createdAt
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

// MARK: - Time blocking — plan work onto a day timeline

/// A *planned* block of work at a specific day + time. Distinct from a logged
/// `TimeEntry` (past study, in Time & Focus) and a recurring `ClassSession` — this is
/// intention: when you plan to do a piece of work. Optionally tied to a course and a
/// specific assignment or todo, so blocking a day pulls the real week onto a timeline.
struct TimeBlock: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var day: Date = Calendar.current.startOfDay(for: .now)   // the calendar day (startOfDay)
    var startMinutes: Int = 9 * 60      // minutes from midnight
    var endMinutes: Int = 10 * 60
    var courseID: UUID? = nil
    var assignmentID: UUID? = nil       // planning a specific assignment
    var todoID: UUID? = nil             // …or a specific to-do
    var notes: String = ""
    var done: Bool = false
    var createdAt: Date = .now
    var updatedAt: Date = .now          // bumped on move/resize/edit — breaks merge ties

    /// Never shorter than 15 min (keeps a block tappable on the timeline).
    var durationMinutes: Int { max(15, endMinutes - startMinutes) }
    var startString: String { ClassSession.hm(startMinutes) }
    var endString: String { ClassSession.hm(endMinutes) }
}

extension TimeBlock {
    /// Where one block sits when blocks overlap. `lane` is its column, `lanes` the
    /// number of columns its overlap cluster needs — the view multiplies width by
    /// `1/lanes` and offsets by `lane`.
    struct Placed: Equatable, Hashable { let id: UUID; let lane: Int; let lanes: Int }

    /// Column layout for a day's blocks: side-by-side lanes for overlaps, grouped by
    /// connected-overlap cluster (greedy interval partition). Pure → unit-testable via
    /// `--timeblock-selftest`.
    static func layout(_ blocks: [TimeBlock]) -> [Placed] {
        let sorted = blocks.sorted { ($0.startMinutes, $0.endMinutes) < ($1.startMinutes, $1.endMinutes) }
        var result: [Placed] = []
        var cluster: [TimeBlock] = []
        var laneEnd: [Int] = []            // end-minute currently occupying each lane
        var laneOf: [UUID: Int] = [:]
        var clusterMaxEnd = Int.min

        func flush() {
            let lanes = max(1, laneEnd.count)
            for b in cluster { result.append(Placed(id: b.id, lane: laneOf[b.id] ?? 0, lanes: lanes)) }
            cluster.removeAll(); laneEnd.removeAll(); laneOf.removeAll(); clusterMaxEnd = Int.min
        }

        for b in sorted {
            // A block starting at/after everything so far ends begins a fresh cluster.
            if !cluster.isEmpty && b.startMinutes >= clusterMaxEnd { flush() }
            let free = laneEnd.firstIndex { $0 <= b.startMinutes }
            let lane: Int
            if let free { lane = free; laneEnd[free] = b.endMinutes }
            else { lane = laneEnd.count; laneEnd.append(b.endMinutes) }
            laneOf[b.id] = lane
            cluster.append(b)
            clusterMaxEnd = max(clusterMaxEnd, b.endMinutes)
        }
        flush()
        return result
    }
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
    var pdfPages: Int? = nil          // extracted-text page count when a PDF is attached (nil = none). Optional → decode-safe for old data.
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
    var weekday: Int = 2              // legacy single day / primary (1=Sun … 7=Sat)
    var days: [Int]? = nil           // the days this class meets (MWF = one class); decode-safe
    var startMinutes: Int = 9 * 60   // minutes from midnight
    var endMinutes: Int = 10 * 60
    var room: String = ""
    var link: String = ""            // zoom/meet link for the class
    var online: Bool? = nil          // virtual class (Zoom/Meet). Optional → old data decodes.

    var isOnline: Bool { online ?? false }
    /// An online class with no set weekly meeting time — listed off the time grid rather
    /// than placed at an hour. (An online class that DOES meet at a time stays on the grid.)
    var isAsync: Bool { isOnline && (days?.isEmpty ?? true) }

    /// The weekdays this class meets — the multi-day `days`, or the legacy single
    /// `weekday` for data written before multi-day support. Always sorted.
    var weekdays: [Int] { (days.map { $0.isEmpty ? [weekday] : $0 } ?? [weekday]).sorted() }
    func meets(on wd: Int) -> Bool { weekdays.contains(wd) }
    /// Compact day label, e.g. "MWF" (R = Thursday, U = Sunday).
    var daysShort: String {
        let letters = ["", "U", "M", "T", "W", "R", "F", "S"]
        return weekdays.map { letters[$0] }.joined()
    }

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
    var folder: String = ""          // optional grouping (e.g. "Journals", "News")

    // `folder` was added after 1.6.0. It's a non-optional String, so the *synthesized*
    // decoder would throw `.keyNotFound` on any feed written before it existed — which
    // fails the whole AppData decode and drops the user to an empty store. Decode every
    // field leniently (missing → default) so old data always loads. NEVER let a new
    // non-optional field reach the model without this treatment.
    init(id: UUID = UUID(), title: String = "", url: String = "", courseID: UUID? = nil, folder: String = "") {
        self.id = id; self.title = title; self.url = url; self.courseID = courseID; self.folder = folder
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        courseID = try c.decodeIfPresent(UUID.self, forKey: .courseID)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
    }
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

// MARK: - Trash (soft-delete; recover a deleted item without reverting later work)

/// One deleted item, captured by `AppState.withUndo` (diffed automatically) and kept
/// until restored, purged, or aged out (30 days).
struct TrashedItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var deletedAt = Date()
    var collection: String   // which AppData array it came from
    var itemID: UUID         // the item's original id
    var label: String        // human summary for the Trash row
    var symbol: String = "trash"
    var payload: Data        // JSON of the removed item, for restore
}

// MARK: - Root persisted document

struct AppData: Codable, Equatable {
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
    var trash: [TrashedItem]? = nil    // soft-deleted items, recoverable (decode-safe)
    var timeBlocks: [TimeBlock]? = nil // planned work on a day timeline (decode-safe)
    var rssRead: [String]? = nil       // links of read News articles (decode-safe; unioned on merge)
}

extension AppData {
    /// Items that disappeared from a collection between `before` and `after` — captured
    /// for the trash. Returns [] for a bulk change (>25 removed: erase/restore) so those
    /// aren't dumped into the trash (backups cover them). Pure, so it's unit-testable.
    static func deletionTrash(before: AppData, after: AppData) -> [TrashedItem] {
        func removed<T: Identifiable & Codable>(_ name: String, _ symbol: String,
                                                _ b: [T], _ a: [T], _ label: (T) -> String) -> [TrashedItem] where T.ID == UUID {
            let live = Set(a.map(\.id))
            return b.filter { !live.contains($0.id) }.compactMap { item in
                guard let d = try? JSONEncoder.studybar.encode(item) else { return nil }
                return TrashedItem(collection: name, itemID: item.id, label: label(item), symbol: symbol, payload: d)
            }
        }
        var t: [TrashedItem] = []
        t += removed("notes", "note.text", before.notes, after.notes) { $0.title.isEmpty ? "Untitled note" : $0.title }
        t += removed("assignments", "checklist", before.assignments, after.assignments) { "Assignment: \($0.title)" }
        t += removed("todos", "checkmark.circle", before.todos, after.todos) { "Task: \($0.text)" }
        t += removed("references", "quote.opening", before.references, after.references) { "Citation: \($0.title)" }
        t += removed("links", "link", before.links, after.links) { "Link: \($0.title.isEmpty ? $0.url : $0.title)" }
        t += removed("snippets", "text.badge.plus", before.snippets, after.snippets) { "Snippet: \($0.keyword.isEmpty ? $0.title : $0.keyword)" }
        t += removed("decks", "rectangle.on.rectangle.angled", before.decks, after.decks) { "Deck: \($0.name)" }
        t += removed("flashcards", "rectangle.on.rectangle.angled", before.flashcards, after.flashcards) { "Card: \(String($0.front.prefix(32)))" }
        t += removed("reading", "book", before.reading, after.reading) { "Book: \($0.title)" }
        t += removed("readingList", "books.vertical", before.readingList, after.readingList) { "Read-later: \($0.title)" }
        t += removed("timeEntries", "timer", before.timeEntries, after.timeEntries) { "Session: \($0.label.isEmpty ? "\($0.seconds / 60)m" : $0.label)" }
        t += removed("classes", "graduationcap", before.classes, after.classes) { "Class: \($0.title.isEmpty ? "Class" : $0.title)" }
        t += removed("courses", "graduationcap.fill", before.courses, after.courses) { "Course: \($0.name)" }
        t += removed("clips", "doc.on.clipboard", before.clips, after.clips) { "Clip: \(String($0.text.prefix(32)))" }
        t += removed("timeBlocks", "calendar.day.timeline.left", before.timeBlocks ?? [], after.timeBlocks ?? []) { "Time block: \($0.title.isEmpty ? "Untitled" : $0.title)" }
        return (t.isEmpty || t.count > 25) ? [] : t     // bulk op → leave to backups
    }
}

// MARK: - Time-block layout self-test
// Run with `StudyBar --timeblock-selftest` (see AppDelegate). Exercises the pure
// overlap→lane layout without any GUI; prints per-case results, exits 0/1.

enum TimeBlockSelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "  ok   " : "FAIL   ") + name)
            if !cond { failures += 1 }
        }
        func block(_ start: Int, _ end: Int) -> TimeBlock {
            TimeBlock(title: "\(start)-\(end)", startMinutes: start, endMinutes: end)
        }
        func placed(_ blocks: [TimeBlock]) -> [UUID: TimeBlock.Placed] {
            Dictionary(TimeBlock.layout(blocks).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        // 1. Empty → empty.
        check("empty → []", TimeBlock.layout([]).isEmpty)

        // 2. Non-overlapping back-to-back → all single-lane.
        do {
            let a = block(540, 600), b = block(600, 660), c = block(660, 720)
            let p = placed([a, b, c])
            check("sequential → 1 lane each", [a, b, c].allSatisfy { p[$0.id]?.lanes == 1 && p[$0.id]?.lane == 0 })
        }
        // 3. Two overlapping → two lanes, distinct columns.
        do {
            let a = block(540, 660), b = block(600, 720)
            let p = placed([a, b])
            check("overlap → 2 lanes", p[a.id]?.lanes == 2 && p[b.id]?.lanes == 2)
            check("overlap → distinct lanes", p[a.id]?.lane != p[b.id]?.lane)
        }
        // 4. Lane reused after a gap (a|b overlap, c after both → c back to a fresh cluster, 1 lane).
        do {
            let a = block(540, 600), b = block(540, 600), c = block(660, 720)
            let p = placed([a, b, c])
            check("gap starts new cluster", p[c.id]?.lanes == 1)
            check("still-overlapping pair keeps 2 lanes", p[a.id]?.lanes == 2 && p[b.id]?.lanes == 2)
        }
        // 5. Three-way overlap → three lanes.
        do {
            let a = block(540, 720), b = block(560, 620), c = block(600, 680)
            let p = placed([a, b, c])
            check("triple overlap → 3 lanes", [a, b, c].allSatisfy { p[$0.id]?.lanes == 3 })
            let lanes = Set([a, b, c].compactMap { p[$0.id]?.lane })
            check("triple overlap → 3 distinct columns", lanes == Set([0, 1, 2]))
        }
        // 6. Touching edges (end == next start) do NOT overlap.
        do {
            let a = block(540, 600), b = block(600, 660)
            let p = placed([a, b])
            check("touching edges → not overlapping", p[a.id]?.lanes == 1 && p[b.id]?.lanes == 1)
        }
        // 7. A short block fits a freed lane while a long block spans (staircase).
        do {
            let long = block(540, 720)                 // spans whole cluster
            let s1 = block(560, 600), s2 = block(620, 660)  // two shorts, non-overlapping with each other
            let p = placed([long, s1, s2])
            check("staircase → 2 lanes (shorts share lane 1)", [long, s1, s2].allSatisfy { p[$0.id]?.lanes == 2 })
            check("staircase → shorts reuse the same lane", p[s1.id]?.lane == p[s2.id]?.lane)
            check("staircase → long keeps its own lane", p[long.id]?.lane != p[s1.id]?.lane)
        }

        print(failures == 0 ? "TIMEBLOCK SELFTEST: ALL PASS" : "TIMEBLOCK SELFTEST: \(failures) FAILURE(S)")
        return failures == 0 ? 0 : 1
    }
}
