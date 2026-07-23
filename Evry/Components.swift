//
//  Components.swift
//  Evry
//
//  Shared building blocks matching the webapp's design system: chips,
//  section labels, progress bar, round icon buttons, cards, empty states.
//

import SwiftUI

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

    private var pct: Int { total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0 }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("\(done) of \(total) done")
                Spacer()
                Text("\(pct)%")
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.textSec)
            ProgressBarView(fraction: total > 0 ? Double(done) / Double(total) : 0, palette: palette)
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
    var cornerRadius: CGFloat = 16

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
    func evryCard(_ palette: Palette, cornerRadius: CGFloat = 16) -> some View {
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
        Button(action: action) {
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

// MARK: - Highlighted Task Input Field

/// TextField wrapper that shows keyword highlighting overlay.
/// Uses a ZStack with a Text overlay to highlight keywords while maintaining TextField editing.
struct HighlightedTaskTextField: View {
    let placeholder: String
    @Binding var text: String
    let palette: Palette
    var fontSize: CGFloat = 15
    var onSubmit: () -> Void
    var focused: FocusState<Bool>.Binding
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hidden TextField for actual text editing. No placeholder here — the
            // overlay Text below is the sole placeholder, otherwise the field's own
            // (UIKit-backed) placeholder renders as a second, out-of-sync label.
            TextField("", text: $text, axis: .vertical)
                .font(.system(size: fontSize))
                .foregroundStyle(.clear) // Make text invisible
                .tint(palette.primary) // Keep cursor visible
                .textSelection(.enabled)
                .lineLimit(1...4)
                .focused(focused)
                .onSubmit(onSubmit)
                .autocorrectionDisabled()
            
            // Overlay with highlighted text
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(palette.textPh)
                    .allowsHitTesting(false)
            } else {
                Text(attributedTaskInput(text, palette: palette, fontSize: fontSize))
                    .lineLimit(1...4)
                    .allowsHitTesting(false)
            }
        }
    }
}
