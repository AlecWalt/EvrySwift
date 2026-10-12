//
//  EvryLevels.swift
//  Evry
//
//  The account level system. People earn XP when they complete a day's goal —
//  every task due today done, or every habit due today checked in — and XP
//  raises their level. Each band of levels has a title and a profile crest
//  that starts plain and grows grander (sky → shield → laurels → crown).
//
//  Stored in UserDefaults: the running total ("xp_total") plus a per-day,
//  per-goal ledger so a goal only ever pays out once a day.
//

import SwiftUI
import SwiftData

// MARK: - XP and levels

enum EvryXP {
    static let totalKey = "xp_total"
    /// XP for completing one daily goal (tasks or habits).
    static let perGoal = 50

    enum Goal: String { case tasks, habits }

    static var total: Int { UserDefaults.standard.integer(forKey: totalKey) }

    static func add(_ amount: Int) {
        UserDefaults.standard.set(max(0, total + amount), forKey: totalKey)
    }

    static func reset() {
        UserDefaults.standard.set(0, forKey: totalKey)
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("xp_awarded_") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Pays out a goal's XP for `date`, once. Returns true if it was awarded now.
    @discardableResult
    static func award(_ goal: Goal, on date: Date = Date()) -> Bool {
        let key = "xp_awarded_\(goal.rawValue)_\(dayKey(date))"
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        UserDefaults.standard.set(true, forKey: key)
        add(perGoal)
        return true
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
        var toNext: Int { needed - into }
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

    var next: CrestTier? { CrestTier(rawValue: rawValue + 1) }

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

/// Invisible watcher (placed once at the app root) that awards XP the moment
/// today's task goal or habit goal is completed — wherever it's completed.
struct DailyGoalXPWatcher: View {
    @Query private var tasks: [TaskItem]
    @Query private var habits: [Habit]

    private struct GoalState: Equatable { var tasksMet = false; var habitsMet = false }

    private var state: GoalState {
        let today = Calendar.current.startOfDay(for: Date())
        let dueTasks = tasks.filter { t in
            !t.isTrashed && !t.isNote && (t.dueDate.map { Calendar.current.isDate($0, inSameDayAs: today) } ?? false)
        }
        let dueHabits = habits.filter { !$0.isFormed && $0.isScheduled(on: today) }
        return GoalState(
            tasksMet: !dueTasks.isEmpty && dueTasks.allSatisfy(\.completed),
            habitsMet: !dueHabits.isEmpty && dueHabits.allSatisfy { HabitStats(habit: $0).todayDone }
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
        let before = EvryXP.progress(for: EvryXP.total).level
        var paid = false
        if s.tasksMet { paid = EvryXP.award(.tasks) || paid }
        if s.habitsMet { paid = EvryXP.award(.habits) || paid }
        guard paid else { return }
        let after = EvryXP.progress(for: EvryXP.total).level
        // A level-up gets the full success tap; a plain XP payout, a light one.
        if after > before {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
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
                    Text("Reach your daily task and habit goals to earn \(EvryXP.perGoal) XP each. Your crest grows as you level up.")
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
