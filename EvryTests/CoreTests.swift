//
//  CoreTests.swift
//  EvryTests
//
//  The Core's rules: decay and confidence, place clustering and promotion,
//  consent gating, declared-over-inferred precedence, context slicing (no
//  coordinates or note text leak), and reset / delete.
//

import Foundation
import Testing
@testable import Evry

// MARK: - Fixtures

private let cal = Calendar.current
private let day: TimeInterval = 86_400

/// Monday 2 March 2026, 10:00 local.
private let monday10 = cal.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 10))!

private func at(_ base: Date, days: Double = 0, hour: Int? = nil) -> Date {
    let d = base.addingTimeInterval(days * day)
    guard let hour else { return d }
    return cal.date(bySettingHour: hour, minute: 0, second: 0, of: d)!
}

@MainActor
private final class FakeLocator: CoreLocating {
    var isAuthorized = true
    var canAsk = false
    var next: CoreCoordinate? = CoreCoordinate(lat: 40.712_8, lng: -74.006_0)
    private(set) var samples = 0
    private(set) var asked = 0
    func requestAccess() { asked += 1 }
    func sample() async -> CoreCoordinate? { samples += 1; return next }
}

@MainActor
private final class SpyExtractor: NoteFactExtracting {
    private(set) var calls = 0
    func extract(from text: String) async -> [ExtractedFact] {
        calls += 1
        return RuleFactExtractor.facts(in: text)
    }
}

@MainActor
private final class TestClock {
    var now = monday10
}

@MainActor
private func makeCore(storage: MemoryCoreStorage? = nil,
                      locator: FakeLocator? = nil,
                      extractor: NoteFactExtracting? = nil,
                      spots: [CoreNamedSpot] = [],
                      clock: TestClock? = nil) -> EvryCore {
    let clock = clock ?? TestClock()
    return EvryCore(storage: storage ?? MemoryCoreStorage(), config: .standard, locator: locator ?? FakeLocator(),
                    extractor: extractor ?? RuleFactExtractor(),
                    namedSpots: { spots }, savedSpot: { _ in nil }, clock: { clock.now })
}

private let home = CoreCoordinate(lat: 40.712_8, lng: -74.006_0)
/// ~80 m from `home`.
private let nearHome = CoreCoordinate(lat: 40.713_5, lng: -74.006_0)
/// ~2 km away.
private let elsewhere = CoreCoordinate(lat: 40.730_0, lng: -74.006_0)

private func task(_ type: String, created: Date = monday10) -> CoreTaskInfo {
    CoreTaskInfo(type: type, createdAt: created, size: .small, locationLabel: nil)
}

/// Visits on separate days at `hour`, so each counts as its own visit.
@MainActor
private func visit(_ core: EvryCore, _ c: CoreCoordinate, times: Int, hour: Int = 10, startDay: Double = 0,
                   reason: CoreSampleReason = .appOpen) {
    for i in 0..<times {
        core.record(.locationSample(c, reason: reason), at: at(monday10, days: startDay + Double(i), hour: hour))
    }
}

// MARK: - Decay & confidence

@MainActor
struct CoreDecayTests {
    @Test func weightHalvesEachHalfLife() {
        let f = CoreLearner.decay(from: monday10, to: at(monday10, days: 30), halfLifeDays: 30)
        #expect(abs(f - 0.5) < 0.0001)
        #expect(CoreLearner.decay(from: monday10, to: at(monday10, days: 60), halfLifeDays: 30) < 0.26)
        // No time travel: a timestamp in the future never inflates a weight.
        #expect(CoreLearner.decay(from: at(monday10, days: 1), to: monday10, halfLifeDays: 30) == 1)
    }

    @Test func evidenceSaturatesBelowOne() {
        let few = CoreLearner.evidence(2, saturation: 4)
        let many = CoreLearner.evidence(20, saturation: 4)
        #expect(few < many)
        #expect(many < 1)
        #expect(CoreLearner.evidence(0, saturation: 4) == 0)
    }

    @Test func confidenceFadesWithAge() {
        let fresh = CoreLearner.confidence(evidence: 0.8, lastSeen: monday10, now: monday10, halfLifeDays: 45)
        let old = CoreLearner.confidence(evidence: 0.8, lastSeen: monday10, now: at(monday10, days: 90), halfLifeDays: 45)
        #expect(fresh == 0.8)
        #expect(abs(old - 0.2) < 0.001)
    }

    @Test func recentTaskBehaviourCountsMore() {
        var p = CoreProfile(now: monday10)
        // Four abandoned work tasks three months ago, four finished now.
        for _ in 0..<4 {
            CoreLearner.apply(.taskCreated(task("work")), to: &p, at: monday10)
            CoreLearner.apply(.taskAbandoned(task("work")), to: &p, at: monday10)
        }
        let later = at(monday10, days: 90)
        for _ in 0..<4 {
            CoreLearner.apply(.taskCreated(task("work", created: later)), to: &p, at: later)
            CoreLearner.apply(.taskCompleted(task("work", created: later)), to: &p, at: later)
        }
        let rate = p.taskBehavior.completionRateByType["work"] ?? 0
        #expect(rate > 0.75)   // an even, undecayed split would be 0.5
    }

    @Test func repeatedlyPushedTypeIsAvoided() {
        var p = CoreProfile(now: monday10)
        for i in 0..<4 {
            let t = task("admin")
            CoreLearner.apply(.taskCreated(t), to: &p, at: monday10)
            CoreLearner.apply(.taskRescheduled(t, from: at(monday10, days: Double(i)), to: at(monday10, days: Double(i) + 2)),
                              to: &p, at: monday10)
        }
        // Moving a task to a time later the same day isn't putting it off.
        let same = task("work")
        CoreLearner.apply(.taskCreated(same), to: &p, at: monday10)
        CoreLearner.apply(.taskRescheduled(same, from: monday10, to: monday10.addingTimeInterval(3600)), to: &p, at: monday10)
        #expect(p.taskBehavior.avoidedTaskTypes == ["admin"])
    }

    @Test func consistentHabitTimeIsMoreConfident() {
        var steady = CoreProfile(now: monday10), scattered = CoreProfile(now: monday10)
        let snap = CoreHabitSnapshot(id: "h", title: "Read", cadence: "Every day", currentStreak: 1, longestStreak: 1, rate30: 1)
        let scatterHours = [6, 13, 19, 23, 2, 10]
        for i in 0..<6 {
            CoreLearner.apply(.habitCheckIn(snap), to: &steady, at: at(monday10, days: Double(i), hour: 7))
            CoreLearner.apply(.habitCheckIn(snap), to: &scattered, at: at(monday10, days: Double(i), hour: scatterHours[i]))
        }
        let a = steady.habits[0], b = scattered.habits[0]
        #expect(a.confidence > b.confidence)
        #expect(a.usualTime?.hour == 7)
        #expect(b.usualTime == nil)
    }

    @Test func weekendMissesBecomeASlipPattern() {
        var p = CoreProfile(now: monday10)
        let snap = CoreHabitSnapshot(id: "h", title: "Run", cadence: "Every day", currentStreak: 0, longestStreak: 3, rate30: 0.6)
        for week in 0..<2 {
            let w = Double(week * 7)
            for d in 0..<5 { CoreLearner.apply(.habitCheckIn(snap), to: &p, at: at(monday10, days: w + Double(d), hour: 7)) }
            CoreLearner.apply(.habitMissed(snap, day: at(monday10, days: w + 5)), to: &p, at: at(monday10, days: w + 6))
            CoreLearner.apply(.habitMissed(snap, day: at(monday10, days: w + 6)), to: &p, at: at(monday10, days: w + 7))
        }
        #expect(p.habits[0].slipPattern == "misses on weekends")
    }
}

// MARK: - Places

@MainActor
struct CorePlaceTests {
    @Test func promotesAfterMinimumVisits() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 2)
        #expect(core.profile.places.isEmpty)
        #expect(core.profile.placeCandidates.count == 1)
        visit(core, nearHome, times: 1, startDay: 2)
        #expect(core.profile.places.count == 1)
        #expect(core.profile.placeCandidates.isEmpty)
        #expect(core.profile.places[0].label == "Place 1")
        #expect(core.profile.places[0].labelSource == .inferred)
    }

    @Test func samplesInsideAnHourAreOneVisit() {
        let core = makeCore()
        core.setLocationConsent(true)
        for minute in [0, 10, 20, 30] {
            core.record(.locationSample(home, reason: .appOpen), at: monday10.addingTimeInterval(Double(minute) * 60))
        }
        #expect(core.profile.places.isEmpty)
        #expect(core.profile.placeCandidates.first?.visits == 1)
    }

    @Test func distantSamplesStaySeparate() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 3)
        visit(core, elsewhere, times: 1, startDay: 3)
        #expect(core.profile.places.count == 1)
        #expect(core.profile.placeCandidates.count == 1)
    }

    @Test func storedCoordinatesAreCoarse() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, CoreCoordinate(lat: 40.712_834_9, lng: -74.006_012_3), times: 3)
        let c = core.profile.places[0].center
        #expect(c == CoreCoordinate(lat: 40.713, lng: -74.006))
    }

    @Test func categoryOnlyWithHighConfidence() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 3, hour: 22)
        #expect(core.profile.places[0].category == nil)   // three visits isn't enough to say "home"
        visit(core, home, times: 6, hour: 22, startDay: 3)
        #expect(core.profile.places[0].category == .home)
    }

    @Test func completionsLinkTaskTypes() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 3, reason: .taskCompleted(type: "chores"))
        #expect((core.profile.places[0].linkedTaskTypes["chores"] ?? 0) >= 2.9)
    }

    @Test func oldInferredPlacesArePruned() {
        let clock = TestClock()
        let core = makeCore(clock: clock)
        core.setLocationConsent(true)
        visit(core, home, times: 3)
        clock.now = at(monday10, days: 200)
        core.maintain()
        #expect(core.profile.places.isEmpty)
    }
}

// MARK: - Consent

@MainActor
struct CoreConsentTests {
    @Test func locationOffCollectsNothing() async {
        let locator = FakeLocator()
        let core = makeCore(locator: locator)
        #expect(core.profile.meta.consent.location == false)
        core.record(.appOpened)
        core.record(.taskCompleted(task("errand")))
        visit(core, home, times: 5)
        await core.settle()
        #expect(locator.samples == 0)
        #expect(core.profile.places.isEmpty)
        #expect(core.profile.placeCandidates.isEmpty)
    }

    @Test func locationOnSamplesAtMeaningfulMoments() async {
        let locator = FakeLocator()
        let core = makeCore(locator: locator)
        core.setLocationConsent(true)
        core.record(.appOpened)
        await core.settle()
        #expect(locator.samples == 1)
        #expect(core.profile.placeCandidates.count == 1)
        // A second open moments later reuses the fix instead of asking again.
        core.record(.appOpened, at: monday10.addingTimeInterval(60))
        await core.settle()
        #expect(locator.samples == 1)
    }

    @Test func noPermissionMeansSparseNotBroken() async {
        let locator = FakeLocator()
        locator.isAuthorized = false
        let core = makeCore(locator: locator)
        core.setLocationConsent(true)
        core.record(.appOpened)
        await core.settle()
        #expect(locator.samples == 0)
        #expect(core.profile.places.isEmpty)
        #expect(core.locationAccess == .denied)
    }

    @Test func noteExtractionOffReadsNothing() async {
        let spy = SpyExtractor()
        let core = makeCore(extractor: spy)
        core.record(.noteSaved(id: "n1", text: "Dentist every Tuesday. My boss Dana wants Project Atlas."))
        await core.settle()
        #expect(spy.calls == 0)
        #expect(core.profile.facts.isEmpty)
    }

    @Test func noteExtractionOnKeepsFactsNotText() async throws {
        let storage = MemoryCoreStorage()
        let core = makeCore(storage: storage, extractor: SpyExtractor())
        core.setNoteConsent(true)
        let sentence = "Dentist every Tuesday at the clinic downtown, then lunch with my boss Dana."
        core.record(.noteSaved(id: "n1", text: sentence))
        await core.settle()
        let summaries = Set(core.profile.facts.map(\.summary))
        #expect(summaries.contains("dentist · Tuesdays"))
        #expect(summaries.contains("boss: Dana"))
        #expect(core.profile.facts.allSatisfy { $0.sourceNoteId == "n1" })
        core.flush()
        let stored = String(decoding: try #require(storage.data), as: UTF8.self)
        #expect(!stored.contains("clinic downtown"))
        #expect(!stored.contains(sentence))
    }

    @Test func turningOffCanDeleteWhatWasCollected() async {
        let core = makeCore()
        core.setLocationConsent(true)
        core.setNoteConsent(true)
        visit(core, home, times: 3)
        core.record(.noteSaved(id: "n1", text: "Piano lesson every Monday"))
        await core.settle()
        #expect(!core.profile.places.isEmpty && !core.profile.facts.isEmpty)

        core.setLocationConsent(false, deleteData: true)
        core.setNoteConsent(false, deleteData: true)
        #expect(core.profile.places.isEmpty && core.profile.placeCandidates.isEmpty)
        #expect(core.profile.facts.isEmpty)
        // And it stays off.
        visit(core, home, times: 3, startDay: 5)
        #expect(core.profile.places.isEmpty)
    }

    @Test func turningOffKeepsDataUnlessAsked() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 3)
        core.setLocationConsent(false)
        #expect(core.profile.places.count == 1)
    }
}

// MARK: - Declared over inferred

@MainActor
struct CoreDeclaredTests {
    @Test func renamedPlaceKeepsItsName() {
        let spot = CoreNamedSpot(label: "Work", coordinate: home)
        let core = makeCore(spots: [spot])
        core.setLocationConsent(true)
        visit(core, home, times: 3)
        let id = core.profile.places[0].id
        #expect(core.profile.places[0].label == "Work")   // suggested from setup's saved place
        core.renamePlace(id, to: "Studio")
        visit(core, home, times: 5, startDay: 4)
        core.maintain()
        #expect(core.profile.places[0].label == "Studio")
        #expect(core.profile.places[0].labelSource == .user)
    }

    @Test func declaredCategoryBeatsTheGuess() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 9, hour: 22)
        let id = core.profile.places[0].id
        #expect(core.profile.places[0].category == .home)
        core.setPlaceCategory(id, to: .work)
        visit(core, home, times: 5, hour: 23, startDay: 10)
        #expect(core.profile.places[0].category == .work)
        #expect(core.getContext(.locationSuggestions).places?.first?.cat == "work")
    }

    @Test func userNamedPlacesAreNeverPruned() {
        let clock = TestClock()
        let core = makeCore(clock: clock)
        core.setLocationConsent(true)
        visit(core, home, times: 3)
        core.renamePlace(core.profile.places[0].id, to: "Grandma's")
        clock.now = at(monday10, days: 400)
        core.maintain()
        #expect(core.profile.places.map(\.label) == ["Grandma's"])
    }

    @Test func confirmedFactsSurviveDecay() async {
        let clock = TestClock()
        let core = makeCore(clock: clock)
        core.setNoteConsent(true)
        core.record(.noteSaved(id: "n1", text: "Therapy every Thursday. My sister Ana visits."))
        await core.settle()
        let therapy = core.profile.facts.first { $0.kind == .appointment }!
        core.confirmFact(therapy.id)
        clock.now = at(monday10, days: 500)
        core.maintain()
        #expect(core.profile.facts.map(\.id) == [therapy.id])
    }

    @Test func declaredPreferencesAreCleaned() {
        let core = makeCore()
        core.updateDeclared {
            $0.goals = ["  Run a 10k ", "run a 10k", ""]
            $0.quietHours = [.init(start: "22:00", end: "07:00"), .init(start: "25:00", end: "07:00")]
            $0.nudgeLevel = .minimal
        }
        #expect(core.profile.declared.goals == ["Run a 10k"])
        #expect(core.profile.declared.quietHours.map(\.id) == ["22:00-07:00"])
        core.record(.appOpened)
        core.maintain()
        #expect(core.profile.declared.nudgeLevel == .minimal)
    }
}

// MARK: - Context slicing

@MainActor
struct CoreContextTests {
    @Test func locationSliceHasNoCoordinates() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 4, reason: .taskCompleted(type: "errand"))
        let json = core.getContext(.locationSuggestions).json
        #expect(json.contains("Place 1"))
        #expect(json.contains("errand"))
        for leak in ["lat", "lng", "center", "40.71", "-74.0"] {
            #expect(!json.contains(leak), "leaked \(leak)")
        }
        for purpose in CorePurpose.allCases {
            #expect(!core.getContext(purpose).json.contains("40.71"))
        }
    }

    @Test func noteTextNeverReachesASlice() async {
        let core = makeCore()
        core.setNoteConsent(true)
        let text = "Working on Atlas Redesign with my manager Priya, the deadline makes me anxious."
        core.record(.noteSaved(id: "secret-note", text: text))
        await core.settle()
        let json = core.getContext(.taskPlanning).json + core.getContext(.general).json
        #expect(json.contains("project: Atlas Redesign"))
        #expect(!json.contains("anxious"))
        #expect(!json.contains("secret-note"))
    }

    @Test func eachPurposeGetsOnlyItsSections() {
        let core = makeCore()
        core.setLocationConsent(true)
        visit(core, home, times: 3)
        core.record(.taskCreated(task("work")))
        core.record(.habitCheckIn(CoreHabitSnapshot(id: "h", title: "Stretch", cadence: "Every day",
                                                    currentStreak: 2, longestStreak: 2, rate30: 1)))
        let reminders = core.getContext(.reminders)
        #expect(reminders.places == nil && reminders.habits == nil && reminders.facts == nil)
        #expect(reminders.nudge == "normal")
        let coaching = core.getContext(.habitCoaching)
        #expect(coaching.habits?.first?.t == "Stretch")
        #expect(coaching.places == nil && coaching.tasks == nil)
        let places = core.getContext(.locationSuggestions)
        #expect(places.habits == nil && places.tasks == nil)
    }

    @Test func quietHoursAreAlwaysApplied() {
        let core = makeCore()
        for i in 0..<5 { core.record(.appOpened, at: at(monday10, days: Double(i), hour: 23)) }
        core.record(.appOpened, at: at(monday10, hour: 9))
        #expect(core.getContext(.reminders).peakH?.contains(23) == true)
        core.updateDeclared { $0.quietHours = [.init(start: "22:00", end: "07:00")] }
        for purpose in CorePurpose.allCases {
            let slice = core.getContext(purpose)
            #expect(slice.q == ["22:00-07:00"])
            #expect(slice.peakH?.contains(23) != true)
        }
        #expect(core.getContext(.reminders).peakH == [9])
    }

    @Test func suppressedTopicsAreLeftOut() {
        let core = makeCore()
        for i in 0..<4 {
            let t = task("admin")
            core.record(.taskCreated(t))
            core.record(.taskRescheduled(t, from: at(monday10, days: Double(i)), to: at(monday10, days: Double(i) + 1)))
        }
        #expect(core.getContext(.reminders).avoid == ["admin"])
        core.updateDeclared { $0.suppressed = ["Admin"] }
        #expect(core.getContext(.reminders).avoid == nil)
        #expect(core.getContext(.taskPlanning).tasks?.contains { $0.t == "admin" } != true)
    }

    @Test func coldStartIsSparse() {
        let core = makeCore()
        for purpose in CorePurpose.allCases {
            let slice = core.getContext(purpose)
            #expect(slice.places == nil && slice.habits == nil && slice.facts == nil)
            #expect(slice.json.count < 120)
        }
    }
}

// MARK: - Reset, delete, storage

@MainActor
struct CoreResetTests {
    @Test func deletesSingleEntries() async {
        let core = makeCore()
        core.setLocationConsent(true)
        core.setNoteConsent(true)
        visit(core, home, times: 3)
        visit(core, elsewhere, times: 3, startDay: 3)
        core.record(.noteSaved(id: "n1", text: "Yoga class every Wednesday. Project Nova."))
        await core.settle()
        let place = core.profile.places[0].id
        core.renamePlace(place, to: "Home")
        core.deleteEntry(.place(place))
        #expect(core.profile.places.count == 1)
        #expect(core.profile.declared.placeLabels[place] == nil)

        let factCount = core.profile.facts.count
        core.deleteEntry(.fact(core.profile.facts[0].id))
        #expect(core.profile.facts.count == factCount - 1)
    }

    @Test func deletingANoteForgetsItsUnconfirmedFacts() async {
        let core = makeCore()
        core.setNoteConsent(true)
        core.record(.noteSaved(id: "n1", text: "Piano lesson every Monday. My friend Sam."))
        await core.settle()
        let keep = core.profile.facts[0].id
        core.confirmFact(keep)
        core.record(.noteDeleted(id: "n1"))
        #expect(core.profile.facts.map(\.id) == [keep])
    }

    @Test func resetForgetsEverything() async throws {
        let storage = MemoryCoreStorage()
        let core = makeCore(storage: storage)
        let firstId = core.profile.meta.userId
        core.setLocationConsent(true)
        core.setNoteConsent(true)
        visit(core, home, times: 3)
        core.record(.taskCreated(task("work")))
        core.updateDeclared { $0.goals = ["Sleep more"] }
        core.reset()
        let p = core.profile
        #expect(p.places.isEmpty && p.placeCandidates.isEmpty && p.facts.isEmpty && p.taskStats.isEmpty)
        #expect(p.declared == CoreDeclared())
        #expect(p.meta.consent == CoreConsent())
        #expect(p.meta.userId != firstId)
        let data = try #require(storage.data)
        let reloaded = try #require(CoreMigrator.decode(data))
        #expect(reloaded.places.isEmpty && reloaded.declared.goals.isEmpty)
    }

    @Test func roundTripsThroughStorage() throws {
        let storage = MemoryCoreStorage()
        let core = makeCore(storage: storage)
        core.setLocationConsent(true)
        visit(core, home, times: 3)
        core.flush()
        let again = makeCore(storage: storage)
        #expect(again.profile.places.count == 1)
        #expect(again.profile.meta.consent.location)
    }

    @Test func writesAreBatched() {
        let storage = MemoryCoreStorage()
        let core = makeCore(storage: storage)
        for _ in 0..<50 { core.record(.taskCreated(task("work"))) }
        #expect(storage.saves == 0)   // waiting on the debounce
        core.flush()
        core.flush()
        #expect(storage.saves == 1)
    }

    @Test func oldOrDamagedFilesOpenSparse() {
        // A v1 file with only meta still opens.
        let minimal = #"{"meta":{"userId":"u","schemaVersion":1,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","consent":{"location":true,"noteExtraction":false}}}"#
        let p = CoreMigrator.decode(Data(minimal.utf8))
        #expect(p?.meta.consent.location == true)
        #expect(p?.places.isEmpty == true)

        let damaged = MemoryCoreStorage(data: Data("not json".utf8))
        let core = makeCore(storage: damaged)
        #expect(damaged.archived == 1)
        #expect(core.profile.places.isEmpty)

        let future = #"{"meta":{"userId":"u","schemaVersion":99,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}"#
        #expect(CoreMigrator.decode(Data(future.utf8)) == nil)
    }
}

// MARK: - Extraction, types, progress

@MainActor
struct CoreMiscTests {
    @Test func ruleExtractorFindsStructuredFacts() {
        let facts = RuleFactExtractor.facts(in: """
            Weekly team meeting moved. Dentist every Tuesday.
            Working on Atlas Redesign. My boss Dana is out. I prefer mornings for deep work.
            """)
        let pairs = Set(facts.map { "\($0.kind.rawValue)|\($0.summary)" })
        #expect(pairs.contains("appointment|dentist · Tuesdays"))
        #expect(pairs.contains("appointment|team meeting · weekly"))
        #expect(pairs.contains("project|project: Atlas Redesign"))
        #expect(pairs.contains("person|boss: Dana"))
        #expect(pairs.contains("preference|prefers mornings for deep work"))
        #expect(facts.allSatisfy { $0.summary.split(separator: " ").count <= 6 })
    }

    @Test func tasksAreTypedNotTitled() {
        #expect(CoreTaskTypes.type(title: "Buy groceries") == "errand")
        #expect(CoreTaskTypes.type(title: "Leg day at the gym") == "fitness")
        #expect(CoreTaskTypes.type(title: "Book the dentist") == "health")
        #expect(CoreTaskTypes.type(title: "Something vague", tags: ["work"]) == "work")
        #expect(CoreTaskTypes.type(title: "Ponder") == "other")
    }

    @Test func testsRunTheSharedCoreInTestMode() {
        // TaskActions / HabitActions tests drive EvryCore.shared — it must not
        // touch the on-device file or location while they do.
        #expect(EvryCore.isTestMode)
    }

    @Test func crystalBuildsOneFragmentPerTwelfth() {
        #expect(CoreCrystal.built(0) == 0)
        #expect(CoreCrystal.built(0.08) == 0)
        #expect(CoreCrystal.built(1.0 / 12) == 1)
        #expect(CoreCrystal.built(0.5) == 6)
        #expect(CoreCrystal.built(0.99) == 11)
        #expect(CoreCrystal.built(1) == 12)
        // Base first: the first three fragments are the bottom point.
        #expect(CoreCrystal.fragments.prefix(3).allSatisfy { $0.row == 0 })
    }

    @Test func progressCountsOnlyActiveModules() {
        var p = CoreProfile(now: monday10)
        let config = CoreConfig.standard
        #expect(CoreLearner.progress(p, config: config).overall == 0)
        p.taskSignals.eventCount = config.targetTaskEvents
        p.rhythms.activeDayCount = config.targetActiveDays
        // Habits, places and notes are inactive, so tasks + rhythms are the whole score.
        #expect(CoreLearner.progress(p, config: config).isComplete)
        p.meta.consent.location = true
        let withPlaces = CoreLearner.progress(p, config: config)
        #expect(!withPlaces.isComplete)
        #expect(withPlaces.modules.first { $0.kind == .places }?.isActive == true)
    }
}
