import Foundation

/// Materializes assignment-type events from subscribed Canvas / LMS `.ics` feeds
/// into real `Assignment`s (with due dates, per-course), deduped by the event UID.
///
/// No Canvas API or token needed — this uses the student's personal **Calendar
/// Feed** URL (Canvas ▸ Calendar ▸ Calendar Feed). Canvas emits every assignment
/// as a VEVENT whose `URL`/`UID` contains "assignment"; class-time and other
/// calendar events are left alone (they stay calendar-only).
///
/// Refresh is idempotent: an item already imported (matched by `sourceUID`) is
/// updated in place (due/title), never duplicated, and user data is never deleted.
enum CanvasFeedImport {
    struct Summary { var created = 0; var updated = 0; var feeds = 0; var failed = 0 }

    private static let staleCutoff: TimeInterval = -14 * 86400   // skip items due > 2 weeks ago

    /// Fetch every subscribed feed and sync its assignment-type events into
    /// `state.data.assignments`. Returns counts for a status line.
    @MainActor
    static func run(state: AppState) async -> Summary {
        var s = Summary()
        let feeds = state.data.icsFeeds
        guard !feeds.isEmpty else { return s }

        for feed in feeds {
            guard let events = await fetch(feed.url) else { s.failed += 1; continue }
            s.feeds += 1
            var feedTouched = 0
            for ev in events where isAssignment(ev) {
                guard let due = ev.start, due.timeIntervalSinceNow > staleCutoff else { continue }
                let uid = ev.uid.isEmpty ? ev.url : ev.uid
                guard !uid.isEmpty else { continue }

                let title = cleanTitle(ev.title)
                let tag = codeTag(ev.title)
                let course = feed.courseID ?? matchCourse(tag, state.data.courses)

                if let i = state.data.assignments.firstIndex(where: { $0.sourceUID == uid }) {
                    // Update in place. Preserve user edits (status/notes/checklist);
                    // only fill the fields the feed owns (course only when still empty).
                    var a = state.data.assignments[i]
                    var changed = false
                    if a.due != due { a.due = due; changed = true }
                    if a.title != title { a.title = title; changed = true }
                    if a.courseID == nil, let course { a.courseID = course; changed = true }
                    if a.sourceFeedID == nil { a.sourceFeedID = feed.id; changed = true }
                    if a.sourceCourseTag == nil, let tag { a.sourceCourseTag = tag; changed = true }
                    if changed { state.data.assignments[i] = a; s.updated += 1; feedTouched += 1 }
                } else if let j = fuzzyIndex(title: title, courseID: course, due: due, in: state.data.assignments) {
                    // Adopt a manually-typed assignment that matches, instead of duplicating.
                    var a = state.data.assignments[j]
                    a.sourceUID = uid; a.sourceFeedID = feed.id; a.due = due; a.sourceCourseTag = tag
                    if a.courseID == nil, let course { a.courseID = course }
                    state.data.assignments[j] = a; s.updated += 1; feedTouched += 1
                } else {
                    var a = Assignment(title: title, courseID: course, due: due)
                    a.sourceUID = uid; a.sourceFeedID = feed.id; a.sourceCourseTag = tag
                    state.data.assignments.append(a)
                    s.created += 1; feedTouched += 1
                }
            }
            if let fi = state.data.icsFeeds.firstIndex(where: { $0.id == feed.id }) {
                state.data.icsFeeds[fi].lastSynced = Date()
                state.data.icsFeeds[fi].lastImported = feedTouched
            }
        }
        return s
    }

    // MARK: - Guided flow: dry-run plan + apply (used by ConnectCanvasView)

    /// One candidate assignment from a feed, resolved but not yet written.
    struct Planned: Identifiable {
        let id = UUID()
        var uid: String
        var title: String
        var due: Date
        var courseID: UUID?      // detected (feed course or [CODE] match); user may override
        var code: String?        // the [CODE] tag Canvas appended, if any (grouping key)
        var isNew: Bool          // false = already imported (this run would update it)
    }

    /// Fetch + map a feed WITHOUT writing — for the connect preview. nil = fetch/parse failed.
    @MainActor
    static func plan(feedURL: String, feedCourseID: UUID?, state: AppState) async -> [Planned]? {
        guard let events = await fetch(feedURL) else { return nil }
        var out: [Planned] = []
        for ev in events where isAssignment(ev) {
            guard let due = ev.start, due.timeIntervalSinceNow > staleCutoff else { continue }
            let uid = ev.uid.isEmpty ? ev.url : ev.uid
            guard !uid.isEmpty else { continue }
            let course = feedCourseID ?? matchCourse(codeTag(ev.title), state.data.courses)
            let title = cleanTitle(ev.title)
            let exists = state.data.assignments.contains { $0.sourceUID == uid }
                || fuzzyIndex(title: title, courseID: course, due: due, in: state.data.assignments) != nil
            out.append(Planned(uid: uid, title: title, due: due,
                               courseID: course, code: codeTag(ev.title), isNew: !exists))
        }
        return out.sorted { $0.due < $1.due }
    }

    /// Write a reviewed plan into assignments. Unlike `run`, this honors an explicit
    /// course choice even when the assignment already has one (the user picked it).
    @MainActor
    @discardableResult
    static func apply(_ planned: [Planned], into state: AppState, feedID: UUID? = nil) -> Summary {
        var s = Summary()
        for p in planned {
            if let i = state.data.assignments.firstIndex(where: { $0.sourceUID == p.uid }) {
                var a = state.data.assignments[i]; var changed = false
                if a.due != p.due { a.due = p.due; changed = true }
                if a.title != p.title { a.title = p.title; changed = true }
                if let c = p.courseID, a.courseID != c { a.courseID = c; changed = true }   // explicit user pick wins
                if let f = feedID, a.sourceFeedID != f { a.sourceFeedID = f; changed = true }
                if a.sourceCourseTag == nil, let t = p.code { a.sourceCourseTag = t; changed = true }
                if changed { state.data.assignments[i] = a; s.updated += 1 }
            } else if let j = fuzzyIndex(title: p.title, courseID: p.courseID, due: p.due, in: state.data.assignments) {
                var a = state.data.assignments[j]
                a.sourceUID = p.uid; a.sourceFeedID = feedID; a.due = p.due; a.sourceCourseTag = p.code
                if let c = p.courseID { a.courseID = c }
                state.data.assignments[j] = a; s.updated += 1
            } else {
                var a = Assignment(title: p.title, courseID: p.courseID, due: p.due)
                a.sourceUID = p.uid; a.sourceFeedID = feedID; a.sourceCourseTag = p.code
                state.data.assignments.append(a)
                s.created += 1
            }
        }
        if let f = feedID, let fi = state.data.icsFeeds.firstIndex(where: { $0.id == f }) {
            state.data.icsFeeds[fi].lastSynced = Date()
            state.data.icsFeeds[fi].lastImported = s.created + s.updated
        }
        return s
    }

    /// Find a manually-typed assignment (no sourceUID) that plausibly matches a feed
    /// item — same normalized title, same course (or the manual one unassigned), due
    /// the same calendar day — so re-imports adopt it instead of duplicating.
    static func fuzzyIndex(title: String, courseID: UUID?, due: Date, in assignments: [Assignment]) -> Int? {
        let key = normalize(title)
        let cal = Calendar.current
        return assignments.firstIndex { a in
            a.sourceUID == nil
                && normalize(a.title) == key
                && (a.courseID == courseID || a.courseID == nil)
                && (a.due.map { cal.isDate($0, inSameDayAs: due) } ?? false)
        }
    }
    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pure mapping helpers (unit-testable)

    /// Canvas assignment VEVENTs carry "assignment" in their URL (`/assignments/<id>`)
    /// and UID (`event-assignment-<id>@…`). Calendar events use `/calendar_events/`.
    static func isAssignment(_ e: ICSEvent) -> Bool {
        (e.url + " " + e.uid).lowercased().contains("assignment")
    }

    /// Strip a trailing "[Course Code]" that Canvas appends to account-wide feed titles.
    static func cleanTitle(_ summary: String) -> String {
        guard let r = summary.range(of: #"\s*\[[^\]]+\]\s*$"#, options: .regularExpression) else {
            return summary.trimmingCharacters(in: .whitespaces)
        }
        return String(summary[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Course for an imported assignment: the feed's own course wins; otherwise
    /// match the bracketed `[CODE]`/name Canvas appends to the title.
    static func courseID(for e: ICSEvent, feed: ICSFeed, courses: [Course]) -> UUID? {
        feed.courseID ?? matchCourse(codeTag(e.title), courses)
    }

    /// The `[CODE]` tag Canvas appends to account-wide feed titles, if present.
    static func codeTag(_ summary: String) -> String? {
        guard let r = summary.range(of: #"\[([^\]]+)\]\s*$"#, options: .regularExpression) else { return nil }
        let tag = summary[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return tag.isEmpty ? nil : tag
    }

    /// Match a Canvas course code/name tag to a Course (case-insensitive, code or name).
    static func matchCourse(_ tag: String?, _ courses: [Course]) -> UUID? {
        guard let low = tag?.lowercased(), !low.isEmpty else { return nil }
        return courses.first {
            $0.code.lowercased() == low || $0.name.lowercased() == low || $0.name.lowercased().contains(low)
        }?.id
    }

    // MARK: - Classification (Classify page)

    /// Feed-imported assignments with no course assigned.
    @MainActor
    static func unclassified(_ state: AppState) -> [Assignment] {
        state.data.assignments.filter { $0.sourceUID != nil && $0.courseID == nil }
    }

    /// Unclassified imports grouped by their [CODE] tag; untagged items ("") sort last.
    @MainActor
    static func classifyGroups(_ state: AppState) -> [(tag: String, items: [Assignment])] {
        var dict: [String: [Assignment]] = [:]
        for a in unclassified(state) { dict[a.sourceCourseTag ?? "", default: []].append(a) }
        return dict.sorted {
            if $0.key.isEmpty != $1.key.isEmpty { return !$0.key.isEmpty }   // tagged groups first
            return $0.value.count > $1.value.count
        }.map { ($0.key, $0.value) }
    }

    /// Re-fetch subscribed feeds and backfill sourceCourseTag (and courseID when a
    /// matching course now exists) on imports that predate tag storage.
    @MainActor
    static func backfillTags(state: AppState) async {
        for feed in state.data.icsFeeds {
            guard let events = await fetch(feed.url) else { continue }
            var byUID: [String: String] = [:]
            for ev in events where isAssignment(ev) {
                let uid = ev.uid.isEmpty ? ev.url : ev.uid
                if let t = codeTag(ev.title) { byUID[uid] = t }
            }
            for i in state.data.assignments.indices {
                guard let uid = state.data.assignments[i].sourceUID, let t = byUID[uid] else { continue }
                if state.data.assignments[i].sourceCourseTag == nil { state.data.assignments[i].sourceCourseTag = t }
                if state.data.assignments[i].courseID == nil, let c = matchCourse(t, state.data.courses) {
                    state.data.assignments[i].courseID = c
                }
            }
        }
    }

    /// Create a Course from a tag and assign every unclassified import with that tag.
    @MainActor @discardableResult
    static func createCourseAndAssign(tag: String, state: AppState) -> UUID {
        let hex = Palette.swatches[state.data.courses.count % Palette.swatches.count]
        // Use the tag as the course code only when it looks like one (e.g. MAP2302) —
        // a long descriptive tag ("First Year Engineering Advising 2025") is a name, not
        // a code, so leave the code empty rather than stuffing the name into it.
        let looksLikeCode = tag.count <= 10 && !tag.contains(" ") && tag.contains(where: \.isNumber)
        let c = Course(name: tag, code: looksLikeCode ? tag : "", colorHex: hex)
        state.data.courses.append(c)
        assign(tag: tag, to: c.id, state: state)
        return c.id
    }

    /// Assign every unclassified import carrying `tag` to `courseID`.
    @MainActor
    static func assign(tag: String, to courseID: UUID, state: AppState) {
        for i in state.data.assignments.indices
        where state.data.assignments[i].sourceUID != nil
            && state.data.assignments[i].courseID == nil
            && (state.data.assignments[i].sourceCourseTag ?? "") == tag {
            state.data.assignments[i].courseID = courseID
        }
    }

    /// Assign specific assignments to a course.
    @MainActor
    static func assign(ids: Set<UUID>, to courseID: UUID, state: AppState) {
        for i in state.data.assignments.indices where ids.contains(state.data.assignments[i].id) {
            state.data.assignments[i].courseID = courseID
        }
    }

    // MARK: - Fetch

    private static func fetch(_ raw: String) async -> [ICSEvent]? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        guard let url = URL(string: s) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return ICSParser.parse(text)
        } catch { return nil }
    }
}
