//
//  CoreReadout.swift
//  Evry
//
//  `EvryCore.getView()` — the Core in plain words, grouped by section, for the
//  Core screen. Every row that can be removed carries the `CoreEntryRef` that
//  `deleteEntry` takes. Coordinates are never shown.
//

import Foundation

struct CoreReadout: Equatable {
    struct Item: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var ref: CoreEntryRef?
        var canRename = false
        var canConfirm = false
    }

    struct Section: Identifiable, Equatable {
        enum Kind: String { case rhythms, habits, tasks, places, facts, feedback }
        var kind: Kind
        var title: String
        var items: [Item]
        /// Shown when `items` is empty.
        var empty: String
        var id: Kind { kind }
    }

    var sections: [Section]

    func section(_ kind: Section.Kind) -> Section? { sections.first { $0.kind == kind } }

    init(_ p: CoreProfile, now: Date = Date()) {
        let behavior = p.taskBehavior
        let d = p.declared
        let dayNames = Calendar.current.shortWeekdaySymbols
        func pct(_ v: Double?) -> String? { v.map { "\(Int(($0 * 100).rounded()))%" } }
        func hours(_ list: [Int]?) -> String? { list.map { $0.map { Self.hourLabel($0) }.joined(separator: ", ") } }

        // Rhythms
        var rhythm: [Item] = []
        let r = p.rhythms
        if let peak = hours(CoreContextBuilder.peakHours(r.hourWeights, d)) {
            rhythm.append(Item(id: "peak", title: "Most active", detail: peak, ref: .rhythms))
        }
        if let days = CoreContextBuilder.peakDays(r.dayWeights)?.compactMap({ name in
            ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].firstIndex(of: name).map { dayNames[$0] }
        }) {
            rhythm.append(Item(id: "days", title: "Busiest days", detail: days.joined(separator: ", "), ref: .rhythms))
        }
        if let plan = hours(CoreContextBuilder.peakHours(r.planningHourWeights, d)) {
            rhythm.append(Item(id: "plan", title: "Usually plans", detail: plan, ref: .rhythms))
        }
        if let done = hours(CoreContextBuilder.peakHours(r.completionHourWeights, d)) {
            rhythm.append(Item(id: "done", title: "Usually finishes", detail: done, ref: .rhythms))
        }
        if let shape = r.weeklyShape {
            rhythm.append(Item(id: "shape", title: "Week shape", detail: shape.capitalizedFirstLetter, ref: .rhythms))
        }

        // Habits
        let placeLabels = Dictionary(p.places.map { ($0.id, d.placeLabels[$0.id] ?? $0.label) }, uniquingKeysWith: { a, _ in a })
        let habits = p.habits.sorted { $0.title < $1.title }.map { h -> Item in
            var bits = ["\(h.currentStreak)-day streak", "\(pct(h.completionRate30d) ?? "0%") in 30 days"]
            if let t = h.usualTime { bits.append("usually around \(Self.hourLabel(t.hour))") }
            if let slip = h.slipPattern { bits.append(slip) }
            if let place = h.usualPlaceId.flatMap({ placeLabels[$0] }) { bits.append("at \(place)") }
            return Item(id: h.habitId, title: h.title, detail: bits.joined(separator: " · "), ref: .habit(h.habitId))
        }

        // Task patterns
        var tasks = p.taskStats.keys.sorted { a, b in
            let sa = p.taskStats[a]!, sb = p.taskStats[b]!
            return sa.created + sa.completed > sb.created + sb.completed
        }.map { type -> Item in
            var bits: [String] = []
            if let v = pct(behavior.completionRateByType[type]) { bits.append("finishes \(v)") }
            if let v = behavior.rescheduleRateByType[type], v > 0 { bits.append("moves \(pct(v)!)") }
            if let h = behavior.avgCreateToCompleteHours[type] { bits.append("~\(Self.durationLabel(h)) to finish") }
            if behavior.avoidedTaskTypes.contains(type) { bits.append("often put off") }
            return Item(id: "type-\(type)", title: type.capitalizedFirstLetter,
                        detail: bits.isEmpty ? "Still learning" : bits.joined(separator: " · "), ref: .taskType(type))
        }
        if p.taskSignals.created >= 3 {
            tasks.append(Item(id: "size", title: "Typical task", detail: behavior.typicalTaskSize.rawValue.capitalizedFirstLetter))
            tasks.append(Item(id: "edits", title: "Edits per task", detail: String(format: "%.1f", behavior.editFrequency)))
        }

        // Places
        let places = p.places.sorted { $0.confidence > $1.confidence }.map { place -> Item in
            let category = d.placeCategories[place.id] ?? place.category
            var bits: [String] = []
            if let category { bits.append(category.label) }
            bits.append("\(place.visits) visit\(place.visits == 1 ? "" : "s")")
            if let w = place.typicalWindows.first {
                bits.append("\(dayNames[w.dow]) \(Self.hourLabel(w.hourStart))–\(Self.hourLabel(w.hourEnd % 24))")
            }
            if let top = place.linkedTaskTypes.max(by: { $0.value < $1.value }) { bits.append("\(top.key) tasks") }
            return Item(id: place.id, title: d.placeLabels[place.id] ?? place.label, detail: bits.joined(separator: " · "),
                        ref: .place(place.id), canRename: true)
        }

        // Facts
        let facts = p.facts.sorted { ($0.userConfirmed ? 2 : $0.confidence) > ($1.userConfirmed ? 2 : $1.confidence) }.map { f in
            Item(id: f.id, title: f.summary,
                 detail: "\(f.kind.rawValue.capitalizedFirstLetter) · \(f.userConfirmed ? "confirmed" : "\(pct(f.confidence)!) sure")",
                 ref: .fact(f.id), canConfirm: !f.userConfirmed)
        }

        // Feedback
        var feedback: [Item] = []
        let fb = p.feedback
        if fb.nudgesShown > 0 {
            feedback.append(Item(id: "nudges", title: "Suggestions taken",
                                 detail: "\(min(fb.nudgesAccepted, fb.nudgesShown)) of \(fb.nudgesShown)", ref: .feedback))
        }
        if fb.mascotEngagement > 0 {
            let level = fb.mascotEngagement >= 0.5 ? "Often" : fb.mascotEngagement >= 0.2 ? "Sometimes" : "Rarely"
            feedback.append(Item(id: "chat", title: "Chats with Evry", detail: level, ref: .feedback))
        }

        sections = [
            Section(kind: .rhythms, title: "Rhythms", items: rhythm, empty: "Your daily rhythm shows up after a few days."),
            Section(kind: .habits, title: "Habits", items: habits, empty: "Check in on a habit to start this."),
            Section(kind: .tasks, title: "Task patterns", items: tasks, empty: "Add and finish a few tasks to start this."),
            Section(kind: .places, title: "Places", items: places,
                    empty: p.meta.consent.location ? "Places appear after a few visits." : "Turn on places to learn where you get things done."),
            Section(kind: .facts, title: "From your notes", items: facts,
                    empty: p.meta.consent.noteExtraction ? "Details appear as you write notes." : "Turn on note details to fill this in."),
            Section(kind: .feedback, title: "Suggestions", items: feedback, empty: "Nothing yet."),
        ]
    }

    static func hourLabel(_ hour: Int) -> String {
        let h = (hour % 24 + 24) % 24
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(h < 12 ? "AM" : "PM")"
    }

    static func durationLabel(_ hours: Double) -> String {
        if hours < 1 { return "\(max(1, Int((hours * 60).rounded()))) min" }
        if hours < 48 { return "\(Int(hours.rounded())) h" }
        return "\(Int((hours / 24).rounded())) days"
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
