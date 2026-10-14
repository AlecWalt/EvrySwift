//
//  TaskLogic.swift
//  Evry
//
//  Pure task logic ported from the webapp: completion stats (js/store.js)
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

/// Completion counts for the Profile's stats tiles and week chart.
struct TaskStats {
    let totalDone: Int
    let weekData: [DayCount]
    let weekDone: Int
    let monthDone: Int
}

func computeStats(_ tasks: [TaskItem]) -> TaskStats {
    let completable = tasks.filter { !$0.isNote }

    let cal = Calendar.current
    let now = Date()
    let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
    let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
    let weekDone = completable.filter { t in
        guard t.completed, let d = t.completedAt else { return false }
        return d >= weekStart
    }.count
    let monthDone = completable.filter { t in
        guard t.completed, let d = t.completedAt else { return false }
        return d >= monthStart
    }.count

    return TaskStats(
        totalDone: completable.filter(\.completed).count,
        weekData: weekData(completable),
        weekDone: weekDone,
        monthDone: monthDone
    )
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

