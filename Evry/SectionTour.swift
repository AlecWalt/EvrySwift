//
//  SectionTour.swift
//  Evry
//
//  First-visit section tours: Evry flies between parts of a screen, lights
//  each one up and explains it. Some steps wait for the person to try the
//  thing themselves (taps inside the highlight reach the app).
//
//  A screen tags its parts with `.tourTarget(_:)` (their on-screen frames are
//  recorded), then asks `TourCenter.shared.request(_:section:steps:)`. The
//  tour starts once nothing else is on screen in that section (the root keeps
//  the gate current) and plays once per section. `SectionTourOverlay` sits at
//  the app's root, over everything.
//
//  Evry is never in two places at once: while a tour runs, the root sets
//  `evryAway`, so the page's own Evry marks step away.
//

import SwiftUI

// MARK: - Targets & steps

/// The parts of the app a tour can light up.
enum TourTarget: Hashable {
    case inboxContent, inboxDay, inboxWeek, inboxBack, inboxEvry
}

/// Things the person does that a waiting step listens for.
enum TourEvent: Equatable {
    case weekOpened, weekClosed, chatOpened
}

struct TourStep {
    enum Advance: Equatable {
        /// A tap anywhere moves on.
        case tap
        /// Waits for the person to do something (their taps inside the
        /// highlight reach the app).
        case event(TourEvent)
    }

    enum Spot {
        case rounded(CGFloat)
        case circle
    }

    var target: TourTarget
    var text: String
    var advance: Advance = .tap
    var spot: Spot = .rounded(16)
    /// Grows (or, negative, shrinks) the highlight around the target.
    var padding: CGFloat = 6
    /// Evry sits on the highlighted spot itself, rather than beside it.
    var evryOnTarget = false
    /// Runs as the step begins (e.g. Evry switching the view).
    var onEnter: (() -> Void)? = nil
    /// For `.event` steps: does the thing for the person — VoiceOver's
    /// "Continue", which can't reach the app under the tour.
    var assist: (() -> Void)? = nil
    /// A tap on the highlight itself runs this, then moves on.
    var onTargetTap: (() -> Void)? = nil

    /// Taps inside the highlight go through to the app.
    var passesThrough: Bool {
        if case .event = advance { return true }
        return false
    }
}

// MARK: - Tour center

@MainActor
@Observable
final class TourCenter {
    static let shared = TourCenter()

    /// Where each target is on screen (global coordinates).
    private(set) var frames: [TourTarget: CGRect] = [:]
    private(set) var tourID: String?
    private(set) var index = 0
    /// Bumped when the person taps outside the highlight on a waiting step.
    private(set) var nudges = 0

    @ObservationIgnored private var steps: [TourStep] = []
    @ObservationIgnored private var pending: (id: String, section: String, steps: [TourStep])?
    @ObservationIgnored private var gate = Gate(blocked: true, section: "")

    /// Whether a tour may start, and which section is showing.
    struct Gate: Equatable {
        var blocked: Bool
        var section: String
    }

    var isActive: Bool { tourID != nil }
    var step: TourStep? { isActive && steps.indices.contains(index) ? steps[index] : nil }
    var isLastStep: Bool { index == steps.count - 1 }

    static func doneKey(_ id: String) -> String { "tour_done_\(id)" }
    static func hasSeen(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: doneKey(id)) }

    /// Every tour plays again (developer tool).
    static func resetAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("tour_done_") {
            defaults.removeObject(forKey: key)
        }
    }

    func register(_ target: TourTarget, frame: CGRect) {
        if frames[target] != frame { frames[target] = frame }
    }

    /// Asks for a section's tour. It starts as soon as nothing else is on
    /// screen in that section — straight away, or once the gate opens.
    func request(_ id: String, section: String, steps: [TourStep]) {
        guard !isActive, !Self.hasSeen(id), !steps.isEmpty else { return }
        pending = (id, section, steps)
        startIfReady()
    }

    /// Kept current by the root: anything covering the page blocks a tour.
    func update(_ gate: Gate) {
        self.gate = gate
        startIfReady()
    }

    private func startIfReady() {
        guard !isActive, let p = pending, !gate.blocked, gate.section == p.section else { return }
        pending = nil
        steps = p.steps
        index = 0
        steps[0].onEnter?()
        // Evry pops in (an overshooting spring).
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { tourID = p.id }
    }

    func next() {
        guard isActive else { return }
        guard index + 1 < steps.count else { return finish() }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { index += 1 }
        steps[index].onEnter?()
    }

    /// A tap on the tour: on the highlight (when it doesn't reach the app) or
    /// anywhere outside it.
    func tapped(onTarget: Bool) {
        guard let step else { return }
        if onTarget, let action = step.onTargetTap {
            next()
            action()
            return
        }
        switch step.advance {
        case .tap: next()
        case .event: nudges += 1   // Evry wiggles: do the thing in the highlight
        }
    }

    /// VoiceOver's "Continue": a waiting step does its thing for the person.
    func assist() {
        guard let step else { return }
        if let assist = step.assist { assist() } else { tapped(onTarget: false) }
    }

    func notify(_ event: TourEvent) {
        guard let step else { return }
        if step.advance == .event(event) {
            next()
        } else if event == .chatOpened {
            finish()
        }
    }

    func finish() {
        guard let id = tourID else { return }
        UserDefaults.standard.set(true, forKey: Self.doneKey(id))
        // Evry pops out: a quick swell as it goes.
        withAnimation(.easeIn(duration: 0.22)) { tourID = nil }
        steps = []
        index = 0
    }
}

extension View {
    /// Records this view's on-screen frame for section tours.
    func tourTarget(_ target: TourTarget) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            TourCenter.shared.register(target, frame: frame)
        }
    }
}

// MARK: - Overlay

/// The tour itself, over everything: a navy scrim with the target cut out
/// and ringed in sky, Evry beside it with what it has to say.
struct SectionTourOverlay: View {
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bubbleHeight: CGFloat = 90

    private var center: TourCenter { .shared }

    var body: some View {
        // The outer reader keeps the safe area (for placing the bubble and the
        // Skip button); the inner one spans the whole screen.
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            GeometryReader { geo in
                if let step = center.step {
                    stage(step, in: geo, insets: insets)
                }
            }
            .ignoresSafeArea()
        }
    }

    private struct Layout {
        var mascot: CGPoint
        var mascotSize: CGFloat
        var bubbleCenter: CGPoint
        var bubbleWidth: CGFloat
    }

    @ViewBuilder
    private func stage(_ step: TourStep, in geo: GeometryProxy, insets: EdgeInsets) -> some View {
        let size = geo.size
        let origin = geo.frame(in: .global).origin
        let target = (center.frames[step.target] ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0))
            .offsetBy(dx: -origin.x, dy: -origin.y)
        let hole = Self.hole(around: target, for: step)
        let radius: CGFloat = switch step.spot {
        case .circle: min(hole.width, hole.height) / 2
        case .rounded(let r): r
        }
        let layout = layout(for: step, hole: hole, size: size, insets: insets)

        ZStack {
            // The scrim — every tap outside the highlight lands here.
            SpotlightShape(hole: hole, radius: radius)
                .fill(Color.evryNavy.opacity(0.55), style: FillStyle(eoFill: true))
                .contentShape(SpotlightShape(hole: hole, radius: radius), eoFill: true)
                .onTapGesture { center.tapped(onTarget: false) }
                .transition(.opacity)

            // Inside the highlight: the app gets the tap on waiting steps;
            // otherwise the tour does.
            if !step.passesThrough {
                Color.clear
                    .frame(width: max(0, hole.width), height: max(0, hole.height))
                    .contentShape(Rectangle())
                    .position(x: hole.midX, y: hole.midY)
                    .onTapGesture { center.tapped(onTarget: true) }
            }

            SpotlightRing(radius: radius, pulse: !reduceMotion)
                .frame(width: max(0, hole.width), height: max(0, hole.height))
                .position(x: hole.midX, y: hole.midY)
                .allowsHitTesting(false)
                .transition(.opacity)

            bubble(step)
                .frame(width: layout.bubbleWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bubbleHeight = $0 }
                .position(layout.bubbleCenter)
                .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))

            mascot(size: layout.mascotSize)
                .position(layout.mascot)
                .allowsHitTesting(false)
                // The tour's Evry pops in and out.
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .scale(scale: 0.2).combined(with: .opacity),
                    removal: .scale(scale: 1.35).combined(with: .opacity)))

        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// The highlight around a target: padded, and for `.circle` a true circle
    /// however tall or wide the target is.
    private static func hole(around target: CGRect, for step: TourStep) -> CGRect {
        let padded = target.insetBy(dx: -step.padding, dy: -step.padding)
        guard case .circle = step.spot else { return padded }
        let side = max(padded.width, padded.height)
        return CGRect(x: padded.midX - side / 2, y: padded.midY - side / 2, width: side, height: side)
    }

    /// Evry beside the highlight — below it if there's room, else above, else
    /// just inside its foot (for whole-page highlights) — or, for
    /// `evryOnTarget`, on the spot itself with the bubble underneath.
    private func layout(for step: TourStep, hole: CGRect, size: CGSize, insets: EdgeInsets) -> Layout {
        let margin: CGFloat = 16
        // Clear of the status bar, and of the tab bar at the bottom.
        let topLimit = insets.top + 8, bottomLimit = size.height - insets.bottom - 64
        if step.evryOnTarget {
            let width = min(290, size.width - 2 * margin)
            let top = hole.maxY + 16
            return Layout(mascot: CGPoint(x: hole.midX, y: hole.midY), mascotSize: 38,
                          bubbleCenter: CGPoint(x: size.width - margin - width / 2, y: top + bubbleHeight / 2),
                          bubbleWidth: width)
        }
        let m: CGFloat = 60
        let width = size.width - 2 * margin - m - 10
        let block = max(bubbleHeight, m)
        // A highlight covering most of the page keeps Evry inside its foot,
        // so the header above stays readable.
        let large = hole.height > size.height * 0.5
        let top: CGFloat
        if bottomLimit - hole.maxY >= block + 16 {
            top = hole.maxY + 16
        } else if !large && hole.minY - topLimit >= block + 16 {
            top = hole.minY - 16 - block
        } else {
            top = min(hole.maxY, bottomLimit) - 28 - block
        }
        return Layout(mascot: CGPoint(x: margin + m / 2, y: top + m / 2), mascotSize: m,
                      bubbleCenter: CGPoint(x: margin + m + 10 + width / 2, y: top + bubbleHeight / 2),
                      bubbleWidth: width)
    }

    private func bubble(_ step: TourStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TypewriterText(text: step.text, haptics: false)
                .id(center.index)
                .font(.nunito(size: 16, weight: .semibold))
                .lineSpacing(3)
                .foregroundStyle(Color.evryNavy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // What to do next, and a way out (kept in the bubble, so it never
            // lands on top of whatever is highlighted).
            HStack {
                if step.advance == .tap {
                    Text(center.isLastStep ? "Tap anywhere to finish" : "Tap to continue")
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(Color.evryNavy.opacity(0.6))
                }
                Spacer(minLength: 8)
                if !center.isLastStep {
                    Button("Skip tour") { center.finish() }
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(Color.evryNavy)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(Color.evrySkySoft, in: Capsule())
                        .contentShape(Capsule())
                        .buttonStyle(PressScaleStyle())
                }
            }
        }
        .padding(14)
        .background(Color.evryWhite, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
        .shadow(color: Color.evryNavy.opacity(0.25), radius: 12, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { center.tapped(onTarget: false) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evry says: \(step.text)")
        .accessibilityAction(named: center.isLastStep ? "Finish" : "Continue") { center.assist() }
        .accessibilityAction(named: "Skip tour") { center.finish() }
    }

    /// Evry, flying: a tilt and stretch on every hop, a wiggle when the person
    /// taps outside a step that's waiting for them.
    private func mascot(size: CGFloat) -> some View {
        EvryMascot(size: size)
            .shadow(color: Color.evryNavy.opacity(0.3), radius: 8, y: 6)
            .keyframeAnimator(initialValue: FlightPose(), trigger: reduceMotion ? 0 : center.index) { view, pose in
                view.rotationEffect(.degrees(pose.tilt)).scaleEffect(pose.scale)
            } keyframes: { _ in
                KeyframeTrack(\.tilt) {
                    CubicKeyframe(-14, duration: 0.2)
                    CubicKeyframe(8, duration: 0.25)
                    SpringKeyframe(0, duration: 0.35)
                }
                KeyframeTrack(\.scale) {
                    CubicKeyframe(0.88, duration: 0.15)
                    CubicKeyframe(1.1, duration: 0.3)
                    SpringKeyframe(1, duration: 0.35)
                }
            }
            .keyframeAnimator(initialValue: CGFloat(0), trigger: center.nudges) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-7, duration: 0.06)
                    CubicKeyframe(7, duration: 0.1)
                    CubicKeyframe(-4, duration: 0.08)
                    SpringKeyframe(0, duration: 0.2)
                }
            }
            .frame(width: size, height: size)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: size)
    }
}

private struct FlightPose {
    var tilt: Double = 0
    var scale: CGFloat = 1
}

/// The whole screen with a rounded hole cut out. Animatable, so the hole
/// glides from one target to the next.
private struct SpotlightShape: Shape {
    var hole: CGRect
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get {
            AnimatablePair(AnimatablePair(hole.minX, hole.minY),
                           AnimatablePair(AnimatablePair(hole.width, hole.height), radius))
        }
        set {
            hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first.first, height: newValue.second.first.second)
            radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let r = max(0, min(radius, min(hole.width, hole.height) / 2))
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: r, height: r), style: .continuous)
        return path
    }
}

/// The sky ring around the highlight, breathing gently.
private struct SpotlightRing: View {
    let radius: CGFloat
    let pulse: Bool
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.evrySky, lineWidth: 3)
            .scaleEffect(on ? 1.03 : 1)
            .opacity(on ? 0.7 : 1)
            .animation(pulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: on)
            .onAppear { on = pulse }
    }
}
