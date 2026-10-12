// NotificationService.swift — schedule and cancel local task reminders.
import Foundation
import UserNotifications

enum NotificationService {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func schedule(_ task: TaskItem) {
        // Reminders require an active membership (trial or subscribed) and the
        // reminders setting on; otherwise nothing is scheduled.
        let remindersOn = UserDefaults.standard.object(forKey: "notif_task_reminders") as? Bool ?? true
        guard MembershipAccess.hasAccess(), remindersOn,
              let due = task.dueDate, !task.completed, task.deletedAt == nil else {
            cancel(task.uid)
            return
        }
        cancel(task.uid)

        let content = UNMutableNotificationContent()
        // Kind reminders instead of nagging alerts: warm, sentence case, no emoji.
        content.title = task.priority == .high
            ? "A gentle nudge for something important"
            : "A kind reminder from Evry"
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
}
