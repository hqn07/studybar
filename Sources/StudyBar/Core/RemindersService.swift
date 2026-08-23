import Foundation
import EventKit

/// One-way push of open assignments into an Apple Reminders "StudyBar" list.
@MainActor
enum RemindersService {
    private static let store = EKEventStore()
    private static let listName = "StudyBar"

    static func push(_ data: AppData) async -> String {
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestFullAccessToReminders { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else { return "Reminders access denied — enable in System Settings ▸ Privacy ▸ Reminders." }

        // Find or create the StudyBar list.
        let cal: EKCalendar
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == listName }) {
            cal = existing
        } else {
            let c = EKCalendar(for: .reminder, eventStore: store)
            c.title = listName
            c.source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local })
                ?? store.sources.first
            do { try store.saveCalendar(c, commit: true) } catch { return "Couldn't create the StudyBar reminders list." }
            cal = c
        }

        // Existing reminders, tagged by assignment id in notes.
        let pred = store.predicateForReminders(in: [cal])
        let existing: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
        let existingTags = existing.compactMap { $0.notes }

        var count = 0
        for a in data.assignments where a.status != .done && a.due != nil {
            let tag = "studybar:\(a.id.uuidString)"
            if existingTags.contains(where: { $0.contains(tag) }) { continue }
            let r = EKReminder(eventStore: store)
            r.calendar = cal
            r.title = a.title.isEmpty ? "Assignment" : a.title
            r.notes = tag
            if let due = a.due {
                r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            }
            try? store.save(r, commit: false)
            count += 1
        }
        try? store.commit()
        return count == 0 ? "Reminders already up to date." : "Pushed \(count) assignment\(count == 1 ? "" : "s") to Reminders."
    }
}
