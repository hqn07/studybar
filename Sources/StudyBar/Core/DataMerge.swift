import Foundation

// MARK: - 3-way merge for conflict-safe sync
//
// When two devices edit the iCloud data file between syncs, a plain "last writer
// wins" clobbers whichever side saves second. Instead we keep the last synced
// snapshot as a common ancestor (`base`) and 3-way merge local (`mine`) against the
// newer on-disk copy (`theirs`). Guarantees, per collection, keyed by stable id:
//   • add on either side            → kept
//   • delete one side, untouched other → honored (dropped)
//   • edit one side, untouched other → edit kept
//   • edit vs delete                → edit wins (never lose an edited item)
//   • edit vs edit                  → last writer wins by mergeStamp (tie → local)
// The whole design biases toward *never losing* data (HARD RULE); the raw newer
// disk file is also copied to a `.conflict-*` backup before any merge, belt-and-suspenders.

/// An item that can be 3-way merged by stable id. `mergeStamp` is the "last activity"
/// time, used only to break a both-sides-edited conflict.
protocol MergeItem: Identifiable, Equatable {
    var mergeStamp: Date { get }
}

/// 3-way merge a scalar: take whichever side changed vs the ancestor; if both changed,
/// prefer `mine` (the active saver).
func merge3<T: Equatable>(_ base: T, _ mine: T, _ theirs: T) -> T {
    if mine == theirs { return mine }
    if theirs == base { return mine }     // only mine changed
    if mine == base { return theirs }     // only theirs changed
    return mine                           // both changed → prefer local
}

/// 3-way merge two edited copies of an id-keyed collection given their ancestor `base`.
/// Order: `mine`'s order preserved; remote-only additions appended.
func mergeLists<T: MergeItem>(base: [T], mine: [T], theirs: [T]) -> [T] where T.ID: Hashable {
    let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let mineByID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let theirsByID = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    /// Resolve the fate of one id across all three sides. `nil` = drop it.
    func decide(_ id: T.ID) -> T? {
        let b = baseByID[id], m = mineByID[id], t = theirsByID[id]
        switch (m, t) {
        case let (m?, t?):
            guard let b else {                       // same id first-seen on both (unlikely for UUID)
                return m.mergeStamp >= t.mergeStamp ? m : t
            }
            let mChanged = m != b, tChanged = t != b
            if mChanged && tChanged { return m.mergeStamp >= t.mergeStamp ? m : t }
            return tChanged ? t : m                  // at most one changed
        case let (m?, nil):                          // gone from theirs
            if let b { return m != b ? m : nil }     // was shared: edited locally → keep; else honor their delete
            return m                                 // added locally → keep
        case let (nil, t?):                          // gone from mine
            if let b { return t != b ? t : nil }     // was shared: edited remotely → keep; else honor my delete
            return t                                 // added remotely → keep
        case (nil, nil):
            return nil                               // deleted on both
        }
    }

    var result: [T] = []
    var emitted = Set<T.ID>()
    for item in mine where emitted.insert(item.id).inserted {
        if let keep = decide(item.id) { result.append(keep) }
    }
    for item in theirs where emitted.insert(item.id).inserted {
        if let keep = decide(item.id) { result.append(keep) }
    }
    return result
}

/// Optional-array variant (decode-tolerant fields). Stays `nil` only when nothing exists
/// on either edited side, so we don't rewrite `nil` into `[]` for older data files.
func mergeOptLists<T: MergeItem>(base: [T]?, mine: [T]?, theirs: [T]?) -> [T]? where T.ID: Hashable {
    let merged = mergeLists(base: base ?? [], mine: mine ?? [], theirs: theirs ?? [])
    if merged.isEmpty && mine == nil && theirs == nil { return nil }
    return merged
}

extension AppData {
    /// 3-way merge the whole document. `base` is the last synced snapshot; `mine` the
    /// in-memory copy; `theirs` the newer on-disk copy.
    static func merged(base: AppData, mine: AppData, theirs: AppData) -> AppData {
        var r = mine
        r.courses     = mergeLists(base: base.courses,     mine: mine.courses,     theirs: theirs.courses)
        r.notes       = mergeLists(base: base.notes,       mine: mine.notes,       theirs: theirs.notes)
        r.clips       = mergeLists(base: base.clips,       mine: mine.clips,       theirs: theirs.clips)
        r.snippets    = mergeLists(base: base.snippets,    mine: mine.snippets,    theirs: theirs.snippets)
        r.assignments = mergeLists(base: base.assignments, mine: mine.assignments, theirs: theirs.assignments)
        r.todos       = mergeLists(base: base.todos,       mine: mine.todos,       theirs: theirs.todos)
        r.links       = mergeLists(base: base.links,       mine: mine.links,       theirs: theirs.links)
        r.timeEntries = mergeLists(base: base.timeEntries, mine: mine.timeEntries, theirs: theirs.timeEntries)
        r.references  = mergeLists(base: base.references,  mine: mine.references,  theirs: theirs.references)
        r.decks       = mergeLists(base: base.decks,       mine: mine.decks,       theirs: theirs.decks)
        r.flashcards  = mergeLists(base: base.flashcards,  mine: mine.flashcards,  theirs: theirs.flashcards)
        r.reading     = mergeLists(base: base.reading,     mine: mine.reading,     theirs: theirs.reading)
        r.readingLog  = mergeLists(base: base.readingLog,  mine: mine.readingLog,  theirs: theirs.readingLog)
        r.classes     = mergeLists(base: base.classes,     mine: mine.classes,     theirs: theirs.classes)
        r.readingList = mergeLists(base: base.readingList, mine: mine.readingList, theirs: theirs.readingList)
        r.icsFeeds    = mergeLists(base: base.icsFeeds,    mine: mine.icsFeeds,    theirs: theirs.icsFeeds)
        r.folders     = mergeLists(base: base.folders,     mine: mine.folders,     theirs: theirs.folders)
        r.gradeItems  = mergeOptLists(base: base.gradeItems, mine: mine.gradeItems, theirs: theirs.gradeItems)
        r.rssFeeds    = mergeOptLists(base: base.rssFeeds,   mine: mine.rssFeeds,   theirs: theirs.rssFeeds)
        r.fileRefs    = mergeOptLists(base: base.fileRefs,   mine: mine.fileRefs,   theirs: theirs.fileRefs)
        r.trash       = mergeOptLists(base: base.trash,      mine: mine.trash,      theirs: theirs.trash)
        // Scalars.
        r.scratchpad  = merge3(base.scratchpad, mine.scratchpad, theirs.scratchpad)
        r.termName    = merge3(base.termName,   mine.termName,   theirs.termName)
        r.termStart   = merge3(base.termStart,  mine.termStart,  theirs.termStart)
        r.termEnd     = merge3(base.termEnd,    mine.termEnd,    theirs.termEnd)
        return r
    }
}

// MARK: - Per-model recency (mergeStamp)
// Only used to break an edit-vs-edit conflict on the same id. Models without a real
// "edited at" fall back to .distantPast → such a conflict resolves to the local copy
// (and the remote copy survives in the .conflict-* backup).

extension Course:          MergeItem { var mergeStamp: Date { createdAt } }
extension Note:            MergeItem { var mergeStamp: Date { updatedAt } }
extension ClipItem:        MergeItem { var mergeStamp: Date { copiedAt } }
extension Snippet:         MergeItem { var mergeStamp: Date { .distantPast } }
extension Assignment:      MergeItem { var mergeStamp: Date { createdAt } }
extension TodoItem:        MergeItem { var mergeStamp: Date { createdAt } }
extension QuickLink:       MergeItem { var mergeStamp: Date { .distantPast } }
extension TimeEntry:       MergeItem { var mergeStamp: Date { date } }
extension Reference:       MergeItem { var mergeStamp: Date { addedAt } }
extension Deck:            MergeItem { var mergeStamp: Date { createdAt } }
extension Flashcard:       MergeItem { var mergeStamp: Date { lastReview ?? .distantPast } }
extension ReadingItem:     MergeItem { var mergeStamp: Date { updatedAt } }
extension ReadEvent:       MergeItem { var mergeStamp: Date { date } }
extension ClassSession:    MergeItem { var mergeStamp: Date { .distantPast } }
extension ReadingListItem: MergeItem { var mergeStamp: Date { addedAt } }
extension ICSFeed:         MergeItem { var mergeStamp: Date { lastSynced ?? .distantPast } }
extension FolderRef:       MergeItem { var mergeStamp: Date { .distantPast } }
extension FileRef:         MergeItem { var mergeStamp: Date { addedAt } }
extension GradeItem:       MergeItem { var mergeStamp: Date { .distantPast } }
extension RSSFeed:         MergeItem { var mergeStamp: Date { .distantPast } }
extension TrashedItem:     MergeItem { var mergeStamp: Date { deletedAt } }

// MARK: - Headless self-test
// Run with `StudyBar --merge-selftest` (see AppDelegate). Exercises the merge
// guarantees without any GUI, prints per-case results, exits 0 (all pass) or 1.

enum MergeSelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            print((cond ? "  ok   " : "FAIL   ") + name)
            if !cond { failures += 1 }
        }

        // Stable ids: build once, mutate copies.
        var a = TodoItem(text: "A"); var b = TodoItem(text: "B"); var c = TodoItem(text: "C")
        let ids = { (xs: [TodoItem]) in Set(xs.map(\.id)) }

        // 1. add on both sides → union.
        do {
            let m = mergeLists(base: [a], mine: [a, b], theirs: [a, c])
            check("add both sides → A,B,C", ids(m) == ids([a, b, c]))
        }
        // 2. delete local, untouched remote → dropped.
        do {
            let m = mergeLists(base: [a, b], mine: [a], theirs: [a, b])
            check("local delete honored", ids(m) == ids([a]))
        }
        // 3. delete remote, untouched local → dropped.
        do {
            let m = mergeLists(base: [a, b], mine: [a, b], theirs: [a])
            check("remote delete honored", ids(m) == ids([a]))
        }
        // 4. delete on both → dropped.
        do {
            let m = mergeLists(base: [a, b], mine: [a], theirs: [a])
            check("delete both → dropped", ids(m) == ids([a]))
        }
        // 5. edit remote only → remote edit kept.
        do {
            var bEdited = b; bEdited.text = "B-remote"
            let m = mergeLists(base: [a, b], mine: [a, b], theirs: [a, bEdited])
            check("remote edit kept", m.first { $0.id == b.id }?.text == "B-remote")
        }
        // 6. edit local only → local edit kept.
        do {
            var bEdited = b; bEdited.text = "B-local"
            let m = mergeLists(base: [a, b], mine: [a, bEdited], theirs: [a, b])
            check("local edit kept", m.first { $0.id == b.id }?.text == "B-local")
        }
        // 7. edit vs delete → edit wins (never lose).
        do {
            var bEdited = b; bEdited.text = "B-remote"
            let m = mergeLists(base: [a, b], mine: [a], theirs: [a, bEdited]) // deleted local, edited remote
            check("edit beats delete", m.contains { $0.id == b.id && $0.text == "B-remote" })
        }
        // 8. edit vs edit → last writer wins by mergeStamp (Note.updatedAt), tie → mine.
        do {
            let t0 = Date(timeIntervalSince1970: 1000)
            var base = Note(); base.updatedAt = t0; base.title = "base"
            var mine = base; mine.title = "mine";  mine.updatedAt = t0.addingTimeInterval(10)
            var theirs = base; theirs.title = "theirs"; theirs.updatedAt = t0.addingTimeInterval(20)
            let m = mergeLists(base: [base], mine: [mine], theirs: [theirs])
            check("edit/edit LWW → later (theirs)", m.first?.title == "theirs")
            var theirsOlder = theirs; theirsOlder.updatedAt = t0.addingTimeInterval(5)
            let m2 = mergeLists(base: [base], mine: [mine], theirs: [theirsOlder])
            check("edit/edit LWW → later (mine)", m2.first?.title == "mine")
        }
        // 9. scalar: both changed → mine.
        check("scalar both-changed → mine", merge3("", "local", "remote") == "local")
        // 10. scalar: only remote changed → remote.
        check("scalar remote-only → remote", merge3("", "", "remote") == "remote")
        // 11. scalar: only local changed → local.
        check("scalar local-only → local", merge3("", "local", "") == "local")
        // 12. optional list: all nil → stays nil; add one side → present.
        do {
            let g = GradeItem(name: "Midterm")
            let allNil: [GradeItem]? = mergeOptLists(base: nil, mine: nil, theirs: nil)
            check("optlist all-nil stays nil", allNil == nil)
            let m = mergeOptLists(base: nil, mine: nil, theirs: [g])
            check("optlist remote add present", m?.count == 1)
        }
        // 13. AppData end-to-end: independent adds + a delete + a scalar edit all converge.
        do {
            var base = AppData()
            base.todos = [a, b]; base.scratchpad = "x"
            var mine = base
            mine.todos = [a, b, c]                 // local: add C
            mine.scratchpad = "x local"            // local: edit scalar
            var theirs = base
            theirs.todos = [a]                     // remote: delete B
            let m = AppData.merged(base: base, mine: mine, theirs: theirs)
            check("AppData: C added + B deleted", ids(m.todos) == ids([a, c]))
            check("AppData: scalar local edit kept", m.scratchpad == "x local")
        }
        // 14. no-op: base==mine==theirs → identical.
        do {
            var d = AppData(); d.todos = [a, b]; d.scratchpad = "s"
            check("no-op merge is identity", AppData.merged(base: d, mine: d, theirs: d) == d)
        }
        // 15. order: mine order preserved, remote-only appended.
        do {
            let m = mergeLists(base: [], mine: [a, b], theirs: [c])
            check("order: mine first, remote appended", m.map(\.id) == [a.id, b.id, c.id])
        }

        // 16. Trash: deletion capture, payload round-trip, bulk cap, no-op.
        do {
            let n1 = Note(title: "Keep A"), n2 = Note(title: "Delete me"), n3 = Note(title: "Keep C")
            var before = AppData(); before.notes = [n1, n2, n3]
            var after = before; after.notes = [n1, n3]
            let t = AppData.deletionTrash(before: before, after: after)
            check("trash: one captured", t.count == 1 && t.first?.collection == "notes" && t.first?.itemID == n2.id)
            let restored = t.first.flatMap { try? JSONDecoder.studybar.decode(Note.self, from: $0.payload) }
            check("trash: payload restores", restored?.id == n2.id && restored?.title == "Delete me")
            var big = AppData(); big.todos = (0..<30).map { TodoItem(text: "t\($0)") }
            check("trash: bulk delete skipped", AppData.deletionTrash(before: big, after: AppData()).isEmpty)
            check("trash: no deletion → empty", AppData.deletionTrash(before: before, after: before).isEmpty)
        }

        print(failures == 0 ? "MERGE SELFTEST: ALL PASS" : "MERGE SELFTEST: \(failures) FAILURE(S)")
        return failures == 0 ? 0 : 1
    }
}
