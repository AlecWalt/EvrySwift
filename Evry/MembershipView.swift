//
//  MembershipView.swift
//  Evry
//

import SwiftUI
import UIKit

// MARK: - Animated feature promo

/// App-level router so the promo card can close itself and hand off to the
/// full-screen plans page (presented from the root, which outlives the promo).
@Observable final class MembershipRouter {
    var showPlans = false
}

/// Trial + subscription access — the single source of truth for the hard-walled
/// model. Evry is fully free for `trialDays` from first launch; after that the app
/// is blocked until the user subscribes. `hasAccess` gates the whole app (there is
/// no per-feature free tier anymore).
enum MembershipAccess {
    static let trialDays = 15

    /// ISO8601 timestamp of first launch, used as the trial clock. Stored under
    /// "app_first_used"; self-heals (stamps now) if missing so the trial always
    /// has a defined start.
    private static let formatter = ISO8601DateFormatter()

    static func trialStart() -> Date {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "app_first_used"), let date = formatter.date(from: raw) {
            return date
        }
        let now = Date()
        d.set(formatter.string(from: now), forKey: "app_first_used")
        return now
    }

    static func isSubscribed() -> Bool {
        UserDefaults.standard.string(forKey: "membership_plan") == "pro"
    }

    /// Whole days left in the free trial (0 once expired). Uses calendar-day
    /// boundaries so "N days left" reads naturally.
    static func daysRemaining(_ now: Date = Date()) -> Int {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: trialDays, to: cal.startOfDay(for: trialStart())) ?? now
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: end)).day ?? 0
        return max(0, days)
    }

    /// True while the free trial is still running and the user hasn't subscribed.
    static func inTrial(_ now: Date = Date()) -> Bool {
        !isSubscribed() && daysRemaining(now) > 0
    }

    /// The global gate: unlocked while subscribed or still within the free trial.
    static func hasAccess(_ now: Date = Date()) -> Bool {
        isSubscribed() || daysRemaining(now) > 0
    }
}

struct MembershipPromoView: View {
    /// When true this is the trial-ended hard wall: no close, no "maybe later",
    /// and the copy is framed around what the user would be leaving behind.
    var isHardWall: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentPage = 0
    @State private var showPlans = false
    /// Pages advance on their own until the user navigates themselves.
    @State private var autoAdvance = true
    /// The page the auto-advance timer is moving to (to tell its moves apart).
    @State private var autoTarget: Int? = nil

    // Hard-wall intro: white screen → logo fades in centered → zooms/shrinks up
    // into the header spot → the popup content fades in.
    @Namespace private var logoNS
    @State private var introLogoIn = false   // centered logo opacity
    @State private var introLanded = false   // logo has flown to the header spot
    @State private var contentShown = false  // popup content revealed

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private let pageCount = 7
    /// The page whose art features Evry (the mascot), not just the mark.
    private static let distillPage = 2
    private var lastIndex: Int { pageCount - 1 }

    private var finalCTA: String { isHardWall ? "Choose your plan" : "See plans" }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Plain white during the intro; settles to the app background as the
            // content appears.
            (isHardWall && !contentShown ? Color.evryWhite : palette.bg).ignoresSafeArea()

            // The soft sky glow, off-canvas behind the header.
            EvryGlow(onNavy: palette.dark)
                .offset(x: 150, y: -190)
                .opacity(isHardWall && !contentShown ? 0 : 1)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Centered Evry logo (mark + wordmark) that sets the framing. The
                // blocking paywall leads with a larger lockup.
                EvryLogo(palette: palette)
                    .scaleEffect(isHardWall ? 1.5 : 1.3)
                    .matchedGeometryEffect(id: "paywallLogo", in: logoNS, isSource: introLanded || !isHardWall)
                    // The Distill page's art brings Evry in, so the mark steps
                    // away there (Evry is never in two places at once).
                    .environment(\.evryAway, currentPage == Self.distillPage)
                    .padding(.top, 44)
                    .padding(.bottom, 8)

                // Pages — each page owns its animation + title + description,
                // so swiping anywhere on a page (including the text) advances cards.
                TabView(selection: $currentPage) {
                    PromoPage(palette: palette,
                              title: "Plan your day in seconds",
                              benefits: ["Type it naturally: “!high”, “#work” and “fri” just work",
                                         "Fling a task up for today, right for tomorrow"]) {
                        PromoPlanArt(palette: palette)
                    }.tag(0)
                    PromoPage(palette: palette,
                              title: "Build habits that stick",
                              benefits: ["Check in daily and watch your streaks grow",
                                         "Fill a 66-day goal until the habit is truly built"]) {
                        PromoHabitsArt(palette: palette)
                    }.tag(1)
                    PromoPage(palette: palette,
                              title: "Clear your head with Distill",
                              benefits: ["Talk or type everything on your mind, unfiltered",
                                         "Distill turns the jumble into clear, dated tasks"]) {
                        PromoDistillArt(palette: palette)
                    }
                    .tag(Self.distillPage)
                    // …and its Evry only shows while it's the current page.
                    .environment(\.evryAway, currentPage != Self.distillPage)
                    PromoPage(palette: palette,
                              title: "Deep focus, on the clock",
                              benefits: ["Calm Pomo sessions with gentle break reminders",
                                         "Focus Mode keeps just today’s path in front of you"]) {
                        PromoFocusArt(palette: palette)
                    }.tag(3)
                    PromoPage(palette: palette,
                              title: "Notes that keep up",
                              benefits: ["Rich text, lists and formatting",
                                         "Folders and search keep every idea findable"]) {
                        PromoNotesArt(palette: palette)
                    }.tag(4)
                    PromoPage(palette: palette,
                              title: "See your progress",
                              benefits: ["Daily goals that follow your real tasks and habits",
                                         "A morning recap of yesterday’s wins"]) {
                        PromoProgressArt(palette: palette)
                    }.tag(5)
                    PromoKeepPage(palette: palette, isHardWall: isHardWall).tag(6)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                // Pill-style page dots
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? palette.primary : palette.border)
                            .frame(width: i == currentPage ? 24 : 8, height: 8)
                            .animation(EvryMotion.settle, value: currentPage)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(currentPage + 1) of \(pageCount)")
                .padding(.bottom, EvrySpace.grid)

                // CTA
                VStack(spacing: 12) {
                    Button {
                        autoAdvance = false
                        if currentPage < lastIndex {
                            withAnimation(EvryMotion.settle) {
                                currentPage += 1
                            }
                        } else {
                            // Open the full-screen plans page over the promo.
                            showPlans = true
                        }
                    } label: {
                        Text(currentPage < lastIndex ? "Next" : finalCTA)
                    }
                    .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))

                    // No opt-out on the hard wall.
                    if !isHardWall {
                        Button("Maybe later") { dismiss() }
                            .font(.evryLabel)
                            .foregroundStyle(palette.textSec)
                            .frame(minHeight: EvrySpace.tap)
                    }
                }
                .padding(.horizontal, EvrySpace.grid)
                .padding(.bottom, 28)
            }
            // The whole popup stays hidden until the intro logo has landed.
            .opacity(isHardWall && !contentShown ? 0 : 1)

            // Close button — hidden on the hard wall.
            if !isHardWall {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .frame(width: 32, height: 32)
                        .background(palette.hover, in: Circle())
                        .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .padding(10)
            }

            // Intro: a large logo centered on the white screen that fades in, then
            // flies up into the header spot (shared matchedGeometry id).
            if isHardWall && !contentShown {
                EvryLogo(palette: palette)
                    .scaleEffect(introLanded ? 1.5 : 2.2)
                    .matchedGeometryEffect(id: "paywallLogo", in: logoNS, isSource: !introLanded)
                    .opacity(introLogoIn ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .onAppear(perform: runIntroIfNeeded)
        // Auto-advance until the user takes over: a tap on Next or a swipe stops
        // it for good, so it can never fire on top of a manual move (which used
        // to skip a page).
        .task(id: currentPage) {
            guard autoAdvance, currentPage < lastIndex else { return }
            do {
                try await Task.sleep(for: .seconds(7.0))
                guard autoAdvance else { return }
                autoTarget = currentPage + 1
                withAnimation(EvryMotion.settle) {
                    currentPage += 1
                }
            } catch {}
        }
        .onChange(of: currentPage) { _, page in
            // Any page change the timer didn't make is the user's.
            if page != autoTarget { autoAdvance = false }
        }
        // On the hard wall, only close the promo once the user has actually
        // subscribed — otherwise closing the plans page must leave the wall up.
        .fullScreenCover(isPresented: $showPlans, onDismiss: {
            if !isHardWall || MembershipAccess.isSubscribed() { dismiss() }
        }) {
            MembershipPlansView()
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }

    /// Hard-wall entrance: fade the centered logo in, fly it up into the header,
    /// then reveal the content. Non-wall promos show everything immediately.
    private func runIntroIfNeeded() {
        guard isHardWall, !contentShown else { return }
        if reduceMotion {
            introLogoIn = true; introLanded = true; contentShown = true
            return
        }
        withAnimation(.easeOut(duration: 0.5)) { introLogoIn = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(EvryMotion.settle) { introLanded = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.4)) { contentShown = true }
        }
    }
}

// MARK: - Promo page shell

/// One feature page: an animated illustration, a title, and two benefits.
private struct PromoPage<Art: View>: View {
    let palette: Palette
    let title: String
    let benefits: [String]
    @ViewBuilder var art: () -> Art

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            art()
                .frame(height: 210)
                .frame(maxWidth: .infinity)

            VStack(spacing: 14) {
                Text(title)
                    .font(.evryH2)
                    .tracking(EvryTracking.h2)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(benefits.enumerated()), id: \.offset) { i, benefit in
                        HStack(alignment: .top, spacing: 12) {
                            EvryCheck()
                            Text(benefit)
                                .font(.evryBody)
                                .foregroundStyle(palette.textSec)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown || reduceMotion ? 0 : 14)
                        .animation(EvryMotion.settle.delay(0.15 + Double(i) * 0.1), value: shown)
                    }
                }
                .frame(maxWidth: 330, alignment: .leading)
            }
            .padding(.horizontal, EvrySpace.card)
            .padding(.top, EvrySpace.grid)
        }
        .onAppear { shown = true }
        .onDisappear { shown = false }
    }
}

/// White card surface used inside the illustrations: the design system's
/// Card (navy-08 hairline, shadow-soft).
private extension View {
    func promoCard(_ palette: Palette, radius: CGFloat = EvryRadius.card) -> some View {
        evryField(palette, cornerRadius: radius)
            .evryShadowSoft(palette)
    }
}

// MARK: - Page 1: Plan your day (Inbox + quick add)

private struct PromoPlanArt: View {
    let palette: Palette

    // One task to start; the new one lands above it (two full-size Inbox rows
    // plus the quick-add card fill the illustration).
    private static let base = ["Team sync"]
    private let entry = "Call mom !high"

    @State private var rows = PromoPlanArt.base
    @State private var typed = ""
    @State private var pillY: CGFloat = 0
    @State private var pillOpacity: Double = 1

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows, id: \.self) { title in
                row(title, isNew: title == entry)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
            Spacer(minLength: 0)
            quickAddPill
                .offset(y: pillY)
                .opacity(pillOpacity)
        }
        // Same 20pt margins as the Inbox.
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .task { await loop() }
    }

    /// A task row exactly like the Inbox's: the real checkbox and trash button,
    /// body-size title, radius-card row. The new task wears the high-priority mark.
    private func row(_ title: String, isNew: Bool) -> some View {
        HStack(spacing: 12) {
            TaskCheckbox(checked: false, palette: palette, contentAlignment: .leading, action: {})
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if isNew {
                    Image(systemName: "exclamationmark.2")
                        .font(.nunito(size: 13, weight: .heavy))
                        .foregroundStyle(Palette.danger)
                }
                Text(isNew ? "Call mom" : title)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TrashBurstButton(palette: palette, action: {})
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .evryField(palette, cornerRadius: EvryRadius.card)
        .allowsHitTesting(false)
    }

    private var quickAddPill: some View {
        HStack(spacing: 0) {
            Text(highlighted)
                .font(.evryBody)
            Rectangle().fill(palette.primary).frame(width: 2, height: 17).padding(.leading, 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.hover, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
        .padding(8)
        .promoCard(palette, radius: EvryRadius.card)
    }

    /// Typed keywords pick up their highlight, like the real quick-add.
    private var highlighted: AttributedString {
        var a = AttributedString(typed.isEmpty ? " " : typed)
        a.foregroundColor = palette.text
        if let r = a.range(of: "!high") {
            a[r].foregroundColor = palette.text
            a[r].font = .nunito(size: 16, weight: .bold)
        }
        return a
    }

    private func loop() async {
        do {
            while true {
                rows = Self.base
                typed = ""
                pillY = 0
                pillOpacity = 1
                try await Task.sleep(for: .milliseconds(600))
                for ch in entry {
                    typed.append(ch)
                    try await Task.sleep(for: .milliseconds(70))
                }
                try await Task.sleep(for: .milliseconds(450))
                // Fling the card up — the task lands at the top of today.
                withAnimation(EvryMotion.settle) { pillY = -110; pillOpacity = 0 }
                try await Task.sleep(for: .milliseconds(200))
                withAnimation(EvryMotion.settle) { rows.insert(entry, at: 0) }
                try await Task.sleep(for: .milliseconds(350))
                // A fresh empty card rises from below.
                typed = ""
                pillY = 50
                withAnimation(EvryMotion.settle) { pillY = 0; pillOpacity = 1 }
                try await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeInOut(duration: 0.3)) { rows = Self.base }
                try await Task.sleep(for: .milliseconds(350))
            }
        } catch {}
    }
}

// MARK: - Page 2: Habits

/// Two acts, one at a time and centred: today's check-in ring fills, fades
/// away, and the habit's 66-day goal card takes its place, filling to the medal.
private struct PromoHabitsArt: View {
    let palette: Palette

    @State private var showCard = false
    @State private var ring: Double = 0
    @State private var level: Double = 0.5
    @State private var days = 33
    @State private var medal = false

    var body: some View {
        ZStack {
            if showCard {
                goalCard
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                checkInRing
                    .transition(.scale(scale: 1.08).combined(with: .opacity))
            }
        }
        .task { await loop() }
    }

    private var checkInRing: some View {
        VStack(spacing: 10) {
            ZStack {
                HabitRing(fraction: ring, color: palette.primary, track: palette.hover, lineWidth: 12)
                VStack(spacing: 2) {
                    Image(systemName: ring >= 1 ? "checkmark" : "drop.fill")
                        .font(.nunito(size: 26, weight: .bold))
                        .foregroundStyle(palette.primary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(ring >= 1 ? "1/1" : "0/1")
                        .font(.nunito(size: 15, weight: .heavy))
                        .foregroundStyle(palette.text)
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 140, height: 140)
            Text("Drink water")
                .font(.evrySmall)
                .foregroundStyle(palette.textSec)
        }
    }

    private var goalCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).fill(palette.card)
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                LiquidFill(level: level, amplitude: 5, phase: t * 2, cycles: 1.2)
                    .fill(Color.evrySky.opacity(palette.dark ? 0.45 : 0.8))
            }
            .clipShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
            RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1)

            VStack(spacing: 0) {
                Text("Goal")
                    .font(.evryCaption)
                    .foregroundStyle(palette.textSec)
                Text("\(days)")
                    .font(.nunito(size: 44, weight: .heavy))
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText(value: Double(days)))
                Text("of 66 days")
                    .font(.evrySmall)
                    .foregroundStyle(palette.textSec)
            }
            .opacity(medal ? 0 : 1)

            if medal {
                VStack(spacing: 8) {
                    HabitMedal(icon: "drop.fill", size: 76)
                    Text("Habit built")
                        .font(.evrySmall)
                        .foregroundStyle(palette.text)
                }
                .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: 170, height: 196)
        .evryShadowSoft(palette)
    }

    private func loop() async {
        do {
            while true {
                showCard = false
                ring = 0; level = 0.5; days = 33; medal = false
                try await Task.sleep(for: .milliseconds(500))
                withAnimation(.easeInOut(duration: 0.9)) { ring = 1 }
                try await Task.sleep(for: .seconds(1.5))
                // The check-in is done — hand over to the long-term goal.
                withAnimation(.easeInOut(duration: 0.45)) { showCard = true }
                try await Task.sleep(for: .milliseconds(550))
                withAnimation(.easeInOut(duration: 1.6)) { level = 1 }
                for d in 34...66 {
                    withAnimation(.snappy(duration: 0.08)) { days = d }
                    try await Task.sleep(for: .milliseconds(48))
                }
                withAnimation(EvryMotion.spring) { medal = true }
                try await Task.sleep(for: .seconds(2.2))
                // Empty the ring while it's hidden so it returns fresh.
                ring = 0
                withAnimation(.easeInOut(duration: 0.45)) { showCard = false }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {}
    }
}

// MARK: - Page 3: Distill

/// Rambling half-sentences drift around, get pulled in by Evry, and come out
/// as clear tasks with due days — messy thinking in, actionable list out.
private struct PromoDistillArt: View {
    let palette: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Thought { let text: String; let x: CGFloat; let y: CGFloat; let angle: Double }
    private let thoughts = [
        Thought(text: "ok I really need to email Sam the deck by thurs??", x: -84, y: -64, angle: -5),
        Thought(text: "mom’s bday is sunday — gift?? cake??", x: 90, y: -66, angle: 6),
        Thought(text: "dentist called… or was that last week", x: -96, y: 8, angle: 4),
        Thought(text: "june flights keep going up, ugh", x: 88, y: 6, angle: -5),
        Thought(text: "why is the bank charging me again", x: -74, y: 74, angle: 6),
        Thought(text: "gym. seriously. this week.", x: 94, y: 76, angle: -6),
    ]
    private let tasks: [(String, String)] = [
        ("Email Sam the deck", "Thu"),
        ("Buy Mom’s birthday gift", "Sun"),
        ("Call the dentist back", "Today"),
        ("Book June flights", "Today"),
    ]

    /// 0 = rambling thoughts, 1 = distilling, 2 = tidy tasks.
    @State private var phase = 0
    @State private var drift = false

    var body: some View {
        ZStack {
            ForEach(Array(thoughts.enumerated()), id: \.offset) { i, th in
                Text(th.text)
                    .font(.nunito(size: 13))
                    .italic()
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .promoCard(palette, radius: EvryRadius.field)
                    .rotationEffect(.degrees(th.angle + (drift ? 2.5 : -2.5)))
                    .offset(x: phase == 0 ? th.x + (drift ? 4 : -4) : 0,
                            y: phase == 0 ? th.y + (drift ? -3 : 3) : 0)
                    .scaleEffect(phase == 0 ? 1 : 0.12)
                    .opacity(phase == 0 ? 1 : 0)
                    .animation(EvryMotion.settle.delay(Double(i) * 0.04), value: phase)
            }

            // Evry gathers the thoughts up and sorts them.
            EvryMascot(size: 72)
                .scaleEffect(phase == 1 ? 1.15 : 0.4)
                .opacity(phase == 1 ? 1 : 0)
                .animation(EvryMotion.spring, value: phase)

            VStack(spacing: 7) {
                ForEach(Array(tasks.enumerated()), id: \.offset) { i, task in
                    HStack(spacing: 10) {
                        Circle().strokeBorder(palette.border, lineWidth: 2).frame(width: 18, height: 18)
                        Text(task.0)
                            .font(.nunito(size: 15))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(task.1)
                            .font(.evryCaption)
                            .foregroundStyle(task.1 == "Today" ? palette.dateColor(.today) : palette.dateColor(.week))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .evryField(palette, cornerRadius: EvryRadius.field)
                    .opacity(phase == 2 ? 1 : 0)
                    .offset(y: phase == 2 ? 0 : 14)
                    .animation(EvryMotion.settle.delay(phase == 2 ? Double(i) * 0.1 : 0), value: phase)
                }
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { drift = true }
        }
        .task {
            do {
                while true {
                    phase = 0
                    try await Task.sleep(for: .seconds(2.4))
                    phase = 1
                    try await Task.sleep(for: .milliseconds(850))
                    phase = 2
                    try await Task.sleep(for: .seconds(2.8))
                }
            } catch {}
        }
    }
}

// MARK: - Page 4: Pomo Focus

private struct PromoFocusArt: View {
    let palette: Palette

    @State private var fraction: Double = 1
    @State private var seconds = 25 * 60
    @State private var onBreak = false

    private var clock: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    var body: some View {
        ZStack {
            // Drawn directly (not HabitRing, whose built-in spring would override
            // the slow linear drain) so the ring empties in step with the clock.
            Circle()
                .stroke(palette.hover, lineWidth: 12)
                .frame(width: 152, height: 152)
            Circle()
                .trim(from: 0, to: onBreak ? 1 : fraction)
                .stroke(onBreak ? Color.evrySky : palette.primary,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 152, height: 152)
            VStack(spacing: 2) {
                Label(onBreak ? "Break" : "Focus", systemImage: onBreak ? "cup.and.saucer.fill" : "timer")
                    .labelStyle(.titleAndIcon)
                    .font(.evryCaption)
                    .foregroundStyle(palette.text)
                Text(clock)
                    .font(.nunito(size: 36, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .task {
            do {
                while true {
                    onBreak = false; fraction = 1; seconds = 25 * 60
                    try await Task.sleep(for: .milliseconds(500))
                    withAnimation(.linear(duration: 2.6)) { fraction = 0 }
                    for i in 1...40 {
                        withAnimation(.snappy(duration: 0.06)) { seconds = max(0, 25 * 60 - i * 38) }
                        try await Task.sleep(for: .milliseconds(65))
                    }
                    seconds = 0
                    withAnimation(EvryMotion.spring) { onBreak = true; seconds = 5 * 60 }
                    try await Task.sleep(for: .seconds(2.0))
                }
            } catch {}
        }
    }
}

// MARK: - Page 5: Notes

private struct PromoNotesArt: View {
    let palette: Palette

    private let lineTexts = ["Farmers market", "Fix the bike", "Pick a camping spot"]

    @State private var lines = 0
    @State private var struck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(palette.primary)
                Text("Weekend")
                    .font(.evryCaption)
                    .foregroundStyle(palette.textSec)
            }
            Text("Weekend ideas")
                .font(.evryTitle)
                .foregroundStyle(palette.text)
            ForEach(Array(lineTexts.enumerated()), id: \.offset) { i, text in
                HStack(spacing: 8) {
                    EvryBullet(size: 8)
                    Text(text)
                        .font(.nunito(size: 15))
                        .foregroundStyle(i == 1 && struck ? palette.textSec : palette.text)
                        // A strikethrough that draws across the line.
                        .overlay(alignment: .leading) {
                            if i == 1 {
                                Rectangle()
                                    .fill(palette.text)
                                    .frame(height: 1.5)
                                    .scaleEffect(x: struck ? 1 : 0, anchor: .leading)
                            }
                        }
                }
                .opacity(i < lines ? 1 : 0)
                .offset(x: i < lines ? 0 : -10)
            }
        }
        .padding(20)
        .frame(width: 250, alignment: .leading)
        .promoCard(palette)
        .task {
            do {
                while true {
                    lines = 0; struck = false
                    try await Task.sleep(for: .milliseconds(500))
                    for i in 1...lineTexts.count {
                        withAnimation(EvryMotion.settle) { lines = i }
                        try await Task.sleep(for: .milliseconds(420))
                    }
                    withAnimation(.easeInOut(duration: 0.45)) { struck = true }
                    try await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.3)) { lines = 0; struck = false }
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch {}
        }
    }
}

// MARK: - Page 6: Progress

private struct PromoProgressArt: View {
    let palette: Palette

    private let targets: [CGFloat] = [0.4, 0.62, 0.48, 0.8, 0.56, 0.9, 1.0]
    @State private var tasks: Double = 0
    @State private var habits: Double = 0
    @State private var bars: [CGFloat] = Array(repeating: 0.08, count: 7)

    var body: some View {
        VStack(spacing: 14) {
            goalRow("Daily tasks", fraction: tasks)
            goalRow("Daily habits", fraction: habits)
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule()
                        .fill(i == 6 ? palette.primary : Color.evrySky)
                        .frame(height: max(6, 54 * bars[i]))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 54, alignment: .bottom)
        }
        .padding(20)
        .frame(width: 280)
        .promoCard(palette)
        .task {
            do {
                while true {
                    tasks = 0; habits = 0; bars = Array(repeating: 0.08, count: 7)
                    try await Task.sleep(for: .milliseconds(450))
                    tasks = 1
                    try await Task.sleep(for: .milliseconds(600))
                    habits = 1
                    for i in 0..<7 {
                        withAnimation(EvryMotion.settle) { bars[i] = targets[i] }
                        try await Task.sleep(for: .milliseconds(90))
                    }
                    try await Task.sleep(for: .seconds(2.4))
                }
            } catch {}
        }
    }

    private func goalRow(_ title: String, fraction: Double) -> some View {
        let reached = fraction >= 1
        return HStack(spacing: 12) {
            Image(systemName: reached ? "trophy.fill" : "trophy")
                .font(.nunito(size: 16, weight: .medium))
                .foregroundStyle(reached ? Color.evryNavy : palette.textPh)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .background(reached ? Color.evrySky : palette.skyMist,
                            in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(reached ? "Goal reached!" : title)
                    .font(.nunito(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                ProgressBarView(fraction: fraction, palette: palette)
            }
        }
        .animation(EvryMotion.settle, value: reached)
    }
}

// MARK: - Page 7: Keep everything (with vs without)

private struct PromoKeepPage: View {
    let palette: Palette
    let isHardWall: Bool

    private let items = ["Inbox & timeline", "Habits & streaks", "Distill",
                         "Pomo focus", "Notes & folders", "Goals & daily recap"]
    @State private var revealed = 0

    private var message: String {
        isHardWall
            ? "Your free trial has ended. Subscribe to pick up right where you left off — nothing you’ve built is lost."
            : "Your \(MembershipAccess.trialDays) free days include everything. After that, Evry needs a membership to keep going."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("Members")
                        .font(.evryCaption)
                        .foregroundStyle(palette.text)
                        .frame(width: 66)
                    Text("Without")
                        .font(.evryCaption)
                        .foregroundStyle(palette.textMuted)
                        .frame(width: 66)
                }
                .padding(.bottom, 6)

                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    let on = i < revealed
                    HStack {
                        Text(item)
                            .font(.nunito(size: 15))
                            .foregroundStyle(palette.text)
                        Spacer(minLength: 4)
                        EvryCheck()
                            .scaleEffect(on ? 1 : 0.2)
                            .opacity(on ? 1 : 0)
                            .frame(width: 66)
                        Image(systemName: "lock.fill")
                            .font(.nunito(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textPh)
                            .opacity(on ? 1 : 0)
                            .frame(width: 66)
                    }
                    .padding(.vertical, 8)
                    .animation(EvryMotion.spring, value: on)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item + (on ? ", included for members" : ""))
                    if i < items.count - 1 { Rectangle().fill(palette.hairline).frame(height: 1) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .promoCard(palette)
            .padding(.horizontal, EvrySpace.grid)

            VStack(spacing: 12) {
                Text(isHardWall ? "Keep everything you’ve built" : "One membership, everything")
                    .font(.evryH2)
                    .tracking(EvryTracking.h2)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(message)
                    .font(.evryBody)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, EvrySpace.card)
            .padding(.top, EvrySpace.grid)
        }
        .task {
            do {
                revealed = 0
                try await Task.sleep(for: .milliseconds(300))
                for i in 1...items.count {
                    revealed = i
                    UISelectionFeedbackGenerator().selectionChanged()
                    try await Task.sleep(for: .milliseconds(170))
                }
            } catch {}
        }
    }
}

// MARK: - Full plans sheet

struct MembershipPlansView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @AppStorage("membership_plan") private var membershipPlan = ""
    /// Monthly by default — it's the better deal.
    @State private var isMonthly = true
    @State private var showCancelConfirm = false

    private var isPro: Bool { membershipPlan == "pro" }
    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    /// The page tone with the one soft sky glow, off-canvas behind the header.
    private var glowBackground: some View {
        ZStack(alignment: .topTrailing) {
            palette.bg
            EvryGlow(onNavy: palette.dark)
                .offset(x: 160, y: -120)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // $3 a week or $6 a month.
    private var price: String  { isMonthly ? "$6" : "$3" }
    private var period: String { isMonthly ? "/mo" : "/wk" }
    private var periodWord: String { isMonthly ? "month" : "week" }
    private var savingsNote: String {
        isMonthly ? "Billed monthly. Cancel anytime." : "Billed weekly. Cancel anytime."
    }

    // Leads with the six features the promo card showcases (in the same order),
    // then the rest — so the promo and the plans page tell one consistent story.
    private let proFeatures = [
        "Natural-language quick add",
        "Swipe to schedule your day",
        "Habits with streaks and 66-day goals",
        "Distill: talk or type, get organized tasks",
        "Pomo focus and focus mode",
        "Rich notes with folders",
        "Daily goals and a morning recap",
        "Kind reminders and a daily digest",
        "Add tasks with Siri and Shortcuts",
    ]

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: EvrySpace.grid) {

                    // SectionHeading: eyebrow, h2 and a lead in textSec.
                    VStack(spacing: 16) {
                        // The full logo, with Evry perched on the plan card below.
                        EvryLogo(palette: palette, markWidth: 32)
                        Text(isPro ? "You’re all set" : "Evrything, together")
                            .font(.evryH2)
                            .tracking(EvryTracking.h2)
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                    if isPro {
                        proStatusSection
                    } else {
                        billingToggle

                        featuredPlan
                            .padding(.top, 20)   // room for the perched mascot

                        Text("Cancel anytime. Pricing in USD.")
                            .font(.nunito(size: 14))
                            .foregroundStyle(palette.textMuted)
                            .padding(.bottom, 8)
                    }
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.bottom, EvrySpace.grid)
            }
            .background(glowBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }.font(.evryLabel)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        // Over the whole screen, not just the membership section.
        .evryConfirm(
            isPresented: $showCancelConfirm,
            title: "Cancel your Evry membership?",
            // There's no billing yet (membership_plan is a local mock), so access
            // ends right away — say so. Restore the billing-period copy with StoreKit.
            message: "Your full access will end right away.",
            confirmTitle: "Yes",
            cancelTitle: "No"
        ) {
            membershipPlan = ""
            dismiss()
        }
        .onAppear {
            // Celebrate a fresh upgrade, not a status check.
            if !isPro { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    // MARK: Billing toggle

    private var billingToggle: some View {
        HStack(spacing: 0) {
            BillingToggleTab(label: "Weekly",  active: !isMonthly, palette: palette) { withAnimation(EvryMotion.settle) { isMonthly = false } }
            BillingToggleTab(label: "Monthly", active:  isMonthly, palette: palette) { withAnimation(EvryMotion.settle) { isMonthly = true  } }
        }
        .padding(4)
        .background(palette.hover, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
    }

    // MARK: Featured plan (PricingTier, featured)

    /// The navy plan panel: radius-panel, shadow-lift, white text, a sky badge,
    /// a sky button and Evry perched over the top-right corner.
    private var featuredPanelFill: Color { palette.dark ? .evryNavySoft : .evryNavy }

    private var featuredPlan: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Early adopter")
                    .font(.evryCaption)
                    .foregroundStyle(Color.evryNavy)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.evrySky, in: Capsule())
                Text("Evry membership")
                    .font(.evryH3)
                    .foregroundStyle(Color.evryWhite)
            }
            .padding(.trailing, 64)   // clear of the mascot

            // Price row
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(price)
                        .font(.evryPrice)
                        .tracking(EvryTracking.price)
                        .foregroundStyle(Color.evryWhite)
                        .contentTransition(.numericText())
                    Text(period)
                        .font(.nunito(size: 16, weight: .semibold))
                        .foregroundStyle(Color.evryWhite80)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(price) a \(periodWord)")
                Text(savingsNote)
                    .font(.nunito(size: 14))
                    .foregroundStyle(Color.evryWhite85)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(Color.evryWhite10).frame(height: 1)

            // Feature list
            VStack(alignment: .leading, spacing: 12) {
                ForEach(proFeatures, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        EvryCheck()
                        Text(feature)
                            .font(.evryBody)
                            .foregroundStyle(Color.evryWhite85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // CTA — the sky button on navy.
            Button {
                membershipPlan = "pro"
                dismiss()
            } label: {
                Text("Subscribe for \(price)\(period)")
            }
            .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
            .padding(.top, 4)
        }
        .padding(EvrySpace.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(featuredPanelFill, in: RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
        .evryShadowLift(palette)
        .overlay(alignment: .topTrailing) {
            EvryMascot(size: 76, float: true)
                .offset(x: 6, y: -30)
        }
    }

    // MARK: Pro status

    /// Shown when the user is already Pro: current status, a billing switch, and
    /// a cancel option (instead of the purchase UI).
    private var proStatusSection: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                // One line each — nothing wraps onto a second line.
                HStack(spacing: 10) {
                    Text("Evry membership")
                        .font(.evryH3)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Label("Active", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.evryCaption)
                        .foregroundStyle(Color.evryNavy)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.evrySky, in: Capsule())
                        .fixedSize()
                }
                billingToggle
                Text(savingsNote)
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textSec)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(EvrySpace.grid)
            .evryCard(palette, cornerRadius: EvryRadius.panel)

            Button(role: .destructive) { showCancelConfirm = true } label: {
                Text("Cancel membership")
            }
            .buttonStyle(EvrySecondaryButtonStyle(palette: palette, fullWidth: true))

            Text("Cancelling ends your full access right away.")
                .font(.nunito(size: 14))
                .foregroundStyle(palette.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - Billing toggle tab

private struct BillingToggleTab: View {
    let label: String
    let active: Bool
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.evryLabel)
            // Active segment: a white face with full ink (no fill colour).
            .foregroundStyle(active ? palette.text : palette.textSec)
            .frame(maxWidth: .infinity, minHeight: EvrySpace.tap)
            .background {
                if active {
                    Capsule().fill(palette.card).evryShadowSoft(palette)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
