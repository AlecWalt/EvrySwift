// NotificationService.swift — schedule and cancel local task reminders.
import Foundation
import UserNotifications

enum NotificationService {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func schedule(_ task: TaskItem) {
        guard let due = task.dueDate, !task.completed, task.deletedAt == nil else {
            cancel(task.uid)
            return
        }
        cancel(task.uid)

        let content = UNMutableNotificationContent()
        content.title = task.priority == .high ? "⚡ High-priority task due" : "Task due"
        content.body = task.title
        content.sound = .default
        if !task.tags.isEmpty {
            content.subtitle = task.tags.prefix(3).map { "#\($0)" }.joined(separator: " ")
        }

        var comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due
        )
        // Due dates with no explicit time (midnight) get a 9 AM nudge.
        if comps.hour == 0 && comps.minute == 0 {
            comps.hour = 9
            comps.minute = 0
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: task.uid.uuidString, content: content, trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func cancel(_ taskID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [taskID.uuidString])
    }

    /// Fires a test notification in 5 seconds. Used from the developer menu.
    static func scheduleTest() {
        let content = UNMutableNotificationContent()
        content.title = "Evry — Test Notification"
        content.body = "Notifications are working correctly. ✅"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "evry-dev-test-\(UUID().uuidString)", content: content, trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Returns a human-readable summary of all pending notification identifiers.
    static func pendingSummary() async -> String {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        if requests.isEmpty { return "No pending notifications." }
        return "\(requests.count) pending:\n" +
            requests.prefix(8).map { "• \($0.content.body)" }.joined(separator: "\n")
    }
}
