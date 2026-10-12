// AddTaskIntent.swift — Siri / Shortcuts "Add a task" App Intent.
import AppIntents
import Foundation

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a task to Evry"
    static var description = IntentDescription(
        "Add a task to your Evry list. Works with Siri and Shortcuts."
    )
    // Keep the app in background; the task is written to UserDefaults and
    // the main app processes it on next foreground activation.
    static var openAppWhenRun = false

    @Parameter(title: "Task title", description: "What the task is called")
    var taskTitle: String

    @Parameter(title: "Due date", default: nil)
    var dueDate: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$taskTitle) to Evry") {
            \.$dueDate
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // parseTaskInput / formatDueDate are @MainActor-isolated (TaskParsing.swift imports SwiftUI).
        let (finalTitle, finalDate, dateSuffix) = await MainActor.run {
            let parsed = parseTaskInput(taskTitle)
            let title = parsed.title.isEmpty ? taskTitle : parsed.title
            let date = dueDate ?? parsed.date  // explicit Siri date wins
            let suffix = date.flatMap { formatDueDate($0) }.map { " due \($0)" } ?? ""
            return (title, date, suffix)
        }

        var entry: [String: Any] = ["title": finalTitle]
        if let due = finalDate {
            entry["dueDate"] = due.timeIntervalSince1970
        }
        let key = "pendingSiriTasks"
        var pending = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        pending.append(entry)
        UserDefaults.standard.set(pending, forKey: key)

        return .result(dialog: "I’ve added “\(finalTitle)” to Evry\(dateSuffix).")
    }
}

struct EvryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Create a new task in \(.applicationName)",
                "Remind me in \(.applicationName)",
            ],
            shortTitle: "Add task",
            systemImageName: "plus.circle"
        )
    }
}
