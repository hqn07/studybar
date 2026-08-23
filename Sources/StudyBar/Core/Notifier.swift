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
