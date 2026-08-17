//
//  Components.swift
//  Evry
//
//  Shared building blocks matching the webapp's design system: chips,
//  section labels, progress bar, round icon buttons, cards, empty states.
//

import SwiftUI
import UIKit

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
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, background == nil ? 0 : 8)
            .padding(.vertical, background == nil ? 0 : 2)
            .foregroundStyle(foreground)
            .background(background ?? .clear, in: Capsule())
    }
}

/// Date chip — text only, colored by category, ⚠ prefix when overdue.
struct DateChip: View {
    let date: Date
    let palette: Palette

    var body: some View {
        if let category = dateCategory(date), let label = formatDueDate(date) {
            ChipView(
                text: category == .overdue ? "⚠ \(label)" : label,
                foreground: palette.dateColor(category)
            )
        }
    }
}

// MARK: - Section label

/// 11pt bold uppercase tracked label ("OVERDUE", "COMPLETED", …).
struct SectionLabel: View {
    let text: String
    let palette: Palette
    var danger = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(danger ? Palette.danger : palette.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }
}

// MARK: - Progress bar

struct ProgressBarView: View {
    let fraction: Double
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.border)
                Capsule()
                    .fill(palette.primary)
                    .frame(width: max(0, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
        .animation(.easeInOut(duration: 0.6), value: fraction)
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
            .font(.system(size: 12))
            .foregroundStyle(palette.textSec)
            ProgressBarView(fraction: fraction, palette: palette)
        }
        .padding(.top, 14)
    }
}

// MARK: - Round icon button (38pt bordered circle — header actions, gear)

struct RoundIconButton: View {
    let systemName: String
    let palette: Palette
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(palette.textSec)
                .frame(width: size, height: size)
                .background(palette.card, in: Circle())
                .overlay(Circle().strokeBorder(palette.border, lineWidth: 1.5))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Scale-down on press (the webapp's :active { transform: scale(0.92) }).
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Card background (task rows, profile cards, project cards)

struct CardBackground: ViewModifier {
    let palette: Palette
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background(palette.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

extension View {
    func evryCard(_ palette: Palette, cornerRadius: CGFloat = 24) -> some View {
        modifier(CardBackground(palette: palette, cornerRadius: cornerRadius))
    }

    /// The app-standard field/row container — matches the task card exactly:
    /// `card` fill, 26pt continuous corners, no border. Use for input fields,
    /// setting rows, and neutral buttons so every surface reads consistently.
    func evryField(_ palette: Palette, cornerRadius: CGFloat = 26) -> some View {
        background(palette.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var imageName: String?
    let title: String
    let text: String
    let palette: Palette

    var body: some View {
        VStack(spacing: 0) {
            if let imageName {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 336)
                    .padding(.bottom, 18)
            }
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.text)
                .padding(.bottom, 8)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(palette.textSec)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

let emptyMessages = [
    "Nothing else left!", "All done for now!", "You're all caught up!",
    "Squeaky clean.", "Nice work — that's everything.",
]

// MARK: - Checkbox (22pt circle, fills green when done)

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
                    .stroke(Palette.success, lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(burstScale)
                    .opacity(burstOpacity)

                Circle()
                    .fill(done ? Palette.success : .clear)
                Circle()
                    .strokeBorder(done ? Palette.success : palette.border, lineWidth: 2)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(.white)
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
/// `TaskCheckbox`'s green completion feel — used for the red "Reschedule all".
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(color, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(color, lineWidth: 2)
                        .scaleEffect(burstScale)
                        .opacity(burstOpacity)
                )
                .scaleEffect(popScale)
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
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(palette.dark ? Color(hex: 0x1E1E1E) : .white)
                .lineLimit(1)
            if let undo = toast.undo {
                Button("Undo") {
                    undo()
                    dismiss()
                }
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Palette.amber)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(palette.dark ? Color(hex: 0xF0F0F0) : Color(hex: 0x3E3E3E), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

// MARK: - Multi-select action bar

struct MultiSelectBar: View {
    let selectedCount: Int
    let palette: Palette
    var onDelete: () -> Void
    var onMove: () -> Void
    var onCancel: () -> Void
    var showMove: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .frame(width: 34, height: 34)
                    .background(palette.hover, in: Circle())
            }
            .buttonStyle(.plain)

            Text(selectedCount == 0 ? "Select tasks" : "\(selectedCount) selected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.text)

            Spacer()

            if selectedCount > 0 {
                if showMove {
                    Button(action: onMove) {
                        Text("Move")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(palette.primaryLight, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onDelete) {
                    Text("Delete")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Palette.danger, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 4)
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
    var actionCornerRadius: CGFloat = 26
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
        .clipped()
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
                .font(.system(size: 14, weight: .semibold))
            Text(a.label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
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
    var fontSize: CGFloat
    var palette: Palette
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> _TaskTextView {
        let tv = _TaskTextView()
        tv.autoFocus = autoFocus
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: fontSize)
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
        init(_ p: InlineTaskInput) { parent = p }

        /// Renders the keyword highlighting directly in the text view (preserving
        /// the caret) so the cursor always tracks the visible text, including wraps.
        func applyHighlight(to tv: _TaskTextView) {
            let selected = tv.selectedRange
            tv.attributedText = attributedTaskInputNS(parent.text, palette: parent.palette, fontSize: parent.fontSize)
            // New typing stays in the plain body style rather than inheriting a keyword's.
            tv.typingAttributes = [
                .font: UIFont.systemFont(ofSize: parent.fontSize),
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
    var fontSize: CGFloat = 15
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
                palette: palette,
                onSubmit: onSubmit
            )

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(palette.textPh)
                    .allowsHitTesting(false)
            }
        }
    }
}
