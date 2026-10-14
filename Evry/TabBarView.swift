//
//  TabBarView.swift
//  Evry
//
//  The system tab bar's Evry styling + the navy swipe-up handle, ported from
//  the webapp's renderTabBar/renderSwipeHandle.
//

import SwiftUI
import UIKit

enum AppTab: String, CaseIterable, Identifiable {
    case inbox, habits, notes, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .habits: "Habits"
        case .notes: "Notes"
        case .profile: "Profile"
        }
    }

    /// The tool glyph asset (template image) for the tab, or nil for Profile,
    /// which isn't a tool and uses an SF Symbol.
    var toolGlyph: String? {
        switch self {
        case .inbox: EvryTool.tasks.glyph
        case .habits: EvryTool.habits.glyph
        case .notes: EvryTool.notes.glyph
        case .profile: nil
        }
    }
}

/// The tab bar item for a tab: the tool's own line glyph (tinted navy via the
/// template rendering) above a Nunito label.
struct EvryTabLabel: View {
    let tab: AppTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            if let glyph = tab.toolGlyph {
                Image(glyph).renderingMode(.template)
            } else {
                Image(systemName: "person")
            }
        }
    }
}

/// Brand styling for the system tab bar: the current tab fills sky-soft (the
/// design system's "current page" state), the selected tab — and any tab the
/// Liquid Glass selector passes over — is blue, the rest navy (white in dark),
/// labels are Nunito. Applied once at launch.
enum EvryTabBarAppearance {
    /// The logo's light blue — brand sky, #B0E6FF.
    static let selectedBlue = Color.evrySky

    static func apply() {
        let selectedInk = UIColor(selectedBlue)
        let normalInk = UIColor(Color(light: .evryNavy75, dark: .evryWhite80))
        let currentFill = UIColor(Color(light: .evrySkySoft,
                                        dark: Color.evryNavy.mix(with: .evrySky, by: 0.18)))
        let font = UIFont(name: "Nunito-Bold", size: 11) ?? .systemFont(ofSize: 11, weight: .bold)

        let item = UITabBarItemAppearance()
        for state in [item.normal, item.focused] {
            state.iconColor = normalInk
            state.titleTextAttributes = [.foregroundColor: normalInk, .font: font]
        }
        item.selected.iconColor = selectedInk
        item.selected.titleTextAttributes = [.foregroundColor: selectedInk, .font: font]

        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        appearance.selectionIndicatorTintColor = currentFill

        let bar = UITabBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.tintColor = selectedInk
        bar.unselectedItemTintColor = normalInk
    }
}

/// The navy pull-up pill that opens quick add.
///
/// - **Tap** or **swipe up** → the primary add action.
/// - **Press and hold** → the pill morphs into a half-circle and two tool
///   bubbles (Brain Dump, Pomo Focus) pop up. Drag over one and release to
///   activate it; release on neither to cancel.
struct SwipeHandle: View {
    let palette: Palette
    /// What the primary action adds, for VoiceOver ("Add task", "Add habit"…).
    var actionLabel: String = "Add task"
    let action: () -> Void
    var onBrainDump: (CGPoint) -> Void = { _ in }
    var onPomodoro: (CGPoint) -> Void = { _ in }

    private enum Tool: Equatable { case brainDump, pomodoro }

    @State private var pull: CGFloat = 0
    @State private var menuOpen = false
    @State private var selected: Tool? = nil
    @State private var swiping = false
    @State private var pressWork: DispatchWorkItem? = nil
    /// Pulled far enough that letting go opens quick add (the pill lights up).
    @State private var armed = false
    /// Quick add already fired mid-drag — ignore the rest of this gesture.
    @State private var committed = false

    // Swipe tuning: 1:1 tracking for the first stretch, then rubber-banding.
    private let trackDistance: CGFloat = 24
    private let armDistance: CGFloat = 34
    private let autoCommitDistance: CGFloat = 96

    // Bubble centers as an offset from the handle's center (y negative = up).
    private let bubbleDX: CGFloat = 82
    private let bubbleDY: CGFloat = -104
    private let hitRadius: CGFloat = 58
    private var brainOffset: CGSize { CGSize(width: -bubbleDX, height: bubbleDY) }
    private var pomoOffset: CGSize { CGSize(width: bubbleDX, height: bubbleDY) }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let globalFrame = geo.frame(in: .global)
            ZStack {
                pill
                if menuOpen { menuOverlay(center: center) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(handleGesture(center: center, globalFrame: globalFrame))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .accessibilityLabel(actionLabel)
        .accessibilityHint("Double tap to add. Touch and hold for Brain dump or Pomo focus.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Pill (line)

    /// The line stretches wider and thicker, brightens, and glows as it's
    /// pulled, then snaps a little fuller once armed.
    private var pill: some View {
        let stretch = min(pull / 60, 1)
        return Capsule()
            .fill(palette.primary)
            .frame(width: 48 + stretch * 28 + (armed ? 8 : 0), height: 4 + stretch * 2 + (armed ? 1 : 0))
            .opacity(menuOpen ? 0 : 0.45 + stretch * 0.55)
            .offset(y: -pull)
            .shadow(color: palette.primary.opacity(0.35 + stretch * 0.35), radius: 5 + stretch * 7)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: armed)
    }

    // MARK: Radial menu

    private func menuOverlay(center: CGPoint) -> some View {
        ZStack {
            // The line "morphs" into a half-circle arc opening upward.
            TopArc()
                .stroke(palette.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 104, height: 52)
                .position(x: center.x, y: center.y)

            toolBubble(.brainDump, icon: "lightbulb.fill", label: "Brain dump")
                .position(x: center.x + brainOffset.width, y: center.y + brainOffset.height)
            toolBubble(.pomodoro, icon: "timer", label: "Pomo focus")
                .position(x: center.x + pomoOffset.width, y: center.y + pomoOffset.height)
        }
        .allowsHitTesting(false)   // selection is driven by the drag, not per-bubble taps
    }

    private func toolBubble(_ tool: Tool, icon: String, label: String) -> some View {
        let isOn = selected == tool
        // Navy-tinted shadows (never black in light mode): resting → soft, hovered → lift.
        let ink = palette.dark ? Color.black : Color.evryNavy
        return VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.nunito(size: 22, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 64, height: 64)
                // White bubble with the card hairline and a navy glyph; the
                // hovered one fills sky-soft and lifts.
                .background(isOn ? palette.skySoft : palette.card, in: Circle())
                .overlay(Circle().strokeBorder(isOn ? Color.evrySky : palette.hairline, lineWidth: 1))
                .shadow(color: ink.opacity(palette.dark ? 0.4 : (isOn ? 0.2 : 0.12)),
                        radius: isOn ? 20 : 12, y: isOn ? 14 : 8)
            Text(label)
                .font(.evryCaption)
                .foregroundStyle(isOn ? palette.text : palette.textSec)
        }
        .scaleEffect(isOn ? 1.12 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isOn)
        // Pop in on open; plain quick fade on close so picking a tool feels instant.
        .transition(.asymmetric(
            insertion: .scale(scale: 0.2).combined(with: .opacity),
            removal: .opacity
        ))
    }

    // MARK: Gesture

    private func handleGesture(center: CGPoint, globalFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard !committed else { return }
                // First touch: arm the long-press that opens the radial menu.
                if pressWork == nil && !menuOpen && !swiping {
                    let work = DispatchWorkItem { openMenu() }
                    pressWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
                }

                let dist = hypot(v.translation.width, v.translation.height)
                if menuOpen {
                    updateSelection(toolAt(v.location, center: center))
                } else if dist > 6 {
                    // Moved before the hold fired → it's a swipe, not a hold.
                    pressWork?.cancel(); pressWork = nil
                    swiping = true
                }

                if swiping {
                    let raw = -v.translation.height
                    // Interactive spring so the pill chases the finger smoothly.
                    withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.82)) {
                        pull = rubberBand(raw)
                    }
                    let nowArmed = raw > armDistance
                    if nowArmed != armed {
                        armed = nowArmed
                        if nowArmed { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8) }
                    }
                    // Far enough — launch without waiting for the finger to lift.
                    if raw > autoCommitDistance { launch() }
                }
            }
            .onEnded { v in
                pressWork?.cancel(); pressWork = nil
                if committed {
                    committed = false
                    return
                }
                if menuOpen {
                    let tool = toolAt(v.location, center: center)
                    closeMenu()
                    activate(tool, globalFrame: globalFrame)
                } else if swiping {
                    swiping = false
                    // Armed, or a quick upward flick, opens; otherwise bounce home.
                    if armed || v.predictedEndTranslation.height < -90 {
                        launch()
                        committed = false
                    } else {
                        armed = false
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { pull = 0 }
                    }
                } else {
                    // A plain tap (released before the hold fired, no real drag):
                    // a quick hop, then launch.
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.6)) { pull = 10 }
                    launch()
                    committed = false
                }
            }
    }

    /// 1:1 for the first stretch, then progressively resistant.
    private func rubberBand(_ raw: CGFloat) -> CGFloat {
        guard raw > 0 else { return 0 }
        guard raw > trackDistance else { return raw }
        let over = raw - trackDistance
        return trackDistance + over * 0.55 / (1 + over / 160)
    }

    /// Fires the add action once per gesture. The pill's own launch (stretching
    /// wide and flying up into the card) is the handle's removal transition in
    /// ContentView, so it plays as the card rises from the same spot.
    private func launch() {
        guard !committed else { return }
        committed = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        action()
        // If the handle stays on screen (e.g. Notes opens a sheet), settle back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            armed = false
            withAnimation(.spring(response: 0.42, dampingFraction: 0.6)) { pull = 0 }
        }
    }

    /// Which bubble the finger is over, if any (nearest within the hit radius).
    private func toolAt(_ loc: CGPoint, center: CGPoint) -> Tool? {
        let p = CGPoint(x: loc.x - center.x, y: loc.y - center.y)
        let dBrain = hypot(p.x - brainOffset.width, p.y - brainOffset.height)
        let dPomo  = hypot(p.x - pomoOffset.width,  p.y - pomoOffset.height)
        if dBrain <= dPomo && dBrain < hitRadius { return .brainDump }
        if dPomo < hitRadius { return .pomodoro }
        return nil
    }

    private func updateSelection(_ tool: Tool?) {
        guard tool != selected else { return }
        selected = tool
        if tool != nil { UISelectionFeedbackGenerator().selectionChanged() }
    }

    private func openMenu() {
        pressWork = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
            pull = 0
            menuOpen = true
        }
    }

    private func closeMenu() {
        withAnimation(.easeOut(duration: 0.14)) {
            menuOpen = false
            selected = nil
        }
    }

    private func activate(_ tool: Tool?, globalFrame: CGRect) {
        guard let tool else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let off = tool == .brainDump ? brainOffset : pomoOffset
        let origin = CGPoint(x: globalFrame.midX + off.width, y: globalFrame.midY + off.height)
        switch tool {
        case .brainDump: onBrainDump(origin)
        case .pomodoro:  onPomodoro(origin)
        }
    }
}

/// The handle's exit when quick add opens: the pill stretches wide, lifts, and
/// fades — reading as the line becoming the card that rises in its place.
struct HandleLaunchModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1 + progress * 3.2, y: 1 + progress * 1.2)
            .offset(y: -70 * progress)
            .opacity(1 - Double(progress))
            .blur(radius: 3 * progress)
    }
}

extension AnyTransition {
    /// Pops the handle back in when quick add closes; launches it on the way out.
    static var handleLaunch: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.3).combined(with: .opacity),
            removal: .modifier(active: HandleLaunchModifier(progress: 1),
                               identity: HandleLaunchModifier(progress: 0))
        )
    }
}

/// A half-circle arc opening upward, anchored to the bottom-center of its rect —
/// the shape the add pill morphs into while the tool menu is open.
private struct TopArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY),
            radius: rect.width / 2,
            startAngle: .degrees(180),
            endAngle: .degrees(360),
            clockwise: false
        )
        return p
    }
}
