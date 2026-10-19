//
//  CoreLearner.swift
//  Evry
//
//  The Core's update rules — pure functions over `CoreProfile`, so they can be
//  tested with a fixed clock. Recent behaviour counts more: every counter is
//  decay-weighted (half-lives in `CoreConfig`), confidence rises with evidence
//  and fades with age, and inferred entries that fade below the prune
//  threshold are dropped. Declared data is never written here.
//

import Foundation

enum CoreLearner {
    static var calendar: Calendar { .current }

    // MARK: - Decay & confidence

    /// The factor a weight keeps after the time from `last` to `now`.
    static func decay(from last: Date?, to now: Date, halfLifeDays: Double) -> Double {
        guard let last, halfLifeDays > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return 1 }
        return pow(0.5, elapsed / (halfLifeDays * 86_400))
    }

    /// 0…1, saturating: `n` pieces of evidence against a "plenty" of `k`.
    static func evidence(_ n: Double, saturation k: Double) -> Double {
        guard n > 0, k > 0 else { return 0 }
        return 1 - exp(-n / k)
    }

    /// Evidence × recency × consistency, kept in 0…1.
    static func confidence(evidence e: Double, lastSeen: Date, now: Date, halfLifeDays: Double,
                           consistency: Double = 1) -> Double {
        let value = e * decay(from: lastSeen, to: now, halfLifeDays: halfLifeDays) * consistency
        return (min(1, max(0, value)) * 1000).rounded() / 1000
    }

    // MARK: - Events

    /// Folds one event into the profile. Note text and location samples are
    /// handled by `EvryCore` (they need consent checks and async work) but
    /// samples land in `ingestSample` below.
    static func apply(_ event: CoreEvent, to p: inout CoreProfile, at now: Date,
                      config: CoreConfig = .standard, namedSpots: [CoreNamedSpot] = []) {
        switch event {
        case .taskCreated(let t):
            updateType(t.type, in: &p, now: now, config: config) { $0.created += 1 }
            updateSignals(&p, now: now, config: config) { s in
                s.created += 1
                s.sizes[t.size.rawValue] += 1
            }
            activity(&p.rhythms, at: now, config: config, kind: .planning)
        case .taskEdited:
            updateSignals(&p, now: now, config: config) { $0.edits += 1 }
            p.taskSignals.eventCount += 1
            activity(&p.rhythms, at: now, config: config, kind: .other)
        case .taskRescheduled(let t, let from, let to):
            // Only a move to a *later day* is avoidance; dropping a task into
            // a time slot today is planning.
            let later = from.map { calendar.startOfDay(for: to) > calendar.startOfDay(for: $0) } ?? false
            updateType(t.type, in: &p, now: now, config: config) { if later { $0.pushed += 1 } }
            activity(&p.rhythms, at: now, config: config, kind: .planning)
        case .taskSnoozed(let t):
            updateType(t.type, in: &p, now: now, config: config) { $0.snoozed += 1 }
            activity(&p.rhythms, at: now, config: config, kind: .other)
        case .taskCompleted(let t):
            let hours = max(0, now.timeIntervalSince(t.createdAt)) / 3600
            updateType(t.type, in: &p, now: now, config: config) {
                $0.completed += 1
                $0.completeHours += hours
            }
            activity(&p.rhythms, at: now, config: config, kind: .completion)
        case .taskReopened(let t):
            updateType(t.type, in: &p, now: now, config: config) { s in
                guard s.completed > 0 else { return }
                let average = s.completeHours / s.completed
                s.completed = max(0, s.completed - 1)
                s.completeHours = max(0, s.completeHours - average)
            }
        case .taskAbandoned(let t):
            updateType(t.type, in: &p, now: now, config: config) { $0.abandoned += 1 }
        case .taskRestored(let t):
            updateType(t.type, in: &p, now: now, config: config) { $0.abandoned = max(0, $0.abandoned - 1) }

        case .habitCheckIn(let s):
            updateHabit(s, in: &p, now: now, config: config) { h in
                let hour = Double(calendar.component(.hour, from: now)) + Double(calendar.component(.minute, from: now)) / 60
                let angle = hour / 24 * 2 * .pi
                h.hourSin += sin(angle)
                h.hourCos += cos(angle)
                h.hourWeight += 1
                h.checkInsByDow[dow(now)] += 1
                h.observations += 1
            }
            activity(&p.rhythms, at: now, config: config, kind: .completion)
        case .habitMissed(let s, let day):
            updateHabit(s, in: &p, now: now, config: config) { h in
                h.missesByDow[dow(day)] += 1
                h.observations += 1
            }
        case .habitUpdated(let s):
            updateHabit(s, in: &p, now: now, config: config, isEvidence: false) { _ in }
        case .habitRemoved(let id):
            p.habits.removeAll { $0.habitId == id }

        case .noteSaved:
            break   // extraction runs in EvryCore, with consent
        case .noteDeleted(let id):
            p.facts.removeAll { $0.sourceNoteId == id && !$0.userConfirmed }

        case .nudgeShown(let type):
            // One "shown" per type per day, however often the view redraws.
            if let last = p.feedback.lastShown[type], calendar.isDate(last, inSameDayAs: now) { break }
            p.feedback.lastShown[type] = now
            p.feedback.nudgesShown += 1
            updateNudge(type, in: &p, now: now, config: config) { $0.shown += 1 }
        case .nudgeAccepted(let type):
            p.feedback.nudgesAccepted += 1
            updateNudge(type, in: &p, now: now, config: config) { $0.accepted += 1 }
        case .nudgeDismissed(let type):
            p.feedback.nudgesDismissed += 1
            updateNudge(type, in: &p, now: now, config: config) { $0.dismissed += 1 }
        case .mascotOpened:
            p.feedback.mascotEngagement = min(1, p.feedback.mascotEngagement * 0.8 + 0.2)
        case .appOpened:
            // Engagement fades a little with every open that doesn't use the chat.
            p.feedback.mascotEngagement = (p.feedback.mascotEngagement * 0.97 * 1000).rounded() / 1000
            activity(&p.rhythms, at: now, config: config, kind: .other)

        case .locationSample(let coordinate, let reason):
            _ = ingestSample(coordinate, reason: reason, into: &p, at: now, config: config, namedSpots: namedSpots)
        }
        p.meta.updatedAt = now
    }

    private static func dow(_ date: Date) -> Int { calendar.component(.weekday, from: date) - 1 }

    // MARK: - Rhythms

    enum ActivityKind { case planning, completion, other }

    static func activity(_ r: inout CoreRhythms, at now: Date, config: CoreConfig, kind: ActivityKind) {
        let f = decay(from: r.lastUpdate, to: now, halfLifeDays: config.rhythmHalfLifeDays)
        if f < 1 {
            r.hourWeights = r.hourWeights.map { $0 * f }
            r.dayWeights = r.dayWeights.map { $0 * f }
            r.planningHourWeights = r.planningHourWeights.map { $0 * f }
            r.completionHourWeights = r.completionHourWeights.map { $0 * f }
            r.planningDayWeights = r.planningDayWeights.map { $0 * f }
        }
        let hour = calendar.component(.hour, from: now)
        let day = dow(now)
        r.hourWeights[hour] += 1
        r.dayWeights[day] += 1
        switch kind {
        case .planning:
            r.planningHourWeights[hour] += 1
            r.planningDayWeights[day] += 1
        case .completion:
            r.completionHourWeights[hour] += 1
        case .other:
            break
        }
        let today = calendar.startOfDay(for: now)
        if r.lastActiveDay != today {
            r.activeDayCount += 1
            r.lastActiveDay = today
        }
        r.lastUpdate = now
        r.confidence = rhythmConfidence(r, now: now, config: config)
    }

    static func rhythmConfidence(_ r: CoreRhythms, now: Date, config: CoreConfig) -> Double {
        guard let last = r.lastUpdate else { return 0 }
        let weight = r.hourWeights.reduce(0, +)
        let e = evidence(weight, saturation: 40) * evidence(Double(r.activeDayCount), saturation: 5)
        return confidence(evidence: e, lastSeen: last, now: now, halfLifeDays: config.rhythmHalfLifeDays)
    }

    /// A one-phrase read of the week, once there's enough to say.
    static func weeklyShape(_ r: CoreRhythms) -> String? {
        let days = r.dayWeights
        let total = days.reduce(0, +)
        guard total >= 10 else { return nil }
        let planning = r.planningDayWeights.reduce(0, +)
        if planning >= 5, r.planningDayWeights[0] / planning >= 0.35 { return "Sunday planner" }
        let weekdays = days[1...5].reduce(0, +)
        let weekend = days[0] + days[6]
        if weekend / total >= 0.4 { return "weekend-heavy" }
        guard weekdays > 0 else { return nil }
        if (days[1] + days[2] + days[3]) / weekdays >= 0.7 { return "front-loaded" }
        if (days[4] + days[5]) / weekdays >= 0.55 { return "back-loaded" }
        return "steady"
    }

    // MARK: - Tasks

    static func updateType(_ type: String, in p: inout CoreProfile, now: Date, config: CoreConfig,
                           _ change: (inout CoreTypeStats) -> Void) {
        var s = p.taskStats[type] ?? CoreTypeStats(lastUpdate: now)
        let f = decay(from: s.lastUpdate, to: now, halfLifeDays: config.taskHalfLifeDays)
        if f < 1 {
            s.created *= f; s.completed *= f; s.pushed *= f
            s.snoozed *= f; s.abandoned *= f; s.completeHours *= f
        }
        s.lastUpdate = now
        change(&s)
        p.taskStats[type] = s
        p.taskSignals.eventCount += 1
    }

    static func updateSignals(_ p: inout CoreProfile, now: Date, config: CoreConfig,
                              _ change: (inout CoreTaskSignals) -> Void) {
        var s = p.taskSignals
        let f = decay(from: s.lastUpdate, to: now, halfLifeDays: config.taskHalfLifeDays)
        if f < 1 {
            s.created *= f; s.edits *= f
            s.sizes = s.sizes.map { $0 * f }
        }
        s.lastUpdate = now
        change(&s)
        p.taskSignals = s
    }

    static func taskBehavior(_ p: CoreProfile) -> CoreTaskBehavior {
        func r2(_ v: Double) -> Double { (min(1, max(0, v)) * 100).rounded() / 100 }
        var b = CoreTaskBehavior()
        for (type, s) in p.taskStats {
            let attempts = max(s.created, s.completed + s.abandoned)
            if attempts >= 0.5 {
                b.completionRateByType[type] = r2(s.completed / attempts)
                b.rescheduleRateByType[type] = r2((s.pushed + s.snoozed) / max(s.created, 1))
                b.abandonRateByType[type] = r2(s.abandoned / max(s.created, s.abandoned, 1))
            }
            if s.completed >= 0.5 {
                b.avgCreateToCompleteHours[type] = (s.completeHours / s.completed * 10).rounded() / 10
            }
            // Repeatedly put off: three or more pushes, on at least half its tasks.
            if s.pushed + s.snoozed >= 3, (s.pushed + s.snoozed) / max(s.created, 1) >= 0.5 {
                b.avoidedTaskTypes.append(type)
            }
        }
        b.avoidedTaskTypes.sort()
        let sig = p.taskSignals
        b.editFrequency = (sig.edits / max(sig.created, 1) * 100).rounded() / 100
        let sizes = sig.sizes
        let total = sizes.reduce(0, +)
        if total >= 3, let top = sizes.indices.max(by: { sizes[$0] < sizes[$1] }), sizes[top] / total >= 0.6 {
            b.typicalTaskSize = [.small, .medium, .large][top]
        }
        return b
    }

    // MARK: - Feedback

    static func updateNudge(_ type: String, in p: inout CoreProfile, now: Date, config: CoreConfig,
                            _ change: (inout CoreFeedback.Counts) -> Void) {
        var c = p.feedback.byType[type] ?? CoreFeedback.Counts(lastUpdate: now)
        let f = decay(from: c.lastUpdate, to: now, halfLifeDays: config.taskHalfLifeDays)
        if f < 1 { c.shown *= f; c.accepted *= f; c.dismissed *= f }
        c.lastUpdate = now
        change(&c)
        p.feedback.byType[type] = c
    }

    // MARK: - Habits

    static func updateHabit(_ s: CoreHabitSnapshot, in p: inout CoreProfile, now: Date, config: CoreConfig,
                            isEvidence: Bool = true, _ change: (inout CoreHabit) -> Void) {
        let index = p.habits.firstIndex { $0.habitId == s.id }
        var h = index.map { p.habits[$0] } ?? CoreHabit(habitId: s.id, title: s.title, cadence: s.cadence, lastEvent: now)
        if isEvidence {
            let f = decay(from: h.lastEvent, to: now, halfLifeDays: config.habitHalfLifeDays)
            if f < 1 {
                h.hourSin *= f; h.hourCos *= f; h.hourWeight *= f
                h.checkInsByDow = h.checkInsByDow.map { $0 * f }
                h.missesByDow = h.missesByDow.map { $0 * f }
                h.placeCounts = h.placeCounts.mapValues { $0 * f }
            }
            h.lastEvent = now
            h.patternsVisible = true
        }
        h.title = s.title
        h.cadence = s.cadence
        h.currentStreak = s.currentStreak
        h.longestStreak = s.longestStreak
        h.completionRate30d = (s.rate30 * 100).rounded() / 100
        change(&h)
        h.confidence = habitConfidence(h, now: now, config: config)
        if let index { p.habits[index] = h } else { p.habits.append(h) }
    }

    /// Plenty of recent check-ins at a consistent time → high. Scattered times
    /// (a contradiction of any "usual time") pull it down.
    static func habitConfidence(_ h: CoreHabit, now: Date, config: CoreConfig) -> Double {
        let seen = h.checkInsByDow.reduce(0, +) + h.missesByDow.reduce(0, +)
        let concentration = h.hourWeight > 0
            ? sqrt(h.hourSin * h.hourSin + h.hourCos * h.hourCos) / h.hourWeight : 0.5
        return confidence(evidence: evidence(seen, saturation: 7), lastSeen: h.lastEvent, now: now,
                          halfLifeDays: config.habitHalfLifeDays, consistency: 0.5 + 0.5 * concentration)
    }

    static func slipPattern(_ h: CoreHabit) -> String? {
        let miss = h.missesByDow, done = h.checkInsByDow
        let endMiss = miss[0] + miss[6], endDone = done[0] + done[6]
        let weekMiss = miss[1...5].reduce(0, +), weekDone = done[1...5].reduce(0, +)
        if endMiss + endDone >= 2, weekMiss + weekDone >= 2 {
            let endRate = endMiss / (endMiss + endDone)
            let weekRate = weekMiss / (weekMiss + weekDone)
            if endRate - weekRate >= 0.3 { return "misses on weekends" }
            if weekRate - endRate >= 0.3 { return "misses on weekdays" }
        }
        let names = calendar.weekdaySymbols
        let worst = (0..<7)
            .filter { miss[$0] >= 2 && miss[$0] / (miss[$0] + done[$0]) >= 0.6 }
            .max { miss[$0] < miss[$1] }
        return worst.map { "often misses \(names[$0])s" }
    }

    // MARK: - Places

    /// Clusters one coarse sample into a place (or a candidate, promoted once it
    /// has `placeMinVisits` visits). Returns the place id it landed in, if any.
    /// Does nothing without location consent.
    @discardableResult
    static func ingestSample(_ raw: CoreCoordinate, reason: CoreSampleReason, into p: inout CoreProfile,
                             at now: Date, config: CoreConfig, namedSpots: [CoreNamedSpot] = []) -> String? {
        guard p.meta.consent.location else { return nil }
        let c = raw.rounded()
        let isVisit: Bool
        let linkType: String?
        switch reason {
        case .appOpen, .habitCheckIn: isVisit = true; linkType = nil
        case .taskCompleted(let type): isVisit = true; linkType = type
        case .taskLocation(let type): isVisit = false; linkType = type
        }
        let bin = "\(dow(now))-\(calendar.component(.hour, from: now))"

        // 1. A place it already knows.
        if let i = p.places.indices
            .filter({ p.places[$0].center.distance(to: c) <= max(p.places[$0].radiusM, config.clusterRadiusM) })
            .min(by: { p.places[$0].center.distance(to: c) < p.places[$1].center.distance(to: c) }) {
            var place = p.places[i]
            let f = decay(from: place.lastVisit, to: now, halfLifeDays: config.placeHalfLifeDays)
            if isVisit {
                let repeatVisit = now.timeIntervalSince(place.lastVisit) < config.visitDedupMinutes * 60
                if !repeatVisit {
                    if f < 1 {
                        place.visitWeight *= f
                        place.visitBins = place.visitBins.mapValues { $0 * f }
                        place.linkedTaskTypes = place.linkedTaskTypes.mapValues { $0 * f }
                    }
                    place.visits += 1
                    place.visitWeight += 1
                    place.visitBins[bin, default: 0] += 1
                    place.lastVisit = now
                }
            }
            if let linkType { place.linkedTaskTypes[linkType, default: 0] += 1 }
            refresh(&place, declared: p.declared, now: now, config: config, namedSpots: namedSpots)
            p.places[i] = place
            return place.id
        }

        // 2. A candidate cluster.
        var cand: CorePlaceCandidate
        if let j = p.placeCandidates.indices
            .filter({ p.placeCandidates[$0].center.distance(to: c) <= config.clusterRadiusM })
            .min(by: { p.placeCandidates[$0].center.distance(to: c) < p.placeCandidates[$1].center.distance(to: c) }) {
            cand = p.placeCandidates.remove(at: j)
            if isVisit, cand.lastVisit.map({ now.timeIntervalSince($0) < config.visitDedupMinutes * 60 }) != true {
                // Running mean of the centre, re-rounded so it stays coarse.
                let n = Double(cand.visits)
                cand.center = CoreCoordinate(lat: (cand.center.lat * n + c.lat) / (n + 1),
                                             lng: (cand.center.lng * n + c.lng) / (n + 1)).rounded()
                cand.visits += 1
                cand.lastVisit = now
                cand.visitBins[bin, default: 0] += 1
            }
        } else {
            cand = CorePlaceCandidate(id: UUID().uuidString, center: c, visits: isVisit ? 1 : 0, firstSeen: now,
                                      lastVisit: isVisit ? now : nil, visitBins: isVisit ? [bin: 1] : [:])
        }
        if let linkType { cand.linkedTaskTypes[linkType, default: 0] += 1 }

        guard cand.visits >= config.placeMinVisits else {
            p.placeCandidates.append(cand)
            if p.placeCandidates.count > config.maxCandidates {
                p.placeCandidates.sort { ($0.lastVisit ?? $0.firstSeen) > ($1.lastVisit ?? $1.firstSeen) }
                p.placeCandidates.removeLast(p.placeCandidates.count - config.maxCandidates)
            }
            return nil
        }

        // 3. Promote.
        var place = CorePlace(id: cand.id, label: nextPlaceLabel(p.places), labelSource: .inferred,
                              center: cand.center, radiusM: config.clusterRadiusM, category: nil,
                              visits: cand.visits, visitWeight: Double(cand.visits), firstVisit: cand.firstSeen,
                              lastVisit: cand.lastVisit ?? now, visitBins: cand.visitBins,
                              linkedTaskTypes: cand.linkedTaskTypes, confidence: 0)
        refresh(&place, declared: p.declared, now: now, config: config, namedSpots: namedSpots)
        p.places.append(place)
        if p.places.count > config.maxPlaces {
            // Keep the strongest; a place the person named is never the one dropped.
            p.places.sort { ($0.labelSource == .user ? 2 : $0.confidence) > ($1.labelSource == .user ? 2 : $1.confidence) }
            p.places.removeLast(p.places.count - config.maxPlaces)
        }
        return place.id
    }

    static func nextPlaceLabel(_ places: [CorePlace]) -> String {
        var n = places.count + 1
        let used = Set(places.map(\.label))
        while used.contains("Place \(n)") { n += 1 }
        return "Place \(n)"
    }

    /// Recomputes a place's confidence, label suggestion and category guess.
    /// Anything the person declared is left exactly as they set it.
    static func refresh(_ place: inout CorePlace, declared: CoreDeclared, now: Date, config: CoreConfig,
                        namedSpots: [CoreNamedSpot]) {
        place.confidence = confidence(evidence: evidence(place.visitWeight, saturation: 4), lastSeen: place.lastVisit,
                                      now: now, halfLifeDays: config.placeHalfLifeDays)
        if let name = declared.placeLabels[place.id] {
            place.label = name
            place.labelSource = .user
        } else if place.labelSource == .inferred,
                  let spot = namedSpots.first(where: { $0.coordinate.rounded().distance(to: place.center) <= config.clusterRadiusM }) {
            place.label = spot.label
        }
        if let set = declared.placeCategories[place.id] {
            place.category = set
        } else {
            place.category = guessCategory(place, config: config)
        }
    }

    /// A category only when the evidence is strong: nights → home, weekday
    /// office hours → work, mostly fitness tasks → gym, mostly errands → store.
    static func guessCategory(_ place: CorePlace, config: CoreConfig) -> CorePlace.Category? {
        var night = 0.0, office = 0.0
        for (key, weight) in place.visitBins {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            let (d, h) = (parts[0], parts[1])
            if h >= 21 || h < 7 { night += weight }
            if (1...5).contains(d) && (9..<17).contains(h) { office += weight }
        }
        let total = place.visitBins.values.reduce(0, +)
        let linked = place.linkedTaskTypes.values.reduce(0, +)
        var best: (CorePlace.Category, Double)?
        func consider(_ c: CorePlace.Category, _ share: Double) {
            if share > (best?.1 ?? 0) { best = (c, share) }
        }
        if total > 0 {
            consider(.home, night / total)
            consider(.work, office / total)
        }
        if linked >= 3 {
            consider(.gym, (place.linkedTaskTypes["fitness"] ?? 0) / linked)
            consider(.store, (place.linkedTaskTypes["errand"] ?? 0) / linked)
        }
        guard let best, best.1 >= 0.6, place.confidence >= config.categoryConfidence else { return nil }
        return best.0
    }

    /// Bins of "dow-hour" weights → merged hour runs per weekday, strongest first.
    static func windows(from bins: [String: Double]) -> [CorePlace.Window] {
        let top = bins.values.max() ?? 0
        guard top > 0 else { return [] }
        let threshold = max(1.0, top * 0.3)
        var hoursByDay: [Int: [Int]] = [:]
        var weightByWindow: [CorePlace.Window: Double] = [:]
        for (key, w) in bins where w >= threshold {
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            hoursByDay[parts[0], default: []].append(parts[1])
        }
        for (d, hours) in hoursByDay {
            var start: Int?
            var prev = -2
            for h in hours.sorted() + [99] {
                if h != prev + 1 {
                    if let s = start {
                        let window = CorePlace.Window(dow: d, hourStart: s, hourEnd: prev + 1)
                        weightByWindow[window] = (s...prev).reduce(0) { $0 + (bins["\(d)-\($1)"] ?? 0) }
                    }
                    start = h
                }
                prev = h
            }
        }
        return weightByWindow.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.dow < $1.key.dow }
            .prefix(6).map(\.key)
    }

    // MARK: - Maintenance

    /// Fades and prunes. Idempotent for a given `now`: confidences are
    /// recomputed from stored evidence, never compounded.
    static func maintain(_ p: inout CoreProfile, now: Date, config: CoreConfig, namedSpots: [CoreNamedSpot] = []) {
        p.rhythms.confidence = rhythmConfidence(p.rhythms, now: now, config: config)

        for i in p.places.indices {
            refresh(&p.places[i], declared: p.declared, now: now, config: config, namedSpots: namedSpots)
        }
        // A place the person named is theirs — it fades, but is never pruned.
        p.places.removeAll { $0.labelSource == .inferred && $0.confidence < config.pruneThreshold }
        let candidateCutoff = now.addingTimeInterval(-config.placeHalfLifeDays * 2 * 86_400)
        p.placeCandidates.removeAll { ($0.lastVisit ?? $0.firstSeen) < candidateCutoff }
        // Declared labels/categories for places that no longer exist go too.
        let ids = Set(p.places.map(\.id))
        p.declared.placeLabels = p.declared.placeLabels.filter { ids.contains($0.key) }
        p.declared.placeCategories = p.declared.placeCategories.filter { ids.contains($0.key) }

        for i in p.facts.indices {
            p.facts[i].confidence = p.facts[i].userConfirmed ? 1
                : confidence(evidence: p.facts[i].evidence, lastSeen: p.facts[i].lastSeen, now: now,
                             halfLifeDays: config.factHalfLifeDays)
        }
        p.facts.removeAll { !$0.userConfirmed && $0.confidence < config.pruneThreshold }

        for i in p.habits.indices {
            p.habits[i].confidence = habitConfidence(p.habits[i], now: now, config: config)
            p.habits[i].patternsVisible = p.habits[i].confidence >= config.pruneThreshold
                || p.habits[i].observations == 0
        }

        // Task types with almost nothing left after decay.
        p.taskStats = p.taskStats.filter { _, s in
            let f = decay(from: s.lastUpdate, to: now, halfLifeDays: config.taskHalfLifeDays)
            return (s.created + s.completed + s.pushed + s.snoozed + s.abandoned) * f >= 0.25
        }
    }

    // MARK: - Progress

    static func progress(_ p: CoreProfile, config: CoreConfig) -> CoreProgress {
        func frac(_ n: Int, _ target: Int) -> Double { target > 0 ? min(1, Double(n) / Double(target)) : 1 }
        let habitObs = p.habits.reduce(0) { $0 + $1.observations }
        let modules: [CoreProgress.Module] = [
            .init(kind: .tasks, fraction: frac(p.taskSignals.eventCount, config.targetTaskEvents), isActive: true,
                  hint: "Learns from adding, moving and finishing tasks"),
            .init(kind: .rhythms, fraction: frac(p.rhythms.activeDayCount, config.targetActiveDays), isActive: true,
                  hint: "\(min(p.rhythms.activeDayCount, config.targetActiveDays)) of \(config.targetActiveDays) days"),
            .init(kind: .habits, fraction: frac(habitObs, config.targetHabitObservations), isActive: !p.habits.isEmpty,
                  hint: p.habits.isEmpty ? "Add a habit to fill this in" : "Learns from check-ins"),
            .init(kind: .places, fraction: frac(p.places.count, config.targetPlaces), isActive: p.meta.consent.location,
                  hint: p.meta.consent.location ? "\(p.places.count) of \(config.targetPlaces) places" : "Off"),
            .init(kind: .facts, fraction: frac(p.facts.count, config.targetFacts), isActive: p.meta.consent.noteExtraction,
                  hint: p.meta.consent.noteExtraction ? "\(p.facts.count) of \(config.targetFacts) details" : "Off"),
        ]
        let active = modules.filter(\.isActive)
        let weight = active.reduce(0) { $0 + $1.kind.weight }
        let overall = weight > 0 ? active.reduce(0) { $0 + $1.kind.weight * $1.fraction } / weight : 0
        return CoreProgress(modules: modules, overall: (overall * 1000).rounded() / 1000)
    }
}
