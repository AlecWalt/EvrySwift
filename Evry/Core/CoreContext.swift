//
//  CoreContext.swift
//  Evry
//
//  Minimal slices of the Core for on-device language-model calls. Each purpose
//  gets only the sections it needs, with short keys, and never coordinates,
//  note text, or anything the person asked Evry not to suggest. Quiet hours
//  ride along with every slice.
//
//      let slice = EvryCore.shared.getContext(.reminders)
//      prompt += "About this person: \(slice.json)"
//

import Foundation

enum CorePurpose: String, CaseIterable {
    case reminders
    case locationSuggestions = "location_suggestions"
    case habitCoaching = "habit_coaching"
    case taskPlanning = "task_planning"
    case general
}

struct CoreContextSlice: Encodable, Equatable {
    struct TaskType: Encodable, Equatable {
        var t: String
        /// Completion, reschedule and abandon rates (0…1); typical hours to done.
        var done: Double?
        var moved: Double?
        var drop: Double?
        var hrs: Double?
    }
    struct Place: Encodable, Equatable {
        var l: String
        var cat: String?
        /// "Mon 9-17".
        var win: [String]?
        var tasks: [String]?
    }
    struct Habit: Encodable, Equatable {
        var t: String
        var cad: String?
        var streak: Int
        var best: Int?
        var rate: Double
        /// Usual hour of day.
        var at: Int?
        var slip: String?
        var place: String?
    }
    struct Fact: Encodable, Equatable {
        var k: String
        var s: String
    }

    var p: String
    /// How complete the Core is (0…1) — how much to lean on it.
    var conf: Double
    var q: [String]?
    var nudge: String?
    var peakH: [Int]?
    var peakD: [String]?
    var planH: [Int]?
    var doneH: [Int]?
    var shape: String?
    var avoid: [String]?
    var tasks: [TaskType]?
    var size: String?
    var edits: Double?
    var places: [Place]?
    var habits: [Habit]?
    var goals: [String]?
    var facts: [Fact]?

    /// Compact JSON for a prompt.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

enum CoreContextBuilder {
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func build(_ purpose: CorePurpose, from p: CoreProfile, config: CoreConfig, now: Date) -> CoreContextSlice {
        let d = p.declared
        let behavior = p.taskBehavior
        var s = CoreContextSlice(p: purpose.rawValue, conf: CoreLearner.progress(p, config: config).overall)
        s.q = d.quietHours.isEmpty ? nil : d.quietHours.map(\.id)

        switch purpose {
        case .reminders:
            s.nudge = d.nudgeLevel.rawValue
            s.peakH = peakHours(p.rhythms.hourWeights, d)
            s.peakD = peakDays(p.rhythms.dayWeights)
            s.doneH = peakHours(p.rhythms.completionHourWeights, d)
            s.shape = p.rhythms.weeklyShape
            s.avoid = avoided(behavior, d)
        case .locationSuggestions:
            s.places = places(p, limit: 5, withWindows: true)
        case .habitCoaching:
            s.habits = habits(p, limit: 6)
            s.peakH = peakHours(p.rhythms.hourWeights, d)
            s.peakD = peakDays(p.rhythms.dayWeights)
            s.goals = d.goals.isEmpty ? nil : d.goals
        case .taskPlanning:
            s.tasks = taskTypes(p, behavior, limit: 6)
            s.avoid = avoided(behavior, d)
            s.size = behavior.typicalTaskSize.rawValue
            s.edits = p.taskSignals.created >= 3 ? behavior.editFrequency : nil
            s.planH = peakHours(p.rhythms.planningHourWeights, d)
            s.doneH = peakHours(p.rhythms.completionHourWeights, d)
            s.shape = p.rhythms.weeklyShape
            s.facts = facts(p, kinds: [.appointment, .project, .person], limit: 5)
        case .general:
            s.nudge = d.nudgeLevel.rawValue
            s.peakH = peakHours(p.rhythms.hourWeights, d)
            s.shape = p.rhythms.weeklyShape
            s.avoid = avoided(behavior, d).map { Array($0.prefix(3)) }
            s.places = places(p, limit: 3, withWindows: false)
            s.habits = habits(p, limit: 3)
            s.goals = d.goals.isEmpty ? nil : Array(d.goals.prefix(3))
            s.facts = facts(p, kinds: Set(CoreFact.Kind.allCases), limit: 3)
        }
        return s
    }

    // MARK: Pieces

    /// The busiest hours outside quiet hours, in clock order.
    static func peakHours(_ weights: [Double], _ d: CoreDeclared, count: Int = 3) -> [Int]? {
        let hours = weights.indices
            .filter { weights[$0] > 0 && !d.isQuiet(hour: $0) }
            .sorted { weights[$0] > weights[$1] }
            .prefix(count)
            .sorted()
        return hours.isEmpty ? nil : Array(hours)
    }

    static func peakDays(_ weights: [Double], count: Int = 2) -> [String]? {
        let days = weights.indices.filter { weights[$0] > 0 }.sorted { weights[$0] > weights[$1] }.prefix(count)
        return days.isEmpty ? nil : days.map { dayNames[$0] }
    }

    private static func avoided(_ b: CoreTaskBehavior, _ d: CoreDeclared) -> [String]? {
        let list = b.avoidedTaskTypes.filter { !d.isSuppressed($0) }
        return list.isEmpty ? nil : list
    }

    private static func round2(_ v: Double?) -> Double? { v.map { ($0 * 100).rounded() / 100 } }

    private static func taskTypes(_ p: CoreProfile, _ b: CoreTaskBehavior, limit: Int) -> [CoreContextSlice.TaskType]? {
        let types = p.taskStats
            .filter { !p.declared.isSuppressed($0.key) }
            .sorted { $0.value.created + $0.value.completed > $1.value.created + $1.value.completed }
            .prefix(limit)
            .map { type, _ in
                CoreContextSlice.TaskType(t: type, done: round2(b.completionRateByType[type]),
                                          moved: round2(b.rescheduleRateByType[type]),
                                          drop: round2(b.abandonRateByType[type]),
                                          hrs: b.avgCreateToCompleteHours[type].map { $0.rounded() })
            }
        return types.isEmpty ? nil : Array(types)
    }

    /// Labels, categories, windows and linked task types. Never `center`.
    private static func places(_ p: CoreProfile, limit: Int, withWindows: Bool) -> [CoreContextSlice.Place]? {
        let d = p.declared
        let list = p.places
            .map { place -> (CorePlace, String, CorePlace.Category?) in
                (place, d.placeLabels[place.id] ?? place.label, d.placeCategories[place.id] ?? place.category)
            }
            .filter { !d.isSuppressed($0.1) && !d.isSuppressed($0.2?.rawValue) }
            .sorted { $0.0.confidence > $1.0.confidence }
            .prefix(limit)
            .map { place, label, category in
                let windows = place.typicalWindows.prefix(3).map { "\(dayNames[$0.dow]) \($0.hourStart)-\($0.hourEnd)" }
                let tasks = place.linkedTaskTypes.filter { !d.isSuppressed($0.key) }
                    .sorted { $0.value > $1.value }.prefix(3).map(\.key)
                return CoreContextSlice.Place(l: label, cat: category?.rawValue,
                                              win: withWindows && !windows.isEmpty ? windows : nil,
                                              tasks: tasks.isEmpty ? nil : tasks)
            }
        return list.isEmpty ? nil : Array(list)
    }

    private static func habits(_ p: CoreProfile, limit: Int) -> [CoreContextSlice.Habit]? {
        let d = p.declared
        let labels = Dictionary(p.places.map { ($0.id, d.placeLabels[$0.id] ?? $0.label) }, uniquingKeysWith: { a, _ in a })
        let list = p.habits
            .filter { !d.isSuppressed($0.title) }
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.title < $1.title }
            .prefix(limit)
            .map { h in
                CoreContextSlice.Habit(t: h.title, cad: h.cadence, streak: h.currentStreak,
                                       best: h.longestStreak > h.currentStreak ? h.longestStreak : nil,
                                       rate: h.completionRate30d, at: h.usualTime?.hour, slip: h.slipPattern,
                                       place: h.usualPlaceId.flatMap { labels[$0] })
            }
        return list.isEmpty ? nil : Array(list)
    }

    private static func facts(_ p: CoreProfile, kinds: Set<CoreFact.Kind>, limit: Int) -> [CoreContextSlice.Fact]? {
        let list = p.facts
            .filter { kinds.contains($0.kind) && !p.declared.isSuppressed($0.summary) && !p.declared.isSuppressed($0.kind.rawValue) }
            .sorted { ($0.userConfirmed ? 2 : $0.confidence) > ($1.userConfirmed ? 2 : $1.confidence) }
            .prefix(limit)
            .map { CoreContextSlice.Fact(k: $0.kind.rawValue, s: $0.summary) }
        return list.isEmpty ? nil : Array(list)
    }
}
