import Foundation
import UserNotifications

/// Local notifications (13) with actionable Complete / Snooze buttons for deadlines.
enum Notifier {
    static let assignmentCategory = "ASSIGNMENT"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = NotifDelegate.shared
        registerCategories()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func registerCategories() {
        let complete = UNNotificationAction(identifier: "COMPLETE", title: "Mark Done", options: [])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 1 day", options: [])
        let cat = UNNotificationCategory(identifier: assignmentCategory,
                                         actions: [complete, snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Schedule a reminder. If `assignmentID` is set, adds Complete / Snooze actions.
    static func schedule(id: String, title: String, body: String, at date: Date, assignmentID: UUID? = nil) {
        guard date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        if let aid = assignmentID {
            content.categoryIdentifier = assignmentCategory
            content.userInfo = ["assignmentID": aid.uuidString]
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Managed reminders (classes + assignments)

    static let classPrefix = "class-"
    /// Class reminders default on; assignment reminders default on. Lead time in minutes.
    static var classRemindersOn: Bool { UserDefaults.standard.object(forKey: "notifyClasses") as? Bool ?? true }
    static var assignmentRemindersOn: Bool { UserDefaults.standard.object(forKey: "notifyAssignments") as? Bool ?? true }
    static var classLeadMinutes: Int { UserDefaults.standard.object(forKey: "notifyClassLead") as? Int ?? 10 }

    /// A repeating weekly reminder that fires at a fixed weekday + time (before a class).
    static func scheduleClass(id: String, title: String, body: String, weekday: Int, hour: Int, minute: Int) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        var comps = DateComponents(); comps.weekday = weekday; comps.hour = hour; comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Rebuild every StudyBar-managed reminder from current data, honoring the settings
    /// toggles. Removes only managed ones (class-* and assignment UUIDs) so pomodoro/break
    /// posts are untouched. Respects the OS's 64-pending-notification limit: classes first
    /// (few, repeating), then assignments due soonest within two weeks.
    static func rescheduleAll(_ data: AppData) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let managed = reqs.map(\.identifier).filter { $0.hasPrefix(classPrefix) || UUID(uuidString: $0) != nil }
            center.removePendingNotificationRequests(withIdentifiers: managed)
            DispatchQueue.main.async {
                var budget = 60   // stay under the 64 hard cap, leave headroom

                if classRemindersOn {
                    let lead = max(0, classLeadMinutes)
                    for c in data.classes {
                        let fire = max(0, c.startMinutes - lead)
                        let name = data.courses.first { $0.id == c.courseID }?.name
                            ?? (c.title.isEmpty ? "Class" : c.title)
                        let body = c.room.isEmpty ? "Starts \(ClassSession.hm(c.startMinutes))"
                                                  : "\(ClassSession.hm(c.startMinutes)) · \(c.room)"
                        for wd in c.weekdays where budget > 0 {
                            scheduleClass(id: "\(classPrefix)\(c.id.uuidString)-\(wd)",
                                          title: lead > 0 ? "\(name) in \(lead) min" : "\(name) now",
                                          body: body, weekday: wd, hour: fire / 60, minute: fire % 60)
                            budget -= 1
                        }
                    }
                }

                if assignmentRemindersOn {
                    let cal = Calendar.current
                    let horizon = cal.date(byAdding: .day, value: 14, to: .now) ?? .now
                    let soon = data.assignments
                        .filter { $0.status != .done }
                        .compactMap { a -> (Assignment, Date)? in a.due.map { (a, $0) } }
                        .filter { $0.1 <= horizon }
                        .sorted { $0.1 < $1.1 }
                    for (a, due) in soon where budget > 0 {
                        // Evening before at 6pm; if that's already past, fire at the due time.
                        let before = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: due)) ?? due
                        var comps = cal.dateComponents([.year, .month, .day], from: before)
                        comps.hour = 18
                        let when = cal.date(from: comps) ?? due
                        let fire = when > .now ? when : due
                        guard fire > .now else { continue }
                        let course = data.courses.first { $0.id == a.courseID }?.code ?? ""
                        schedule(id: a.id.uuidString,
                                 title: fire == due ? "Due: \(a.title)" : "Due tomorrow: \(a.title)",
                                 body: course.isEmpty ? "" : course, at: fire, assignmentID: a.id)
                        budget -= 1
                    }
                }
            }
        }
    }
}

/// Handles notification action buttons + foreground presentation.
final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions { [.banner, .sound] }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let idStr = info["assignmentID"] as? String, let id = UUID(uuidString: idStr) else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case "COMPLETE": AppActions.completeAssignment(id: id)
            case "SNOOZE": AppActions.snoozeAssignment(id: id, days: 1)
            default: AppActions.open(module: "assignments")   // tapped the notification body
            }
        }
    }
}
