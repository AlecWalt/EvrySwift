//
//  EvryCore.swift
//  Evry
//
//  The Core's engine and public API:
//
//      record(_:)          fold an app event into the profile
//      getContext(_:)      a minimal, coordinate-free slice for a model call
//      getView()           the profile in readable sections, for the Core screen
//      updateDeclared(_:)  edit what the person stated themselves
//      deleteEntry(_:)     forget one entry
//      reset()             forget everything
//
//  The profile is kept in memory and written to a small JSON file in
//  Application Support (excluded from iCloud backup, so coordinates stay on
//  this device), debounced so ingestion costs nothing noticeable. Nothing here
//  talks to a network.
//

import Foundation
import CoreLocation
import Observation

// MARK: - Entry references

/// One deletable / editable entry in the Core.
enum CoreEntryRef: Hashable {
    case place(String)
    case fact(String)
    case habit(String)
    case taskType(String)
    case rhythms
    case feedback
    case goal(String)
    case quietHours(String)
    case suppressed(String)
}

// MARK: - Engine

@MainActor
@Observable
final class EvryCore {
    static let shared = EvryCore(storage: isTestMode ? MemoryCoreStorage() : FileCoreStorage(), config: .standard,
                                 locator: isTestMode ? nil : CoreLocationSampler(),
                                 extractor: RuleFactExtractor(), namedSpots: { EvryCore.setupPlaces() },
                                 savedSpot: { EvryCore.setupPlace(matching: $0) }, clock: { Date() })

    /// Test mode: under unit tests (or when launched with `-EvryCoreTestMode`)
    /// the shared Core keeps everything in memory and never asks for location,
    /// so tests that drive TaskActions / HabitActions leave the real Core alone.
    static let isTestMode: Bool = {
        let info = ProcessInfo.processInfo
        return info.environment["XCTestConfigurationFilePath"] != nil
            || info.arguments.contains("-EvryCoreTestMode")
    }()

    private(set) var profile: CoreProfile

    @ObservationIgnored let config: CoreConfig
    @ObservationIgnored private let storage: CoreStorage
    @ObservationIgnored private let locator: CoreLocating?
    @ObservationIgnored var extractor: NoteFactExtracting
    /// Places the person saved in setup, used only to name learned places.
    @ObservationIgnored var namedSpots: () -> [CoreNamedSpot]
    /// Looks up a saved place's coordinate from a task's location text.
    @ObservationIgnored var savedSpot: (String) -> CoreCoordinate?
    @ObservationIgnored var clock: () -> Date

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false
    /// The latest coarse fix, in memory only — reused for a few minutes rather
    /// than waking location services again.
    @ObservationIgnored private var lastSample: (coordinate: CoreCoordinate, at: Date)?
    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]

    /// `shared` uses the on-disk store, real location and setup's places;
    /// tests pass in-memory stand-ins and a fixed clock.
    init(storage: CoreStorage,
         config: CoreConfig,
         locator: CoreLocating?,
         extractor: NoteFactExtracting,
         namedSpots: @escaping () -> [CoreNamedSpot],
         savedSpot: @escaping (String) -> CoreCoordinate?,
         clock: @escaping () -> Date) {
        self.storage = storage
        self.config = config
        self.locator = locator
        self.extractor = extractor
        self.namedSpots = namedSpots
        self.savedSpot = savedSpot
        self.clock = clock
        var loaded: CoreProfile?
        if let data = storage.load() {
            loaded = CoreMigrator.decode(data)
            // Unreadable (or from a newer build): set it aside, start sparse.
            if loaded == nil { storage.archiveUnreadable() }
        }
        self.profile = loaded ?? CoreProfile(now: clock())
    }

    // MARK: Record

    /// The single entry point for app events. Cheap and synchronous: it
    /// updates the in-memory profile and schedules a debounced write. Never
    /// throws; with consent off, Layer 2 events are simply ignored.
    func record(_ event: CoreEvent, at date: Date? = nil) {
        let now = date ?? clock()
        switch event {
        case .noteSaved(let id, let text):
            guard profile.meta.consent.noteExtraction else { return }
            let extractor = extractor
            track { [weak self] in
                // The text lives only in this task; only the structured facts are kept.
                let found = await extractor.extract(from: text)
                guard let self, self.profile.meta.consent.noteExtraction else { return }
                CoreLearner.mergeFacts(found, fromNote: id, into: &self.profile, at: self.clock(), config: self.config)
                self.scheduleSave()
            }
            return
        case .locationSample:
            guard profile.meta.consent.location else { return }
        default:
            break
        }

        var spots: [CoreNamedSpot] = []
        if case .locationSample = event { spots = namedSpots() }
        CoreLearner.apply(event, to: &profile, at: now, config: config, namedSpots: spots)
        scheduleSave()

        // Meaningful moments for a coarse location sample (with consent).
        switch event {
        case .appOpened:
            sampleLocation(.appOpen, at: now)
        case .taskCompleted(let t):
            sampleLocation(.taskCompleted(type: t.type), at: now)
        case .taskCreated(let t):
            // A task planned at a saved place links its type to that place.
            if profile.meta.consent.location, let label = t.locationLabel, !label.isEmpty,
               let spot = savedSpot(label) {
                record(.locationSample(spot, reason: .taskLocation(type: t.type)), at: now)
            }
        case .habitCheckIn(let s):
            attributeHabit(s.id, at: now)
        default:
            break
        }
    }

    /// Waits for in-flight extraction and location work (tests, previews).
    func settle() async {
        while let task = pending.values.first {
            await task.value
        }
    }

    // MARK: Context

    func getContext(_ purpose: CorePurpose) -> CoreContextSlice {
        CoreContextBuilder.build(purpose, from: profile, config: config, now: clock())
    }

    // MARK: View

    var progress: CoreProgress { CoreLearner.progress(profile, config: config) }

    func getView() -> CoreReadout { CoreReadout(profile, now: clock()) }

    // MARK: Declared

    /// Edits the person's own preferences. Inference never overwrites these;
    /// labels and categories set here take effect on places immediately.
    func updateDeclared(_ change: (inout CoreDeclared) -> Void) {
        var d = profile.declared
        change(&d)
        func clean(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        d.goals = clean(d.goals)
        d.suppressed = clean(d.suppressed)
        d.quietHours = Array(Set(d.quietHours.filter {
            CoreDeclared.QuietHours.minutes($0.start) != nil && CoreDeclared.QuietHours.minutes($0.end) != nil
        })).sorted { $0.start < $1.start }
        d.placeLabels = d.placeLabels
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        profile.declared = d
        let now = clock()
        let spots = namedSpots()
        for i in profile.places.indices {
            CoreLearner.refresh(&profile.places[i], declared: d, now: now, config: config, namedSpots: spots)
        }
        profile.meta.updatedAt = now
        scheduleSave()
    }

    func renamePlace(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let i = profile.places.firstIndex(where: { $0.id == id }) {
            // Cleared: hand the label back to inference.
            profile.places[i].labelSource = .inferred
            profile.places[i].label = CoreLearner.nextPlaceLabel(profile.places.filter { $0.id != id })
        }
        updateDeclared { $0.placeLabels[id] = trimmed.isEmpty ? nil : trimmed }
    }

    func setPlaceCategory(_ id: String, to category: CorePlace.Category?) {
        updateDeclared { $0.placeCategories[id] = category }
    }

    func confirmFact(_ id: String) {
        guard let i = profile.facts.firstIndex(where: { $0.id == id }) else { return }
        profile.facts[i].userConfirmed = true
        profile.facts[i].confidence = 1
        profile.meta.updatedAt = clock()
        scheduleSave()
    }

    // MARK: Consent

    enum LocationAccess { case granted, notAsked, denied }

    var locationAccess: LocationAccess {
        guard let locator else { return .denied }
        if locator.isAuthorized { return .granted }
        return locator.canAsk ? .notAsked : .denied
    }

    /// Turning location on asks for permission if it hasn't been asked yet.
    /// Turning it off stops collection at once; `deleteData` also forgets
    /// every place, candidate and place link.
    func setLocationConsent(_ on: Bool, deleteData: Bool = false) {
        profile.meta.consent.location = on
        if on, let locator, locator.canAsk { locator.requestAccess() }
        if !on {
            lastSample = nil
            if deleteData { clearLocationData() }
        }
        profile.meta.updatedAt = clock()
        scheduleSave()
    }

    func setNoteConsent(_ on: Bool, deleteData: Bool = false) {
        profile.meta.consent.noteExtraction = on
        if !on && deleteData { profile.facts.removeAll() }
        profile.meta.updatedAt = clock()
        scheduleSave()
    }

    func clearLocationData() {
        profile.places.removeAll()
        profile.placeCandidates.removeAll()
        profile.declared.placeLabels.removeAll()
        profile.declared.placeCategories.removeAll()
        for i in profile.habits.indices { profile.habits[i].placeCounts.removeAll() }
        lastSample = nil
        scheduleSave()
    }

    // MARK: Delete & reset

    func deleteEntry(_ ref: CoreEntryRef) {
        switch ref {
        case .place(let id):
            profile.places.removeAll { $0.id == id }
            profile.declared.placeLabels[id] = nil
            profile.declared.placeCategories[id] = nil
            for i in profile.habits.indices { profile.habits[i].placeCounts[id] = nil }
        case .fact(let id):
            profile.facts.removeAll { $0.id == id }
        case .habit(let id):
            profile.habits.removeAll { $0.habitId == id }
        case .taskType(let type):
            profile.taskStats[type] = nil
        case .rhythms:
            profile.rhythms = CoreRhythms()
        case .feedback:
            profile.feedback = CoreFeedback()
        case .goal(let goal):
            profile.declared.goals.removeAll { $0 == goal }
        case .quietHours(let id):
            profile.declared.quietHours.removeAll { $0.id == id }
        case .suppressed(let term):
            profile.declared.suppressed.removeAll { $0 == term }
        }
        profile.meta.updatedAt = clock()
        scheduleSave()
    }

    /// Forgets everything — including consent, which goes back to off — and
    /// erases the file straight away.
    func reset() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        lastSample = nil
        profile = CoreProfile(now: clock())
        storage.erase()
        isDirty = true
        flush()
    }

    // MARK: Maintenance

    /// Fades and prunes inferred entries. Run on app open.
    func maintain() {
        CoreLearner.maintain(&profile, now: clock(), config: config, namedSpots: namedSpots())
        scheduleSave()
    }

    /// Habit misses have been swept up to and including `day`.
    func markHabitSweep(_ day: Date) {
        profile.meta.lastHabitSweep = day
        scheduleSave()
    }

    /// Drops habit profiles whose habit no longer exists (or is built).
    func retainHabits(_ ids: Set<String>) {
        let before = profile.habits.count
        profile.habits.removeAll { !ids.contains($0.habitId) }
        if profile.habits.count != before { scheduleSave() }
    }

    // MARK: Storage

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self, debounce = config.saveDebounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes now if anything changed. Call when the app goes to the background.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let data = try? CoreMigrator.encoder.encode(profile) else { return }
        storage.save(data)
        isDirty = false
    }

    // MARK: Location

    private func sampleLocation(_ reason: CoreSampleReason, at now: Date) {
        guard profile.meta.consent.location, let locator, locator.isAuthorized else { return }
        if let last = lastSample, now.timeIntervalSince(last.at) < config.sampleReuseSeconds {
            // Same spot as a moment ago: an app open adds nothing; a completion
            // still links its task type.
            if case .appOpen = reason { return }
            record(.locationSample(last.coordinate, reason: reason), at: now)
            return
        }
        track { [weak self] in
            guard let fix = await locator.sample()?.rounded() else { return }
            guard let self, self.profile.meta.consent.location else { return }
            self.lastSample = (fix, now)
            self.record(.locationSample(fix, reason: reason), at: now)
        }
    }

    /// A check-in made where Evry last saw the person (within a few minutes)
    /// counts toward that habit's usual place. No new location fix is taken.
    private func attributeHabit(_ habitId: String, at now: Date) {
        guard profile.meta.consent.location, let last = lastSample,
              now.timeIntervalSince(last.at) < config.sampleReuseSeconds,
              let place = profile.places.first(where: { $0.center.distance(to: last.coordinate) <= max($0.radiusM, config.clusterRadiusM) }),
              let i = profile.habits.firstIndex(where: { $0.habitId == habitId }) else { return }
        profile.habits[i].placeCounts[place.id, default: 0] += 1
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pending[id] = Task { [weak self] in
            await work()
            self?.pending[id] = nil
        }
    }

    // MARK: Defaults

    /// Setup's frequent places, as label + coarse coordinate.
    static func setupPlaces() -> [CoreNamedSpot] {
        FrequentPlaces.load().map { p in
            CoreNamedSpot(label: p.label == PlaceRole.fallbackLabel ? p.name : p.label,
                          coordinate: CoreCoordinate(lat: p.latitude, lng: p.longitude).rounded())
        }
    }

    static func setupPlace(matching location: String) -> CoreCoordinate? {
        let text = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = FrequentPlaces.load().first(where: { $0.locationString == text || $0.name == text }) else { return nil }
        return CoreCoordinate(lat: p.latitude, lng: p.longitude).rounded()
    }
}

// MARK: - Storage

protocol CoreStorage: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
    func erase()
    /// Sets an unreadable file aside rather than losing it outright.
    func archiveUnreadable()
}

/// `Application Support/Core/core.json`, excluded from backup and protected
/// until first unlock.
final class FileCoreStorage: CoreStorage {
    private let url: URL

    init(directory: URL? = nil) {
        let fm = FileManager.default
        let base = directory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        var dir = base.appendingPathComponent("Core", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        url = dir.appendingPathComponent("core.json")
    }

    func load() -> Data? { try? Data(contentsOf: url) }

    func save(_ data: Data) {
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func erase() { try? FileManager.default.removeItem(at: url) }

    func archiveUnreadable() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}

/// For tests and previews.
final class MemoryCoreStorage: CoreStorage {
    var data: Data?
    private(set) var saves = 0
    private(set) var archived = 0

    init(data: Data? = nil) { self.data = data }

    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data; saves += 1 }
    func erase() { data = nil }
    func archiveUnreadable() { archived += 1; data = nil }
}

// MARK: - Schema migration

enum CoreMigrator {
    /// One step per schema bump, on the raw JSON: `steps[1]` turns a v1 file
    /// into v2, and so on. Empty while the schema is at version 1.
    static let steps: [Int: (inout [String: Any]) -> Void] = [:]

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func decode(_ data: Data) -> CoreProfile? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var version = (object["meta"] as? [String: Any])?["schemaVersion"] as? Int ?? 1
        // A file from a newer build can't be read safely.
        guard version <= CoreProfile.currentSchemaVersion else { return nil }
        while version < CoreProfile.currentSchemaVersion {
            steps[version]?(&object)
            version += 1
        }
        if var meta = object["meta"] as? [String: Any] {
            meta["schemaVersion"] = CoreProfile.currentSchemaVersion
            object["meta"] = meta
        }
        guard let migrated = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? decoder.decode(CoreProfile.self, from: migrated)
    }
}

// MARK: - Location sampling

protocol CoreLocating: AnyObject {
    var isAuthorized: Bool { get }
    /// Permission hasn't been asked for yet.
    var canAsk: Bool { get }
    func requestAccess()
    /// One coarse fix, or nil (no permission, no fix in time).
    func sample() async -> CoreCoordinate?
}

/// One-shot, hundred-metre fixes only — never continuous updates. A fix the
/// system already has from the last few minutes is used as-is.
final class CoreLocationSampler: NSObject, CoreLocating, CLLocationManagerDelegate {
    private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return m
    }()
    private var waiting: [CheckedContinuation<CoreCoordinate?, Never>] = []
    private var request = 0

    var isAuthorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    var canAsk: Bool { manager.authorizationStatus == .notDetermined }

    func requestAccess() { manager.requestWhenInUseAuthorization() }

    func sample() async -> CoreCoordinate? {
        guard isAuthorized else { return nil }
        if let last = manager.location, -last.timestamp.timeIntervalSinceNow < 300,
           last.horizontalAccuracy >= 0, last.horizontalAccuracy <= 500 {
            return Self.coordinate(last)
        }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            request += 1
            let id = request
            manager.requestLocation()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.request == id else { return }
                self.finish(nil)
            }
        }
    }

    private func finish(_ coordinate: CoreCoordinate?) {
        request += 1
        let resume = waiting
        waiting = []
        for c in resume { c.resume(returning: coordinate) }
    }

    nonisolated private static func coordinate(_ location: CLLocation) -> CoreCoordinate {
        CoreCoordinate(lat: location.coordinate.latitude, lng: location.coordinate.longitude).rounded()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last.map(Self.coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}
