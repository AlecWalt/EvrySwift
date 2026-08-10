//
//  PomodoroView.swift
//  Evry
//
//  Pomodoro UI — phase label, progress ring, Start/Pause/Reset/Skip controls
//  and schedule presets, ported from the webapp's renderPomodoroTab
//  (js/extraTabs.js). Ring color: accent while focusing, green on short
//  breaks, indigo on long breaks.
//
//  PomodoroContent is the embeddable core; the Focus tab shows it front and
//  center (FocusTabView), and PomodoroView wraps it in a sheet for the
//  Profile tab and the in-Focus-Mode status card.
//

import SwiftUI
import UIKit

// MARK: - Embeddable pomodoro content

struct PomodoroContent: View {
    /// Passed in (not environment-derived) so it always matches the
    /// container this is embedded in.
    let palette: Palette
    /// Called right after Start is pressed — starting a session is what
    /// drops the app into Focus Mode.
    var onStart: (() -> Void)? = nil

    @Environment(PomodoroModel.self) private var pomodoro

    private var phaseColor: Color {
        switch pomodoro.phase {
        case .work: palette.primary
        case .shortBreak: Palette.success
        case .longBreak: Color(hex: 0x6366F1)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(pomodoro.phase.label.uppercased())
                .font(.system(size: 12.5, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(phaseColor)
                .padding(.top, 24)
                .padding(.bottom, 20)

            ring
                .padding(.bottom, 28)

            controls
                .padding(.bottom, 32)

            schedule
        }
        .frame(maxWidth: .infinity)
    }

    private var ring: some View {
        let progress = pomodoro.totalDuration > 0 ? 1 - pomodoro.remaining / pomodoro.totalDuration : 0

        return ZStack {
            Circle()
                .stroke(palette.border, lineWidth: 10)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(phaseColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: progress)

            VStack(spacing: 4) {
                Text(pomodoro.timeLabel)
                    .font(.system(size: 40, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
                Text("\(pomodoro.completedSessions) session\(pomodoro.completedSessions == 1 ? "" : "s") done")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
            }
        }
        .frame(width: 220, height: 220)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            secondaryButton("Reset") {
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                    gen.impactOccurred(intensity: 0.5)
                }
                pomodoro.reset()
            }

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
                Text(pomodoro.running ? "Pause" : "Start")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(palette.primary, in: Capsule())
            }
            .buttonStyle(PressScaleStyle(scale: 0.97))

            secondaryButton("Skip") {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                pomodoro.skip()
            }
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textSec)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1.5))
        }
        .buttonStyle(PressScaleStyle(scale: 0.97))
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Preset picker
            VStack(alignment: .leading, spacing: 8) {
                Text("SCHEDULE")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 4)

                VStack(spacing: 8) {
                    ForEach(PomodoroPreset.all) { preset in
                        let active = pomodoro.preset == preset
                        Button {
                            pomodoro.selectPreset(preset)
                        } label: {
                            Text("\(preset.workMin)/\(preset.shortBreakMin)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(active ? palette.primary : palette.textSec)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(active ? palette.primaryLight : palette.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(active ? palette.primary : palette.border, lineWidth: 1.5))
                        }
                        .buttonStyle(PressScaleStyle(scale: 0.97))
                    }
                }
            }

            // Sessions target
            VStack(alignment: .leading, spacing: 8) {
                Text("SESSIONS")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 4)

                HStack(spacing: 6) {
                    ForEach([0, 1, 2, 3, 4], id: \.self) { n in
                        let active = pomodoro.targetSessions == n
                        Button {
                            pomodoro.setTargetSessions(n)
                        } label: {
                            Text(n == 0 ? "∞" : "\(n)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(active ? palette.primary : palette.textSec)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(active ? palette.primaryLight : palette.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(active ? palette.primary : palette.border, lineWidth: 1.5))
                        }
                        .buttonStyle(PressScaleStyle(scale: 0.97))
                    }
                }
            }
        }
        .frame(maxWidth: 360)
    }
}

// MARK: - Focus tab (landing page — "Enter Focus Mode" button opens the sheet)

struct FocusTabView: View {
    let palette: Palette
    var onEnterFocusMode: () -> Void

    @State private var showPomodoro = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(palette.primary)
                    .padding(.bottom, 4)
                Text("Focus Mode")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(palette.text)
                Text("Start a Pomodoro session to enter\na distraction-free focus environment.")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                showPomodoro = true
            } label: {
                Text("Enter Focus Mode")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(palette.primary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.97))
            .padding(.horizontal, 24)
            .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
        .sheet(isPresented: $showPomodoro) {
            PomodoroView(onStart: onEnterFocusMode)
        }
    }
}

// MARK: - Sheet wrapper (Profile tab, Focus Mode status card)

struct PomodoroView: View {
    /// Called right after Start is pressed — the sheet closes itself first.
    var onStart: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            ScrollView {
                PomodoroContent(palette: palette, onStart: onStart.map { startCallback in
                    { dismiss(); startCallback() }
                })
                .padding(20)
            }
            .background(palette.bg)
            .navigationTitle("Pomodoro")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
    }
}

#Preview("Focus tab") {
    FocusTabView(palette: Palette(dark: false, accent: .byKey("default")), onEnterFocusMode: {})
        .environment(Appearance())
        .environment(PomodoroModel())
}

#Preview("Sheet") {
    PomodoroView()
        .environment(Appearance())
        .environment(PomodoroModel())
}
