//
//  TaskLogic.swift
//  Evry
//
//  Pure task logic ported from the webapp: stats/streaks (js/store.js)
//  and the next-action picker (js/utils/nextAction.js).
//

import Foundation

// MARK: - Stats

struct DayCount: Identifiable {
    let date: Date
    let count: Int
    let isToday: Bool

    var id: Date { date }
}

struct TaskStats {
    let todayTotal: Int
    let todayDone: Int
    let totalDone: Int
    let total: Int
    let streak: Int
    let longestStreak: Int
    let weekData: [DayCount]
}

/// Today view membership: notes always; incomplete tasks due today or
/// overdue; tasks completed today.
func isTodayTask(_ t: TaskItem) -> Bool {
    if t.isNote { return true }
    if !t.completed && (isTodayDate(t.dueDate) || isOverdueDate(t.dueDate)) { return true }
    if t.completed && isTodayDate(t.completedAt) { return true }
    return false
}

func computeStats(_ tasks: [TaskItem]) -> TaskStats {
    let completable = tasks.filter { !$0.isNote }
    let todayCompletable = tasks.filter { isTodayTask($0) && !$0.isNote }

    return TaskStats(
        todayTotal: todayCompletable.count,
        todayDone: todayCompletable.filter(\.completed).count,
        totalDone: completable.filter(\.completed).count,
        total: completable.count,
        streak: computeStreak(completable),
        longestStreak: computeLongestStreak(completable),
        weekData: weekData(completable)
    )
}

private func completionDays(_ tasks: [TaskItem]) -> Set<Date> {
    Set(tasks.compactMap { $0.completedAt.map(startOfDay) })
}

private func computeStreak(_ tasks: [TaskItem]) -> Int {
    let days = completionDays(tasks)
    var cursor = startOfDay(Date())
    if !days.contains(cursor) {
        cursor = addDays(cursor, -1)
    }
    var streak = 0
    while days.contains(cursor) {
        streak += 1
        cursor = addDays(cursor, -1)
    }
    return streak
}

private func computeLongestStreak(_ tasks: [TaskItem]) -> Int {
    let days = completionDays(tasks).sorted()
    var longest = 0, run = 0
    var prev: Date?
    for day in days {
        if let prev, addDays(prev, 1) == day {
            run += 1
        } else {
            run = 1
        }
        longest = max(longest, run)
        prev = day
    }
    return longest
}

private func weekData(_ tasks: [TaskItem]) -> [DayCount] {
    let today = startOfDay(Date())
    return (0..<7).map { i in
        let d = addDays(today, i - 6)
        let count = tasks.filter { $0.completedAt.map(startOfDay) == d }.count
        return DayCount(date: d, count: count, isToday: i == 6)
    }
}

// MARK: - Next action (Focus tab)

/// How urgently a task needs attention, lowest number first — overdue beats
/// due-today beats a dateless high-priority task beats everything else.
private func urgencyBucket(_ t: TaskItem) -> Int {
    if isOverdueDate(t.dueDate) { return 0 }
    if isTodayDate(t.dueDate) { return 1 }
    if t.dueDate == nil && t.priority == .high { return 2 }
    if t.dueDate == nil { return 3 }
    return 4
}

private func byDateThenPriorityThenAge(_ a: TaskItem, _ b: TaskItem) -> Bool {
    if let da = a.dueDate, let db = b.dueDate, da != db { return da < db }
    if a.priority.rank != b.priority.rank { return a.priority.rank < b.priority.rank }
    return a.createdAt < b.createdAt
}

/// Picks the single most pressing task to act on right now. `skippedOrder`
/// holds the ids of tasks passed on via "Not this one", oldest skip first —
/// skip means "not next," not "never." Skip rotation stays within an urgency
/// tier: today's task can only lose its turn to another task due today.
func nextAction(tasks: [TaskItem], skippedOrder: [UUID]) -> TaskItem? {
    let candidates = tasks.filter { !$0.completed && !$0.isNote }
    guard !candidates.isEmpty else { return nil }

    let skipRank = Dictionary(uniqueKeysWithValues: skippedOrder.enumerated().map { ($1, $0) })

    let tiers = Dictionary(grouping: candidates, by: urgencyBucket)
    let tierKeys = tiers.keys.sorted()

    for key in tierKeys {
        let group = tiers[key]!.sorted(by: byDateThenPriorityThenAge)
        if let notSkipped = group.first(where: { skipRank[$0.uid] == nil }) {
            return notSkipped
        }
    }

    // Everything's been skipped at least once — bring back the longest-ago
    // skip from the most urgent non-empty tier.
    return tiers[tierKeys[0]]!
        .sorted { (skipRank[$0.uid] ?? 0) < (skipRank[$1.uid] ?? 0) }
        .first
}

// MARK: - Sorting

/// Pinned tasks float to the top; a stable partition, not a re-sort.
func sortPinnedFirst(_ tasks: [TaskItem]) -> [TaskItem] {
    guard tasks.contains(where: \.pinned) else { return tasks }
    return tasks.filter(\.pinned) + tasks.filter { !$0.pinned }
}

// MARK: - Project timeline status (projectsTab.js timelineStatus)

struct TimelineStatus {
    let text: String
    var overdue = false
    var soon = false
}

func timelineStatus(project: Project, allDone: Bool) -> TimelineStatus? {
    guard let due = project.dueDate else { return nil }
    let today = startOfDay(Date())
    let dueDay = startOfDay(due)
    let diffDays = Calendar.current.dateComponents([.day], from: today, to: dueDay).day ?? 0
    if allDone { return TimelineStatus(text: "Complete") }
    if diffDays < 0 { return TimelineStatus(text: "Overdue \(abs(diffDays))d", overdue: true) }
    if diffDays == 0 { return TimelineStatus(text: "Due today", soon: true) }
    if diffDays == 1 { return TimelineStatus(text: "Due tomorrow", soon: true) }
    return TimelineStatus(text: "\(diffDays)d left")
}
