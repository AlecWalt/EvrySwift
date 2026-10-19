//
//  PomodoroView.swift
//  Evry
//
//  Pomodoro UI — a full-screen focus experience in the app's "navy band": a
//  full navy surface with white / white-85 text, sky accents and sky / ghost-light buttons. A
//  large progress ring with a rolling countdown, a phase pill + calm line, and
//  a circular control cluster. Phases differ by their pill, glyph and words
//  (and the ring's sky strength), never by a new hue.
//
//  PomodoroContent is the embeddable core; PomodoroView wraps it in a
//  full-screen cover for the Inbox, Profile, and Path tabs.
//

import SwiftUI
import UIKit

// MARK: - Embeddable pomodoro content

struct PomodoroContent: View {
    /// Passed in (not environment-derived) so it always matches the container.
    /// PomodoroView passes the navy palette (`Palette(dark: true)`).
    let palette: Palette
    /// Called right after Start is pressed — starting a session is what drops
    /// the app into Focus Mode.
    var onStart: (() -> Void)? = nil
    /// Drives the staggered entrance. The container flips this to true once its
    /// intro (the fill-wipe) finishes, so the elements slide straight up into
    /// place rather than being inserted with a diagonal default transition.
    var animateIn: Bool = true

    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Staggered entrance + a gentle ring breath.
    @State private var appeared = false
    @State private var breathe = false

    /// The ring's ink: full sky while focusing, softer steps on breaks. The
    /// phase pill's glyph and words carry the meaning.
    private var phaseColor: Color {
        switch pomodoro.phase {
        case .work: palette.primary
        case .shortBreak: palette.primary.opacity(0.75)
        case .longBreak: palette.primary.opacity(0.55)
        }
    }

    private var phaseIcon: String {
        switch pomodoro.phase {
        case .work: "timer"
        case .shortBreak: "cup.and.saucer.fill"
        case .longBreak: "leaf.fill"
        }
    }

    private var motivation: String {
        switch pomodoro.phase {
        case .work: "One block at a time. Stay with it."
        case .shortBreak: "Breathe. Look away from the screen for a moment."
        case .longBreak: "Step away and recharge. You’ve earned it."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 14)
                .animation(EvryMotion.settle, value: appeared)

            ring
                .padding(.top, 28)
                .padding(.bottom, 32)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
                .animation(EvryMotion.settle.delay(0.08), value: appeared)

            controls
                .padding(.bottom, 36)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 16)
                .animation(EvryMotion.settle.delay(0.16), value: appeared)

            schedule
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 20)
                .animation(EvryMotion.settle.delay(0.24), value: appeared)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if !reduceMotion { breathe = true }
            // If we're already active (e.g. embedded without a wipe), run the
            // entrance now; otherwise wait for the container to flip animateIn.
            if animateIn { DispatchQueue.main.async { appeared = true } }
        }
        .onChange(of: animateIn) { _, go in
            if go { appeared = true }
        }
    }

    // MARK: Header — phase pill + encouragement

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: phaseIcon)
                    .accessibilityHidden(true)
                Text(pomodoro.phase.label)
            }
            .font(.evrySmall)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(palette.skySoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.evrySky, lineWidth: 1))
            .id(pomodoro.phase)
            .transition(.opacity)

            Text(motivation)
                .font(.evryBody)
                .foregroundStyle(palette.textSec)
                .multilineTextAlignment(.center)
                .id(motivation)                 // cross-fade when the phase changes
                .transition(.opacity)
        }
        .animation(EvryMotion.settle, value: pomodoro.phase)
    }

    // MARK: Ring

    private var ring: some View {
        let progress = pomodoro.totalDuration > 0 ? 1 - pomodoro.remaining / pomodoro.totalDuration : 0

        return ZStack {
            Circle()
                .stroke(palette.border, lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(phaseColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: progress)
                .animation(EvryMotion.settle, value: pomodoro.phase)

            VStack(spacing: 6) {
                Text(pomodoro.timeLabel)
                    .font(.nunito(size: 56, weight: .heavy))
                    .tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy(duration: 0.3), value: pomodoro.timeLabel)

                Text("\(pomodoro.completedSessions) session\(pomodoro.completedSessions == 1 ? "" : "s") done")
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textMuted)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: pomodoro.completedSessions)
            }
        }
        .frame(width: 260, height: 260)
        // A slow, calm breath so it feels alive (off under Reduce Motion).
        .scaleEffect(breathe ? 1.015 : 1)
        .animation(breathe ? .easeInOut(duration: 2.6).repeatForever(autoreverses: true) : nil, value: breathe)
        .accessibilityElement(children: .combine)
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

            // Primary Start / Pause — the sky disc (the main action on navy).
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
                        .fill(palette.primary)
                        .frame(width: 82, height: 82)
                        .evryShadowButton(palette)
                    Image(systemName: pomodoro.running ? "pause.fill" : "play.fill")
                        .font(.nunito(size: 30, weight: .bold))
                        .foregroundStyle(palette.onPrimary)
                        .contentTransition(.symbolEffect(.replace))
                        // play.fill is visually right-heavy; nudge it to optical center.
                        .offset(x: pomodoro.running ? 0 : 2)
                }
            }
            .buttonStyle(PressScaleStyle(scale: 0.93))
            .accessibilityLabel(pomodoro.running ? "Pause" : "Start")

            circleControl("forward.fill", "Skip") {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                withAnimation { pomodoro.skip() }
            }
        }
    }

    /// A ghost-light round control: clear fill, white-35 ring, white glyph.
    private func circleControl(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.nunito(size: 18, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 56, height: 56)
                    .overlay(Circle().strokeBorder(ghostBorder, lineWidth: 1))
                    .contentShape(Circle())
                Text(label)
                    .font(.evryCaption)
                    .foregroundStyle(palette.textMuted)
            }
        }
        .buttonStyle(PressScaleStyle(scale: 0.93))
    }

    private func loopStepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.nunito(size: 14, weight: .bold))
                .foregroundStyle(palette.primary)
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Control outlines: white-35 on navy (the ghost-light border), navy-16 on light.
    private var ghostBorder: Color { palette.dark ? .evryWhite35 : palette.border }

    // MARK: Schedule + loops

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Schedule")
                    .font(.evrySmall)
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 4)

                HStack(spacing: 8) {
                    ForEach(PomodoroPreset.all) { preset in
                        let active = pomodoro.preset == preset
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(EvryMotion.settle) {
                                pomodoro.selectPreset(preset)
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Text(preset.label)
                                    .font(.evrySmall)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text("\(preset.workMin)/\(preset.shortBreakMin) min")
                                    .font(.nunito(size: 12))
                            }
                            // Active preset: the sky fill with navy ink; others are
                            // ghost-light faces on navy.
                            .foregroundStyle(active ? palette.onSky : palette.text)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(active ? palette.sky : .clear,
                                        in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous)
                                .strokeBorder(active ? Color.clear : ghostBorder, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
                        }
                        .buttonStyle(PressScaleStyle(scale: 0.96))
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Loops")
                    .font(.evrySmall)
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 4)

                HStack(spacing: 12) {
                    Text(pomodoro.targetSessions == 0
                         ? "Unlimited"
                         : "\(pomodoro.targetSessions) loop\(pomodoro.targetSessions == 1 ? "" : "s")")
                        .font(.evryLabel)
                        .foregroundStyle(palette.text)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: pomodoro.targetSessions)
                    Spacer()
                    HStack(spacing: 0) {
                        loopStepButton("minus", label: "Fewer loops") {
                            pomodoro.setTargetSessions(max(0, pomodoro.targetSessions - 1))
                        }
                        Rectangle().fill(ghostBorder).frame(width: 1, height: 22)
                        loopStepButton("plus", label: "More loops") {
                            pomodoro.setTargetSessions(min(12, pomodoro.targetSessions + 1))
                        }
                    }
                    .overlay(Capsule().strokeBorder(ghostBorder, lineWidth: 1))
                }
                .padding(.leading, 20)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(ghostBorder, lineWidth: 1))
            }
        }
        .frame(maxWidth: 380)
    }
}

// MARK: - Full-screen cover (Inbox, Profile, Path tabs)

struct PomodoroView: View {
    /// Called right after Start is pressed — the cover closes itself first.
    var onStart: (() -> Void)? = nil
    /// Screen point the fill-wipe grows from (the tapped tool bubble). Nil falls
    /// back to the top-right corner.
    var fillOrigin: CGPoint? = nil

    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    // Fill-wipe intro: sky sweeps out, the navy
    // surface sweeps over it, then content appears.
    @State private var appeared = false
    @State private var loading = true
    @State private var accentFill: CGFloat = 0
    @State private var bgFill: CGFloat = 0
    // Fades the whole screen out on close, with the cover's
    // own slide suppressed so it reads as a dissolve rather than a pan-down.
    @State private var closing = false

    // First-run explainer: shown the very first time Pomo Focus is opened.
    @AppStorage("pomodoro_intro_seen") private var introSeen = false
    @State private var showIntro = false

    /// The focus screen is the brand's navy band in both light and dark mode:
    /// navy surface, white / white-85 text, sky accents.
    private let palette = Palette(dark: true)

    var body: some View {
        NavigationStack {
            ZStack {
            ScrollView {
                // Always present so its elements slide straight up when the wipe
                // finishes (animateIn), rather than the whole block being inserted
                // with a diagonal default transition.
                PomodoroContent(
                    palette: palette,
                    onStart: onStart.map { startCallback in { close(then: startCallback) } },
                    animateIn: appeared
                )
                .padding(.horizontal, EvrySpace.grid)
                .padding(.top, 8)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
            .opacity(closing ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // Only add the button (and its system background) once the content
                // has appeared — so it doesn't show during the fill-wipe.
                if appeared {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { close() } label: {
                            Image(systemName: "xmark")
                                .font(.nunito(size: 15, weight: .bold))
                        }
                        .accessibilityLabel("Close")
                    }
                }
                ToolbarItem(placement: .principal) {
                    EyebrowPill(text: "Pomodoro", palette: palette)
                        .opacity(appeared ? 1 : 0)
                        .accessibilityAddTraits(.isHeader)
                }
            }

            // First-run explainer, over everything.
            if showIntro {
                introScreen
                    .transition(.opacity)
                    .zIndex(100)
            }
            }
            // Hide the nav bar (and its X / title) while the explainer is up.
            .toolbar(showIntro ? .hidden : .automatic, for: .navigationBar)
        }
        // System controls (nav items, scroll bounce tint) render as on-navy.
        .environment(\.colorScheme, .dark)
        .overlay { if loading { fillLoader } }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.42)) { accentFill = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.easeInOut(duration: 0.42)) { bgFill = 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                loading = false
                // First open ever → show the explainer first and hold the tool's
                // own entrance until it's dismissed, so the timer doesn't animate
                // in behind (and clip through) the popup.
                if introSeen {
                    withAnimation(.easeOut(duration: 0.35)) { appeared = true }
                } else {
                    withAnimation(.easeOut(duration: 0.35)) { showIntro = true }
                }
            }
        }
    }

    /// Two stacked fills growing from the origin: sky first, then the navy
    /// surface over it.
    private var fillLoader: some View {
        ZStack {
            CornerFillShape(progress: accentFill, origin: fillOrigin).fill(Color.evrySky)
            CornerFillShape(progress: bgFill, origin: fillOrigin).fill(palette.bg)
        }
        .ignoresSafeArea()
    }

    /// Fades the screen out, then removes the cover with its slide suppressed —
    /// the mirror of the fade-in.
    private func close(then: (() -> Void)? = nil) {
        withAnimation(.easeIn(duration: 0.22)) { closing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { dismiss() }
            then?()
        }
    }

    // MARK: First-run explainer

    private func dismissIntro() {
        introSeen = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.3)) { showIntro = false }
        // Play the timer's entrance only after the popup has fully faded out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        }
    }

    /// One-time screen shown on the first Pomo Focus open: what it is + how it
    /// works.
    private var introScreen: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            EvryGlow(onNavy: true)
                .offset(x: 140, y: -260)
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                EvryMascot(size: 96, float: true)

                Text("Pomodoro")
                    .font(.evryH2)
                    .tracking(EvryTracking.h2)
                    .foregroundStyle(palette.text)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)

                Text("Work in short, focused sprints with gentle breaks in between.")
                    .font(.evryLead)
                    .lineSpacing(4)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)

                VStack(spacing: 20) {
                    introStep("play.fill", "Start a sprint",
                              "Pick a length and press start. The timer counts down while you focus on one thing.")
                    introStep("cup.and.saucer.fill", "Take a break",
                              "When the sprint ends, Evry reminds you to rest, then starts the next round.")
                    introStep("chart.bar.fill", "Watch it add up",
                              "Every finished sprint adds to your focus time. No pressure, just progress.")
                }
                .padding(.top, 34)
                .padding(.horizontal, 30)

                Spacer(minLength: 12)

                Button { dismissIntro() } label: {
                    Text("Open the timer")
                }
                .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
                .padding(.horizontal, EvrySpace.grid)
                .padding(.bottom, 40)
            }
        }
    }

    private func introStep(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.nunito(size: 18, weight: .semibold))
                .foregroundStyle(palette.onSky)
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .background(palette.sky, in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.evryLabel)
                    .foregroundStyle(palette.text)
                Text(desc)
                    .font(.nunito(size: 14))
                    .lineSpacing(2)
                    .foregroundStyle(palette.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Full screen") {
    PomodoroView()
        .environment(Appearance())
        .environment(PomodoroModel())
}
