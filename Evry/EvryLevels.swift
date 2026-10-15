//
//  EvryLevels.swift
//  Evry
//
//  The account level system. People earn XP when they complete a day's goal —
//  every task due today done, or every habit due today checked in — plus the
//  odd bonus for finishing a task or writing a new note. XP raises their
//  level. Each band of levels has a title and a profile crest that starts
//  plain and grows grander (sky → shield → laurels → crown).
//
//  Earned XP isn't applied straight away: it's queued ("xp_pending") and
//  builds up, then flies into the profile photo as crystals (5 XP each) the
//  next time the Profile page opens — see `XPStream`.
//
//  Stored in UserDefaults: the running total ("xp_total"), the queue, a
//  per-day, per-goal ledger so a goal only ever pays out once a day, and
//  per-day bonus tallies so bonuses can't be farmed.
//

import SwiftUI
import SwiftData

// MARK: - XP and levels

enum EvryXP {
    static let totalKey = "xp_total"
    static let pendingKey = "xp_pending"
    /// XP for completing one daily goal (tasks or habits).
    static let perGoal = 50
    /// XP each flying crystal carries.
    static let perCrystal = 5

    enum Goal: String { case tasks, habits }

    /// Where XP is kept. Under tests, a throwaway suite, so tests that
    /// complete tasks never touch the real level.
    static var defaults: UserDefaults = EvryCore.isTestMode
        ? (UserDefaults(suiteName: "EvryXP.tests") ?? .standard) : .standard

    static var total: Int { defaults.integer(forKey: totalKey) }

    /// Earned but not yet applied — waiting for the next Profile visit.
    static var pending: Int { defaults.integer(forKey: pendingKey) }

    /// Applies XP to the total now (the crystals, as each one lands).
    static func add(_ amount: Int) {
        defaults.set(max(0, total + amount), forKey: totalKey)
    }

    /// Queues earned XP for the next Profile visit.
    static func queue(_ amount: Int) {
        guard amount > 0 else { return }
        defaults.set(pending + amount, forKey: pendingKey)
    }

    /// Takes everything queued, emptying the queue.
    static func takePending() -> Int {
        let amount = pending
        defaults.set(0, forKey: pendingKey)
        return amount
    }

    static func reset() {
        defaults.set(0, forKey: totalKey)
        defaults.set(0, forKey: pendingKey)
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("xp_awarded_") || key.hasPrefix("xp_bonus_") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Queues a goal's XP for `date`, once. Returns true if it was earned now.
    @discardableResult
    static func award(_ goal: Goal, on date: Date = Date()) -> Bool {
        let key = "xp_awarded_\(goal.rawValue)_\(dayKey(date))"
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        queue(perGoal)
        return true
    }

    // MARK: Bonuses

    /// The occasional extra for everyday actions.
    enum Bonus: String {
        case taskCompleted, noteCreated

        /// How often it pays out.
        var chance: Double { self == .taskCompleted ? 0.35 : 0.5 }
        /// The amounts it can pay (always whole crystals).
        var amounts: [Int] { self == .taskCompleted ? [5, 5, 10] : [5, 10, 15] }
        /// Most it can pay in one day, so toggling a task can't farm XP.
        var dailyCap: Int { self == .taskCompleted ? 50 : 30 }
    }

    /// Maybe queues a bonus. `roll` and `pick` (0..<1) are the dice; tests
    /// pass fixed values. Returns the XP queued (0 if none).
    @discardableResult
    static func rollBonus(_ bonus: Bonus, on date: Date = Date(),
                          roll: Double = .random(in: 0..<1), pick: Double = .random(in: 0..<1)) -> Int {
        guard roll < bonus.chance else { return 0 }
        let key = "xp_bonus_\(bonus.rawValue)_\(dayKey(date))"
        let paidToday = defaults.integer(forKey: key)
        let amount = bonus.amounts[min(bonus.amounts.count - 1, Int(pick * Double(bonus.amounts.count)))]
        let paid = min(amount, bonus.dailyCap - paidToday)
        guard paid > 0 else { return 0 }
        defaults.set(paidToday + paid, forKey: key)
        queue(paid)
        return paid
    }

    /// The crystals a queued amount flies in as: 5 XP each, any remainder on
    /// the last one.
    static func crystals(for amount: Int) -> [Int] {
        guard amount > 0 else { return [] }
        var out = Array(repeating: perCrystal, count: amount / perCrystal)
        if amount % perCrystal > 0 { out.append(amount % perCrystal) }
        return out
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// XP needed to go from `level` to the next — each level asks a little more.
    static func requirement(forLevel level: Int) -> Int { 100 + (level - 1) * 50 }

    struct Progress: Equatable {
        let level: Int
        /// XP earned inside the current level.
        let into: Int
        /// XP the current level needs in total.
        let needed: Int
        var fraction: Double { needed > 0 ? Double(into) / Double(needed) : 0 }
    }

    static func progress(for xp: Int) -> Progress {
        var level = 1, remaining = max(0, xp)
        while remaining >= requirement(forLevel: level) {
            remaining -= requirement(forLevel: level)
            level += 1
        }
        return Progress(level: level, into: remaining, needed: requirement(forLevel: level))
    }
}

// MARK: - Crest tiers

/// Each band of levels: its title and how its crest is dressed.
enum CrestTier: Int, CaseIterable, Comparable {
    case plain, sky, shield, laurel, starred, radiant

    static func < (a: CrestTier, b: CrestTier) -> Bool { a.rawValue < b.rawValue }

    /// The first level of each tier.
    var startLevel: Int {
        switch self {
        case .plain: 1
        case .sky: 3
        case .shield: 5
        case .laurel: 8
        case .starred: 12
        case .radiant: 17
        }
    }

    static func forLevel(_ level: Int) -> CrestTier {
        allCases.last { level >= $0.startLevel } ?? .plain
    }

    /// The title shown under the person's name.
    var title: String {
        switch self {
        case .plain: "Getting started"
        case .sky: "Finding your rhythm"
        case .shield: "Steady and sure"
        case .laurel: "Calm keeper"
        case .starred: "Clear mind"
        case .radiant: "Evry legend"
        }
    }
}

// MARK: - Crest view

/// The profile crest for a level. It starts as a plain ring and, tier by tier,
/// becomes a sky disc, a shield, a laurelled shield, a starred navy shield and
/// finally a crowned, radiant one. Only white, sky and navy — grandeur comes
/// from form, not new colours.
struct EvryCrest: View {
    let level: Int
    var size: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    private var tier: CrestTier { .forLevel(level) }

    var body: some View {
        ZStack {
            if tier == .radiant {
                SunburstShape(rays: 14)
                    .fill(Color.evrySky.opacity(0.75))
                    .frame(width: size * 1.55, height: size * 1.55)
                    .rotationEffect(.degrees(spin && !reduceMotion ? 360 : 0))
                    .animation(.linear(duration: 24).repeatForever(autoreverses: false), value: spin)
            }
            if tier >= .laurel {
                laurels
            }
            emblem
            if tier >= .starred {
                Image(systemName: tier == .radiant ? "crown.fill" : "sparkle")
                    .font(.nunito(size: size * (tier == .radiant ? 0.34 : 0.28), weight: .black))
                    .foregroundStyle(Color.evryNavy)
                    .offset(y: -size * 0.58)
            }
        }
        .frame(width: size, height: size)
        .onAppear { spin = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level) crest")
    }

    @ViewBuilder private var emblem: some View {
        let number = Text("\(level)")
            .font(.nunito(size: size * (level >= 10 ? 0.31 : 0.42), weight: .heavy))
            .monospacedDigit()
        switch tier {
        case .plain:
            Circle().fill(Color.evryWhite)
                .overlay(Circle().strokeBorder(Color.evryNavy20, lineWidth: max(1.5, size * 0.05)))
                .overlay(number.foregroundStyle(Color.evryNavy))
        case .sky:
            Circle().fill(Color.evrySky)
                .overlay(Circle().strokeBorder(Color.evryWhite, lineWidth: max(2, size * 0.07)))
                .overlay(number.foregroundStyle(Color.evryNavy))
        case .shield, .laurel:
            ShieldShape().fill(Color.evrySky)
                .overlay(ShieldShape().stroke(Color.evryNavy, lineWidth: max(1.5, size * 0.055)))
                .overlay(number.foregroundStyle(Color.evryNavy).offset(y: -size * 0.04))
                .frame(width: size * 0.84, height: size)
        case .starred, .radiant:
            ShieldShape().fill(Color.evryNavy)
                .overlay(ShieldShape().stroke(Color.evrySky, lineWidth: max(2, size * 0.07)))
                .overlay(number.foregroundStyle(Color.evryWhite).offset(y: -size * 0.04))
                .frame(width: size * 0.84, height: size)
        }
    }

    /// A laurel wreath curling up either side of the shield.
    private var laurels: some View {
        HStack(spacing: size * 0.62) {
            Image(systemName: "laurel.leading")
            Image(systemName: "laurel.trailing")
        }
        .font(.system(size: size * 0.5, weight: .semibold))
        .foregroundStyle(Color.evryNavy)
        .offset(y: size * 0.06)
    }
}

/// A classic heater shield: flat top with rounded shoulders, tapering to a point.
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        var p = Path()
        p.move(to: CGPoint(x: x + w * 0.5, y: y))
        p.addQuadCurve(to: CGPoint(x: x + w, y: y + h * 0.12), control: CGPoint(x: x + w * 0.8, y: y + h * 0.1))
        p.addLine(to: CGPoint(x: x + w, y: y + h * 0.48))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y + h), control: CGPoint(x: x + w * 0.95, y: y + h * 0.85))
        p.addQuadCurve(to: CGPoint(x: x, y: y + h * 0.48), control: CGPoint(x: x + w * 0.05, y: y + h * 0.85))
        p.addLine(to: CGPoint(x: x, y: y + h * 0.12))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y), control: CGPoint(x: x + w * 0.2, y: y + h * 0.1))
        p.closeSubpath()
        return p
    }
}

/// Soft triangular rays around a centre, for the top crest.
struct SunburstShape: Shape {
    let rays: Int

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.45
        var p = Path()
        for i in 0..<rays {
            let a = Double(i) / Double(rays) * 2 * .pi
            let half = .pi / Double(rays) * 0.45
            p.move(to: CGPoint(x: c.x + cos(a - half) * inner, y: c.y + sin(a - half) * inner))
            p.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
            p.addLine(to: CGPoint(x: c.x + cos(a + half) * inner, y: c.y + sin(a + half) * inner))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Awarding

/// Invisible watcher (placed once at the app root) that queues XP the moment
/// today's task goal or habit goal is completed — wherever it's completed. It
/// lands on the next Profile visit.
struct DailyGoalXPWatcher: View {
    /// Only today's due tasks — it sits at the app root, so an unfiltered query
    /// re-ran this on every edit to any task.
    @Query private var dueTasks: [TaskItem]
    @Query private var habits: [Habit]

    init() {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        _dueTasks = Query(filter: #Predicate<TaskItem> { t in
            if let due = t.dueDate { t.deletedAt == nil && !t.isNote && due >= start && due < end } else { false }
        })
    }

    private struct GoalState: Equatable { var tasksMet = false; var habitsMet = false }

    private var state: GoalState {
        let today = Calendar.current.startOfDay(for: Date())
        let dueHabits = habits.filter { $0.isDue(on: today) }
        return GoalState(
            tasksMet: !dueTasks.isEmpty && dueTasks.allSatisfy(\.completed),
            habitsMet: !dueHabits.isEmpty && dueHabits.allSatisfy(\.isDoneToday)
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { award(state) }
            .onChange(of: state) { _, new in award(new) }
    }

    private func award(_ s: GoalState) {
        var paid = false
        if s.tasksMet { paid = EvryXP.award(.tasks) || paid }
        if s.habitsMet { paid = EvryXP.award(.habits) || paid }
        // Queued, not applied — the level-up moment happens on the Profile page.
        if paid { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
}

// MARK: - XP crystals

/// One crystal of queued XP flying from the bottom of the screen into the
/// profile photo.
struct XPFlight: Identifiable {
    static let duration = 0.7

    let id = UUID()
    let amount: Int
    /// Which run of the stream it belongs to — a crystal from a stream that was
    /// cut short (the page closed) lands harmlessly.
    let run: Int
    let start: CGPoint
}

/// The flying crystal: straight from the bottom of the screen to the centre
/// of the photo — every one converges on the same spot — starting large and
/// shrinking a little as it closes in, then reports landing.
struct XPFlyingCrystal: View {
    let flight: XPFlight
    /// The photo's centre, read live so a scroll mid-flight is followed.
    let target: CGPoint
    let palette: Palette
    var onLand: (CGPoint) -> Void

    @State private var t: Double = 0

    var body: some View {
        CoreCrystal(fraction: 1, palette: palette, bright: true)
            .frame(height: 48)
            // A soft sky glow (no dark shadow), so it reads on the white page.
            .shadow(color: Color.evrySky.opacity(0.9), radius: 6)
            .modifier(StraightFlight(t: t, start: flight.start, end: target))
            .onAppear {
                // Gathers speed as it goes, so it strikes the photo.
                withAnimation(.timingCurve(0.45, 0, 0.85, 0.55, duration: XPFlight.duration)) { t = 1 } completion: {
                    onLand(target)
                }
            }
            .allowsHitTesting(false)
    }
}

/// Places a view along the straight line from `start` to `end`, easing from
/// full size down to about 60% as it arrives. Animatable, so it travels the line.
private struct StraightFlight: ViewModifier, Animatable {
    var t: Double
    let start: CGPoint
    let end: CGPoint

    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.4 * t)
            .position(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
    }
}

/// Plays queued XP into the profile photo: takes the queue, launches one
/// crystal per 5 XP from the bottom middle of the screen, and applies each
/// crystal's XP as it lands, so the level ring fills crystal by crystal. A
/// level-up gets room to play out before the next crystals fly. If the page
/// closes mid-stream, whatever hasn't landed goes back on the queue.
@MainActor
@Observable
final class XPStream {
    struct PopMark: Identifiable {
        let id = UUID()
        let at: CGPoint
    }

    private(set) var flights: [XPFlight] = []
    private(set) var pops: [PopMark] = []
    /// Bumped on every landing (the photo gives a small bounce).
    private(set) var hits = 0
    /// The photo's centre in the page's coordinate space, kept current by the
    /// page. Every crystal flies here.
    var photoCenter: CGPoint = .zero
    /// The crystal layer's size (its bottom edge is where crystals start).
    @ObservationIgnored var layerSize: CGSize = .zero

    @ObservationIgnored private var run = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var unlanded = 0

    var isRunning: Bool { task != nil }

    func play(reduceMotion: Bool) {
        guard task == nil else { return }
        let amount = EvryXP.takePending()
        guard amount > 0 else { return }
        if reduceMotion {
            // No flight: it all lands at once and the ring glides.
            EvryXP.add(amount)
            return
        }
        unlanded = amount
        run += 1
        let thisRun = run
        let pieces = EvryXP.crystals(for: amount)
        // Big hauls fly faster, so a long stream doesn't drag.
        let gap = max(0.05, min(0.14, 4.0 / Double(pieces.count)))
        task = Task { [weak self] in
            // Let the page settle before the first crystal flies.
            try? await Task.sleep(for: .milliseconds(650))
            var xp = EvryXP.total
            for piece in pieces {
                guard let self, !Task.isCancelled, self.run == thisRun else { return }
                self.launch(piece, run: thisRun)
                let levelsUp = EvryXP.progress(for: xp + piece).level > EvryXP.progress(for: xp).level
                xp += piece
                // A level-up fills the ring, bursts and refills (~2.7 s) — wait it out.
                try? await Task.sleep(for: .seconds(levelsUp ? XPFlight.duration + 2.8 : gap))
            }
            try? await Task.sleep(for: .seconds(XPFlight.duration + 0.4))
            if let self, self.run == thisRun { self.task = nil }
        }
    }

    /// The page is closing: stop, and put back whatever hasn't landed.
    func stop() {
        run += 1
        task?.cancel()
        task = nil
        if unlanded > 0 { EvryXP.queue(unlanded) }
        unlanded = 0
        flights.removeAll()
        pops.removeAll()
    }

    func land(_ flight: XPFlight, at point: CGPoint) {
        flights.removeAll { $0.id == flight.id }
        guard flight.run == run else { return }
        unlanded = max(0, unlanded - flight.amount)
        EvryXP.add(flight.amount)
        hits += 1
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        let pop = PopMark(at: point)
        pops.append(pop)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.pops.removeAll { $0.id == pop.id }
        }
    }

    private func launch(_ amount: Int, run: Int) {
        let width = layerSize.width > 0 ? layerSize.width : 390
        let height = layerSize.height > 0 ? layerSize.height : 800
        // From the bottom middle, just off screen.
        flights.append(XPFlight(amount: amount, run: run, start: CGPoint(x: width / 2, y: height + 30)))
    }
}

/// Draws the stream's crystals and pops over the page.
struct XPCrystalLayer: View {
    let stream: XPStream
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(stream.flights) { flight in
                    XPFlyingCrystal(flight: flight, target: stream.photoCenter, palette: palette) { point in
                        stream.land(flight, at: point)
                    }
                }
                ForEach(stream.pops) { pop in XPPop(at: pop.at) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { stream.layerSize = geo.size }
            .onChange(of: geo.size) { _, size in stream.layerSize = size }
        }
        // Down to the very bottom of the screen, where the crystals start.
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The pop where a crystal strikes the photo: a sky ring and a few shards.
struct XPPop: View {
    let at: CGPoint
    @State private var burst = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.evrySky, lineWidth: 3)
                .frame(width: 30, height: 30)
                .scaleEffect(burst ? 1.7 : 0.3)
                .opacity(burst ? 0 : 1)
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) / 6 * 2 * .pi
                Circle()
                    .fill(i.isMultiple(of: 2) ? Color.evrySky : Color.evryNavy.opacity(0.6))
                    .frame(width: 5, height: 5)
                    .offset(x: burst ? cos(angle) * 26 : 0, y: burst ? sin(angle) * 26 : 0)
                    .opacity(burst ? 0 : 1)
            }
        }
        .position(at)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.42)) { burst = true } }
    }
}

// MARK: - Crest gallery

/// Every crest and the level that unlocks it — the ones still ahead are shown
/// faded, so there's always something to grow into.
struct CrestGallerySheet: View {
    let level: Int
    let palette: Palette

    @Environment(\.dismiss) private var dismiss
    @State private var shown = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reach your daily task and habit goals to earn \(EvryXP.perGoal) XP each. Finishing tasks and writing new notes can earn a little extra. New XP lands when you open your profile, and your crest grows as you level up.")
                        .font(.evryBody)
                        .lineSpacing(4)
                        .foregroundStyle(palette.textSec)
                        .padding(.bottom, 6)

                    ForEach(Array(CrestTier.allCases.enumerated()), id: \.offset) { i, tier in
                        let unlocked = level >= tier.startLevel
                        HStack(spacing: 16) {
                            // Each row shows its own tier's crest; yours shows your level.
                            EvryCrest(level: CrestTier.forLevel(level) == tier ? level : tier.startLevel, size: 48)
                                .frame(width: 72, height: 72)
                                .opacity(unlocked ? 1 : 0.35)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tier.title)
                                    .font(.evryLabel)
                                    .foregroundStyle(palette.text)
                                Text(unlocked ? (CrestTier.forLevel(level) == tier ? "Your crest now" : "Unlocked")
                                              : "Unlocks at level \(tier.startLevel)")
                                    .font(.nunito(size: 14, weight: unlocked ? .semibold : .regular))
                                    .foregroundStyle(palette.textSec)
                            }
                            Spacer(minLength: 0)
                            if !unlocked {
                                Image(systemName: "lock.fill")
                                    .font(.nunito(size: 14, weight: .bold))
                                    .foregroundStyle(palette.textPh)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .evryCard(palette, shadow: false)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 12)
                        .animation(EvryMotion.settle.delay(0.05 * Double(i)), value: shown)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(EvrySpace.gutter)
            }
            .background(palette.bg)
            .navigationTitle("Crests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .onAppear { shown = true }
    }
}
