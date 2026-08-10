//
//  GuideTourView.swift
//  Evry
//
//  Interactive app guide — switches tabs, shows live sample content, highlights
//  the current tab icon with a pulsing glow, and explains each section with a
//  frosted-glass tooltip card. No dark overlay; the full app is always visible.
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
            title: "Welcome to Evry 👋",
            body: "Your all-in-one task manager. Let's take a quick look at each section — tap Next to walk through them."
        ),
        TourStep(
            tab: .inbox,
            title: "Inbox",
            body: "Your daily task list, sorted by date. Overdue items float to the top automatically. Swipe a task right to complete it, or left to delete."
        ),
        TourStep(
            tab: .focus,
            title: "Focus",
            body: "Start a Pomodoro timer for distraction-free work blocks. Your highest-priority tasks show up here so you always know what's next."
        ),
        TourStep(
            tab: .projects,
            title: "Projects",
            body: "Group related tasks into a Project. Each card shows a live progress bar. Tap to open, long-press to reorder."
        ),
        TourStep(
            tab: .calendar,
            title: "Calendar",
            body: "See all your tasks plotted by due date. Tap any day to view what's scheduled. Tasks with due dates appear here automatically."
        ),
        TourStep(
            tab: .profile,
            title: "Profile",
            body: "Track your streaks and completion rate. Use the search icon to find any task or project instantly. Tap the gear to customise the app."
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

    @State private var pulse = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var step: TourStep { coordinator.steps[coordinator.currentStep] }

    // Fixed tab order matching ContentView's TabView declaration.
    private let tabOrder: [AppTab] = [.inbox, .focus, .projects, .calendar, .profile]

    private var activeTabIndex: Int { tabOrder.firstIndex(of: step.tab) ?? 0 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Absorb taps on the app content so the user stays on the tour path.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .ignoresSafeArea()

                // Pulsing glow ring around the current tab icon.
                tabGlow(geo: geo)
                    .allowsHitTesting(false)

                // Frosted-glass tooltip card pinned just below the status bar.
                VStack(spacing: 0) {
                    tooltipCard
                        .padding(.horizontal, 14)
                        .padding(.top, geo.safeAreaInsets.top + 6)
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: coordinator.currentStep)
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
            // Expanding pulse ring
            Circle()
                .fill(palette.primary.opacity(0.22))
                .frame(width: 58, height: 58)
                .scaleEffect(pulse ? 1.55 : 1.0)
                .opacity(pulse ? 0 : 1)

            // Solid accent ring
            Circle()
                .strokeBorder(palette.primary, lineWidth: 2.5)
                .frame(width: 42, height: 42)

            // Tinted fill
            Circle()
                .fill(palette.primary.opacity(0.14))
                .frame(width: 42, height: 42)
        }
        .position(x: x, y: y)
    }

    // MARK: Tooltip card

    private var tooltipCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(step.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                Spacer()
                Button { coordinator.end() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(step.body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                // Step dots
                HStack(spacing: 5) {
                    ForEach(0..<coordinator.steps.count, id: \.self) { i in
                        Capsule()
                            .fill(i == coordinator.currentStep ? palette.primary : Color.secondary.opacity(0.3))
                            .frame(width: i == coordinator.currentStep ? 18 : 5, height: 5)
                            .animation(.spring(response: 0.3), value: coordinator.currentStep)
                    }
                }
                Spacer()
                Button(coordinator.currentStep == coordinator.steps.count - 1 ? "Done" : "Next →") {
                    coordinator.advance()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.onPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(palette.primary, in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(palette.primary.opacity(0.35), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 28, y: 6)
    }

    // MARK: Pulse helpers

    private func startPulse() {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }

    private func resetPulse() {
        pulse = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { startPulse() }
    }
}
