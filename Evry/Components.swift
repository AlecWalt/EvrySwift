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
    let action: () -> Void

    var body: some View {
        Button {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(checked ? Palette.success : .clear)
                Circle()
                    .strokeBorder(checked ? Palette.success : palette.border, lineWidth: 2)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            // Expand hit area without shifting the visual — extra space goes
            // to the right and below so leading/top position is unchanged.
            .frame(width: size + 16, height: size + 16, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: checked)
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
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var primed = false
    // Direction decided once per gesture; gestureOriginX zeros the card at lock-in.
    @State private var lockedHorizontal: Bool? = nil
    @State private var gestureOriginX: CGFloat = 0

    private let revealWidth: CGFloat = 80
    // Fire when 80% of the action button is revealed; hard-clamped so the row
    // never slides past the button edge (no gap between content and action).
    private var threshold: CGFloat { revealWidth * 0.8 }

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
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { v in
                            guard !isDragging else { return }
                            let dx = v.translation.width
                            let dy = v.translation.height

                            // Lock in direction once 10pt of combined movement is reached.
                            if lockedHorizontal == nil, abs(dx) + abs(dy) > 10 {
                                let horiz = abs(dx) > abs(dy) * 1.1
                                lockedHorizontal = horiz
                                // Record translation at lock-in so the card starts at 0.
                                if horiz { gestureOriginX = dx }
                            }

                            guard lockedHorizontal == true else { return }

                            let adjusted = dx - gestureOriginX
                            if adjusted > 0 && leadingAction == nil { return }
                            if adjusted < 0 && trailingAction == nil { return }
                            offset = dampedOffset(adjusted)

                            let nowPrimed = abs(adjusted) >= threshold
                            if nowPrimed && !primed {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            primed = nowPrimed
                        }
                        .onEnded { v in
                            let wasHorizontal = lockedHorizontal == true
                            let adjusted = v.translation.width - gestureOriginX
                            lockedHorizontal = nil
                            gestureOriginX = 0

                            guard wasHorizontal else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                                    offset = 0; primed = false
                                }
                                return
                            }

                            if adjusted > threshold, let leading = leadingAction {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                                primed = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { leading.action() }
                            } else if adjusted < -threshold, let trailing = trailingAction {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                                primed = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { trailing.action() }
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                                    offset = 0; primed = false
                                }
                            }
                        }
                )
        }
        .clipped()
        .onChange(of: isDragging) { _, dragging in
            if dragging {
                lockedHorizontal = nil
                gestureOriginX = 0
                withAnimation(.spring(response: 0.3)) { offset = 0; primed = false }
            }
        }
    }

    private func actionSlot(_ a: Action, isLeading: Bool) -> some View {
        let progress = isLeading
            ? CGFloat(min(1, max(0, (offset - 8) / (revealWidth - 8))))
            : CGFloat(min(1, max(0, (-offset - 8) / (revealWidth - 8))))
        let isActiveSide = isLeading ? offset > 0 : offset < 0

        return Button { a.action() } label: {
            VStack(spacing: 4) {
                Image(systemName: a.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(a.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(a.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(Double(progress))
        .scaleEffect(primed && isActiveSide ? 1.1 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: primed)
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
    var tintColor: UIColor
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> _TaskTextView {
        let tv = _TaskTextView()
        tv.autoFocus = autoFocus
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .clear
        tv.tintColor = tintColor
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .sentences
        tv.returnKeyType = .send
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        return tv
    }

    func updateUIView(_ uiView: _TaskTextView, context: Context) {
        if uiView.text != text { uiView.text = text; uiView.invalidateIntrinsicContentSize() }
        uiView.tintColor = tintColor
        context.coordinator.parent = self
        let want = focused.wrappedValue
        if want && !uiView.isFirstResponder { uiView.becomeFirstResponder() }
        else if !want && uiView.isFirstResponder { uiView.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InlineTaskInput
        init(_ p: InlineTaskInput) { parent = p }

        func textView(_ tv: UITextView, shouldChangeTextIn r: NSRange, replacementText t: String) -> Bool {
            if t == "\n" { parent.onSubmit(); return false }
            return true
        }
        func textViewDidChange(_ tv: UITextView) { parent.text = tv.text; tv.invalidateIntrinsicContentSize() }
        func textViewDidBeginEditing(_ tv: UITextView) { parent.focused.wrappedValue = true }
        func textViewDidEndEditing(_ tv: UITextView) { parent.focused.wrappedValue = false }
    }
}

/// TextField wrapper that shows keyword highlighting overlay.
/// Uses a ZStack with a UITextView overlay to highlight keywords while maintaining editing.
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
                tintColor: UIColor(palette.primary),
                onSubmit: onSubmit
            )

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(palette.textPh)
                    .allowsHitTesting(false)
            } else {
                Text(attributedTaskInput(text, palette: palette, fontSize: fontSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsHitTesting(false)
            }
        }
    }
}
