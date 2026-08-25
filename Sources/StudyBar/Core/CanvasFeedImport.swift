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
            for ev in events where isAssignment(ev) {
                guard let due = ev.start, due.timeIntervalSinceNow > staleCutoff else { continue }
                let uid = ev.uid.isEmpty ? ev.url : ev.uid
                guard !uid.isEmpty else { continue }

                let title = cleanTitle(ev.title)
                let course = courseID(for: ev, feed: feed, courses: state.data.courses)

                if let i = state.data.assignments.firstIndex(where: { $0.sourceUID == uid }) {
                    // Update in place. Preserve user edits (status/notes/checklist);
                    // only refresh the fields the feed owns.
                    var a = state.data.assignments[i]
                    var changed = false
                    if a.due != due { a.due = due; changed = true }
                    if a.title != title { a.title = title; changed = true }
                    if a.courseID == nil, let course { a.courseID = course; changed = true }
                    if changed { state.data.assignments[i] = a; s.updated += 1 }
                } else {
                    var a = Assignment(title: title, courseID: course, due: due)
                    a.sourceUID = uid
                    state.data.assignments.append(a)
                    s.created += 1
                }
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
            out.append(Planned(uid: uid, title: cleanTitle(ev.title), due: due,
                               courseID: course, code: codeTag(ev.title),
                               isNew: !state.data.assignments.contains { $0.sourceUID == uid }))
        }
        return out.sorted { $0.due < $1.due }
    }

    /// Write a reviewed plan into assignments. Unlike `run`, this honors an explicit
    /// course choice even when the assignment already has one (the user picked it).
    @MainActor
    @discardableResult
    static func apply(_ planned: [Planned], into state: AppState) -> Summary {
        var s = Summary()
        for p in planned {
            if let i = state.data.assignments.firstIndex(where: { $0.sourceUID == p.uid }) {
                var a = state.data.assignments[i]; var changed = false
                if a.due != p.due { a.due = p.due; changed = true }
                if a.title != p.title { a.title = p.title; changed = true }
                if let c = p.courseID, a.courseID != c { a.courseID = c; changed = true }
                if changed { state.data.assignments[i] = a; s.updated += 1 }
            } else {
                var a = Assignment(title: p.title, courseID: p.courseID, due: p.due)
                a.sourceUID = p.uid
                state.data.assignments.append(a)
                s.created += 1
            }
        }
        return s
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
