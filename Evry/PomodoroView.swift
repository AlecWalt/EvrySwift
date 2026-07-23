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
            secondaryButton("Reset") { pomodoro.reset() }

            Button {
                if pomodoro.running {
                    pomodoro.pause()
                } else {
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

            secondaryButton("Skip") { pomodoro.skip() }
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
                        pomodoro.selectPreset(preset)
                    } label: {
                        Text(preset.label)
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
        .frame(maxWidth: 360)
    }
}

// MARK: - Focus tab (PathView with pomodoro widget)

struct FocusTabView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void

    var body: some View {
        PathView(
            palette: palette,
            onEdit: onEdit,
            onDelete: onDelete,
            inFocusMode: false
        )
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
                PomodoroContent(palette: palette, onStart: {
                    dismiss()
                    onStart?()
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
    FocusTabView(palette: Palette(dark: false, accent: .byKey("default")), onEdit: { _ in }, onDelete: { _ in })
        .environment(Appearance())
        .environment(PomodoroModel())
}

#Preview("Sheet") {
    PomodoroView()
        .environment(Appearance())
        .environment(PomodoroModel())
}
