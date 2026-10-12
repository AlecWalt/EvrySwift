//
//  GuideTourView.swift
//  Evry
//
//  Interactive app guide — switches tabs, shows live sample content, highlights
//  the current tab icon with a soft sky ring, and explains each section in
//  Evry's own words from a card pinned to the top. No dark overlay; the full
//  app is always visible.
//

import SwiftUI

// MARK: - Tour step

struct TourStep {
    let tab: AppTab
    let title: String
    let body: String
}

// MARK: - Coordinator

@Observable
final class TourCoordinator {
    var isActive = false
    var currentStep = 0

    let steps: [TourStep] = [
        TourStep(
            tab: .inbox,
            title: "Hi, I’m Evry",
            body: "I keep your tasks, habits and notes together in one calm place. Shall I show you around?"
        ),
        TourStep(
            tab: .inbox,
            title: "Inbox",
            body: "I sort your tasks by day here, and anything overdue rises to the top. Swipe a task right to finish it, or left to delete it."
        ),
        TourStep(
            tab: .habits,
            title: "Habits",
            body: "Create a habit and tap its circle each time you do it. I’ll keep track of your streaks and your week for you."
        ),
        TourStep(
            tab: .notes,
            title: "Notes",
            body: "Jot down anything here. Sort notes into folders and pin the ones you reach for most. Swipe left to delete, right to pin."
        ),
        TourStep(
            tab: .profile,
            title: "Profile",
            body: "Your streaks and progress live here. Tap search to find any task, or the gear to adjust Evry. Ready to start?"
        ),
    ]

    var currentTab: AppTab { steps[currentStep].tab }

    func start() { currentStep = 0; isActive = true }

    func advance() {
        if currentStep < steps.count - 1 { currentStep += 1 }
        else { isActive = false }
    }

    func end() { isActive = false }
}

// MARK: - Overlay

struct TourOverlayView: View {
    @Environment(TourCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulse = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var step: TourStep { coordinator.steps[coordinator.currentStep] }
    private var isLastStep: Bool { coordinator.currentStep == coordinator.steps.count - 1 }

    @AppStorage("tab_inbox_visible")    private var tabInbox    = true
    @AppStorage("tab_habits_visible")   private var tabHabits   = true
    @AppStorage("tab_calendar_visible") private var tabCalendar = false
    @AppStorage("tab_notes_visible")    private var tabNotes    = true

    // Visible tabs, in ContentView's TabView declaration order, so the glow
    // lands on the right icon whatever the Layout settings are.
    private var tabOrder: [AppTab] {
        let all: [(AppTab, Bool)] = [(.inbox, tabInbox), (.habits, tabHabits), (.calendar, tabCalendar),
                                     (.notes, tabNotes), (.profile, true)]
        return all.filter(\.1).map(\.0)
    }

    private var activeTabIndex: Int { tabOrder.firstIndex(of: step.tab) ?? 0 }

    /// The tool a step is about, so its tile can sit beside the title. The
    /// welcome and profile steps are Evry's own, so they show no tool tile.
    private var stepTool: EvryTool? {
        guard coordinator.currentStep > 0 else { return nil }
        switch step.tab {
        case .inbox:    return .tasks
        case .habits:   return .habits
        case .notes:    return .notes
        case .calendar: return .calendar
        case .profile:  return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Absorb taps on the app content so the user stays on the tour path.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .ignoresSafeArea()

                // Soft ring around the current tab icon.
                tabGlow(geo: geo)
                    .allowsHitTesting(false)

                // Tooltip card pinned just below the status bar.
                VStack(spacing: 0) {
                    tooltipCard
                        .padding(.horizontal, EvrySpace.gutter)
                        .padding(.top, geo.safeAreaInsets.top + 8)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : EvryMotion.settle, value: coordinator.currentStep)
        .onAppear { startPulse() }
        .onChange(of: coordinator.currentStep) { _, _ in resetPulse() }
    }

    // MARK: Tab glow

    private func tabGlow(geo: GeometryProxy) -> some View {
        let count = CGFloat(tabOrder.count)
        let x = (CGFloat(activeTabIndex) + 0.5) / count * geo.size.width
        // Tab icons sit 24 pt above the home-indicator safe area.
        let y = geo.size.height - geo.safeAreaInsets.bottom - 24

        return ZStack {
            // Expanding pulse ring (off under Reduce Motion).
            Circle()
                .fill(Color.evrySky.opacity(0.55))
                .frame(width: 58, height: 58)
                .scaleEffect(pulse ? 1.55 : 1.0)
                .opacity(reduceMotion ? 0 : (pulse ? 0 : 1))

            // Soft sky disc with a navy ring.
            Circle()
                .fill(Color.evrySky.opacity(0.35))
                .frame(width: 44, height: 44)
            Circle()
                .strokeBorder(palette.primary, lineWidth: 2)
                .frame(width: 44, height: 44)
        }
        .position(x: x, y: y)
    }

    // MARK: Tooltip card

    private var tooltipCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if let stepTool {
                    ToolIcon(tool: stepTool, tile: 32, palette: palette)
                }
                Text(step.title)
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { coordinator.end() } label: {
                    Image(systemName: "xmark")
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .frame(width: 32, height: 32)
                        .background(palette.hover, in: Circle())
                        .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the tour")
            }

            TourBubble(text: step.body, palette: palette)

            HStack(spacing: 8) {
                // Step dots
                HStack(spacing: 6) {
                    ForEach(0..<coordinator.steps.count, id: \.self) { i in
                        Capsule()
                            .fill(i == coordinator.currentStep ? palette.primary : palette.border)
                            .frame(width: i == coordinator.currentStep ? 20 : 8, height: 8)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(coordinator.currentStep + 1) of \(coordinator.steps.count)")
                Spacer()
                Button {
                    coordinator.advance()
                } label: {
                    HStack(spacing: 6) {
                        Text(isLastStep ? "Start using Evry" : "Next")
                        if !isLastStep {
                            Image(systemName: "arrow.right")
                                .font(.nunito(size: 14, weight: .bold))
                        }
                    }
                }
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
            }
        }
        .padding(EvrySpace.grid)
        .evryField(palette, cornerRadius: EvryRadius.card)
        .evryShadowLift(palette)
    }

    // MARK: Pulse helpers

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }

    private func resetPulse() {
        pulse = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { startPulse() }
    }
}

// MARK: - Tour bubble

/// Evry's line in the tour: the mascot beside a sky-soft bubble (1pt sky ring,
/// tail bottom-left), matching `EvryBubble`. Kept local because `EvryBubble`
/// sizes its bubble to 85% of the *screen* width, which overflows an inset card.
private struct TourBubble: View {
    let text: String
    let palette: Palette

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: EvryRadius.field, bottomLeadingRadius: EvryRadius.tail,
                               bottomTrailingRadius: EvryRadius.field, topTrailingRadius: EvryRadius.field,
                               style: .continuous)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            EvryMascot(size: 40)
            Text(text)
                .font(.evryBubble)
                .lineSpacing(5)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.skySoft, in: shape)
                .overlay(shape.strokeBorder(Color.evrySky, lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Evry says: " + text)
    }
}
