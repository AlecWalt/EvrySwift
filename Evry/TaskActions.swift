//
//  TaskActions.swift
//  Evry
//
//  Shared task mutations — the Swift port of the store.js mutation helpers
//  (toggle with recurrence spin-off, soft delete/restore, snooze, duplicate).
//

import Foundation
import SwiftData
import UserNotifications

enum TaskActions {
    /// Toggle completion. Completing a recurring task spins off its next
    /// occurrence immediately, same as the webapp.
    static func toggle(_ task: TaskItem, context: ModelContext) {
        let completing = !task.completed
        task.completed = completing
        task.completedAt = completing ? Date() : nil

        if completing {
            NotificationService.cancel(task.uid)
        } else {
            NotificationService.schedule(task)
        }

        if completing, let recurrence = task.recurrence, let due = task.dueDate {
            let next = TaskItem(
                title: task.title,
                dueDate: recurrence.nextOccurrence(after: due),
                tags: task.tags,
                priority: task.priority,
                notes: task.notes,
                isNote: task.isNote
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
        NotificationService.cancel(task.uid)
    }

    static func restore(_ task: TaskItem) {
        task.deletedAt = nil
        NotificationService.schedule(task)
    }

    static func snooze(_ task: TaskItem) {
        guard let due = task.dueDate else { return }
        task.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: due)
    }

    /// Move a task's due date to `date` and reschedule its notification.
    static func reschedule(_ task: TaskItem, to date: Date) {
        task.dueDate = date
        NotificationService.schedule(task)
    }

    /// Returns the next occurrence of `weekday` (0 = Sun … 6 = Sat), never today.
    static func nextWeekdayDate(_ weekday: Int) -> Date {
        let todayIdx = Calendar.current.component(.weekday, from: Date()) - 1
        var diff = ((weekday - todayIdx) + 7) % 7
        if diff == 0 { diff = 7 }
        return startOfDay(Calendar.current.date(byAdding: .day, value: diff, to: Date()) ?? Date())
    }

    static func duplicate(_ task: TaskItem, context: ModelContext) {
        let copy = TaskItem(
            title: "\(task.title) (copy)",
            dueDate: task.dueDate,
            tags: task.tags,
            priority: task.priority,
            notes: task.notes,
            isNote: task.isNote
        )
        copy.recurrence = task.recurrence
        copy.subtasks = task.subtasks.map { SubtaskData(title: $0.title) }
        context.insert(copy)
    }

    /// Purge trashed tasks older than the 30-day retention window.
    static func purgeExpiredTrash(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.deletedAt != nil }
        )
        guard let trashed = try? context.fetch(descriptor) else { return }
        for task in trashed {
            guard let deletedAt = task.deletedAt, deletedAt < cutoff else { continue }
            context.delete(task)
        }
    }
}
