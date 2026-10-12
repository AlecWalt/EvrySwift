//
//  Components.swift
//  Evry
//
//  Shared building blocks built on the Evry Design System tokens (Theme.swift):
//  chips, section labels, progress bar, icon buttons, cards, buttons, eyebrows,
//  the mascot, tool icons, speech bubbles, empty states.
//

import SwiftUI
import UIKit

// MARK: - Corner fill (screen-transition wipe)

/// A fill that expands as a disc from an `origin` point, covering `progress`
/// (0→1) of its own rect. When no origin is given it starts at the top-right
/// corner. Used as Brain Dump / Pomodoro's fill-wipe intro — passing the tapped
/// tool bubble's position makes the wipe grow out of that bubble.
struct CornerFillShape: Shape {
    var progress: CGFloat
    /// Disc origin in the shape's own coordinate space; nil = top-right corner.
    var origin: CGPoint? = nil

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard progress > 0 else { return p }
        let o = origin ?? CGPoint(x: rect.maxX, y: rect.minY)
        // Reach the farthest rect corner from the origin so the disc fully covers
        // the screen at progress 1 (1.03 clears any rounding).
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
        let maxR = (corners.map { hypot($0.x - o.x, $0.y - o.y) }.max() ?? 0) * 1.03
        p.addArc(center: o, radius: maxR * min(1, progress),
                 startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        return p
    }
}

// MARK: - Palette access

/// Convenience for views: builds the current palette from the environment.
struct PaletteReader<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @ViewBuilder var content: (Palette) -> Content

    var body: some View {
        content(Palette(dark: scheme == .dark, accent: appearance.accent))
    }
}

// MARK: - Chip

/// Pill chip (12pt medium, 2x8 padding) — tags, priority, recurrence.
struct ChipView: View {
    let text: String
    let foreground: Color
    var background: Color?

    var body: some View {
        Text(text)
            .font(.nunito(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, background == nil ? 0 : 8)
            .padding(.vertical, background == nil ? 0 : 2)
            .foregroundStyle(foreground)
            .background(background ?? .clear, in: Capsule())
    }
}

/// Date chip — text only. Urgency is carried by weight and the alert glyph
/// (the design system has no red): overdue shows the alert icon in bold.
struct DateChip: View {
    let date: Date
    let palette: Palette

    var body: some View {
        if let category = dateCategory(date), let label = formatDueDate(date) {
            HStack(spacing: 3) {
                if category == .overdue {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.nunito(size: 11, weight: .bold))
                        .accessibilityLabel("Overdue")
                }
                Text(label)
                    .font(.nunito(size: 12, weight: category == .overdue || category == .today ? .bold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(palette.dateColor(category))
        }
    }
}

// MARK: - Section label

/// Bold sentence-case group label ("Overdue", "Completed", …) — text-sm.
/// The design system never uppercases labels. `danger` marks an urgent group
/// with the alert glyph instead of a colour.
struct SectionLabel: View {
    let text: String
    let palette: Palette
    var danger = false

    var body: some View {
        HStack(spacing: 5) {
            if danger {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.nunito(size: 12, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text.evrySentenceCased)
                .font(.nunito(size: 14, weight: .bold))
        }
        .foregroundStyle(danger ? palette.text : palette.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }
}

// MARK: - Page title

/// The app's standard page title: a text-h2 heavy, tight line with an optional
/// supporting subtitle and an optional eyebrow-style pill (e.g. "Today"). Used
/// across the Timeline, Calendar, and Notes headers so every page reads the same.
struct PageTitle: View {
    let title: String
    var subtitle: String? = nil
    /// Small eyebrow pill shown beside the subtitle (e.g. "Today").
    var badge: String? = nil
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.evryH2)
                .tracking(EvryTracking.h2)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .contentTransition(.opacity)

            if subtitle != nil || badge != nil {
                HStack(spacing: 8) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.nunito(size: 14, weight: .semibold))
                            .foregroundStyle(palette.textSec)
                            .contentTransition(.opacity)
                    }
                    if let badge {
                        EyebrowPill(text: badge, palette: palette, size: 11)
                            .transition(.opacity)
                    }
                }
                // Fixed height so a badge appearing/disappearing doesn't shift layout.
                .frame(height: 20, alignment: .leading)
            }
        }
    }
}

extension Date {
    /// The day-of-month as an ordinal string ("26th").
    var ordinalDayString: String {
        let day = Calendar.current.component(.day, from: self)
        return Self.ordinalDayFormatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }
    private static let ordinalDayFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()
}

// MARK: - Progress bar

struct ProgressBarView: View {
    let fraction: Double
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.skySoft)
                Capsule()
                    .fill(palette.primary)
                    .frame(width: max(0, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
        .animation(EvryMotion.settle, value: fraction)
    }
}

/// Header progress area — "3 of 5 done   60%" label + bar.
struct ProgressArea: View {
    let done: Int
    let total: Int
    let palette: Palette

    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    private var pct: Int { Int((fraction * 100).rounded()) }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("\(done) of \(total) done")
                Spacer()
                Text("\(pct)%")
            }
            .font(.nunito(size: 12))
            .foregroundStyle(palette.textSec)
            ProgressBarView(fraction: fraction, palette: palette)
        }
        .padding(.top, 14)
    }
}

// MARK: - Round icon button (38pt bordered circle — header actions, gear)

/// The standard page-header action (top-right of a page title): a 44pt white
/// tile with a navy glyph — shared so every page's header controls match.
struct HeaderIconButton: View {
    let systemName: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeaderIconLabel(systemName: systemName, palette: palette)
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// The visual of `HeaderIconButton`, for controls that supply their own gesture.
struct HeaderIconLabel: View {
    let systemName: String
    let palette: Palette
    var active = false

    var body: some View {
        // White card face with a navy hairline and navy glyph; while active
        // (e.g. the Inbox tools menu is open) it fills sky-soft.
        Image(systemName: systemName)
            .font(.nunito(size: 16, weight: .bold))
            .foregroundStyle(palette.primary)
            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
            .background(active ? palette.skySoft : palette.card,
                        in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1))
    }
}

struct RoundIconButton: View {
    let systemName: String
    let palette: Palette
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.nunito(size: size * 0.42, weight: .medium))
                .foregroundStyle(palette.text)
                .frame(width: size, height: size)
                .background(palette.card, in: Circle())
                .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                .frame(minWidth: EvrySpace.tap, minHeight: EvrySpace.tap)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Scale-down on press. Honours Reduce Motion (no transform).
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .animation(EvryMotion.hover, value: configuration.isPressed)
    }
}

// MARK: - Card background (task rows, profile cards, project cards)

/// The design system's Card: white fill, 1pt navy-08 hairline, radius-card
/// (24pt) corners, shadow-soft. Use for self-contained objects only.
struct CardBackground: ViewModifier {
    let palette: Palette
    var cornerRadius: CGFloat = EvryRadius.card
    /// Flat cards (the app's list rows and Profile) keep the hairline only.
    var shadow = true

    func body(content: Content) -> some View {
        let card = content
            .background(palette.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.hairline, lineWidth: 1)
            )
        if shadow { card.evryShadowSoft(palette) } else { card }
    }
}

extension View {
    func evryCard(_ palette: Palette, cornerRadius: CGFloat = EvryRadius.card, shadow: Bool = true) -> some View {
        modifier(CardBackground(palette: palette, cornerRadius: cornerRadius, shadow: shadow))
    }

    /// The design system's *secondary* button face: white fill, navy label and
    /// a navy-16 outline. (For the one main action on a view, use
    /// `EvryPrimaryButtonStyle` instead.)
    func evryButtonFace<S: InsettableShape>(_ palette: Palette, in shape: S, enabled: Bool = true) -> some View {
        foregroundStyle(enabled ? palette.primary : palette.textPh)
            .background(palette.card, in: shape)
            .overlay(shape.strokeBorder(palette.border, lineWidth: 1))
    }

    /// The app-standard field/row container: `card` fill with the navy-08
    /// hairline on radius-card corners. Use for input fields, setting rows and
    /// neutral surfaces so every surface reads consistently.
    func evryField(_ palette: Palette, cornerRadius: CGFloat = EvryRadius.card) -> some View {
        background(palette.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1))
    }
}

// MARK: - Empty state

/// The app's one empty-state layout (Inbox, Habits, Notes): Evry the mascot
/// (or a supplied image / symbol), a title, and a single hint line.
struct EmptyStateView: View {
    var imageName: String?
    /// SF Symbol shown above the title instead of the mascot.
    var systemImage: String? = nil
    /// Shows Evry above the title when no image or symbol is supplied.
    var showsMascot = true
    let title: String
    let text: String
    let palette: Palette

    var body: some View {
        VStack(spacing: 0) {
            if imageName == nil, systemImage == nil, showsMascot {
                EvryMascot(size: 96, float: true)
                    .padding(.bottom, 16)
            }
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 336)
                    .padding(.bottom, 18)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.nunito(size: 36))
                    .foregroundStyle(palette.textPh)
                    .padding(.bottom, 12)
                    .accessibilityHidden(true)   // decorative
            }
            Text(title)
                .font(.evryTitle)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Text(text)
                .font(.evryBody)
                .lineSpacing(4)
                .foregroundStyle(palette.textSec)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

let emptyMessages = [
    "Nothing else left!", "All done for now.", "You’re all caught up!",
    "A clear list. Enjoy it.", "Nice work — that’s everything.",
]

// MARK: - Checkbox (22pt circle, becomes the sky check disc when done)

struct TaskCheckbox: View {
    let checked: Bool
    let palette: Palette
    var size: CGFloat = 22
    /// Placement of the visible circle within its enlarged hit area. Defaults to
    /// top-leading (aligns with the title's first line); `.leading` centers it
    /// vertically for rows that center their content (e.g. the Timeline).
    var contentAlignment: Alignment = .topLeading
    /// Incrementing this from the parent (e.g. on swipe-to-complete) plays the
    /// same optimistic completion animation + delayed commit as a direct tap.
    var externalCompleteToken: Int = 0
    /// Fired the instant a completion animation begins (before the delayed commit),
    /// so a parent can kick off matching animations in sync (e.g. subtasks).
    var onBeginComplete: (() -> Void)? = nil
    let action: () -> Void

    // Completion animation state — a springy pop plus a radiating ring burst.
    @State private var popScale: CGFloat = 1
    @State private var burstScale: CGFloat = 0.7
    @State private var burstOpacity: Double = 0
    // Optimistic "checked" shown immediately on tap, before the model toggle is
    // committed — lets the completion animation play before the row moves away.
    @State private var justCompleted = false
    @State private var completeWork: DispatchWorkItem? = nil

    private var done: Bool { checked || justCompleted }

    var body: some View {
        Button {
            if done {
                // Uncheck — cancel any pending completion and revert immediately.
                completeWork?.cancel()
                completeWork = nil
                justCompleted = false
                UISelectionFeedbackGenerator().selectionChanged()
                if checked { action() }
            } else {
                beginCompletion()
            }
        } label: {
            ZStack {
                // Ring that bursts outward when the task is completed.
                Circle()
                    .stroke(Palette.doneFill, lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(burstScale)
                    .opacity(burstOpacity)

                Circle()
                    .fill(done ? Palette.doneFill : .clear)
                Circle()
                    .strokeBorder(done ? Palette.doneFill : palette.textPh, lineWidth: 2)
                if done {
                    Image(systemName: "checkmark")
                        .font(.nunito(size: size * 0.45, weight: .heavy))
                        .foregroundStyle(palette.onSky)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(popScale)
            // Expand hit area. Alignment controls where the visible circle sits
            // within it (top-leading by default; leading to center it vertically).
            .frame(width: size + 16, height: size + 16, alignment: contentAlignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: done)
        .onChange(of: checked) { _, isChecked in
            // External completes (e.g. swipe-to-done) still animate; resetting on
            // uncheck clears the optimistic flag.
            if isChecked {
                if !justCompleted { playCompletion() }
            } else {
                justCompleted = false
            }
        }
        .onChange(of: externalCompleteToken) { _, newValue in
            // Swipe-to-complete (or any parent trigger) runs the same optimistic
            // animation + delayed commit path as a direct tap.
            if newValue > 0 { beginCompletion() }
        }
    }

    /// Shows the checked state immediately + plays the burst, then commits the
    /// real toggle after a short delay so the animation reads before the row moves.
    private func beginCompletion() {
        guard !done else { return }
        justCompleted = true
        onBeginComplete?()
        playCompletion()
        let work = DispatchWorkItem { action(); completeWork = nil }
        completeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func playCompletion() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Pop the checkbox: quick overshoot, then settle back.
        withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) {
            popScale = 1.35
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.55).delay(0.12)) {
            popScale = 1
        }

        // Radiating ring: snap to full opacity at the checkbox size, then expand
        // outward and fade.
        burstScale = 0.85
        burstOpacity = 0.75
        withAnimation(.easeOut(duration: 0.45)) {
            burstScale = 2.2
            burstOpacity = 0
        }
    }
}

// MARK: - Burst pill button

/// A pill button that plays a completion-style pop + radiating ring burst in the
/// given color, then fires its action after the pop so the animation reads before
/// any resulting layout change (e.g. the overdue banner disappearing). Mirrors
/// `TaskCheckbox`'s completion feel — used for "Reschedule all".
struct BurstPillButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    @State private var popScale: CGFloat = 1
    @State private var burstScale: CGFloat = 1
    @State private var burstOpacity: Double = 0

    var body: some View {
        Button {
            play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { action() }
        } label: {
            Text(title)
                .font(.nunito(size: 13, weight: .bold))
                .foregroundStyle(Palette.onSignal)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .background(color, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(color, lineWidth: 2)
                        .scaleEffect(burstScale)
                        .opacity(burstOpacity)
                )
                .scaleEffect(popScale)
                // Visible pill stays compact; the hit area meets the 44pt minimum.
                .frame(minHeight: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func play() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)

        // Pop: quick overshoot, then settle back (same shape as the checkbox pop).
        withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { popScale = 1.18 }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.55).delay(0.12)) { popScale = 1 }

        // Radiating outline: snap in at the pill's size, then expand outward and fade.
        burstScale = 1.0
        burstOpacity = 0.8
        withAnimation(.easeOut(duration: 0.45)) {
            burstScale = 1.7
            burstOpacity = 0
        }
    }
}

// MARK: - Trash burst button

/// The row's trash button. Mirrors `TaskCheckbox`'s completion feel — a springy
/// pop plus a radiating ring burst — in the strong ink, then fires its delete
/// action after the pop so the burst reads before the row animates away.
struct TrashBurstButton: View {
    let palette: Palette
    let action: () -> Void

    @State private var popScale: CGFloat = 1
    @State private var burstScale: CGFloat = 0.85
    @State private var burstOpacity: Double = 0
    @State private var tinted = false

    var body: some View {
        Button {
            play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { action() }
        } label: {
            ZStack {
                // Ring that bursts outward on tap (same shape as the checkbox's).
                Circle()
                    .stroke(Palette.danger, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .scaleEffect(burstScale)
                    .opacity(burstOpacity)

                Image(systemName: "trash")
                    .font(.nunito(size: 13))
                    .foregroundStyle(tinted ? Palette.danger : palette.textSec)
                    .scaleEffect(popScale)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
        .opacity(tinted ? 1 : 0.6)
    }

    private func play() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        withAnimation(.easeOut(duration: 0.15)) { tinted = true }

        // Pop: quick overshoot, then settle back (same shape as the checkbox pop).
        withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { popScale = 1.35 }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.55).delay(0.12)) { popScale = 1 }

        // Radiating ring: snap in at the icon's size, then expand outward and fade.
        burstScale = 0.85
        burstOpacity = 0.75
        withAnimation(.easeOut(duration: 0.45)) {
            burstScale = 2.2
            burstOpacity = 0
        }
    }
}

// MARK: - Scroll indicator

/// A slim accent-coloured scroll indicator on the *leading* edge, replacing the
/// system's grey trailing one. Sized and positioned from the scroll geometry,
/// it shows while scrolling and fades out shortly after.
struct EvryScrollIndicator: ViewModifier {
    let palette: Palette

    private struct Metrics: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
    }

    @State private var metrics = Metrics()
    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Metrics.self) { g in
                Metrics(offset: g.contentOffset.y + g.contentInsets.top,
                        content: g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom,
                        container: g.containerSize.height)
            } action: { _, new in
                metrics = new
            }
            .onScrollPhaseChange { _, phase in
                if phase.isScrolling { show() } else { scheduleHide() }
            }
            .overlay(alignment: .topLeading) { indicator.allowsHitTesting(false) }
    }

    private var indicator: some View {
        GeometryReader { geo in
            let inset: CGFloat = 6
            let track = max(0, geo.size.height - inset * 2)
            let scrollable = metrics.content - metrics.container
            if scrollable > 1, metrics.container > 0, track > 0 {
                let thumb = max(28, track * min(1, metrics.container / metrics.content))
                let progress = min(max(metrics.offset / scrollable, 0), 1)
                Capsule()
                    .fill(palette.primary)
                    .frame(width: 4, height: thumb)
                    .offset(x: 3, y: inset + (track - thumb) * progress)
                    .opacity(visible ? 0.9 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func show() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { visible = true }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { visible = false }
        }
    }
}

extension View {
    /// Swaps the system scroll indicator for the app's leading, accent one.
    /// Apply directly to a vertical `ScrollView`.
    func evryScrollIndicator(_ palette: Palette) -> some View {
        modifier(EvryScrollIndicator(palette: palette))
    }
}

// MARK: - Confirmation prompt

/// The app's themed confirmation — the same centered card over a dimmed
/// backdrop as the Focus Mode "Exit" prompt — used in place of system
/// confirmation dialogs for deletes and other destructive actions.
struct ConfirmPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    var message: String? = nil
    let confirmTitle: String
    var cancelTitle = "Cancel"
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if isPresented {
                    Color.evryNavy.opacity(0.4)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { close() }

                    card
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(EvryMotion.settle, value: isPresented)
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.evryBody)
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 12) {
                Button { close() } label: {
                    Text(cancelTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(EvrySecondaryButtonStyle(palette: palette))

                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    isPresented = false
                    onConfirm()
                } label: {
                    Text(confirmTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
            }
        }
        .padding(EvrySpace.card)
        .frame(maxWidth: 360)
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
        .evryShadowLift(palette)
        .padding(.horizontal, 32)
        // Keep the title, message and both buttons readable by VoiceOver, while
        // the card is treated as modal over the content behind it.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func close() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isPresented = false
    }
}

extension View {
    /// Presents the app's themed destructive-confirmation card over this view.
    func evryConfirm(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(ConfirmPrompt(isPresented: isPresented, title: title, message: message,
                               confirmTitle: confirmTitle, cancelTitle: cancelTitle, onConfirm: onConfirm))
    }
}

// MARK: - Toast

struct ToastData: Equatable {
    let id = UUID()
    let message: String
    var undo: (() -> Void)?

    static func == (lhs: ToastData, rhs: ToastData) -> Bool { lhs.id == rhs.id }
}

struct ToastView: View {
    let toast: ToastData
    let palette: Palette
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.nunito(size: 13.5, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            if let undo = toast.undo {
                Button("Undo") {
                    undo()
                    dismiss()
                }
                .font(.nunito(size: 13.5, weight: .bold))
                .foregroundStyle(palette.primary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        // White pill with the navy hairline and a lifted navy shadow.
        .background(palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
        .evryShadowLift(palette)
    }
}

// MARK: - Multi-select action bar

struct MultiSelectBar: View {
    let selectedCount: Int
    let palette: Palette
    var onDelete: () -> Void
    var onMove: () -> Void
    var onCancel: () -> Void
    var onGroup: () -> Void = {}
    var showMove: Bool = true
    var showGroup: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.nunito(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .frame(width: 34, height: 34)
                    .background(palette.hover, in: Circle())
                    .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel selection")

            Text(selectedCount == 0 ? "Select tasks" : "\(selectedCount) selected")
                .font(.nunito(size: 14, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .fixedSize()

            Spacer()

            if selectedCount > 0 {
                if showMove {
                    Button(action: onMove) {
                        Text("Move")
                            .font(.nunito(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .evryButtonFace(palette, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if showGroup {
                    Button(action: onGroup) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.plus")
                                .font(.nunito(size: 13, weight: .semibold))
                            Text("Group")
                                .font(.nunito(size: 13, weight: .semibold))
                                .lineLimit(1)
                        }
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .evryButtonFace(palette, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onDelete) {
                    Text("Delete")
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(palette.onPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(palette.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
        .evryShadowLift(palette)
        .padding(.horizontal, 16)
    }
}

// MARK: - Swipe Action Row

/// Wraps any content with swipe-to-reveal action buttons.
/// Swipe left → trailing action (delete). Swipe right → leading action (complete).
/// Reveals swipe actions on horizontal drags.
/// Direction is locked after 10pt of combined movement so there is no initial jump and
/// both left and right swipes work equally well. Tracking is purely 1:1 from lock-in.
/// Rubber-band resistance kicks in past `revealWidth`. Light haptic = primed; medium = fired.
struct SwipeActionRow<Content: View>: View {
    struct Action {
        let label: String
        let icon: String
        let color: Color
        let action: () -> Void
    }

    var leadingAction: Action?
    var trailingAction: Action?
    var isDragging: Bool = false
    /// Fires true when a horizontal swipe locks in, false when it ends — lets the
    /// parent suppress hold gestures (multi-select/reschedule) during a swipe.
    var onHorizontalSwipeChanged: ((Bool) -> Void)? = nil
    /// Corner radius of the revealed action containers — matches the fronting
    /// card so the two shapes line up (defaults to the roomier card radius).
    var actionCornerRadius: CGFloat = EvryRadius.card
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var primed = false
    // A UIKit pan (SwipeCatcher) only fires this for horizontal drags, so vertical
    // drags fall straight through to the enclosing ScrollView.
    @State private var swipeActive = false

    private let revealWidth: CGFloat = 80
    // Fire only when the card is still ~70% revealed at release, measured from the
    // card's actual position — sliding out then back to center must not fire.
    private var threshold: CGFloat { revealWidth * 0.7 }

    private func dampedOffset(_ raw: CGFloat) -> CGFloat {
        let s: CGFloat = raw < 0 ? -1 : 1
        return s * min(abs(raw), revealWidth)  // hard clamp — no overshoot
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let leading = leadingAction {
                HStack {
                    actionSlot(leading, isLeading: true).frame(width: revealWidth)
                    Spacer()
                }
            }
            if let trailing = trailingAction {
                HStack {
                    Spacer()
                    actionSlot(trailing, isLeading: false).frame(width: revealWidth)
                }
            }

            content()
                .offset(x: offset)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.82), value: offset)
        }
        // The swipe is driven by a UIKit horizontal-only pan on the enclosing
        // ScrollView. It begins ONLY when the drag is horizontal, so up/down drags
        // are left entirely to the ScrollView (scroll-over-tasks works), while
        // left/right reveal the actions.
        .background(SwipeCatcher(onChanged: swipeChanged, onEnded: swipeEnded))
        // Deliberately not clipped: the action bubbles grow a touch when primed
        // and would otherwise have their rounded corners cropped by the row's
        // bounds. (They're fully transparent until revealed, so nothing leaks.)
        .onChange(of: isDragging) { _, dragging in
            if dragging {
                swipeActive = false
                withAnimation(.spring(response: 0.3)) { offset = 0; primed = false }
            }
        }
    }

    private func swipeChanged(_ dx: CGFloat) {
        guard !isDragging else { return }
        if !swipeActive {
            swipeActive = true
            onHorizontalSwipeChanged?(true)
        }
        // Respect which sides actually have an action.
        if dx > 0 && leadingAction == nil { offset = 0; primed = false; return }
        if dx < 0 && trailingAction == nil { offset = 0; primed = false; return }
        offset = dampedOffset(dx)
        let nowPrimed = abs(dx) >= threshold
        if nowPrimed && !primed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        primed = nowPrimed
    }

    private func swipeEnded(_ dx: CGFloat, _ vx: CGFloat) {
        // Fire from the card's actual on-screen position, not the raw finger
        // translation, so sliding out then back to center never fires.
        let finalOffset = offset
        if swipeActive { swipeActive = false; onHorizontalSwipeChanged?(false) }

        if finalOffset >= threshold, let leading = leadingAction {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
            primed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { leading.action() }
        } else if finalOffset <= -threshold, let trailing = trailingAction {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
            primed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { trailing.action() }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { offset = 0; primed = false }
        }
    }

    // Passive visual only — the action fires from the swipe threshold in onEnded,
    // never as an independent button tap. (A live Button here would "press" if the
    // finger happened to start over it, deleting/completing regardless of the slide.)
    private func actionSlot(_ a: Action, isLeading: Bool) -> some View {
        let progress = isLeading
            ? CGFloat(min(1, max(0, (offset - 8) / (revealWidth - 8))))
            : CGFloat(min(1, max(0, (-offset - 8) / (revealWidth - 8))))
        let isActiveSide = isLeading ? offset > 0 : offset < 0

        return VStack(spacing: 4) {
            Image(systemName: a.icon)
                .font(.nunito(size: 14, weight: .semibold))
            Text(a.label)
                .font(.nunito(size: 12, weight: .bold))
        }
        .foregroundStyle(a.color == Palette.doneFill ? Color.evryNavy : Palette.onSignal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(a.color, in: RoundedRectangle(cornerRadius: actionCornerRadius, style: .continuous))
        .opacity(Double(progress))
        .scaleEffect(primed && isActiveSide ? 1.1 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: primed)
        .allowsHitTesting(false)
    }
}

// MARK: - Swipe catcher (horizontal-only pan that coexists with vertical scroll)

/// Installs a `UIPanGestureRecognizer` on the enclosing `UIScrollView` that only
/// *begins* when a drag is horizontal AND started over this row. Vertical drags
/// never begin it, so they fall through to the scroll view — this is the same way
/// `UITableView` swipe actions live inside a scroll view. It reports the row's
/// horizontal translation; `SwipeActionRow` turns that into the reveal.
private struct SwipeCatcher: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        // Never a hit-test target — it's only a frame reference + a handle onto the
        // enclosing scroll view, so taps still reach the row's buttons.
        v.isUserInteractionEnabled = false
        context.coordinator.host = v
        context.coordinator.attach()
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.attach()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChanged: onChanged, onEnded: onEnded) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void
        weak var host: UIView?
        private weak var scroll: UIScrollView?
        private var pan: UIPanGestureRecognizer?
        private var startX: CGFloat = 0
        private var active = false

        init(onChanged: @escaping (CGFloat) -> Void, onEnded: @escaping (CGFloat, CGFloat) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach() {
            guard pan == nil, host != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pan == nil, let host = self.host,
                      let scroll = Self.enclosingScroll(host) else { return }
                let p = UIPanGestureRecognizer(target: self, action: #selector(self.handle(_:)))
                p.delegate = self
                p.cancelsTouchesInView = false   // taps still reach the row
                scroll.addGestureRecognizer(p)
                self.pan = p
                self.scroll = scroll
            }
        }

        func detach() {
            if let pan, let scroll { scroll.removeGestureRecognizer(pan) }
            pan = nil
            scroll = nil
        }

        private static func enclosingScroll(_ v: UIView) -> UIScrollView? {
            var cur = v.superview
            while let c = cur {
                if let s = c as? UIScrollView { return s }
                cur = c.superview
            }
            return nil
        }

        @objc private func handle(_ g: UIPanGestureRecognizer) {
            guard let scroll else { return }
            switch g.state {
            case .began:
                startX = g.translation(in: scroll).x
                active = true
                onChanged(0)
            case .changed:
                guard active else { return }
                onChanged(g.translation(in: scroll).x - startX)
            case .ended, .cancelled, .failed:
                guard active else { return }
                active = false
                onEnded(g.translation(in: scroll).x - startX, g.velocity(in: scroll).x)
            default:
                break
            }
        }

        // Coexist with the scroll view's own pan (and other rows' catchers).
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // Begin only for a clearly-horizontal drag that started over THIS row.
        // Vertical drags return false, leaving them to the scroll view.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let host, let scroll else { return false }
            let vel = pan.velocity(in: scroll)
            guard abs(vel.x) > abs(vel.y) else { return false }
            let loc = pan.location(in: host)
            return host.bounds.insetBy(dx: -6, dy: -2).contains(loc)
        }
    }
}

// MARK: - Highlighted Task Input Field

// UITextView subclass that calls becomeFirstResponder() inside didMoveToWindow so the
// keyboard starts animating concurrently with the sheet animation instead of after it.
private final class _TaskTextView: UITextView {
    var autoFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard autoFocus, window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() }
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: max(bounds.width, 1), height: .infinity))
    }
}

private struct InlineTaskInput: UIViewRepresentable {
    @Binding var text: String
    var autoFocus: Bool
    var focused: Binding<Bool>
    /// Size for a single line of text; longer entries step down to `minFontSize`.
    var fontSize: CGFloat
    var minFontSize: CGFloat
    var palette: Palette
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> _TaskTextView {
        let tv = _TaskTextView()
        tv.autoFocus = autoFocus
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.font = .nunito(size: context.coordinator.currentSize)
        tv.textColor = UIColor(palette.text)
        tv.tintColor = UIColor(palette.primary)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .sentences
        tv.returnKeyType = .send
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        context.coordinator.applyHighlight(to: tv)
        return tv
    }

    func updateUIView(_ uiView: _TaskTextView, context: Context) {
        context.coordinator.parent = self
        uiView.tintColor = UIColor(palette.primary)
        // External change (e.g. cleared after submit) — rebuild the highlighted text.
        if uiView.text != text {
            context.coordinator.applyHighlight(to: uiView)
            uiView.invalidateIntrinsicContentSize()
        }
        let want = focused.wrappedValue
        if want && !uiView.isFirstResponder { uiView.becomeFirstResponder() }
        else if !want && uiView.isFirstResponder { uiView.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InlineTaskInput
        /// The size currently rendered — shrinks as the entry wraps onto more lines.
        var currentSize: CGFloat
        init(_ p: InlineTaskInput) { parent = p; currentSize = p.fontSize }

        /// Large for a single line, stepping down ~1.5pt per extra wrapped line to
        /// the minimum. Lines are measured at the full size so the result can't
        /// oscillate as the text shrinks.
        func fittedSize(for tv: UITextView) -> CGFloat {
            let maxSize = parent.fontSize
            let width = tv.bounds.width
            guard width > 0, !parent.text.isEmpty else { return maxSize }
            let font = UIFont(name: "Nunito-Regular", size: maxSize) ?? .systemFont(ofSize: maxSize)
            let height = (parent.text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil
            ).height
            let lines = max(1, Int((height / font.lineHeight).rounded(.up)))
            return max(parent.minFontSize, maxSize - CGFloat(lines - 1) * 1.5)
        }

        /// Renders the keyword highlighting directly in the text view (preserving
        /// the caret) so the cursor always tracks the visible text, including wraps.
        func applyHighlight(to tv: _TaskTextView) {
            currentSize = fittedSize(for: tv)
            let selected = tv.selectedRange
            tv.attributedText = attributedTaskInputNS(parent.text, palette: parent.palette, fontSize: currentSize)
            // New typing stays in the plain body style rather than inheriting a keyword's.
            tv.typingAttributes = [
                .font: UIFont.nunito(size: currentSize),
                .foregroundColor: UIColor(parent.palette.text)
            ]
            tv.selectedRange = selected
        }

        func textView(_ tv: UITextView, shouldChangeTextIn r: NSRange, replacementText t: String) -> Bool {
            if t == "\n" { parent.onSubmit(); return false }
            return true
        }
        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            if let t = tv as? _TaskTextView { applyHighlight(to: t) }
            tv.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ tv: UITextView) { parent.focused.wrappedValue = true }
        func textViewDidEndEditing(_ tv: UITextView) { parent.focused.wrappedValue = false }
    }
}

/// Quick-add field that renders keyword highlighting inline in the text view, so
/// the caret always stays aligned with the visible text (even across line wraps).
struct HighlightedTaskTextField: View {
    let placeholder: String
    @Binding var text: String
    let palette: Palette
    /// Single-line size; the entry shrinks toward `minFontSize` as it wraps.
    var fontSize: CGFloat = 19
    var minFontSize: CGFloat = 15
    var autoFocus: Bool = false
    var onSubmit: () -> Void
    var focused: Binding<Bool>

    var body: some View {
        ZStack(alignment: .topLeading) {
            InlineTaskInput(
                text: $text,
                autoFocus: autoFocus,
                focused: focused,
                fontSize: fontSize,
                minFontSize: minFontSize,
                palette: palette,
                onSubmit: onSubmit
            )

            if text.isEmpty {
                Text(placeholder)
                    .font(.nunito(size: fontSize))
                    .foregroundStyle(palette.textPh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Evry Design System components
//
// Native renditions of the design system's building blocks (see
// EvryDesignSystem/EvryDesignSystem.md → Components). Names match the web
// components so the site and the app stay in step.

extension String {
    /// Sentence-cases an ALL-CAPS label ("OVERDUE" → "Overdue"). Mixed-case
    /// strings are returned unchanged, so names like "Evry" are preserved.
    var evrySentenceCased: String {
        guard self == uppercased(), contains(where: \.isLetter) else { return self }
        let lower = lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}

// MARK: Button

/// primary: navy pill, white bold label, shadow-btn. The one main action on a
/// view. At least 48pt tall. (On navy surfaces it becomes the sky button.)
struct EvryPrimaryButtonStyle: ButtonStyle {
    let palette: Palette
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.evryLabel)
            .foregroundStyle(palette.onPrimary)
            .padding(.horizontal, EvrySpace.buttonX)
            .padding(.vertical, EvrySpace.buttonY)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: EvrySpace.buttonHeight)
            .background(configuration.isPressed ? palette.primaryPressed : palette.primary, in: Capsule())
            .evryShadowButton(palette)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(EvryMotion.hover, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// secondary: white pill with a navy-16 border; pressed fills sky-soft and
/// darkens the border to navy-28. The alternative next to a primary.
struct EvrySecondaryButtonStyle: ButtonStyle {
    let palette: Palette
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.evryLabel)
            .foregroundStyle(palette.text)
            .padding(.horizontal, EvrySpace.buttonX)
            .padding(.vertical, EvrySpace.buttonY)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: EvrySpace.buttonHeight)
            .background(configuration.isPressed ? palette.skySoft : palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(
                configuration.isPressed ? (palette.dark ? Color.evryWhite60 : .evryNavy28) : palette.border,
                lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(EvryMotion.hover, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// sky: the primary action on a navy surface (navy label on a sky pill).
struct EvrySkyButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.evryLabel)
            .foregroundStyle(Color.evryNavy)
            .padding(.horizontal, EvrySpace.buttonX)
            .padding(.vertical, EvrySpace.buttonY)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: EvrySpace.buttonHeight)
            .background(configuration.isPressed ? Color.evryWhite : .evrySky, in: Capsule())
            .animation(EvryMotion.hover, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// ghost-light: a secondary action on navy (white-35 border, white label).
struct EvryGhostLightButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.evryLabel)
            .foregroundStyle(Color.evryWhite)
            .padding(.horizontal, EvrySpace.buttonX)
            .padding(.vertical, EvrySpace.buttonY)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: EvrySpace.buttonHeight)
            .background(configuration.isPressed ? Color.evryWhite10 : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(configuration.isPressed ? Color.evryWhite60 : .evryWhite35, lineWidth: 1))
            .animation(EvryMotion.hover, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: Eyebrow

/// A small sentence-case pill label above a heading: sky-soft fill, 1pt sky
/// ring, bold navy text. Never uppercase, never a button.
struct EyebrowPill: View {
    let text: String
    let palette: Palette
    var size: CGFloat = 14

    var body: some View {
        Text(text.evrySentenceCased)
            .font(.nunito(size: size, weight: .bold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .padding(.horizontal, size * 0.75)
            .padding(.vertical, size * 0.25)
            .background(palette.skySoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.evrySky, lineWidth: 1))
    }
}

// MARK: Check & Bullet

/// "What's included" tick: a 20pt sky disc with a navy tick.
struct EvryCheck: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "checkmark")
            .font(.nunito(size: size * 0.5, weight: .heavy))
            .foregroundStyle(Color.evryNavy)
            .frame(width: size, height: size)
            .background(Color.evrySky, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The plain bullet: a 12pt sky dot.
struct EvryBullet: View {
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color.evrySky)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: Mascot & Logo

// Design rule (never broken): Evry is never visible in two places at once.
// Overlays that bring Evry in (e.g. the chat) set `evryAway` on the content
// underneath, and every Evry there — mascot, bubble avatar, star mark — fades
// out, so Evry reads as having moved into the overlay.
extension EnvironmentValues {
    /// True while Evry is "away" in an overlay above this content.
    @Entry var evryAway: Bool = false
}

extension View {
    /// Hides an Evry (mascot or star mark) while Evry is away in an overlay.
    func evryPresence() -> some View { modifier(EvryPresence()) }
}

private struct EvryPresence: ViewModifier {
    @Environment(\.evryAway) private var away

    func body(content: Content) -> some View {
        content
            .opacity(away ? 0 : 1)
            .scaleEffect(away ? 0.8 : 1)
            .animation(EvryMotion.settle, value: away)
            .accessibilityHidden(away)
    }
}

/// Evry, the white star. Optional gentle float (6s bob) and a white disc behind
/// (required on sky so the star's sky shadow stays visible). All motion stops
/// under Reduce Motion. Never cropped, recoloured or stretched.
struct EvryMascot: View {
    var size: CGFloat = 96
    var float = false
    var disc = false
    var shadow = false
    /// Empty when nearby text already names Evry.
    var accessibilityText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        // Decorative unless a description is given (nearby text names Evry).
        (accessibilityText == nil ? Image(decorative: "EvryMascot") : Image("EvryMascot"))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .padding(disc ? size * 0.14 : 0)
            .background {
                if disc { Circle().fill(Color.evryWhite) }
            }
            .shadow(color: shadow ? Color.evryNavy.opacity(0.18) : .clear, radius: 12, y: 18)
            .offset(y: float && up ? -size * 0.06 : 0)
            .rotationEffect(.degrees(float && up ? -1.5 : 0))
            .onAppear {
                guard float, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { up = true }
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText ?? "")
            .accessibilityHidden(accessibilityText == nil)
            .evryPresence()
    }
}

/// The plain sky star mark beside the "Evry" wordmark (24pt, 800, +0.03em).
struct EvryLogo: View {
    let palette: Palette
    var onNavy = false
    var markWidth: CGFloat = 36
    /// The wordmark's size (text-wordmark is 24); tracking stays +0.03em.
    var wordmarkSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 10 * wordmarkSize / 24) {
            Image("EvryPlainMark")
                .resizable()
                .scaledToFit()
                .frame(width: markWidth)
                .evryPresence()
            Text("Evry")
                .font(.nunito(size: wordmarkSize, weight: .heavy))
                .tracking(wordmarkSize * 0.03)
                .foregroundStyle(onNavy ? Color.evryWhite : palette.text)
        }
        .frame(minHeight: EvrySpace.tap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evry")
    }
}

// MARK: ToolIcon

/// The four tools. Each has its own glyph *and* tile shape, so they differ by
/// form and fill strength, never by colour.
enum EvryTool: String, CaseIterable {
    case tasks, habits, notes, calendar

    var label: String {
        switch self {
        case .tasks: "Tasks"
        case .habits: "Habits"
        case .notes: "Notes"
        case .calendar: "Calendar"
        }
    }

    var glyph: String {
        switch self {
        case .tasks: "EvryIconTasks"
        case .habits: "EvryIconHabits"
        case .notes: "EvryIconNotes"
        case .calendar: "EvryIconCalendar"
        }
    }
}

/// A rounded square with its top-right corner cut to a small radius — the
/// Notes tile's "folded sheet".
struct NotesTileShape: InsettableShape {
    var radius: CGFloat
    var foldRadius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return Path(roundedRect: r, cornerRadii: RectangleCornerRadii(
            topLeading: radius, bottomLeading: radius, bottomTrailing: radius, topTrailing: foldRadius),
            style: .continuous)
    }

    func inset(by amount: CGFloat) -> NotesTileShape {
        var s = self; s.inset += amount; return s
    }
}

/// A tool's glyph inside that tool's own tile. `md` = 48pt tile / 24pt glyph,
/// `sm` = 32pt / 18pt. Decorative: always pair it with the tool's name.
struct ToolIcon: View {
    let tool: EvryTool
    var tile: CGFloat = 48
    let palette: Palette

    private var glyphSize: CGFloat { tile <= 32 ? 18 : tile / 2 }
    private var radius: CGFloat { EvryRadius.tile * tile / 48 }

    var body: some View {
        Image(tool.glyph)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: glyphSize, height: glyphSize)
            .foregroundStyle(tool == .calendar ? palette.text : Color.evryNavy)
            .frame(width: tile, height: tile)
            .background { tileShape }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var tileShape: some View {
        switch tool {
        case .tasks:
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.evrySky)
        case .habits:
            Circle().fill(Color.evrySky.opacity(0.7))
        case .notes:
            NotesTileShape(radius: radius, foldRadius: 5.6 * tile / 48).fill(Color.evrySky.opacity(0.45))
        case .calendar:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(palette.card)
                .strokeBorder(palette.text, lineWidth: 2)
        }
    }
}

// MARK: EvryBubble

/// One line of conversation. Evry's lines sit in a sky-soft bubble with a sky
/// ring beside the mascot, tail bottom-left; the person's lines are navy on the
/// right, tail bottom-right. Text is text-bubble (15pt / 1.625).
struct EvryBubble: View {
    enum Speaker { case evry, you }

    let text: String
    var speaker: Speaker = .evry
    var small = false
    /// Hide Evry's avatar where Evry is already shown (e.g. the chat).
    var showsAvatar = true
    let palette: Palette

    private var bubbleShape: UnevenRoundedRectangle {
        let r = EvryRadius.field, t = EvryRadius.tail
        return speaker == .evry
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: t, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: t, topTrailingRadius: r, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if speaker == .evry {
                if showsAvatar { EvryMascot(size: small ? 28 : 40) }
            } else {
                Spacer(minLength: 48)
            }
            Text(text)
                .font(small ? .nunito(size: 13) : .evryBubble)
                .lineSpacing(small ? 2 : 5)
                .foregroundStyle(speaker == .evry ? palette.text : palette.onPrimary)
                .padding(.horizontal, small ? 12 : 14)
                .padding(.vertical, small ? 8 : 10)
                .background(speaker == .evry ? palette.skySoft : palette.primary, in: bubbleShape)
                .overlay {
                    if speaker == .evry { bubbleShape.strokeBorder(Color.evrySky, lineWidth: 1) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            // The person's lines keep a 15% lead so they read as right-aligned.
            if speaker == .evry { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((speaker == .evry ? "Evry says: " : "You: ") + text)
    }
}

// MARK: FormField

/// FormField's field: white, 1.5pt navy-20 border (full navy when focused or
/// in error), radius-field corners, 12×16 padding, 16pt text.
struct EvryTextFieldStyle: ViewModifier {
    let palette: Palette
    var focused = false
    var error = false

    func body(content: Content) -> some View {
        content
            .font(.evryBody)
            .foregroundStyle(palette.text)
            .tint(palette.primary)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous)
                    .strokeBorder(focused || error ? palette.text : (palette.dark ? Color.evryWhite35 : .evryNavy20),
                                  lineWidth: 1.5)
            )
    }
}

extension View {
    func evryTextField(_ palette: Palette, focused: Bool = false, error: Bool = false) -> some View {
        modifier(EvryTextFieldStyle(palette: palette, focused: focused, error: error))
    }
}

/// A field error: the alert glyph and a bold 14pt polite message. No red —
/// the icon and words carry it.
struct FieldError: View {
    let message: String
    let palette: Palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .accessibilityHidden(true)
            Text(message)
        }
        .font(.evrySmall)
        .foregroundStyle(palette.text)
        .padding(.top, 8)
    }
}

// MARK: PlaceholderTag

/// A dashed pill marking content still to be confirmed before launch.
struct PlaceholderTag: View {
    var label = "Placeholder"
    let palette: Palette

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil")
            Text(label)
        }
        .font(.evryCaption)
        .foregroundStyle(palette.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.dark ? Color.evryWhite35 : .evryNavy40,
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }
}

// MARK: Soft glow

/// The one gradient in the system: a soft sky radial glow fading to nothing,
/// placed off-canvas behind hero content.
struct EvryGlow: View {
    var onNavy = false

    var body: some View {
        RadialGradient(colors: [Color.evrySky.opacity(onNavy ? 0.16 : 0.55), Color.evrySky.opacity(0)],
                       center: .center, startRadius: 0, endRadius: 220)
            .frame(width: 440, height: 440)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: Quick-add card

/// The app's one creation card (new task, habit, note folder): a bottom panel
/// over the live app with a grabber that lands lit then settles, the caller's
/// fields, and an optional full-width primary action. Grows up out of the
/// swipe-up handle; tap outside or swipe the card down to close.
struct QuickAddCard<Content: View>: View {
    let palette: Palette
    /// Primary action label (e.g. "Add folder"); nil hides the button.
    var actionTitle: String? = nil
    var actionEnabled = true
    var onAction: () -> Void = {}
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var grabberLit = true
    @State private var dragY: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // Transparent tap-catcher — the live app stays visible behind the card.
            Color.evryNavy.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                // Lands lit in ink (the pill becoming the grabber), then settles.
                Capsule()
                    .fill(grabberLit ? palette.primary : palette.border)
                    .frame(width: grabberLit ? 56 : 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .accessibilityHidden(true)

                VStack(spacing: 16) { content() }

                if let actionTitle {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                        .disabled(!actionEnabled)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, EvrySpace.grid)
            .padding(.bottom, EvrySpace.grid)
            .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .evryShadowLift(palette)
            .offset(y: max(0, dragY))
            .gesture(dismissDrag)
            .scaleEffect(x: appeared ? 1 : 0.82, y: appeared ? 1 : 0.6, anchor: .bottom)
            .offset(y: appeared ? 0 : 70)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : EvryMotion.settle) { appeared = true }
            withAnimation(.easeInOut(duration: 0.45).delay(0.35)) { grabberLit = false }
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { dragY = $0.translation.height }
            .onEnded { v in
                if v.translation.height > 80 || v.predictedEndTranslation.height > 220 {
                    onClose()
                } else {
                    withAnimation(EvryMotion.settle) { dragY = 0 }
                }
            }
    }
}

/// A field label inside a `QuickAddCard`: a navy glyph and bold text-sm.
struct QuickAddLabel: View {
    let text: String
    let icon: String
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.nunito(size: 14, weight: .bold))
                .foregroundStyle(palette.primary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.evrySmall)
                .foregroundStyle(palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }
}

/// The horizontal icon picker row used by the quick-add cards: 44pt tiles,
/// sky-soft at rest, the selection filled with `tint` and ringed in ink.
struct QuickAddIconRow: View {
    let icons: [String]
    @Binding var selection: String
    var tint: Color
    var ink: Color
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(icons, id: \.self) { symbol in
                    let on = selection == symbol
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        selection = symbol
                    } label: {
                        Image(systemName: symbol)
                            .font(.nunito(size: 17, weight: .semibold))
                            .foregroundStyle(on ? ink : palette.text)
                            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                            .background(on ? tint : palette.skySoft,
                                        in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
                            .overlay {
                                if on {
                                    RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous)
                                        .strokeBorder(palette.text, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: Typewriter text

/// Evry's lines "typed" out a character at a time, with small pauses at
/// punctuation so it reads like someone writing. The full text reserves its
/// layout from the start (untyped characters are just clear), so bubbles never
/// grow or reflow while typing. Restarts whenever `text` changes; instant under
/// Reduce Motion. `onFinished` fires once the whole line is shown.
struct TypewriterText: View {
    let text: String
    /// Seconds per character (shortened for long lines so typing stays brisk).
    var speed: Double = 0.03
    var onFinished: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    var body: some View {
        Text(typed)
            // A new line replaces the old one outright (it then types in) —
            // no cross-fade, which would spill the old text past its bubble.
            .contentTransition(.identity)
            .accessibilityLabel(text)
            .task(id: text) { await type() }
    }

    /// The text with everything past the cursor made clear.
    private var typed: AttributedString {
        var out = AttributedString(text)
        let count = out.characters.count
        guard shown < count else { return out }
        let cut = out.characters.index(out.startIndex, offsetBy: shown)
        out[cut..<out.endIndex].foregroundColor = .clear
        return out
    }

    private func type() async {
        let characters = Array(text)
        guard !reduceMotion, !characters.isEmpty else {
            shown = characters.count
            onFinished?()
            return
        }
        shown = 0
        // Long lines speed up so a full line never takes much over ~1.6s.
        let step = min(speed, 1.6 / Double(characters.count))
        for i in characters.indices {
            // Linger just after punctuation, like a breath between phrases.
            let prev: Character = i > 0 ? characters[i - 1] : " "
            let pause: Double = ".!?".contains(prev) ? 6 : (",—:;".contains(prev) ? 3 : 1)
            try? await Task.sleep(for: .seconds(step * pause))
            if Task.isCancelled { return }
            shown = i + 1
        }
        onFinished?()
    }
}
