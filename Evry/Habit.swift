//
//  Habit.swift
//  Evry
//
//  Habits module — data layer. A `Habit` owns a list of `HabitEntry` check-ins
//  (one per tap), so a habit can have a daily target above one (e.g. "Drink
//  water ×8"). Streaks and completion rates are derived from the entries in a
//  single pass by `HabitStats`, and every mutation goes through `HabitActions`.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Model

@Model
final class Habit {
    var uid: UUID = UUID()
    var name: String = ""
    var icon: String = "flame"
    var colorHex: Int = Int(HabitStyle.defaultColor)
    /// Check-ins needed to complete the habit on a given day.
    var dailyTarget: Int = 1
    /// Scheduled weekdays (Calendar weekday numbers, 1 = Sunday … 7 = Saturday).
    /// Empty means every day.
    var weekdays: [Int] = []
    /// Long-term goal: completed days until the habit is considered formed.
    /// Defaults to 66 — the average time to automaticity cited in *Atomic Habits*
    /// (Lally et al., 2009).
    var goalDays: Int = Habit.defaultGoalDays
    /// When the long-term goal was reached — the habit is "built". Kept as a
    /// record (the card turns into a trophy) rather than deleted.
    var formedAt: Date?
    var createdAt: Date = Date()
    var sortOrder: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \HabitEntry.habit)
    var entries: [HabitEntry]? = []

    static let defaultGoalDays = 66

    init(name: String, icon: String = "flame", colorHex: Int = Int(HabitStyle.defaultColor),
         dailyTarget: Int = 1, weekdays: [Int] = [], goalDays: Int = Habit.defaultGoalDays) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.dailyTarget = max(1, dailyTarget)
        self.weekdays = weekdays
        self.goalDays = max(1, goalDays)
    }

    /// The habit's brand shade (a sky → navy strength step). `colorHex` is kept
    /// as a stable identifier only, so existing habits decode unchanged.
    var color: Color { HabitStyle.color(for: UInt32(truncatingIfNeeded: colorHex)) }
    /// Glyph/label ink that reads on a `color` fill.
    var ink: Color { HabitStyle.ink(for: UInt32(truncatingIfNeeded: colorHex)) }

    /// The long-term goal has been reached.
    var isFormed: Bool { formedAt != nil }

    func isScheduled(on day: Date, calendar: Calendar = .current) -> Bool {
        weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: day))
    }

    /// Check-ins per day, keyed by start of day, built in one pass.
    var countsByDay: [Date: Int] {
        var counts: [Date: Int] = [:]
        for entry in entries ?? [] { counts[entry.day, default: 0] += 1 }
        return counts
    }

    /// Human-readable schedule ("Every day", "Weekdays", "Mon, Wed, Fri").
    var scheduleLabel: String {
        let set = Set(weekdays)
        if set.isEmpty || set.count == 7 { return "Every day" }
        if set == [2, 3, 4, 5, 6] { return "Weekdays" }
        if set == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return HabitStyle.orderedWeekdays
            .filter { set.contains($0) }
            .map { symbols[$0 - 1] }
            .joined(separator: ", ")
    }
}

@Model
final class HabitEntry {
    var uid: UUID = UUID()
    /// Start of the day this check-in counts toward.
    var day: Date = Date()
    var loggedAt: Date = Date()
    var habit: Habit?

    init(habit: Habit, day: Date) {
        self.habit = habit
        self.day = Calendar.current.startOfDay(for: day)
    }
}

// MARK: - Styling

enum HabitStyle {
    /// The selectable habit colours. The Evry palette has no extra hues, so these
    /// legacy hex values are now only stable *identifiers* (they're what's stored
    /// in `Habit.colorHex`); each renders as a sky → navy strength step by its
    /// position here, lightest first. Never remove or rewrite an entry — that
    /// would orphan stored habits (unknown values fall back to the middle step).
    static let colors: [UInt32] = [
        0x22C55E, 0x14B8A6, 0x3B82F6, 0x8B5CF6, 0x64748B,
        0xEC4899, 0xEF4444, 0xF97316, 0xF59E0B,
    ]
    /// The middle shade — new habits start on a calm mid tone until one is picked.
    static let defaultColor: UInt32 = 0x64748B

    /// 0 (lightest, sky) … 1 (deepest, toward navy) for a stored colour value.
    static func shade(for hex: UInt32) -> Double {
        guard let i = colors.firstIndex(of: hex), colors.count > 1 else { return 0.5 }
        return Double(i) / Double(colors.count - 1)
    }

    /// The rendered brand shade: a mix of sky and navy, never a new hue. Light
    /// mode keeps enough navy for rings and fills to read on white; dark mode
    /// stays bright enough to read on navy.
    static func color(for hex: UInt32) -> Color {
        let s = shade(for: hex)
        return Color(light: Color.evrySky.mix(with: .evryNavy, by: 0.3 + s * 0.6),
                     dark: Color.evrySky.mix(with: .evryNavy, by: s * 0.4))
    }

    /// Ink for a glyph placed on `color(for:)`: white on the deeper light-mode
    /// steps, navy everywhere else.
    static func ink(for hex: UInt32) -> Color {
        Color(light: shade(for: hex) >= 0.35 ? .evryWhite : .evryNavy, dark: .evryNavy)
    }
    static let icons: [String] = [
        "flame", "drop", "figure.run", "dumbbell", "bicycle", "figure.walk",
        "book", "pencil", "brain.head.profile", "leaf", "bed.double", "sun.max",
        "moon", "heart", "fork.knife", "cup.and.saucer", "pills", "music.note",
        "paintbrush", "laptopcomputer", "dollarsign.circle", "phone.down", "sparkles", "star",
    ]

    /// Weekday numbers ordered from the user's first weekday (e.g. Sun…Sat or Mon…Sun).
    static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}

// MARK: - Stats

/// Progress numbers for one habit, derived from a single pass over its entries.
struct HabitStats {
    let counts: [Date: Int]
    let target: Int
    /// Check-ins logged today.
    let today: Int
    /// Consecutive completed scheduled days, ending today (or yesterday if today
    /// is still in progress, so an unfinished today doesn't break the streak).
    let currentStreak: Int
    let bestStreak: Int
    /// Days on which the target was met.
    let completedDays: Int
    /// Share of scheduled days completed over the last 30 days (0…1).
    let rate30: Double

    /// Long-term goal in completed days.
    let goal: Int

    var todayDone: Bool { today >= target }
    /// Progress toward the long-term goal (0…1).
    var goalFraction: Double { min(1, Double(completedDays) / Double(goal)) }
    var goalReached: Bool { completedDays >= goal }
    var todayFraction: Double { min(1, Double(today) / Double(max(1, target))) }

    func count(on day: Date) -> Int { counts[Calendar.current.startOfDay(for: day)] ?? 0 }

    init(habit: Habit, now: Date = Date()) {
        let cal = Calendar.current
        let counts = habit.countsByDay
        let target = max(1, habit.dailyTarget)
        let todayStart = cal.startOfDay(for: now)
        // History starts at creation, or earlier if check-ins were backfilled.
        let start = min(cal.startOfDay(for: habit.createdAt), counts.keys.min() ?? todayStart)
        let isDone: (Date) -> Bool = { (counts[$0] ?? 0) >= target }

        self.counts = counts
        self.target = target
        self.goal = max(1, habit.goalDays)
        self.today = counts[todayStart] ?? 0
        self.completedDays = counts.values.filter { $0 >= target }.count

        // Current streak — walk back from today over scheduled days.
        var streak = 0
        var day = todayStart
        if habit.isScheduled(on: day) && !isDone(day) {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        while day >= start {
            if habit.isScheduled(on: day) {
                guard isDone(day) else { break }
                streak += 1
            }
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        self.currentStreak = streak

        // Best streak — one forward pass over the habit's whole history.
        var best = 0, run = 0
        day = start
        while day <= todayStart {
            if habit.isScheduled(on: day) {
                if isDone(day) { run += 1; best = max(best, run) }
                else if day < todayStart { run = 0 }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        self.bestStreak = best

        // 30-day rate — today only counts once it's done.
        let windowStart = max(start, cal.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart)
        var scheduled = 0, done = 0
        day = windowStart
        while day <= todayStart {
            if habit.isScheduled(on: day) && (day < todayStart || isDone(day)) {
                scheduled += 1
                if isDone(day) { done += 1 }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        self.rate30 = scheduled > 0 ? Double(done) / Double(scheduled) : 0
    }
}

// MARK: - Actions

enum HabitActions {
    /// Logs one check-in for `day`.
    static func checkIn(_ habit: Habit, on day: Date = Date(), context: ModelContext) {
        let entry = HabitEntry(habit: habit, day: day)
        context.insert(entry)
        try? context.save()
        refreshFormed(habit, context: context)
    }

    /// Stamps (or clears) `formedAt` as completed days cross the long-term goal.
    /// Called after every change to a habit's history or goal length.
    static func refreshFormed(_ habit: Habit, context: ModelContext) {
        let reached = HabitStats(habit: habit).goalReached
        if reached && habit.formedAt == nil {
            habit.formedAt = Date()
        } else if !reached && habit.formedAt != nil {
            habit.formedAt = nil
        } else {
            return
        }
        try? context.save()
    }

    /// Removes the most recent check-in for `day`, if any.
    static func undoCheckIn(_ habit: Habit, on day: Date = Date(), context: ModelContext) {
        let start = Calendar.current.startOfDay(for: day)
        guard let last = (habit.entries ?? [])
            .filter({ $0.day == start })
            .max(by: { $0.loggedAt < $1.loggedAt }) else { return }
        context.delete(last)
        try? context.save()
        refreshFormed(habit, context: context)
    }

    #if DEBUG
    /// TEMP developer helper: fills the most recent incomplete scheduled day
    /// before today with a full day of check-ins, so history (streak, goal bar)
    /// can be previewed as if the habit had been done on more days.
    /// Returns false if no such day was found within ten years.
    @discardableResult
    static func devBackfillCompletedDay(_ habit: Habit, context: ModelContext) -> Bool {
        let cal = Calendar.current
        let counts = habit.countsByDay
        let target = max(1, habit.dailyTarget)
        var day = cal.startOfDay(for: Date())
        for _ in 0..<3650 {
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { return false }
            day = prev
            let have = counts[day] ?? 0
            guard habit.isScheduled(on: day), have < target else { continue }
            for _ in have..<target { context.insert(HabitEntry(habit: habit, day: day)) }
            try? context.save()
            refreshFormed(habit, context: context)
            return true
        }
        return false
    }
    #endif

    /// Deletes the habit and (via cascade) its whole history.
    static func delete(_ habit: Habit, context: ModelContext) {
        context.delete(habit)
        try? context.save()
    }
}
