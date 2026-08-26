import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    static weak var current: AppState?

    // Persisted document. Any write schedules a debounced save.
    @Published var data: AppData { didSet { scheduleSave() } }

    // UI state (not persisted here; settings persisted via @AppStorage in views)
    @Published var selectedModuleID: String = "today" {
        didSet { modulePrefs.recordUse(selectedModuleID) }
    }
    @Published var globalSearch: String = ""
    /// Set by the command palette to ask a module to open its "new item" editor.
    @Published var pendingNew: String? = nil
    /// Toggled by the global hotkey to request the command palette.
    @Published var paletteRequested = false

    @Published var modulePrefs = ModulePrefs()

    // MARK: Undo — Gmail-style one-level undo for destructive actions.
    struct UndoEntry: Identifiable, Equatable {
        let id = UUID(); let label: String; let snapshot: AppData
        static func == (l: UndoEntry, r: UndoEntry) -> Bool { l.id == r.id }
    }
    @Published var undo: UndoEntry? = nil
    private var undoClearTask: Task<Void, Never>?

    /// Run a destructive mutation with one-level undo: snapshots `data` first,
    /// then shows an undo banner for ~6s.
    func withUndo(_ label: String, _ mutation: () -> Void) {
        let snapshot = data
        mutation()
        let entry = UndoEntry(label: label, snapshot: snapshot)
        undo = entry
        undoClearTask?.cancel()
        undoClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await MainActor.run { if self?.undo?.id == entry.id { self?.undo = nil } }
        }
    }
    func performUndo() {
        guard let u = undo else { return }
        data = u.snapshot
        undo = nil
        undoClearTask?.cancel()
    }
    func dismissUndo() { undo = nil; undoClearTask?.cancel() }

    // AI assistant conversation (ephemeral; not persisted).
    let aiChat = AIChat()

    // Live/ephemeral module state
    @Published var pomodoro = PomodoroEngine()
    @Published var breaks = BreakReminders()
    var clipboard: ClipboardMonitor!

    private var fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    static var localDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var iCloudDir: URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        let d = cloudDocs.appendingPathComponent("StudyBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func dataURL(iCloud: Bool) -> URL {
        let dir = (iCloud ? iCloudDir : nil) ?? localDir
        return dir.appendingPathComponent("data.json")
    }

    var usingICloud: Bool { UserDefaults.standard.bool(forKey: "iCloudSync") }

    init() {
        let useCloud = UserDefaults.standard.bool(forKey: "iCloudSync")
        fileURL = AppState.dataURL(iCloud: useCloud)

        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.studybar.decode(AppData.self, from: raw) {
            data = decoded
        } else {
            data = AppData.seed()
        }
        pomodoro.onComplete = { [weak self] seconds, label, courseID, assignmentID in
            self?.logPomodoro(seconds: seconds, label: label, courseID: courseID, assignmentID: assignmentID)
        }
        clipboard = ClipboardMonitor(state: self)
        clipboard.start()
        AppState.current = self

        // Forward nested engine changes so views observing AppState re-render each tick.
        pomodoro.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        BackupManager.maybeAuto(data)

        // Existing users (with real content) skip onboarding.
        if UserDefaults.standard.object(forKey: "onboarded") == nil {
            let hasContent = !data.assignments.isEmpty
                || data.courses.contains { $0.name != "Getting Started" }
                || data.notes.count > 1 || !data.decks.isEmpty
            UserDefaults.standard.set(hasContent, forKey: "onboarded")
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = data
        let url = fileURL
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            if let raw = try? JSONEncoder.studybar.encode(snapshot) {
                try? raw.write(to: url, options: .atomic)
            }
            SpotlightIndexer.reindexThrottled(snapshot)
            _ = self
        }
    }

    func saveNow() {
        if let raw = try? JSONEncoder.studybar.encode(data) {
            try? raw.write(to: fileURL, options: .atomic)
        }
    }

    var dataFileURL: URL { fileURL }

    /// Move the data file between local and iCloud Drive, keeping current data.
    func setICloud(_ on: Bool) {
        guard on != usingICloud else { return }
        if on && AppState.iCloudDir == nil { return }   // iCloud Drive not available
        UserDefaults.standard.set(on, forKey: "iCloudSync")
        let target = AppState.dataURL(iCloud: on)
        if let raw = try? JSONEncoder.studybar.encode(data) {
            try? raw.write(to: target, options: .atomic)
        }
        // Remove the old file if it differs.
        if target != fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = target
    }
    var iCloudAvailable: Bool { AppState.iCloudDir != nil }

    // MARK: Course helpers

    func course(_ id: UUID?) -> Course? {
        guard let id else { return nil }
        return data.courses.first { $0.id == id }
    }

    /// Grade what-if items (stored optional in AppData; exposed as a plain array).
    var gradeItems: [GradeItem] {
        get { data.gradeItems ?? [] }
        set { data.gradeItems = newValue }
    }
    var rssFeeds: [RSSFeed] {
        get { data.rssFeeds ?? [] }
        set { data.rssFeeds = newValue }
    }
    var fileRefs: [FileRef] {
        get { data.fileRefs ?? [] }
        set { data.fileRefs = newValue }
    }

    // MARK: Derived / badges

    /// Assignments due within `days`, not done, sorted by due date.
    func upcomingAssignments(days: Int = 7) -> [Assignment] {
        let horizon = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        return data.assignments
            .filter { $0.status != .done && $0.due != nil }
            .filter { ($0.due ?? .distantFuture) <= horizon }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// Count for the menu bar badge: overdue + due within 3 days.
    var dueSoonCount: Int {
        data.assignments.filter { a in
            guard a.status != .done, let d = a.daysUntilDue else { return false }
            return d <= 3
        }.count
    }

    /// Next class today that hasn't ended yet, with minutes until it starts.
    var nextClassToday: (session: ClassSession, minutesUntil: Int)? {
        let wd = Calendar.current.component(.weekday, from: .now)
        let c = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let upcoming = data.classes
            .filter { $0.weekday == wd && $0.endMinutes >= now }
            .sorted { $0.startMinutes < $1.startMinutes }
        guard let s = upcoming.first else { return nil }
        return (s, max(0, s.startMinutes - now))
    }

    // MARK: Reading mutations (log pages read, track start/finish)

    func setReadingPage(_ id: UUID, to page: Int) {
        guard let i = data.reading.firstIndex(where: { $0.id == id }) else { return }
        var item = data.reading[i]
        let old = item.currentPage
        var p = max(0, page)
        if item.totalPages > 0 { p = min(p, item.totalPages) }
        if item.startedAt == nil && p > 0 { item.startedAt = .now }
        let delta = p - old
        item.currentPage = p
        if item.totalPages > 0 {
            let nowDone = p >= item.totalPages
            if nowDone && !item.done { item.finishedAt = .now; item.timesRead = max(item.timesRead, 1) }
            item.done = nowDone
        }
        item.updatedAt = .now
        data.reading[i] = item
        if delta > 0 { data.readingLog.append(ReadEvent(itemID: id, pages: delta)) }
    }
    func bumpReading(_ id: UUID, by delta: Int) {
        guard let cur = data.reading.first(where: { $0.id == id })?.currentPage else { return }
        setReadingPage(id, to: cur + delta)
    }
    /// Cross-link a book from the Reading tracker into the Reading List (links).
    /// De-dupes on matching URL, else title. Returns false if it was already there.
    @discardableResult
    func addToReadingList(_ book: ReadingItem) -> Bool {
        let exists = data.readingList.contains {
            (!book.url.isEmpty && $0.url == book.url)
            || $0.title.caseInsensitiveCompare(book.title) == .orderedSame
        }
        guard !exists else { return false }
        data.readingList.insert(
            ReadingListItem(title: book.title, url: book.url, courseID: book.courseID),
            at: 0)
        return true
    }
    func toggleReadingDone(_ id: UUID) {
        guard let i = data.reading.firstIndex(where: { $0.id == id }) else { return }
        var it = data.reading[i]
        it.done.toggle()
        if it.done {
            if it.totalPages > 0 {
                let delta = it.totalPages - it.currentPage
                it.currentPage = it.totalPages
                if delta > 0 { data.readingLog.append(ReadEvent(itemID: id, pages: delta)) }
            }
            it.finishedAt = .now; it.timesRead = max(it.timesRead, 1)
        } else {
            it.finishedAt = nil
        }
        it.updatedAt = .now
        data.reading[i] = it
    }
    func toggleReadingUnit(_ id: UUID, unitID: UUID) {
        guard let i = data.reading.firstIndex(where: { $0.id == id }),
              let u = data.reading[i].units.firstIndex(where: { $0.id == unitID }) else { return }
        let wasDone = data.reading[i].units[u].done
        data.reading[i].units[u].done.toggle()
        if data.reading[i].units[u].done && !wasDone {
            // Log a reading event so streak/pace still work for chapter-based books.
            let est = data.reading[i].totalPages > 0 ? max(1, data.reading[i].totalPages / max(1, data.reading[i].units.count)) : 10
            data.readingLog.append(ReadEvent(itemID: id, pages: est))
        }
        if data.reading[i].startedAt == nil { data.reading[i].startedAt = .now }
        let allDone = !data.reading[i].units.isEmpty && data.reading[i].units.allSatisfy { $0.done }
        if allDone && !data.reading[i].done { data.reading[i].done = true; data.reading[i].finishedAt = .now; data.reading[i].timesRead = max(data.reading[i].timesRead, 1) }
        if !allDone { data.reading[i].done = false }
        data.reading[i].updatedAt = .now
    }
    func addReadingUnits(_ id: UUID, titles: [String]) {
        guard let i = data.reading.firstIndex(where: { $0.id == id }) else { return }
        for t in titles where !t.trimmingCharacters(in: .whitespaces).isEmpty {
            data.reading[i].units.append(ReadingUnit(title: t.trimmingCharacters(in: .whitespaces)))
        }
        data.reading[i].updatedAt = .now
    }

    func rereadBook(_ id: UUID) {
        guard let i = data.reading.firstIndex(where: { $0.id == id }) else { return }
        data.reading[i].currentPage = 0
        data.reading[i].units = data.reading[i].units.map { var u = $0; u.done = false; return u }
        data.reading[i].done = false
        data.reading[i].startedAt = .now
        data.reading[i].finishedAt = nil
        data.reading[i].timesRead += 1
        data.reading[i].updatedAt = .now
    }

    // MARK: Pomodoro logging

    private func logPomodoro(seconds: Int, label: String, courseID: UUID?, assignmentID: UUID?) {
        // If linked to an assignment, inherit its course.
        let cid = courseID ?? data.assignments.first { $0.id == assignmentID }?.courseID
        data.timeEntries.append(TimeEntry(courseID: cid, assignmentID: assignmentID,
                                          label: label, seconds: seconds, kind: "pomodoro"))
    }
}

// MARK: - JSON coders

extension JSONEncoder {
    static var studybar: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
extension JSONDecoder {
    static var studybar: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Seed data (first launch)

extension AppData {
    static func seed() -> AppData {
        var d = AppData()
        let c = Course(name: "Getting Started", code: "STUDY 101", colorHex: "#4F8DFD")
        d.courses = [c]
        d.links = [
            QuickLink(title: "Google Scholar", url: "https://scholar.google.com", symbol: "graduationcap"),
            QuickLink(title: "Library", url: "https://library.org", symbol: "books.vertical")
        ]
        d.notes = [Note(title: "Welcome to StudyBar",
                        body: "This is your first note. Everything is stored locally on your Mac.\n\nAdd courses, then assignments, notes, links and timers all hang off them.",
                        pinned: true)]
        return d
    }
}
