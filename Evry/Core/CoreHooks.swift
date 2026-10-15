//
//  CoreHooks.swift
//  Evry
//
//  The bridge from the app's models to the Core: one-line calls the task,
//  habit, note and assistant code paths make, which turn a `TaskItem` or
//  `Habit` into the small, title-free shapes the Core records. The Core itself
//  never sees SwiftData.
//

import Foundation
import SwiftData

// MARK: - Task types

/// Sorts a task into a coarse type by its words and tags — the only thing the
/// Core keeps about what a task *is*. Titles are never stored.
enum CoreTaskTypes {
    static let all = ["health", "fitness", "errand", "chores", "work", "admin", "social", "study", "creative", "other"]

    /// Checked in order; phrases match whole words.
    private static let rules: [(type: String, words: [String])] = [
        ("health", ["doctor", "dentist", "meds", "medication", "pills", "therapy", "therapist", "pharmacy",
                    "prescription", "checkup", "check-up", "vitamins", "vet"]),
        ("fitness", ["gym", "workout", "work out", "run", "running", "jog", "yoga", "pilates", "lift", "lifting",
                     "swim", "bike", "cycling", "hike", "exercise", "climbing", "stretch", "walk"]),
        ("errand", ["buy", "pick up", "pickup", "groceries", "grocery", "shop", "shopping", "store", "return",
                    "drop off", "post office", "mail", "package", "bank", "gas", "refill"]),
        ("chores", ["clean", "laundry", "dishes", "vacuum", "tidy", "trash", "mow", "cook", "wash", "organize",
                    "declutter", "iron", "water the plants"]),
        ("work", ["email", "emails", "meeting", "report", "deadline", "client", "presentation", "slides", "invoice",
                  "project", "review", "standup", "proposal", "deck", "work", "office"]),
        ("admin", ["pay", "bill", "bills", "renew", "insurance", "tax", "taxes", "form", "paperwork", "budget",
                   "appointment", "book", "schedule", "register", "cancel", "sign up"]),
        ("social", ["call", "text", "birthday", "party", "dinner", "visit", "friend", "friends", "mom", "dad",
                    "family", "date", "gift", "wedding"]),
        ("study", ["study", "homework", "read", "reading", "class", "exam", "essay", "lecture", "assignment",
                   "quiz", "learn"]),
        ("creative", ["write", "writing", "draw", "paint", "practice", "guitar", "piano", "music", "design", "sketch"]),
    ]

    static func type(title: String, tags: [String] = []) -> String {
        // A tag that names a type wins ("#work").
        for tag in tags {
            let t = tag.lowercased()
            if all.contains(t) { return t }
        }
        let text = " " + PlaceLabels.words(title + " " + tags.joined(separator: " ")).joined(separator: " ") + " "
        for rule in rules where rule.words.contains(where: { text.contains(" \($0) ") }) {
            return rule.type
        }
        return "other"
    }
}

// MARK: - Hooks

enum CoreHooks {
    private static var core: EvryCore { .shared }

    static func info(_ task: TaskItem) -> CoreTaskInfo {
        let size: CoreTaskSize = task.subtasks.count >= 4 || task.notes.count > 280 ? .large
            : task.subtasks.count >= 1 || task.notes.count > 80 ? .medium : .small
        return CoreTaskInfo(type: CoreTaskTypes.type(title: task.title, tags: task.tags), createdAt: task.createdAt,
                            size: size, locationLabel: task.location.isEmpty ? nil : task.location)
    }

    // Notes-as-tasks (`isNote`) aren't to-dos, so they don't shape task behaviour.

    static func taskCreated(_ task: TaskItem) {
        guard !task.isNote else { return }
        core.record(.taskCreated(info(task)))
    }

    static func taskEdited(_ task: TaskItem) {
        guard !task.isNote else { return }
        core.record(.taskEdited(info(task)))
    }

    static func taskRescheduled(_ task: TaskItem, from: Date?, to: Date) {
        guard !task.isNote, from != to else { return }
        core.record(.taskRescheduled(info(task), from: from, to: to))
    }

    static func taskSnoozed(_ task: TaskItem) {
        guard !task.isNote else { return }
        core.record(.taskSnoozed(info(task)))
    }

    static func taskToggled(_ task: TaskItem) {
        guard !task.isNote else { return }
        core.record(task.completed ? .taskCompleted(info(task)) : .taskReopened(info(task)))
    }

    /// Deleting an open task is abandoning it; clearing done ones isn't.
    static func taskDeleted(_ task: TaskItem) {
        guard !task.isNote, !task.completed else { return }
        core.record(.taskAbandoned(info(task)))
    }

    static func taskRestored(_ task: TaskItem) {
        guard !task.isNote, !task.completed else { return }
        core.record(.taskRestored(info(task)))
    }

    // MARK: Habits

    static func snapshot(_ habit: Habit, now: Date = Date()) -> CoreHabitSnapshot {
        let stats = HabitStats(habit: habit, now: now)
        return CoreHabitSnapshot(id: habit.uid.uuidString, title: habit.name, cadence: habit.scheduleLabel,
                                 currentStreak: stats.currentStreak, longestStreak: stats.bestStreak,
                                 rate30: stats.rate30)
    }

    static func habitCheckedIn(_ habit: Habit) { core.record(.habitCheckIn(snapshot(habit))) }

    static func habitChanged(_ habit: Habit) { core.record(.habitUpdated(snapshot(habit))) }

    static func habitDeleted(id: UUID) { core.record(.habitRemoved(id: id.uuidString)) }

    /// Records a miss for every scheduled day since the last sweep (at most a
    /// week back) whose target wasn't met, refreshes every habit's numbers, and
    /// drops profiles for habits that are gone or built.
    static func sweepHabits(context: ModelContext, now: Date = Date()) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: today),
              let habits = try? context.fetch(FetchDescriptor<Habit>()) else { return }
        let active = habits.filter { !$0.isFormed }
        core.retainHabits(Set(active.map { $0.uid.uuidString }))

        let weekAgo = cal.date(byAdding: .day, value: -7, to: today) ?? today
        let after = core.profile.meta.lastHabitSweep.flatMap { cal.date(byAdding: .day, value: 1, to: $0) }
        let start = max(after ?? yesterday, weekAgo)
        for habit in active {
            let snap = snapshot(habit, now: now)
            let counts = habit.countsByDay
            let target = max(1, habit.dailyTarget)
            let born = cal.startOfDay(for: habit.createdAt)
            var day = max(start, born)
            while day <= yesterday {
                if habit.isScheduled(on: day) && (counts[day] ?? 0) < target {
                    core.record(.habitMissed(snap, day: day), at: now)
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            core.record(.habitUpdated(snap), at: now)
        }
        if (core.profile.meta.lastHabitSweep ?? .distantPast) < yesterday { core.markHabitSweep(yesterday) }
    }

    // MARK: Notes

    /// Hands a saved note to the Core — only when note-extraction consent is on
    /// (the text isn't even assembled otherwise). Only facts are kept.
    static func noteSaved(_ note: Note) {
        guard core.profile.meta.consent.noteExtraction, !note.isEmpty, !note.isTrashed else { return }
        core.record(.noteSaved(id: note.uid.uuidString, text: note.title + "\n" + note.plainText))
    }

    static func noteDeleted(_ note: Note) { core.record(.noteDeleted(id: note.uid.uuidString)) }

    // MARK: App & assistant

    /// App launch / return to the foreground.
    static func appOpened(context: ModelContext) {
        core.record(.appOpened)
        sweepHabits(context: context)
        core.maintain()
    }

    static func appBackgrounded() { core.flush() }

    static func mascotOpened() { core.record(.mascotOpened) }

    static func nudgeShown(_ type: String) { core.record(.nudgeShown(type: type)) }
    static func nudgeAccepted(_ type: String) { core.record(.nudgeAccepted(type: type)) }
    static func nudgeDismissed(_ type: String) { core.record(.nudgeDismissed(type: type)) }
}
