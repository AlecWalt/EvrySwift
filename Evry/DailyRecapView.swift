//
//  DailyRecapView.swift
//  Evry
//
//  The start-of-day recap of yesterday (tasks, focus, time saved). Tone:
//  celebrate progress without the pressure — calm copy, the mascot for
//  success, and charts in sky / navy strength steps only.
//

import SwiftUI

// MARK: - UserDefaults storage

enum AccomplishmentsStore {
    /// The per-day key used by FocusLog and the once-a-day recap guard:
    /// "2026-10-14", the same whatever the device's language or region (the old
    /// locale-formatted key changed when they did, losing focus history).
    static func dateKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// The pre-fix, locale-formatted key — still read so earlier days count.
    static func legacyDateKey(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day())
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Chart steps

extension Palette {
    /// Chart / metric series colours: strength steps between sky and navy, so
    /// series differ by strength, never by hue. Index 0 is the strongest ink.
    fileprivate func chartStep(_ index: Int) -> Color {
        let light: [Color] = [.evryNavy, Color.evrySky.mix(with: .evryNavy, by: 0.55), Color.evrySky.mix(with: .evryNavy, by: 0.25)]
        let dark: [Color] = [.evrySky, Color.evrySky.mix(with: .evryNavy, by: 0.25), Color.evrySky.mix(with: .evryNavy, by: 0.45)]
        let steps = self.dark ? dark : light
        return steps[index % steps.count]
    }
}

// MARK: - Daily recap (start-of-day "yesterday" summary)

/// A calm start-of-day popup summarizing what the user did yesterday: tasks
/// completed, focus time (from Pomodoro), and an estimate of time saved. Evry
/// pops in as the hero, a little sky confetti falls, the metric cards reveal in
/// turn with count-up numbers and sky/navy step bars. Shown once per day by
/// ContentView. Decorative motion is skipped under Reduce Motion.
struct DailyRecapView: View {
    let date: Date            // the day being recapped (yesterday)
    let tasksCompleted: Int
    let focusMinutes: Int
    /// The user's own daily targets (from Profile), so the recap can report how
    /// well they did against their goals rather than fixed numbers.
    var taskGoal: Int = 5
    var focusGoal: Int = 60

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var heroPop = false
    @State private var confetti = false
    @State private var dTasks = 0
    @State private var dFocus = 0
    @State private var dSaved = 0

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    /// Rough estimate: capturing/organizing each task by hand costs ~4 min.
    private var timeSavedMinutes: Int { tasksCompleted * 4 }

    /// How many of the two daily goals were met.
    private var goalsHit: Int {
        (tasksCompleted >= taskGoal ? 1 : 0) + (focusMinutes >= focusGoal ? 1 : 0)
    }

    private var headline: String {
        if tasksCompleted == 0 && focusMinutes == 0 { return "A fresh start today" }
        if goalsHit == 2 { return "A lovely, steady day" }
        return "Steady progress"
    }

    /// Evry's one-line, first-person note on how the day measured up to the
    /// user's goals — kind whatever happened.
    private var goalLine: String {
        if tasksCompleted == 0 && focusMinutes == 0 {
            return "Yesterday was a quiet one, and that’s fine. Shall we pick one small thing for today?"
        }
        switch goalsHit {
        case 2: return "You met both of your daily goals. I’m proud of you. Ready for today?"
        case 1:
            let met = tasksCompleted >= taskGoal ? "task" : "focus"
            return "You met your \(met) goal. Every step counts. Shall we keep it going?"
        default: return "Every bit of progress counts. Today’s a new day. Shall we start small?"
        }
    }

    private func hm(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
    private func frac(_ value: Int, goal: Int) -> CGFloat {
        min(1, CGFloat(value) / CGFloat(max(1, goal)))
    }

    var body: some View {
        ZStack {
            backdrop
            if !reduceMotion {
                RecapConfetti(palette: palette, active: confetti).allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                heroBadge
                    .padding(.top, 36)

                VStack(spacing: 8) {
                    EyebrowPill(text: "Yesterday", palette: palette)
                    Text(headline)
                        .font(.evryH2)
                        .tracking(EvryTracking.h2)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(date.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.evryBody)
                        .foregroundStyle(palette.textSec)
                }
                .padding(.top, 16)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
                .animation(EvryMotion.settle.delay(0.2), value: appeared)

                // No avatar: the hero above is already Evry.
                EvryBubble(text: goalLine, showsAvatar: false, palette: palette)
                    .padding(.horizontal, EvrySpace.grid)
                    .padding(.top, 18)
                    .opacity(appeared ? 1 : 0)
                    .animation(EvryMotion.settle.delay(0.3), value: appeared)

                Spacer(minLength: 20)

                VStack(spacing: 14) {
                    metricCard(0, icon: .tool(.tasks), label: "Tasks completed",
                               value: "\(dTasks)", fraction: frac(tasksCompleted, goal: taskGoal))
                    metricCard(1, icon: .symbol("timer"), label: "Focus time",
                               value: hm(dFocus), fraction: frac(focusMinutes, goal: focusGoal))
                    metricCard(2, icon: .star, label: "Time saved, roughly",
                               value: "~\(hm(dSaved))", fraction: frac(timeSavedMinutes, goal: 30))
                }
                .padding(.horizontal, EvrySpace.grid)

                Spacer(minLength: 20)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    dismiss()
                } label: {
                    Text("Start today")
                }
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                .padding(.horizontal, EvrySpace.grid)
                .padding(.bottom, 36)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.7), value: appeared)
            }
        }
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear { runIntro() }
    }

    // MARK: Pieces

    private var backdrop: some View {
        ZStack {
            palette.bg
            EvryGlow(onNavy: palette.dark)
                .offset(y: -260)
        }
        .ignoresSafeArea()
    }

    /// Evry as the success hero, popping in with a small overshoot.
    private var heroBadge: some View {
        EvryMascot(size: 112, float: true, shadow: true)
            .scaleEffect(heroPop || reduceMotion ? 1 : 0.4)
            .rotationEffect(.degrees(heroPop || reduceMotion ? 0 : -8))
            .animation(EvryMotion.spring, value: heroPop)
            .frame(height: 150)
    }

    private enum MetricIcon {
        case tool(EvryTool)
        case symbol(String)
        case star
    }

    @ViewBuilder private func metricIcon(_ icon: MetricIcon) -> some View {
        switch icon {
        case .tool(let tool):
            ToolIcon(tool: tool, tile: 32, palette: palette)
        case .symbol(let name):
            Image(systemName: name)
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(palette.onSky)
                .frame(width: 32, height: 32)
                .background(palette.sky.opacity(0.7), in: Circle())
                .accessibilityHidden(true)
        case .star:
            Image("EvryIconStar")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(palette.onSky)
                .frame(width: 32, height: 32)
                .background(palette.sky.opacity(0.45), in: RoundedRectangle(cornerRadius: EvryRadius.tile * 32 / 48, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private func metricCard(_ index: Int, icon: MetricIcon, label: String, value: String,
                            fraction: CGFloat) -> some View {
        let delay = 0.35 + Double(index) * 0.12
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                metricIcon(icon)
                Text(label)
                    .font(.evryLabel)
                    .foregroundStyle(palette.text)
                Spacer()
                Text(value)
                    .font(.nunito(size: 22, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.skySoft)
                    Capsule()
                        .fill(palette.chartStep(index))
                        .frame(width: appeared ? geo.size.width * fraction : 0)
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .evryCard(palette)
        .accessibilityElement(children: .combine)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 14)
        .animation(EvryMotion.reveal.delay(delay), value: appeared)
    }

    // MARK: Intro sequence

    private func runIntro() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(EvryMotion.spring) { heroPop = true }
        withAnimation(EvryMotion.settle.delay(0.15)) { appeared = true }
        confetti = true
        Task { await countUp() }
    }

    /// Rolls each metric number up from zero (eased) once the cards have revealed.
    private func countUp() async {
        if reduceMotion {
            dTasks = tasksCompleted; dFocus = focusMinutes; dSaved = timeSavedMinutes
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let steps = 22
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let eased = 1 - pow(1 - t, 3)
            dTasks = Int((Double(tasksCompleted) * eased).rounded())
            dFocus = Int((Double(focusMinutes) * eased).rounded())
            dSaved = Int((Double(timeSavedMinutes) * eased).rounded())
            try? await Task.sleep(nanoseconds: 28_000_000)
        }
        dTasks = tasksCompleted; dFocus = focusMinutes; dSaved = timeSavedMinutes
    }
}

// MARK: - Recap confetti

/// A light fall of soft pills in sky / navy strength steps — never new hues.
private struct RecapConfetti: View {
    let palette: Palette
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<18, id: \.self) { i in
                    ConfettiPiece(index: i, width: geo.size.width, height: geo.size.height,
                                  color: color(i), active: active)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ i: Int) -> Color {
        let cs = [palette.sky, palette.chartStep(1), palette.chartStep(0), palette.sky.opacity(0.7)]
        return cs[i % cs.count]
    }
}

private struct ConfettiPiece: View {
    let index: Int
    let width: CGFloat
    let height: CGFloat
    let color: Color
    let active: Bool

    @State private var fall = false

    private var xFrac: CGFloat { CGFloat((index * 37) % 100) / 100 }
    private var delay: Double { Double(index % 8) * 0.06 }
    private var drift: CGFloat { CGFloat((index % 7) - 3) * 16 }
    private var size: CGFloat { 6 + CGFloat(index % 3) * 3 }

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: size, height: size * 1.6)
            .rotationEffect(.degrees(fall ? Double((index * 57) % 360) + 200 : Double((index * 57) % 360)))
            .position(x: width * xFrac + (fall ? drift : 0), y: fall ? height * 0.96 : -30)
            .opacity(fall ? 0 : 1)
            .animation(.easeIn(duration: 1.6).delay(delay), value: fall)
            .onChange(of: active) { _, a in if a { fall = true } }
            .onAppear { if active { fall = true } }
    }
}
