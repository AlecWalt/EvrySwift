//
//  CoreModel.swift
//  Evry
//
//  The Core — a compact, structured picture of how someone uses Evry, built
//  up from app usage so on-device features can adapt to them. It holds
//  *summaries* (top places, habit rhythms, task patterns), never raw history:
//  events feed it, but only the distilled result is kept. See CORE.md.
//
//  Everything here is plain Codable data. The rules that change it live in
//  `CoreLearner`, the engine in `EvryCore`.
//

import Foundation

// MARK: - Profile

struct CoreProfile: Codable, Equatable {
    static let currentSchemaVersion = 1

    var meta: CoreMeta
    /// What the person said themselves. Inference never writes here.
    var declared = CoreDeclared()
    var places: [CorePlace] = []
    /// Clusters still below the visit threshold. On-device learning state only:
    /// never shown as places, never part of any context slice.
    var placeCandidates: [CorePlaceCandidate] = []
    var rhythms = CoreRhythms()
    var habits: [CoreHabit] = []
    /// Decay-weighted counters per task type ("errand", "work"…), from which
    /// `taskBehavior` is derived.
    var taskStats: [String: CoreTypeStats] = [:]
    var taskSignals = CoreTaskSignals()
    var facts: [CoreFact] = []
    var feedback = CoreFeedback()

    init(now: Date = Date()) {
        meta = CoreMeta(createdAt: now, updatedAt: now)
    }

    // Every section is optional on read, so a file written by an older (or
    // partly corrupted) build still opens with whatever it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(CoreMeta.self, forKey: .meta)
        declared = try c.decodeIfPresent(CoreDeclared.self, forKey: .declared) ?? CoreDeclared()
        places = try c.decodeIfPresent([CorePlace].self, forKey: .places) ?? []
        placeCandidates = try c.decodeIfPresent([CorePlaceCandidate].self, forKey: .placeCandidates) ?? []
        rhythms = try c.decodeIfPresent(CoreRhythms.self, forKey: .rhythms) ?? CoreRhythms()
        habits = try c.decodeIfPresent([CoreHabit].self, forKey: .habits) ?? []
        taskStats = try c.decodeIfPresent([String: CoreTypeStats].self, forKey: .taskStats) ?? [:]
        taskSignals = try c.decodeIfPresent(CoreTaskSignals.self, forKey: .taskSignals) ?? CoreTaskSignals()
        facts = try c.decodeIfPresent([CoreFact].self, forKey: .facts) ?? []
        feedback = try c.decodeIfPresent(CoreFeedback.self, forKey: .feedback) ?? CoreFeedback()
    }

    /// The spec's task-behaviour summary, derived from the counters.
    var taskBehavior: CoreTaskBehavior { CoreLearner.taskBehavior(self) }
}

struct CoreMeta: Codable, Equatable {
    /// A random on-device id — not tied to any account.
    var userId: String = UUID().uuidString
    var schemaVersion: Int = CoreProfile.currentSchemaVersion
    var createdAt: Date
    var updatedAt: Date
    var consent = CoreConsent()
    /// The last day habit misses were swept up to (see `CoreHooks.sweepHabits`).
    var lastHabitSweep: Date?
}

/// Layer 2 switches. Both start off; when off, those modules collect nothing.
struct CoreConsent: Codable, Equatable {
    var location = false
    var noteExtraction = false
}

// MARK: - Declared

struct CoreDeclared: Codable, Equatable {
    enum NudgeLevel: String, Codable, CaseIterable, Identifiable {
        case minimal, normal, proactive
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    struct QuietHours: Codable, Equatable, Hashable, Identifiable {
        /// "HH:mm", 24-hour.
        var start: String
        var end: String
        var id: String { "\(start)-\(end)" }

        /// Whether `hour:minute` falls inside, wrapping past midnight ("22:00"–"07:00").
        func contains(hour: Int, minute: Int = 0) -> Bool {
            guard let s = Self.minutes(start), let e = Self.minutes(end), s != e else { return false }
            let t = hour * 60 + minute
            return s < e ? (t >= s && t < e) : (t >= s || t < e)
        }

        static func minutes(_ hhmm: String) -> Int? {
            let parts = hhmm.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            return parts[0] * 60 + parts[1]
        }
    }

    var quietHours: [QuietHours] = []
    var goals: [String] = []
    /// "Don't suggest this" — topics, task types, place or habit names.
    var suppressed: [String] = []
    var nudgeLevel: NudgeLevel = .normal
    /// User-renamed places, by place id. Always wins over an inferred label.
    var placeLabels: [String: String] = [:]
    /// User-set place categories, by place id. Always wins over a guess.
    var placeCategories: [String: CorePlace.Category] = [:]

    func isQuiet(hour: Int) -> Bool { quietHours.contains { $0.contains(hour: hour) } }

    /// True when `text` mentions anything the person asked not to be suggested.
    func isSuppressed(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let lower = text.lowercased()
        return suppressed.contains { term in
            let t = term.trimmingCharacters(in: .whitespaces).lowercased()
            return !t.isEmpty && lower.contains(t)
        }
    }
}

// MARK: - Places

/// A coarse coordinate (~100 m), rounded before it is ever stored.
nonisolated struct CoreCoordinate: Codable, Equatable, Hashable {
    var lat: Double
    var lng: Double

    /// Three decimals ≈ 110 m of latitude (less of longitude away from the
    /// equator) — enough to tell places apart, too coarse to pinpoint a door.
    func rounded() -> CoreCoordinate {
        CoreCoordinate(lat: (lat * 1000).rounded() / 1000, lng: (lng * 1000).rounded() / 1000)
    }

    /// Great-circle distance in metres.
    func distance(to other: CoreCoordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (other.lat - lat) * .pi / 180
        let dLng = (other.lng - lng) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(other.lat * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct CorePlace: Codable, Equatable, Identifiable {
    enum LabelSource: String, Codable { case user, inferred }
    enum Category: String, Codable, CaseIterable, Identifiable {
        case home, work, gym, store, other
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    struct Window: Codable, Equatable, Hashable {
        /// 0 = Sunday … 6 = Saturday.
        var dow: Int
        var hourStart: Int
        /// Exclusive.
        var hourEnd: Int
    }

    var id: String
    /// "Place 3" until named.
    var label: String
    var labelSource: LabelSource
    /// Coarse, on-device only. Never leaves `EvryCore`.
    var center: CoreCoordinate
    var radiusM: Double
    var category: Category?
    var visits: Int
    /// Visits, decay-weighted — what confidence is built from.
    var visitWeight: Double
    var firstVisit: Date
    var lastVisit: Date
    /// Decay-weighted visits per "dow-hour" bucket (sparse).
    var visitBins: [String: Double] = [:]
    /// Decay-weighted count of task types done (or planned) here.
    var linkedTaskTypes: [String: Double] = [:]
    var confidence: Double

    /// The hours this place is usually visited, merged into runs per weekday.
    var typicalWindows: [Window] { CoreLearner.windows(from: visitBins) }
}

struct CorePlaceCandidate: Codable, Equatable, Identifiable {
    var id: String
    var center: CoreCoordinate
    var visits: Int
    var firstSeen: Date
    var lastVisit: Date?
    var visitBins: [String: Double] = [:]
    var linkedTaskTypes: [String: Double] = [:]
}

/// A place the person named themselves (from setup's frequent places), used
/// only to suggest a label for a learned place nearby.
struct CoreNamedSpot: Equatable {
    var label: String
    var coordinate: CoreCoordinate
}

// MARK: - Rhythms

struct CoreRhythms: Codable, Equatable {
    /// Decay-weighted activity per hour (0–23) / weekday (0 = Sunday). Read the
    /// normalized views below.
    var hourWeights = Array(repeating: 0.0, count: 24)
    var dayWeights = Array(repeating: 0.0, count: 7)
    var planningHourWeights = Array(repeating: 0.0, count: 24)
    var completionHourWeights = Array(repeating: 0.0, count: 24)
    /// Which weekdays tasks get planned on — spots a "Sunday planner".
    var planningDayWeights = Array(repeating: 0.0, count: 7)
    var lastUpdate: Date?
    /// Distinct days with any activity (lifetime) — drives Core progress.
    var activeDayCount = 0
    var lastActiveDay: Date?
    var confidence = 0.0

    var activeHours: [Double] { Self.normalized(hourWeights) }
    var activeDays: [Double] { Self.normalized(dayWeights) }
    var planningHours: [Double] { Self.normalized(planningHourWeights) }
    var completionHours: [Double] { Self.normalized(completionHourWeights) }
    var weeklyShape: String? { CoreLearner.weeklyShape(self) }

    /// Scaled so the busiest bucket is 1.
    static func normalized(_ values: [Double]) -> [Double] {
        let top = values.max() ?? 0
        guard top > 0 else { return values.map { _ in 0 } }
        return values.map { ($0 / top * 100).rounded() / 100 }
    }
}

// MARK: - Habits

struct CoreHabit: Codable, Equatable, Identifiable {
    struct UsualTime: Equatable { var hour: Int; var spread: Double }

    var habitId: String
    var title: String
    /// "Every day", "Weekdays", "Mon, Wed, Fri".
    var cadence: String
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var completionRate30d: Double = 0
    /// Decay-weighted circular sums of check-in hours (so 23:00 and 01:00 average to midnight).
    var hourSin = 0.0
    var hourCos = 0.0
    var hourWeight = 0.0
    /// Decay-weighted check-ins / misses per weekday (0 = Sunday).
    var checkInsByDow = Array(repeating: 0.0, count: 7)
    var missesByDow = Array(repeating: 0.0, count: 7)
    var placeCounts: [String: Double] = [:]
    var observations = 0
    var lastEvent: Date
    var confidence = 0.0
    /// Cleared when it fades below the prune threshold.
    var patternsVisible = true

    var id: String { habitId }

    var usualTime: UsualTime? {
        guard patternsVisible, hourWeight >= 3 else { return nil }
        let r = sqrt(hourSin * hourSin + hourCos * hourCos) / hourWeight
        guard r > 0.35 else { return nil }   // check-ins are all over the clock
        var angle = atan2(hourSin, hourCos)
        if angle < 0 { angle += 2 * .pi }
        let hour = Int((angle / (2 * .pi) * 24).rounded()) % 24
        // Circular standard deviation, in hours.
        let spread = sqrt(-2 * log(max(r, 1e-6))) / (2 * .pi) * 24
        return UsualTime(hour: hour, spread: (spread * 10).rounded() / 10)
    }

    var usualPlaceId: String? {
        guard patternsVisible else { return nil }
        let total = placeCounts.values.reduce(0, +)
        guard total >= 3, let top = placeCounts.max(by: { $0.value < $1.value }),
              top.value / total >= 0.6 else { return nil }
        return top.key
    }

    var slipPattern: String? { patternsVisible ? CoreLearner.slipPattern(self) : nil }
}

/// What a habit hook hands the Core — the numbers `HabitStats` already works out.
struct CoreHabitSnapshot: Equatable {
    var id: String
    var title: String
    var cadence: String
    var currentStreak: Int
    var longestStreak: Int
    var rate30: Double
}

// MARK: - Tasks

struct CoreTypeStats: Codable, Equatable {
    var created = 0.0
    var completed = 0.0
    /// Moved to a later day.
    var pushed = 0.0
    var snoozed = 0.0
    var abandoned = 0.0
    /// Sum of create → complete hours, decayed with the rest.
    var completeHours = 0.0
    var lastUpdate: Date
}

struct CoreTaskSignals: Codable, Equatable {
    var created = 0.0
    var edits = 0.0
    /// Decay-weighted small / medium / large counts.
    var sizes = [0.0, 0.0, 0.0]
    var lastUpdate: Date?
    /// Lifetime count of task events — drives Core progress (never decays).
    var eventCount = 0
}

enum CoreTaskSize: Int, Codable { case small = 0, medium, large }

/// The spec's task-behaviour shape — derived, never stored.
struct CoreTaskBehavior: Equatable {
    enum Size: String { case small, medium, large, mixed }
    var completionRateByType: [String: Double] = [:]
    var avgCreateToCompleteHours: [String: Double] = [:]
    var rescheduleRateByType: [String: Double] = [:]
    var abandonRateByType: [String: Double] = [:]
    var avoidedTaskTypes: [String] = []
    /// Edits per task created; high may mean overwhelm.
    var editFrequency: Double = 0
    var typicalTaskSize: Size = .mixed
}

/// What a task hook hands the Core: the type and shape of a task, never its title.
struct CoreTaskInfo: Equatable {
    var type: String
    var createdAt: Date
    var size: CoreTaskSize
    /// The task's location text, used only to look up a place the person
    /// already saved. Never stored.
    var locationLabel: String?
}

// MARK: - Facts

struct CoreFact: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case appointment, project, person, preference, other }

    var id: String
    var kind: Kind
    /// Short and structured ("dentist · Tuesdays") — never note text.
    var summary: String
    var sourceNoteId: String
    var firstSeen: Date
    var lastSeen: Date
    /// Current confidence: `evidence`, faded by the time since `lastSeen`.
    var confidence: Double
    /// Confidence as of `lastSeen` — rises with sightings, falls with contradictions.
    var evidence: Double
    var userConfirmed: Bool = false
}

// MARK: - Feedback

struct CoreFeedback: Codable, Equatable {
    struct Counts: Codable, Equatable {
        var shown = 0.0
        var accepted = 0.0
        var dismissed = 0.0
        var lastUpdate: Date
    }

    var nudgesShown = 0
    var nudgesAccepted = 0
    var nudgesDismissed = 0
    var byType: [String: Counts] = [:]
    /// 0…1, how often the person opens Evry's chat, decayed per app open.
    var mascotEngagement = 0.0
    /// When each nudge type was last counted as shown (one per day).
    var lastShown: [String: Date] = [:]

    var acceptRateByNudgeType: [String: Double] {
        byType.compactMapValues { c in c.shown >= 1 ? min(1, c.accepted / c.shown) : nil }
    }
}

// MARK: - Events

enum CoreEvent {
    case taskCreated(CoreTaskInfo)
    case taskEdited(CoreTaskInfo)
    case taskRescheduled(CoreTaskInfo, from: Date?, to: Date)
    case taskSnoozed(CoreTaskInfo)
    case taskCompleted(CoreTaskInfo)
    /// Un-completed — takes back a completion.
    case taskReopened(CoreTaskInfo)
    /// Deleted while still open.
    case taskAbandoned(CoreTaskInfo)
    /// Restored from trash — takes back an abandonment.
    case taskRestored(CoreTaskInfo)
    case habitCheckIn(CoreHabitSnapshot)
    case habitMissed(CoreHabitSnapshot, day: Date)
    /// Stats changed without a check-in (undo, schedule edit).
    case habitUpdated(CoreHabitSnapshot)
    case habitRemoved(id: String)
    /// The text is read by the extractor (with consent) and then dropped.
    case noteSaved(id: String, text: String)
    case noteDeleted(id: String)
    case nudgeShown(type: String)
    case nudgeAccepted(type: String)
    case nudgeDismissed(type: String)
    case mascotOpened
    case appOpened
    /// A coarse location sample. Usually produced by the Core itself after a
    /// task completion or app open; ignored unless location consent is on.
    case locationSample(CoreCoordinate, reason: CoreSampleReason)
}

enum CoreSampleReason: Equatable {
    case appOpen
    /// Where the person was when they finished a task — a visit.
    case taskCompleted(type: String)
    /// A saved place a task was planned at — links the type, not a visit.
    case taskLocation(type: String)
    case habitCheckIn(habitId: String)
}

// MARK: - Config

struct CoreConfig {
    var rhythmHalfLifeDays = 30.0
    var taskHalfLifeDays = 30.0
    var habitHalfLifeDays = 21.0
    var placeHalfLifeDays = 45.0
    var factHalfLifeDays = 90.0
    /// Inferred places, facts and habit patterns below this confidence are dropped.
    var pruneThreshold = 0.15
    /// Visits before a cluster becomes a Place.
    var placeMinVisits = 3
    var clusterRadiusM = 150.0
    /// Samples at the same place within this window count as one visit.
    var visitDedupMinutes = 60.0
    /// A category is only guessed at or above this confidence.
    var categoryConfidence = 0.7
    var maxPlaces = 20
    var maxCandidates = 40
    var maxFacts = 60
    /// Writes wait this long for more events before hitting disk.
    var saveDebounce: Duration = .seconds(3)
    /// Location is sampled at most this often (seconds); recent samples are reused.
    var sampleReuseSeconds: TimeInterval = 300

    // The "desired size": the evidence at which each module is fully useful.
    var targetTaskEvents = 120
    var targetActiveDays = 21
    var targetHabitObservations = 42
    var targetPlaces = 3
    var targetFacts = 5

    static let standard = CoreConfig()
}

// MARK: - Progress

/// How close the Core is to its desired size — the Profile visualizer.
struct CoreProgress: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case tasks, rhythms, habits, places, facts
        var id: String { rawValue }

        var label: String {
            switch self {
            case .tasks: "Tasks"
            case .rhythms: "Rhythms"
            case .habits: "Habits"
            case .places: "Places"
            case .facts: "Notes"
            }
        }

        var icon: String {
            switch self {
            case .tasks: "checkmark.square"
            case .rhythms: "clock"
            case .habits: "arrow.triangle.2.circlepath"
            case .places: "mappin.and.ellipse"
            case .facts: "note.text"
            }
        }

        /// Share of the overall score when active.
        var weight: Double {
            switch self {
            case .tasks: 0.3
            case .rhythms: 0.25
            case .habits: 0.2
            case .places: 0.15
            case .facts: 0.1
            }
        }
    }

    struct Module: Equatable, Identifiable {
        var kind: Kind
        var fraction: Double
        /// Inactive modules (consent off, no habits yet) don't count toward the total.
        var isActive: Bool
        /// Why it's inactive, or what's left to learn.
        var hint: String
        var id: Kind { kind }
    }

    var modules: [Module]
    var overall: Double
    var isComplete: Bool { overall >= 0.995 }
}
