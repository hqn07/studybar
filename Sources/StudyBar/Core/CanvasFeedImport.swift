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
    /// match the bracketed `[CODE]`/name Canvas appends to the title, against the
    /// user's courses (case-insensitive, code or name).
    static func courseID(for e: ICSEvent, feed: ICSFeed, courses: [Course]) -> UUID? {
        if let c = feed.courseID { return c }
        guard let r = e.title.range(of: #"\[([^\]]+)\]\s*$"#, options: .regularExpression) else { return nil }
        let tag = e.title[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        guard !tag.isEmpty else { return nil }
        return courses.first {
            $0.code.lowercased() == tag || $0.name.lowercased() == tag || $0.name.lowercased().contains(tag)
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
