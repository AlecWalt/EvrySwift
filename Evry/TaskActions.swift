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
        let completedBefore = task.completedAt
        task.completed = completing
        task.completedAt = completing ? Date() : nil
        CoreHooks.taskToggled(task)

        if completing {
            // Now and then a finished task earns a little XP (queued for the profile).
            if !task.isNote { EvryXP.rollBonus(.taskCompleted) }
            NotificationService.cancel(task.uid)
            // Finishing a folder's last open task removes the folder.
            pruneGroupIfFinished(task.group, context: context)
        } else {
            NotificationService.schedule(task)
        }

        guard let recurrence = task.recurrence, let due = task.dueDate else { return }
        let nextDue = recurrence.nextOccurrence(after: due)
        if completing {
            let next = clone(task, title: task.title, dueDate: nextDue)
            context.insert(next)
            NotificationService.schedule(next)
        } else if let completedBefore {
            // Un-completing takes back the occurrence that completing spun off
            // (if it hasn't been touched since) — otherwise toggling on and off
            // piles up copies.
            removeSpawnedOccurrence(of: task, due: nextDue, spawnedAfter: completedBefore, context: context)
        }
    }

    /// A fresh, open copy of `task` — everything the person set on it, minus
    /// completion and subtask ticks.
    private static func clone(_ task: TaskItem, title: String, dueDate: Date?) -> TaskItem {
        let copy = TaskItem(
            title: title,
            dueDate: dueDate,
            tags: task.tags,
            priority: task.priority,
            notes: task.notes,
            location: task.location,
            isNote: task.isNote,
            // Carry the task's own location over as-is (empty stays empty).
            autoLocation: false
        )
        copy.recurrence = task.recurrence
        copy.pinned = task.pinned
        copy.group = task.group
        copy.subtasks = task.subtasks.map { SubtaskData(title: $0.title) }
        return copy
    }

    private static func removeSpawnedOccurrence(of task: TaskItem, due: Date, spawnedAfter: Date,
                                                context: ModelContext) {
        let title = task.title
        let candidates = FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.title == title && !$0.completed && $0.deletedAt == nil
        })
        let spawned = ((try? context.fetch(candidates)) ?? []).first { t in
            t.uid != task.uid && t.recurrenceRaw == task.recurrenceRaw && t.dueDate == due
                && t.createdAt >= spawnedAfter.addingTimeInterval(-2)
        }
        guard let spawned else { return }
        NotificationService.cancel(spawned.uid)
        context.delete(spawned)
    }

    /// Soft delete — the task goes to trash (30-day retention) so the
    /// delete toast's Undo can restore it.
    static func delete(_ task: TaskItem) {
        task.deletedAt = Date()
        CoreHooks.taskDeleted(task)
        NotificationService.cancel(task.uid)
        // Deleting a folder's last open task removes the folder.
        if let context = task.modelContext {
            pruneGroupIfFinished(task.group, context: context)
        }
    }

    /// Deletes a task-group folder once none of its tasks are left open (every
    /// one completed or deleted). The nullify rule detaches the finished tasks,
    /// so they stay in the Completed section / trash as loose tasks.
    static func pruneGroupIfFinished(_ group: TaskGroup?, context: ModelContext) {
        guard let group else { return }
        let open = (group.tasks ?? []).contains { !$0.completed && !$0.isTrashed }
        guard !open else { return }
        context.delete(group)
    }

    /// Sweeps any folders already left with no open tasks (e.g. finished before
    /// the auto-remove rule existed).
    static func pruneFinishedGroups(context: ModelContext) {
        guard let groups = try? context.fetch(FetchDescriptor<TaskGroup>()) else { return }
        for group in groups { pruneGroupIfFinished(group, context: context) }
        try? context.save()
    }

    static func restore(_ task: TaskItem) {
        task.deletedAt = nil
        CoreHooks.taskRestored(task)
        NotificationService.schedule(task)
    }

    static func snooze(_ task: TaskItem) {
        guard let due = task.dueDate,
              let next = Calendar.current.date(byAdding: .day, value: 1, to: due) else { return }
        CoreHooks.taskSnoozed(task)
        // The reminder moves with it (counted as a snooze, not also a reschedule).
        move(task, to: next)
    }

    /// Move a task's due date to `date` and reschedule its notification.
    static func reschedule(_ task: TaskItem, to date: Date) {
        CoreHooks.taskRescheduled(task, from: task.dueDate, to: date)
        move(task, to: date)
    }

    private static func move(_ task: TaskItem, to date: Date) {
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
        let copy = clone(task, title: "\(task.title) (copy)", dueDate: task.dueDate)
        context.insert(copy)
        CoreHooks.taskCreated(copy)
        NotificationService.schedule(copy)
    }

    /// Moves overdue tasks onto today, keeping any time they had (and their
    /// reminders), then saves.
    static func moveToToday(_ tasks: [TaskItem], context: ModelContext) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for task in tasks {
            let time = task.dueDate.map { cal.dateComponents([.hour, .minute], from: $0) }
            let date = cal.date(bySettingHour: time?.hour ?? 0, minute: time?.minute ?? 0, second: 0, of: today) ?? today
            reschedule(task, to: date)
        }
        try? context.save()
    }

    /// Tasks always have a due date. Any saved before that rule (e.g. added
    /// with Return when it didn't date them) are moved onto today so they show
    /// up in the Inbox instead of being stranded out of sight.
    static func assignMissingDueDates(context: ModelContext) {
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.dueDate == nil }
        )
        guard let undated = try? context.fetch(descriptor), !undated.isEmpty else { return }
        let today = Calendar.current.startOfDay(for: Date())
        for task in undated {
            task.dueDate = today
            NotificationService.schedule(task)
        }
        try? context.save()
    }

    /// Purge trashed tasks older than the 30-day retention window.
    static func purgeExpiredTrash(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { t in
            if let deletedAt = t.deletedAt { deletedAt < cutoff } else { false }
        })
        guard let expired = try? context.fetch(descriptor) else { return }
        for task in expired { context.delete(task) }
    }
}
