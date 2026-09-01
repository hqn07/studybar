import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {

    static weak var current: AppState?

    // Persisted document. Any write schedules a debounced save.
    @Published var data: AppData { didSet { if !suppressSave { scheduleSave() } } }

    // UI state (not persisted here; settings persisted via @AppStorage in views)
    @Published var selectedModuleID: String = "today" {
        didSet {
            if !restoringModule { modulePrefs.recordUse(selectedModuleID) }
            UserDefaults.standard.set(selectedModuleID, forKey: "lastModule")
        }
    }
    /// Set while restoring the last module on launch so it doesn't count as a "use".
    private var restoringModule = false
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
        captureDeletions(from: snapshot)
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

    // MARK: Trash — soft-deleted items captured by diffing withUndo (see Models.TrashedItem)

    var trashCount: Int { data.trash?.count ?? 0 }

    /// After a destructive mutation, capture anything that disappeared from a collection
    /// into the trash — so a single deleted item can be recovered later without reverting
    /// newer work. A bulk change (erase-all, restore-backup) is skipped; backups cover those.
    private func captureDeletions(from before: AppData) {
        let t = AppData.deletionTrash(before: before, after: data)
        if !t.isEmpty { data.trash = (data.trash ?? []) + t }
    }

    /// Restore trashed items back into their collections.
    func restoreFromTrash(_ ids: Set<UUID>) {
        let dec = JSONDecoder.studybar
        for t in (data.trash ?? []).filter({ ids.contains($0.id) }) {
            func add<T: Decodable & Identifiable>(_ keyPath: WritableKeyPath<AppData, [T]>, _ type: T.Type) where T.ID == UUID {
                guard let x = try? dec.decode(type, from: t.payload),
                      !data[keyPath: keyPath].contains(where: { $0.id == x.id }) else { return }
                data[keyPath: keyPath].append(x)
            }
            switch t.collection {
            case "notes":        add(\.notes, Note.self)
            case "assignments":  add(\.assignments, Assignment.self)
            case "todos":        add(\.todos, TodoItem.self)
            case "references":   add(\.references, Reference.self)
            case "links":        add(\.links, QuickLink.self)
            case "snippets":     add(\.snippets, Snippet.self)
            case "decks":        add(\.decks, Deck.self)
            case "flashcards":   add(\.flashcards, Flashcard.self)
            case "reading":      add(\.reading, ReadingItem.self)
            case "readingList":  add(\.readingList, ReadingListItem.self)
            case "timeEntries":  add(\.timeEntries, TimeEntry.self)
            case "classes":      add(\.classes, ClassSession.self)
            case "courses":      add(\.courses, Course.self)
            case "clips":        add(\.clips, ClipItem.self)
            case "timeBlocks":   restoreTimeBlock(t.payload)
            default: break
            }
        }
        data.trash?.removeAll { ids.contains($0.id) }
        if data.trash?.isEmpty == true { data.trash = nil }
    }

    /// Restore a trashed time block (optional collection → own helper, since the generic
    /// `add` above works on non-optional `[T]` key paths).
    private func restoreTimeBlock(_ payload: Data) {
        guard let x = try? JSONDecoder.studybar.decode(TimeBlock.self, from: payload) else { return }
        var blocks = data.timeBlocks ?? []
        guard !blocks.contains(where: { $0.id == x.id }) else { return }
        blocks.append(x)
        data.timeBlocks = blocks
    }

    func purgeFromTrash(_ ids: Set<UUID>) {
        data.trash?.removeAll { ids.contains($0.id) }
        if data.trash?.isEmpty == true { data.trash = nil }
    }
    func emptyTrash() { data.trash = nil }
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
    /// Modification date of the data file as we last read or wrote it — used to
    /// detect external changes (another device/instance) before overwriting.
    private var loadedMtime: Date?
    /// Snapshot of `data` at the last point it matched disk (load / reload / commit) —
    /// the common ancestor for a 3-way merge when disk changed under us.
    private var baseData: AppData
    /// Set while adopting on-disk data so the reload doesn't re-trigger a save.
    private var suppressSave = false
    /// Set when the data file existed but could not be decoded on launch. While true the
    /// app NEVER writes the store — the unreadable file is preserved untouched so a fix or
    /// a manual restore can recover it, instead of an empty session overwriting it.
    /// (Read by the UI to warn the user; see `dataSaveBlocked`.)
    private(set) var saveBlocked = false
    var dataSaveBlocked: Bool { saveBlocked }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

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
        // Dev/test override so a build can point at a throwaway store instead of the
        // user's live data (never test a build against the real iCloud file).
        if let override = ProcessInfo.processInfo.environment["STUDYBAR_DATA_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("data.json")
        }
        let dir = (iCloud ? iCloudDir : nil) ?? localDir
        return dir.appendingPathComponent("data.json")
    }

    /// Preserve the raw bytes of a data file that wouldn't decode, so nothing is lost even
    /// if it never decodes — the load guard also blocks saves so the original stays put.
    static func quarantineUnreadable(_ url: URL, raw: Data) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = url.deletingLastPathComponent()
            .appendingPathComponent("data.json.unreadable-\(f.string(from: Date()))")
        if !FileManager.default.fileExists(atPath: dst.path) { try? raw.write(to: dst, options: .atomic) }
        NSLog("StudyBar: data file did not decode — preserved a copy at %@ and blocked saves", dst.lastPathComponent)
    }

    var usingICloud: Bool { UserDefaults.standard.bool(forKey: "iCloudSync") }

    init() {
        let useCloud = UserDefaults.standard.bool(forKey: "iCloudSync")
        fileURL = AppState.dataURL(iCloud: useCloud)

        var initial: AppData
        let existingRaw = try? Data(contentsOf: fileURL)
        if let raw = existingRaw, let decoded = try? JSONDecoder.studybar.decode(AppData.self, from: raw) {
            initial = decoded
        } else if let raw = existingRaw, raw.count > 2 {
            // The file EXISTS and has content but would not decode (a schema break, or
            // corruption). Seeding an empty store here and then autosaving it is exactly
            // how the 2026-08-31 wipe happened. Instead: preserve the raw bytes to a
            // sibling, load an empty session, and BLOCK every save so the real file is
            // never overwritten. The user keeps their data; the app is read-only until
            // relaunched against a build/file that decodes.
            AppState.quarantineUnreadable(fileURL, raw: raw)
            initial = AppData.seed()
            saveBlocked = true
        } else {
            initial = AppData.seed()   // genuinely fresh install (no file, or empty file)
        }
        // Age out trashed items older than 30 days (before adopting, so no extra save).
        if let tr = initial.trash {
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            let kept = tr.filter { $0.deletedAt > cutoff }
            initial.trash = kept.isEmpty ? nil : kept
        }
        data = initial
        baseData = initial
        loadedMtime = AppState.mtime(fileURL)
        pomodoro.onComplete = { [weak self] seconds, label, courseID, assignmentID in
            self?.logPomodoro(seconds: seconds, label: label, courseID: courseID, assignmentID: assignmentID)
        }
        clipboard = ClipboardMonitor(state: self)
        clipboard.start()
        AppState.current = self

        // The window remembers the last module you were in (validated → falls back to
        // Today). The popover always opens on the Today glance regardless.
        if let last = UserDefaults.standard.string(forKey: "lastModule"),
           ModuleRegistry.info(last) != nil {
            restoringModule = true; selectedModuleID = last; restoringModule = false
        }

        // When the app returns to the foreground, pick up any external change to the
        // data file (another device via iCloud, or another instance) so this running
        // copy never holds stale data that a later save would clobber.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged() }
        }

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
            // Brand-new install → ship a calm starter set; the long tail stays one tap
            // away in Settings ▸ Modules. Never touches an existing user's setup.
            if !hasContent && UserDefaults.standard.object(forKey: "hiddenModules") == nil {
                modulePrefs.seedStarterSet()
            }
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.commitSave()
            SpotlightIndexer.reindexThrottled(self.data)
        }
    }

    func saveNow() { commitSave() }

    /// Write the current data, but never silently destroy a newer file. If the file on
    /// disk changed since we last read/wrote it (another device via iCloud, or another
    /// instance), 3-way merge our in-memory copy against it — so edits from *both* sides
    /// survive — then write the union. The raw newer disk file is also copied to a
    /// timestamped `.conflict-*` backup first, belt-and-suspenders.
    private func commitSave() {
        // The on-disk file couldn't be read at launch and is quarantined — never overwrite it.
        guard !saveBlocked else { return }
        if let merged = mergeAgainstDiskIfChanged() {
            suppressSave = true
            data = merged
            suppressSave = false
        }
        // Shrink guard: refuse to write an effectively-empty store over a non-empty file.
        // A full wipe is virtually always a bug (bad load, decode fallback), not intent —
        // back the disk copy up and skip the destructive write rather than lose records.
        if data.isEffectivelyEmpty, let raw = try? Data(contentsOf: fileURL),
           let disk = try? JSONDecoder.studybar.decode(AppData.self, from: raw), !disk.isEffectivelyEmpty {
            backupDiskFile()
            NSLog("StudyBar: refused to overwrite a non-empty store (%d records) with an empty one", disk.contentCount)
            return
        }
        guard let raw = try? JSONEncoder.studybar.encode(data) else { return }
        do {
            try raw.write(to: fileURL, options: .atomic)
            loadedMtime = AppState.mtime(fileURL)
            baseData = data
        } catch { /* leave loadedMtime/baseData so a later save retries the merge check */ }
    }

    /// If the on-disk file is newer than our last sync point, back it up and return the
    /// 3-way merge of (ancestor `baseData`, our `data`, the newer disk copy). Returns nil
    /// when there is no external change, or the disk file can't be decoded (in which case
    /// the raw file has still been backed up, so overwriting it loses nothing).
    private func mergeAgainstDiskIfChanged() -> AppData? {
        guard let disk = AppState.mtime(fileURL), let loaded = loadedMtime,
              disk.timeIntervalSince(loaded) > 1 else { return nil }   // >1s allows for fs granularity
        backupDiskFile()
        guard let raw = try? Data(contentsOf: fileURL),
              let theirs = try? JSONDecoder.studybar.decode(AppData.self, from: raw) else { return nil }
        return AppData.merged(base: baseData, mine: data, theirs: theirs)
    }

    /// Copy the current on-disk file to a timestamped `.conflict-*` sibling.
    private func backupDiskFile() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = fileURL.deletingLastPathComponent()
            .appendingPathComponent("data.json.conflict-\(f.string(from: Date()))")
        try? FileManager.default.copyItem(at: fileURL, to: dst)
    }

    /// The on-disk file changed under us (another device/instance): merge it into our
    /// live state instead of adopting it wholesale, so unsaved local edits survive too.
    func reloadIfChanged() {
        guard let disk = AppState.mtime(fileURL) else { return }
        if let loaded = loadedMtime, disk.timeIntervalSince(loaded) <= 1 { return }
        guard let raw = try? Data(contentsOf: fileURL),
              let theirs = try? JSONDecoder.studybar.decode(AppData.self, from: raw) else { return }
        let merged = AppData.merged(base: baseData, mine: data, theirs: theirs)
        suppressSave = true
        data = merged
        suppressSave = false
        loadedMtime = disk
        baseData = merged
        // If the merge added anything the disk file lacks (unsaved local edits), persist
        // the union so the other device converges on it too.
        if merged != theirs { scheduleSave() }
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
        loadedMtime = AppState.mtime(fileURL)
        baseData = data
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
    // MARK: News read-state — keyed by article link (Articles are re-parsed each refresh).
    func isRead(_ link: String) -> Bool { (data.rssRead ?? []).contains(link) }
    func markRead(_ link: String, _ read: Bool = true) {
        var set = Set(data.rssRead ?? [])
        if read { set.insert(link) } else { set.remove(link) }
        data.rssRead = set.isEmpty ? nil : Array(set)
    }
    func markRead(_ links: [String]) {
        guard !links.isEmpty else { return }
        var set = Set(data.rssRead ?? []); set.formUnion(links)
        data.rssRead = Array(set)
    }
    var fileRefs: [FileRef] {
        get { data.fileRefs ?? [] }
        set { data.fileRefs = newValue }
    }
    /// Planned work blocks (stored optional in AppData; exposed as a plain array).
    var timeBlocks: [TimeBlock] {
        get { data.timeBlocks ?? [] }
        set { data.timeBlocks = newValue.isEmpty ? nil : newValue }
    }

    /// Blocks planned for a given calendar day, sorted by start time.
    func timeBlocks(on day: Date) -> [TimeBlock] {
        let d = Calendar.current.startOfDay(for: day)
        return timeBlocks.filter { Calendar.current.isDate($0.day, inSameDayAs: d) }
            .sorted { $0.startMinutes < $1.startMinutes }
    }

    /// Insert or update a block (bumps `updatedAt` so a sync tie resolves to the edit).
    func upsertTimeBlock(_ block: TimeBlock) {
        var b = block; b.updatedAt = .now
        var blocks = timeBlocks
        if let i = blocks.firstIndex(where: { $0.id == b.id }) { blocks[i] = b } else { blocks.append(b) }
        timeBlocks = blocks
    }

    func deleteTimeBlock(_ id: UUID) {
        withUndo("Delete block") { timeBlocks.removeAll { $0.id == id } }
    }

    /// Start a focus session for a planned block: it inherits the block's course and
    /// linked assignment (so the logged time lands back on them) and runs for the block's
    /// planned length. Caller-independent — also jumps to the Time & Focus module so the
    /// running timer is visible.
    func focusTimeBlock(_ b: TimeBlock) {
        pomodoro.focusMinutes = max(5, min(180, b.durationMinutes))
        let label = b.title.isEmpty ? (course(b.courseID)?.name ?? "Focus") : b.title
        pomodoro.startFocus(label: label, courseID: b.courseID, assignmentID: b.assignmentID)
        selectedModuleID = "timefocus"
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
            .filter { $0.meets(on: wd) && $0.endMinutes >= now }
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
