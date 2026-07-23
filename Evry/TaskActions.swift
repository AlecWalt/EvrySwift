//
//  TaskActions.swift
//  Evry
//
//  Shared task mutations — the Swift port of the store.js mutation helpers
//  (toggle with recurrence spin-off, soft delete/restore, snooze, duplicate).
//

import Foundation
import SwiftData

enum TaskActions {
    /// Toggle completion. Completing a recurring task spins off its next
    /// occurrence immediately, same as the webapp.
    static func toggle(_ task: TaskItem, context: ModelContext) {
        let completing = !task.completed
        task.completed = completing
        task.completedAt = completing ? Date() : nil

        if completing, let recurrence = task.recurrence, let due = task.dueDate {
            let next = TaskItem(
                title: task.title,
                dueDate: recurrence.nextOccurrence(after: due),
                tags: task.tags,
                priority: task.priority,
                notes: task.notes,
                isNote: task.isNote,
                project: task.project
            )
            next.recurrence = recurrence
            next.subtasks = task.subtasks.map { SubtaskData(title: $0.title) }
            context.insert(next)
        }
    }

    /// Soft delete — the task goes to trash (30-day retention) so the
    /// delete toast's Undo can restore it.
    static func delete(_ task: TaskItem) {
        task.deletedAt = Date()
    }

    static func restore(_ task: TaskItem) {
        task.deletedAt = nil
    }

    static func snooze(_ task: TaskItem) {
        guard let due = task.dueDate else { return }
        task.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: due)
    }

    static func duplicate(_ task: TaskItem, context: ModelContext) {
        let copy = TaskItem(
            title: "\(task.title) (copy)",
            dueDate: task.dueDate,
            tags: task.tags,
            priority: task.priority,
            notes: task.notes,
            isNote: task.isNote,
            project: task.project
        )
        copy.recurrence = task.recurrence
        copy.subtasks = task.subtasks.map { SubtaskData(title: $0.title) }
        context.insert(copy)
    }

    /// Purge trashed tasks older than the 30-day retention window.
    static func purgeExpiredTrash(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<TaskItem>()
        guard let all = try? context.fetch(descriptor) else { return }
        for task in all where task.deletedAt.map({ $0 < cutoff }) == true {
            context.delete(task)
        }
    }
}
