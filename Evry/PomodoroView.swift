//
//  PomodoroView.swift
//  Evry
//
//  Pomodoro UI — a full-screen focus experience styled after the Brain Dump
//  screen: accent-gradient backdrop, a large glowing progress ring with a
//  rolling countdown, animated phase + encouragement text, and a circular
//  control cluster. Ring/phase color: accent while focusing, green on short
//  breaks, indigo on long breaks.
//
//  PomodoroContent is the embeddable core; PomodoroView wraps it in a
//  full-screen cover for the Inbox, Profile, and Path tabs.
//

import SwiftUI
import UIKit

// MARK: - Embeddable pomodoro content

struct PomodoroContent: View {
    /// Passed in (not environment-derived) so it always matches the container.
    let palette: Palette
    /// Called right after Start is pressed — starting a session is what drops
    /// the app into Focus Mode.
    var onStart: (() -> Void)? = nil

    @Environment(PomodoroModel.self) private var pomodoro

    // Staggered entrance + a gentle ring breath.
    @State private var appeared = false
    @State private var breathe = false

    private var phaseColor: Color {
        switch pomodoro.phase {
        case .work: palette.primary
        case .shortBreak: Palette.success
        case .longBreak: Color(hex: 0x6366F1)
        }
    }
    private var onPhaseColor: Color { pomodoro.phase == .work ? palette.onPrimary : .white }

    private var motivation: String {
        switch pomodoro.phase {
        case .work: "One block at a time — stay with it."
        case .shortBreak: "Breathe. Look away from the screen."
        case .longBreak: "Step away and recharge."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: appeared)

            ring
                .padding(.top, 30)
                .padding(.bottom, 34)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.9)
                .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.08), value: appeared)

            controls
                .padding(.bottom, 36)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.16), value: appeared)

            schedule
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)
                .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.24), value: appeared)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            breathe = true
            DispatchQueue.main.async { appeared = true }
        }
    }

    // MARK: Header — phase pill + encouragement

    private var header: some View {
        VStack(spacing: 10) {
            Text(pomodoro.phase.label.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(1)
                .foregroundStyle(phaseColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(phaseColor.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(phaseColor.opacity(0.35), lineWidth: 1))
                .contentTransition(.opacity)

            Text(motivation)
                .font(.system(size: 14))
                .foregroundStyle(palette.textSec)
                .multilineTextAlignment(.center)
                .id(motivation)                 // cross-fade when the phase changes
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.4), value: pomodoro.phase)
    }

    // MARK: Ring

    private var ring: some View {
        let progress = pomodoro.totalDuration > 0 ? 1 - pomodoro.remaining / pomodoro.totalDuration : 0

        return ZStack {
            Circle()
                .stroke(palette.border.opacity(0.5), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(phaseColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: progress)
                .animation(.easeInOut(duration: 0.4), value: pomodoro.phase)

            VStack(spacing: 6) {
                Text(pomodoro.timeLabel)
                    .font(.system(size: 54, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.3), value: pomodoro.timeLabel)

                Text("\(pomodoro.completedSessions) session\(pomodoro.completedSessions == 1 ? "" : "s") done")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.textSec)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: pomodoro.completedSessions)
            }
        }
        .frame(width: 260, height: 260)
        // Soft phase-colored glow — brighter while the timer is running. Kept
        // restrained so it reads as a halo, not a bloom.
        .shadow(color: phaseColor.opacity(pomodoro.running ? 0.2 : 0.07),
                radius: pomodoro.running ? 16 : 8)
        .animation(.easeInOut(duration: 0.5), value: pomodoro.running)
        // A slow, calm breath so it feels alive.
        .scaleEffect(breathe ? 1.015 : 0.99)
        .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: breathe)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 34) {
            circleControl("arrow.counterclockwise", "Reset") {
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { gen.impactOccurred(intensity: 0.5) }
                withAnimation { pomodoro.reset() }
            }

            // Primary Start / Pause — a big phase-colored disc.
            Button {
                if pomodoro.running {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    pomodoro.pause()
                } else {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    pomodoro.start()
                    onStart?()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 82, height: 82)
                        .shadow(color: phaseColor.opacity(0.3), radius: 9, y: 4)
                    Image(systemName: pomodoro.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(onPhaseColor)
                        .contentTransition(.symbolEffect(.replace))
                        // play.fill is visually right-heavy; nudge it to optical center.
                        .offset(x: pomodoro.running ? 0 : 2)
                }
            }
            .buttonStyle(PressScaleStyle(scale: 0.93))

            circleControl("forward.fill", "Skip") {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                withAnimation { pomodoro.skip() }
            }
        }
    }

    private func circleControl(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .frame(width: 56, height: 56)
                    .background(palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(palette.border, lineWidth: 1.5))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPh)
            }
        }
        .buttonStyle(PressScaleStyle(scale: 0.93))
    }

    private func loopStepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Schedule + loops

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SCHEDULE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    ForEach(PomodoroPreset.all) { preset in
                        let active = pomodoro.preset == preset
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                pomodoro.selectPreset(preset)
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Text(preset.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(active ? palette.primary : palette.text)
                                Text("\(preset.workMin)/\(preset.shortBreakMin)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(active ? palette.primary.opacity(0.8) : palette.textSec)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(active ? palette.primaryLight : palette.card,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(active ? palette.primary : palette.border, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(PressScaleStyle(scale: 0.96))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("LOOPS")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 4)

                HStack(spacing: 12) {
                    Text(pomodoro.targetSessions == 0
                         ? "Unlimited"
                         : "\(pomodoro.targetSessions) loop\(pomodoro.targetSessions == 1 ? "" : "s")")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: pomodoro.targetSessions)
                    Spacer()
                    HStack(spacing: 0) {
                        loopStepButton("minus") {
                            pomodoro.setTargetSessions(max(0, pomodoro.targetSessions - 1))
                        }
                        Rectangle().fill(palette.border).frame(width: 1, height: 22)
                        loopStepButton("plus") {
                            pomodoro.setTargetSessions(min(12, pomodoro.targetSessions + 1))
                        }
                    }
                    .background(palette.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1.5))
            }
        }
        .frame(maxWidth: 380)
    }
}

// MARK: - Full-screen cover (Inbox, Profile, Path tabs)

struct PomodoroView: View {
    /// Called right after Start is pressed — the cover closes itself first.
    var onStart: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var appeared = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            ScrollView {
                PomodoroContent(palette: palette, onStart: onStart.map { startCallback in
                    { dismiss(); startCallback() }
                })
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(accentBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Pomodoro")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(palette.text)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        // Fade the whole cover in over the accent backdrop.
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.3)) { appeared = true } }
    }

    /// The selected accent color washes down from the top into the neutral app
    /// background — matching the Brain Dump screen's atmosphere.
    private var accentBackground: some View {
        ZStack {
            palette.bg
            LinearGradient(
                colors: [palette.primary.opacity(palette.dark ? 0.26 : 0.18),
                         palette.primary.opacity(0.04), .clear],
                startPoint: .top, endPoint: .center
            )
            RadialGradient(
                colors: [palette.primary.opacity(0.12), .clear],
                center: .init(x: 0.5, y: 0.08), startRadius: 0, endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

#Preview("Full screen") {
    PomodoroView()
        .environment(Appearance())
        .environment(PomodoroModel())
}
