//
//  SetupFlowView.swift
//  Evry
//
//  Onboarding. It opens on what Evry gives you — three short, calm slides (no
//  mascot yet). Starting setup brings Evry in: it pops onto a white screen, does
//  a happy hop and says hello, then asks — one thing at a time — for the
//  person's name, their email, and (with the reasons spelled out) their location.
//
//  Evry is a single view for the whole flow: it moves and resizes between steps
//  rather than appearing per page, so Evry is never in two places at once.
//  Everything that changes is animated, and decorative motion stops under
//  Reduce Motion.
//

import SwiftUI
import CoreLocation
import UIKit

// MARK: - Steps

private enum SetupStep: Int, Comparable {
    case splash, hello, intro, welcome, name, email, location, trial, done

    static func < (a: SetupStep, b: SetupStep) -> Bool { a.rawValue < b.rawValue }

    /// The steps shown as progress dots.
    static let questions: [SetupStep] = [.name, .email, .location, .trial]
}

// MARK: - Location helper

@Observable
private final class LocationHelper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }

    func requestAccess() { manager.requestWhenInUseAuthorization() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
    }
}

// MARK: - Flow

struct SetupFlowView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("user_name") private var savedName = ""
    @AppStorage("user_email") private var savedEmail = ""

    @State private var step: SetupStep = .splash
    @State private var introPage = 0
    /// Direction of the last step change, so pages slide the right way.
    @State private var forward = true
    @State private var name = ""
    @State private var email = ""
    @State private var emailError = false
    @State private var location = LocationHelper()

    // Welcome choreography.
    @State private var mascotIn = false
    @State private var bubbleIn = false
    @State private var controlsIn = false
    /// Bumped to play Evry's happy hop.
    @State private var happy = 0

    @FocusState private var focused: Field?
    private enum Field { case name, email }

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var firstName: String { trimmedName.split(separator: " ").first.map(String.init) ?? trimmedName }

    /// The narrow column every field and button sits in.
    private let columnWidth: CGFloat = 280

    var body: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            // The big colour section — it moves, bends and changes with each step.
            SetupBackdrop(layout: band, palette: palette)

            switch step {
            case .splash:
                SplashView(palette: palette) {
                    withAnimation(EvryMotion.settle) { step = .hello }
                }
                .transition(.opacity)
            case .hello:
                HelloView(palette: palette) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(EvryMotion.settle) { step = .intro }
                }
                .transition(.opacity.combined(with: .offset(y: -24)))
            case .intro:
                FeatureIntro(page: $introPage, palette: palette, onStart: startSetup)
                    .transition(.opacity.combined(with: .offset(y: 24)))
            default:
                setupStage
                    .transition(.opacity)
            }
        }
        .onAppear(perform: prefill)
        .onChange(of: location.status) { _, status in
            // Once the person answers the system prompt, move on.
            guard step == .location, status != .notDetermined else { return }
            go(to: .trial, focus: nil)
        }
    }

    /// Evry and the questions — everything after the intro.
    private var setupStage: some View {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)

                // The one Evry for the whole flow.
                HappyMascot(size: mascotSize, happy: happy, listening: isTyping)
                    .scaleEffect(mascotIn ? 1 : 0.3)
                    .opacity(mascotIn ? 1 : 0)
                    .animation(EvryMotion.settle, value: mascotSize)

                if bubbleIn {
                    SpeechBubble(text: bubbleText, palette: palette) {
                        // The welcome's button arrives once Evry has finished saying hello.
                        if step == .welcome && !controlsIn {
                            withAnimation(EvryMotion.settle) { controlsIn = true }
                        }
                    }
                        .padding(.top, 14)
                        .padding(.horizontal, 32)
                        .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                }

                stepContent
                    .padding(.top, 24)

                Spacer(minLength: 12)

                if controlsIn {
                    controls
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .offset(y: 24)))
                }
            }
            .frame(maxWidth: .infinity)
    }

    // MARK: Layout pieces

    /// Where the colour section sits for each step (and each intro slide).
    private var band: BandLayout {
        let off = BandLayout.off, past = BandLayout.past
        switch step {
        case .splash:
            // Tucked away below the screen, ready to rise into the welcome.
            return BandLayout(top: past, bottom: past)
        case .hello:
            return BandLayout(top: 0.6, topBulge: -42, topTilt: -16, bottom: past)
        case .intro:
            switch introPage {
            case 0: return BandLayout(top: off, bottom: 0.47, bottomBulge: 34)
            case 1: return BandLayout(top: off, bottom: 0.5, bottomBulge: -28, bottomTilt: 26)
            default: return BandLayout(top: off, bottom: 0.47, bottomBulge: 26, bottomTilt: -30)
            }
        case .welcome:
            return BandLayout(top: 0.74, topBulge: -36, bottom: past)
        // The questions keep a slim strip up top, clear of Evry (who never
        // sits on sky without a disc).
        case .name:
            return BandLayout(top: off, bottom: 0.13, bottomBulge: 14, bottomTilt: 12)
        case .email:
            return BandLayout(top: off, bottom: 0.13, bottomBulge: -10, bottomTilt: -12)
        case .location:
            return BandLayout(top: off, bottom: 0.12, bottomBulge: 16, bottomTilt: 14)
        case .trial:
            return BandLayout(top: 0.69, topBulge: -36, topTilt: 18, bottom: past, navy: true)
        case .done:
            return BandLayout(top: 0.82, topBulge: -40, topTilt: -14, bottom: past)
        }
    }

    private var mascotSize: CGFloat {
        switch step {
        case .splash, .hello, .intro, .welcome: 170
        case .done: 140
        default: focused == nil ? 120 : 88
        }
    }

    /// Evry leans in while the person types an answer.
    private var isTyping: Bool {
        switch focused {
        case .name: !trimmedName.isEmpty
        case .email: !trimmedEmail.isEmpty
        case nil: false
        }
    }

    private var topBar: some View {
        HStack {
            if step > .welcome && step < .done {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.nunito(size: 17, weight: .bold))
                        .foregroundStyle(palette.text)
                        .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Back")
                .transition(.opacity.combined(with: .offset(x: -12)))
            }
            Spacer()
        }
        .overlay {
            if step > .welcome && step < .done {
                progressDots.transition(.opacity)
            }
        }
        .frame(height: EvrySpace.tap)
        .padding(.horizontal, 8)
        .animation(EvryMotion.settle, value: step)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.questions, id: \.rawValue) { q in
                Capsule()
                    .fill(q <= step ? palette.primary : palette.border)
                    .frame(width: q == step ? 22 : 8, height: 8)
            }
        }
        .animation(EvryMotion.spring, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((SetupStep.questions.firstIndex(of: step) ?? 0) + 1) of \(SetupStep.questions.count)")
    }

    private var bubbleText: String {
        switch step {
        case .splash, .hello, .intro: ""
        case .welcome: "Hi, I’m Evry! Let’s get started :)"
        case .name: "What should I call you?"
        case .email: "Nice to meet you, \(firstName)! What’s your email?"
        case .location:
            switch location.status {
            case .denied, .restricted: "No problem — you can turn location on in Settings anytime."
            case .authorizedWhenInUse, .authorizedAlways: "Your location’s already on — thank you!"
            default: "Can I use your location?"
            }
        case .trial: "You’ll have access to Evry for \(MembershipAccess.trialDays) days! After that, we’ll ask if you’d like to sign up!"
        case .done: firstName.isEmpty ? "You’re all set!" : "You’re all set, \(firstName)!"
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        ZStack {
            switch step {
            case .splash, .hello, .intro, .welcome, .done:
                Color.clear.frame(height: 0)
            case .name:
                nameField.transition(pageTransition)
            case .email:
                emailField.transition(pageTransition)
            case .location:
                locationReasons.transition(pageTransition)
            case .trial:
                trialBadge.transition(pageTransition)
            }
        }
        .frame(width: columnWidth)
        .animation(EvryMotion.settle, value: step)
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private var nameField: some View {
        TextField("", text: $name, prompt: Text("Your name").foregroundStyle(palette.textPh))
            .textContentType(.givenName)
            .textInputAutocapitalization(.words)
            .submitLabel(.next)
            .focused($focused, equals: .name)
            .onSubmit(next)
            .multilineTextAlignment(.center)
            .evryTextField(palette, focused: focused == .name)
            .animation(EvryMotion.hover, value: focused)
            .accessibilityLabel("Your name")
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(palette.textPh))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focused, equals: .email)
                .onSubmit(next)
                .multilineTextAlignment(.center)
                .evryTextField(palette, focused: focused == .email, error: emailError)
                .animation(EvryMotion.hover, value: focused)
                .accessibilityLabel("Your email")
                .onChange(of: email) { _, _ in
                    if emailError { withAnimation(EvryMotion.settle) { emailError = false } }
                }

            if emailError {
                FieldError(message: "That email doesn’t look quite right.", palette: palette)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(EvryMotion.settle, value: emailError)
    }

    /// The trial, at a glance: a big day count that pops in under Evry's line.
    private var trialBadge: some View {
        VStack(spacing: 0) {
            Text("\(MembershipAccess.trialDays)")
                .font(.nunito(size: 48, weight: .heavy))
                .tracking(EvryTracking.price)
                .foregroundStyle(Color.evryNavy)
            Text("days free")
                .font(.nunito(size: 14, weight: .bold))
                .foregroundStyle(Color.evryNavy.opacity(0.8))
        }
        .frame(width: 128, height: 128)
        .background(Color.evrySky, in: Circle())
        .overlay(Circle().strokeBorder(Color.evryWhite, lineWidth: 4))
        .modifier(RiseIn(index: 1))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(MembershipAccess.trialDays) days free")
    }

    /// Why Evry asks for location — said plainly before the system prompt.
    private var locationReasons: some View {
        VStack(alignment: .leading, spacing: 12) {
            reasonRow(icon: "mappin.and.ellipse",
                      title: "Location Searching",
                      detail: "Helps us find local spots when adding locations to tasks or events.",
                      index: 0)
            reasonRow(icon: "car.fill",
                      title: "Driving Times",
                      detail: "We’ll automatically calculate driving times based on location.",
                      index: 1)
            Text("You can change this anytime in Settings.")
                .font(.nunito(size: 13, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .modifier(RiseIn(index: 2))
        }
    }

    private func reasonRow(icon: String, title: String, detail: String, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(Color.evryNavy)
                .frame(width: 34, height: 34)
                .background(Color.evrySky, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.nunito(size: 15, weight: .bold))
                    .foregroundStyle(palette.text)
                Text(detail)
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .evryCard(palette, cornerRadius: EvryRadius.field, shadow: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
        .modifier(RiseIn(index: index))
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            switch step {
            case .welcome:
                Button("Let’s go", action: next)
                    .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
            case .name:
                Button("Continue", action: next)
                    .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                    .disabled(trimmedName.isEmpty)
            case .email:
                Button("Continue", action: next)
                    .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                    .disabled(trimmedEmail.isEmpty)
            case .location:
                if location.status == .notDetermined {
                    Button("Allow location") { location.requestAccess() }
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                    Button("Not now", action: next)
                        .buttonStyle(EvrySecondaryButtonStyle(palette: palette, fullWidth: true))
                } else {
                    Button("Continue", action: next)
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                }
            case .trial:
                // On the navy band: the sky button.
                Button("Sounds good", action: finish)
                    .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
            case .splash, .hello, .intro, .done:
                EmptyView()
            }
        }
        .frame(width: columnWidth)
        .animation(EvryMotion.settle, value: step)
        .animation(EvryMotion.hover, value: trimmedName.isEmpty)
        .animation(EvryMotion.hover, value: trimmedEmail.isEmpty)
    }

    // MARK: Flow

    private func prefill() {
        if name.isEmpty { name = savedName }
        if email.isEmpty { email = savedEmail }
    }

    /// Leaving the intro: the slides clear, then Evry arrives.
    private func startSetup() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : EvryMotion.settle) { step = .welcome }
        playWelcome()
    }

    /// Evry pops in, hops happily, then types hello; the button rises in once
    /// the line is finished (see the bubble's `onFinished`).
    private func playWelcome() {
        guard !mascotIn else { return }
        let quick = reduceMotion
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(quick ? 0 : 450))
            withAnimation(quick ? .easeOut(duration: 0.25) : EvryMotion.pop) { mascotIn = true }
            try? await Task.sleep(for: .milliseconds(quick ? 0 : 520))
            if !quick { happy += 1 }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            try? await Task.sleep(for: .milliseconds(quick ? 0 : 750))
            withAnimation(quick ? .easeOut(duration: 0.25) : EvryMotion.spring) { bubbleIn = true }
        }
    }

    private func next() {
        switch step {
        case .splash, .hello, .intro:
            startSetup()
        case .welcome:
            go(to: .name, focus: .name)
        case .name:
            guard !trimmedName.isEmpty else { return }
            savedName = trimmedName
            go(to: .email, focus: .email)
        case .email:
            guard isValidEmail(trimmedEmail) else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                withAnimation(EvryMotion.settle) { emailError = true }
                return
            }
            savedEmail = trimmedEmail
            go(to: .location, focus: nil)
        case .location:
            go(to: .trial, focus: nil)
        case .trial, .done:
            finish()
        }
    }

    private func goBack() {
        switch step {
        case .name: go(to: .welcome, focus: nil, forward: false)
        case .email: go(to: .name, focus: .name, forward: false)
        case .location: go(to: .email, focus: .email, forward: false)
        case .trial: go(to: .location, focus: nil, forward: false)
        default: break
        }
    }

    private func go(to target: SetupStep, focus: Field?, forward isForward: Bool = true) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        forward = isForward
        // Field to field (name ⇄ email): hand focus straight across so the
        // keyboard stays up and nothing jumps. Otherwise the keyboard goes down.
        let keyboardWasUp = focused != nil
        if focus == nil || !keyboardWasUp { focused = nil }
        withAnimation(reduceMotion ? .easeOut(duration: 0.25) : EvryMotion.settle) {
            emailError = false
            step = target
        }
        // A little hop each time Evry asks something new.
        if isForward && !reduceMotion { happy += 1 }
        guard let focus else { return }
        Task { @MainActor in
            if keyboardWasUp {
                // The new field is inserted this frame; focus it on the next
                // one, while the old field is still in place — no keyboard gap.
                await Task.yield()
            } else {
                // Coming from a screen without the keyboard: let the page slide
                // in before it comes up.
                try? await Task.sleep(for: .milliseconds(380))
            }
            if step == target { focused = focus }
        }
    }

    /// Evry says goodbye with a happy hop, then the app opens.
    private func finish() {
        guard step != .done else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        focused = nil
        forward = true
        withAnimation(EvryMotion.settle) {
            controlsIn = false
            step = .done
        }
        if !reduceMotion { happy += 1 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1700))
            dismiss()
        }
    }

    private func isValidEmail(_ s: String) -> Bool {
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !s.contains(" ") else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

// MARK: - Colour bands (full-screen colour sections)

/// Where the big colour section sits for a step: a band between a top edge and
/// a bottom edge, each a soft curve. Fractions are of the screen height;
/// values past 0…1 put that edge off-screen (so a "top" band has `top < 0`, a
/// "bottom" band `bottom > 1`, and the full flood both). Bulge and tilt are in
/// points: bulge bows the edge (negative = up), tilt raises one side.
private struct BandLayout: Equatable {
    var top: Double
    var topBulge: Double = 0
    var topTilt: Double = 0
    var bottom: Double
    var bottomBulge: Double = 0
    var bottomTilt: Double = 0
    /// Navy instead of sky — the flow's one navy band (near the end).
    var navy = false

    static let off = -0.2
    static let past = 1.2

    /// The softer band layered just behind, for depth.
    var behind: BandLayout {
        var b = self
        if top > 0 { b.top -= 0.04 }
        if bottom < 1 { b.bottom += 0.04 }
        b.topBulge *= 1.35; b.bottomBulge *= 1.35
        b.topTilt *= -0.7; b.bottomTilt *= -0.7
        return b
    }
}

/// A full-width band of colour with curved top and bottom edges. Every value
/// animates, so one band can sweep, bend and travel between layouts.
private struct BandShape: Shape {
    var layout: BandLayout

    var animatableData: AnimatablePair<AnimatablePair<Double, AnimatablePair<Double, Double>>,
                                       AnimatablePair<Double, AnimatablePair<Double, Double>>> {
        get {
            AnimatablePair(AnimatablePair(layout.top, AnimatablePair(layout.topBulge, layout.topTilt)),
                           AnimatablePair(layout.bottom, AnimatablePair(layout.bottomBulge, layout.bottomTilt)))
        }
        set {
            layout.top = newValue.first.first
            layout.topBulge = newValue.first.second.first
            layout.topTilt = newValue.first.second.second
            layout.bottom = newValue.second.first
            layout.bottomBulge = newValue.second.second.first
            layout.bottomTilt = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let h = rect.height, w = rect.width
        let topY = layout.top * h, bottomY = layout.bottom * h
        var p = Path()
        p.move(to: CGPoint(x: 0, y: topY + layout.topTilt))
        p.addQuadCurve(to: CGPoint(x: w, y: topY - layout.topTilt),
                       control: CGPoint(x: w / 2, y: topY + layout.topBulge * 2))
        p.addLine(to: CGPoint(x: w, y: bottomY - layout.bottomTilt))
        p.addQuadCurve(to: CGPoint(x: 0, y: bottomY + layout.bottomTilt),
                       control: CGPoint(x: w / 2, y: bottomY + layout.bottomBulge * 2))
        p.closeSubpath()
        return p
    }
}

/// The two layered bands behind the setup flow. Solid fills only — the
/// design system allows no gradients besides the sky glow.
private struct SetupBackdrop: View {
    let layout: BandLayout
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var front: Color {
        if layout.navy { return palette.dark ? Color.evryNavySoft : .evryNavy }
        return palette.dark ? Color.evryNavy.mix(with: .evrySky, by: 0.28) : .evrySky
    }

    private var back: Color {
        if layout.navy { return palette.dark ? Color.evryNavy.mix(with: .evrySky, by: 0.28) : .evrySky }
        return palette.dark ? Color.evryNavy.mix(with: .evrySky, by: 0.14) : .evrySkySoft
    }

    var body: some View {
        ZStack {
            BandShape(layout: layout.behind)
                .fill(back)
                // The back band drifts slowly, so the screen never feels still.
                .offset(y: breathe && !reduceMotion ? 7 : -7)
                .animation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true), value: breathe)
            BandShape(layout: layout)
                .fill(front)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.95, dampingFraction: 0.86),
                   value: layout)
        .onAppear { breathe = true }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Splash

/// The opening splash: sky ribbons draw in from opposite corners and sway,
/// Evry's logo settles in the middle, then everything clears into the intro.
private struct SplashView: View {
    let palette: Palette
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0      // ribbons drawing in, 0→1
    @State private var cleared: CGFloat = 0    // ribbons retracting, 0→1
    @State private var sway = false
    @State private var logoIn = false
    @State private var logoOut = false

    var body: some View {
        ZStack {
            ribbons(corner: .topLeading)
            ribbons(corner: .bottomTrailing)

            EvryLogo(palette: palette, markWidth: 76, wordmarkSize: 46)
                .scaleEffect(logoOut ? 1.12 : (logoIn ? 1 : 0.82))
                .opacity(logoIn && !logoOut ? 1 : 0)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evry")
        .task { await play() }
    }

    private func ribbons(corner: RibbonShape.Corner) -> some View {
        ZStack {
            RibbonShape(corner: corner, offset: 0, sway: sway ? 1 : 0)
                .trim(from: cleared, to: drawn)
                .stroke(palette.dark ? Color.evryNavy.mix(with: .evrySky, by: 0.2) : .evrySkySoft,
                        style: StrokeStyle(lineWidth: 78, lineCap: .round))
            RibbonShape(corner: corner, offset: 30, sway: sway ? 1 : 0)
                .trim(from: cleared, to: drawn)
                .stroke(Color.evrySky, style: StrokeStyle(lineWidth: 40, lineCap: .round))
        }
        .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: sway)
    }

    private func play() async {
        if reduceMotion {
            drawn = 1; logoIn = true
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeOut(duration: 0.3)) { logoOut = true; cleared = 1 }
            try? await Task.sleep(for: .milliseconds(300))
            onFinish()
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 1.1)) { drawn = 1 }
        sway = true
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(EvryMotion.pop) { logoIn = true }
        try? await Task.sleep(for: .milliseconds(1700))
        // Out: the ribbons pull away along their own length as the logo lifts off.
        withAnimation(.timingCurve(0.6, 0, 0.8, 0.6, duration: 0.65)) { cleared = 1 }
        withAnimation(.easeIn(duration: 0.4)) { logoOut = true }
        try? await Task.sleep(for: .milliseconds(450))
        onFinish()
    }
}

/// A soft S-shaped ribbon sweeping across one corner of the screen.
private struct RibbonShape: Shape {
    enum Corner { case topLeading, bottomTrailing }
    let corner: Corner
    /// Shifts the ribbon along its normal, to stack two bands side by side.
    var offset: CGFloat
    /// 0…1 — bends the wave a little, for the slow sway.
    var sway: CGFloat

    var animatableData: CGFloat {
        get { sway }
        set { sway = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let s = sway * 26
        // Drawn for the top-leading corner, then rotated for bottom-trailing.
        var p = Path()
        p.move(to: CGPoint(x: -60, y: h * 0.27 + offset))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.13 + offset),
                   control1: CGPoint(x: w * 0.22, y: h * 0.31 + offset + s),
                   control2: CGPoint(x: w * 0.26, y: h * 0.12 + offset - s))
        p.addCurve(to: CGPoint(x: w + 60, y: -h * 0.02 + offset),
                   control1: CGPoint(x: w * 0.74, y: h * 0.14 + offset + s),
                   control2: CGPoint(x: w * 0.82, y: -h * 0.03 + offset - s))
        guard corner == .bottomTrailing else { return p }
        return p.applying(CGAffineTransform(translationX: w, y: h).rotated(by: .pi))
    }
}

// MARK: - Hello

/// Right after the splash: a warm thank-you before the intro slides. No
/// mascot yet — Evry arrives once setup starts.
private struct HelloView: View {
    let palette: Palette
    let onContinue: () -> Void

    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("Welcome!")
                .font(.nunito(size: 44, weight: .heavy))
                .tracking(-0.9)
                .foregroundStyle(palette.text)
                .appearWhen(shown, delay: 0.05)
            Text("Thanks for downloading Evry! Now, let’s make your day easier (^o^)")
                .font(.evryLead)
                .lineSpacing(5)
                .foregroundStyle(palette.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 14)
                .appearWhen(shown, delay: 0.22)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
            Button("Continue", action: onContinue)
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                .frame(width: 280)
                .appearWhen(shown, delay: 0.45)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, EvrySpace.grid)
        .onAppear { shown = true }
    }
}

// MARK: - Feature intro

/// The opening slides: what Evry gives you, told as feelings — peace of mind,
/// time back, calmer days. No mascot here; Evry arrives when setup starts.
private struct FeatureIntro: View {
    @Binding var page: Int
    let palette: Palette
    let onStart: () -> Void

    private struct Slide {
        let title: String
        let body: String
    }

    private let slides = [
        Slide(title: "Take the load off your mind",
              body: "Your to‑dos, notes, plans and habits live in one calm place, so you don’t have to carry them all in your head."),
        Slide(title: "Have Evry do it for you",
              body: "Evry sorts your thoughts, plans your day and reminds you at the right moment, giving you back time and energy."),
        Slide(title: "Make life simpler",
              body: "The tedious, fiddly parts of life get lighter, so every day feels simpler and less stressful."),
    ]

    private var isLast: Bool { page == slides.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLast {
                    Button("Skip", action: onStart)
                        .font(.nunito(size: 15, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .frame(minWidth: EvrySpace.tap, minHeight: EvrySpace.tap)
                        .transition(.opacity)
                }
            }
            .frame(height: EvrySpace.tap)
            .padding(.horizontal, 12)
            .animation(EvryMotion.settle, value: isLast)

            TabView(selection: $page) {
                ForEach(slides.indices, id: \.self) { i in
                    slideView(slides[i], index: i, active: page == i)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page) { _, _ in UISelectionFeedbackGenerator().selectionChanged() }

            dots.padding(.bottom, 20)

            Button(isLast ? "Get started" : "Next") {
                if isLast { onStart() } else { withAnimation(EvryMotion.settle) { page += 1 } }
            }
            .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
            .frame(width: 280)
            .contentTransition(.opacity)
            .animation(EvryMotion.settle, value: isLast)
            .padding(.bottom, 12)
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(slides.indices, id: \.self) { i in
                Capsule()
                    .fill(i == page ? palette.primary : palette.border)
                    .frame(width: i == page ? 22 : 8, height: 8)
            }
        }
        .animation(EvryMotion.spring, value: page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page + 1) of \(slides.count)")
    }

    private func slideView(_ slide: Slide, index: Int, active: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch index {
                case 0: LoadOffArt(active: active, palette: palette)
                case 1: DoneForYouArt(active: active, palette: palette)
                default: SimplerArt(active: active, palette: palette)
                }
            }
            .frame(height: 250)
            .background {
                // A white porthole, so sky tiles and chips read over the sky band.
                Circle()
                    .fill(palette.card)
                    .frame(width: 290, height: 290)
                    .scaleEffect(active ? 1 : 0.85)
                    .animation(EvryMotion.spring, value: active)
            }
            .accessibilityHidden(true)

            Text(slide.title)
                .font(.nunito(size: 28, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .padding(.top, 36)
                .appearWhen(active, delay: 0.18)
            Text(slide.body)
                .font(.evryBody)
                .lineSpacing(5)
                .foregroundStyle(palette.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 10)
                .appearWhen(active, delay: 0.26)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, EvrySpace.grid)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Fades and rises in when `active` turns on (and back out when it turns
    /// off), after `delay`. Plain fade under Reduce Motion.
    func appearWhen(_ active: Bool, delay: Double = 0) -> some View {
        modifier(AppearWhen(active: active, delay: delay))
    }
}

private struct AppearWhen: ViewModifier {
    let active: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: active || reduceMotion ? 0 : 16)
            .animation(active ? EvryMotion.settle.delay(delay) : .easeOut(duration: 0.15), value: active)
    }
}

/// Slide 1: a face weighed down by everything it's keeping track of — eyes
/// squeezed into "> <", a squiggly mouth, thoughts and to-dos buzzing around
/// it. Then the noise clears, its eyes open, it looks left, then right, and
/// finally smiles straight ahead.
private struct LoadOffArt: View {
    let active: Bool
    let palette: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The noise is buzzing around the face.
    @State private var noisy = false
    /// The noise has been and gone (it flies outward rather than back in).
    @State private var cleared = false
    /// Squinting eyes and a squiggly mouth.
    @State private var stressed = false
    /// Where the eyes look: -1 left, 0 ahead, 1 right.
    @State private var gaze: Double = 0
    @State private var smiling = false

    /// The buzzing "noise": what the face is trying to hold on to.
    private struct Bit { let symbol: String?; let angle: Double; let radius: CGFloat; let size: CGFloat; let speed: Double }
    private let bits: [Bit] = [
        Bit(symbol: "questionmark", angle: -100, radius: 104, size: 20, speed: 9),
        Bit(symbol: "bell.fill", angle: -45, radius: 112, size: 18, speed: 11),
        Bit(symbol: nil, angle: -10, radius: 118, size: 30, speed: 13),
        Bit(symbol: "calendar", angle: 30, radius: 108, size: 19, speed: 10),
        Bit(symbol: "exclamationmark", angle: 70, radius: 112, size: 20, speed: 12),
        Bit(symbol: nil, angle: 120, radius: 110, size: 26, speed: 9.5),
        Bit(symbol: "checklist", angle: 160, radius: 112, size: 19, speed: 11.5),
        Bit(symbol: "lightbulb.fill", angle: -150, radius: 108, size: 18, speed: 10.5),
        Bit(symbol: nil, angle: -175, radius: 96, size: 22, speed: 12.5),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(noisy || stressed) || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(bits.enumerated()), id: \.offset) { i, bit in
                    noise(bit, index: i, t: t)
                }
                face(t: t)
            }
        }
        .task(id: active) { await play() }
    }

    private func face(t: Double) -> some View {
        // A little tremble while stressed.
        let shake = stressed && !reduceMotion ? sin(t * 38) * 1.6 : 0
        return ZStack {
            HStack(spacing: 34) {
                EyeShape(squint: stressed ? 1 : 0, pointsRight: true)
                EyeShape(squint: stressed ? 1 : 0, pointsRight: false)
            }
            .frame(height: 26)
            .offset(x: gaze * 10, y: -18)
            MouthShape(squiggle: stressed ? 1 : 0, smile: smiling ? 1 : (stressed ? -0.15 : 0))
                .frame(width: 54, height: 26)
                .offset(x: gaze * 3, y: 26)
        }
        .foregroundStyle(Color.evryNavy)
        .offset(x: shake + gaze * 4)
        .scaleEffect(smiling ? 1.06 : 1)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: stressed)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: gaze)
        .animation(.spring(response: 0.55, dampingFraction: 0.55), value: smiling)
    }

    @ViewBuilder
    private func noise(_ bit: Bit, index i: Int, t: Double) -> some View {
        let rad = bit.angle * .pi / 180
        // Jitter: each bit buzzes on its own rhythm while it's there.
        let jx = reduceMotion ? 0 : sin(t * bit.speed + Double(i)) * 5
        let jy = reduceMotion ? 0 : cos(t * bit.speed * 1.2 + Double(i) * 2) * 5
        let spin = reduceMotion ? 0 : sin(t * bit.speed * 0.7 + Double(i)) * 12
        let reach = noisy ? bit.radius : (cleared ? bit.radius + 60 : bit.radius * 0.4)
        Group {
            if let symbol = bit.symbol {
                Image(systemName: symbol)
                    .font(.nunito(size: bit.size, weight: .heavy))
                    .foregroundStyle(i.isMultiple(of: 3) ? Color.evryNavy : Color.evryNavy.opacity(0.75))
            } else {
                ScribbleShape()
                    .stroke(Color.evrySky, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: bit.size, height: bit.size * 0.7)
            }
        }
        .rotationEffect(.degrees(spin))
        .offset(x: cos(rad) * reach + jx, y: sin(rad) * reach + jy)
        .scaleEffect(noisy ? 1 : 0.3)
        .opacity(noisy ? 1 : 0)
        .animation(noisy ? EvryMotion.pop.delay(0.06 * Double(i)) : .easeIn(duration: 0.35).delay(0.03 * Double(i)),
                   value: noisy)
    }

    private func play() async {
        noisy = false; cleared = false; stressed = false; gaze = 0; smiling = false
        guard active else { return }
        if reduceMotion {
            smiling = true
            return
        }
        // Overwhelmed.
        try? await Task.sleep(for: .milliseconds(500))
        if Task.isCancelled { return }
        stressed = true
        noisy = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        try? await Task.sleep(for: .milliseconds(2400))
        if Task.isCancelled { return }
        // The noise goes first…
        cleared = true
        noisy = false
        try? await Task.sleep(for: .milliseconds(700))
        if Task.isCancelled { return }
        // …then the eyes open and look around: left…
        stressed = false
        gaze = -1
        try? await Task.sleep(for: .milliseconds(750))
        if Task.isCancelled { return }
        // …right…
        gaze = 1
        try? await Task.sleep(for: .milliseconds(750))
        if Task.isCancelled { return }
        // …and a smile, straight ahead.
        gaze = 0
        smiling = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}

/// One eye that morphs between open (a tall rounded dot) and a squint chevron
/// (">" for the left eye, "<" for the right).
private struct EyeShape: Shape {
    var squint: Double
    let pointsRight: Bool

    var animatableData: Double {
        get { squint }
        set { squint = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let midY = rect.midY
        // Open: a short stroke that the round caps turn into a dot. Squinting
        // stretches it into the chevron's arms.
        let half = 2.0 + squint * 6.5
        let reach = 14.0 * squint * (pointsRight ? 1 : -1)
        let baseX = pointsRight ? -7.0 * squint : 7.0 * squint
        var p = Path()
        p.move(to: CGPoint(x: baseX, y: midY - half))
        p.addLine(to: CGPoint(x: baseX + reach, y: midY))
        p.addLine(to: CGPoint(x: baseX, y: midY + half))
        return p.strokedPath(StrokeStyle(lineWidth: 11 - squint * 3, lineCap: .round, lineJoin: .round))
    }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { CGSize(width: 1, height: 26) }
}

/// The mouth: a line that can wobble into a squiggle or curve up into a smile.
private struct MouthShape: Shape {
    var squiggle: Double
    var smile: Double
    /// Number of wiggles across the width.
    var waves: Double = 2
    /// Shifts the wiggle along the line (for a shimmer).
    var phase: Double = 0
    var lineWidth: CGFloat = 6

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(squiggle, smile) }
        set { squiggle = newValue.first; smile = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, midY = rect.midY
        var p = Path()
        let steps = 28
        for i in 0...steps {
            let f = Double(i) / Double(steps)          // 0…1 across
            let x = -0.5 + f                            // -0.5…0.5
            let wave = sin(f * .pi * 2 * waves + phase) * 5 * squiggle
            // Smile: corners up, centre down.
            let curve = smile * 9 * (1 - 4 * x * x)
            let pt = CGPoint(x: rect.minX + w * f, y: midY + wave + curve - smile * 2)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

/// A little scribble — a thought that won't sit still.
private struct ScribbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addCurve(to: CGPoint(x: rect.width * 0.45, y: rect.midY),
                   control1: CGPoint(x: rect.width * 0.1, y: rect.minY),
                   control2: CGPoint(x: rect.width * 0.35, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY * 0.8),
                   control1: CGPoint(x: rect.width * 0.6, y: rect.minY),
                   control2: CGPoint(x: rect.width * 0.85, y: rect.maxY))
        return p
    }
}

/// Slide 2: Evry doing it for you. A thought bubble full of scribbled "text"
/// pops up; the bubble melts away, the scribbles straighten into tidy lines
/// with check circles beside them, and each one is ticked off.
private struct DoneForYouArt: View {
    let active: Bool
    let palette: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var bubble = false
    @State private var thinking = false
    @State private var straight = false
    @State private var checked = 0

    private let widths: [CGFloat] = [118, 92, 106]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !thinking || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ThoughtBubble()
                    .fill(palette.skySoft)
                    .overlay(ThoughtBubble().stroke(Color.evrySky, lineWidth: 1.5))
                    .frame(width: 214, height: 150)
                    .scaleEffect(bubble ? 1 : 0.6, anchor: .bottomLeading)
                    .opacity(bubble ? 1 : 0)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(widths.indices, id: \.self) { i in
                        row(i, t: t)
                    }
                }
                .offset(y: -8)
            }
        }
        .task(id: active) { await play() }
    }

    private func row(_ i: Int, t: Double) -> some View {
        let done = checked > i
        return HStack(spacing: straight ? 12 : 0) {
            ZStack {
                if done {
                    EvryCheck(size: 24).transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    Circle().strokeBorder(Color.evryNavy.opacity(0.6), lineWidth: 2.5)
                }
            }
            .frame(width: straight ? 24 : 0, height: 24)
            .opacity(straight ? 1 : 0)
            .scaleEffect(straight ? 1 : 0.4)

            // While thinking the scribbles shimmer along (the phase moves).
            MouthShape(squiggle: straight ? 0 : 1, smile: 0, waves: 5,
                       phase: thinking ? t * 7 + Double(i) : 0, lineWidth: 5)
                .frame(width: widths[i], height: 18)
                .foregroundStyle(done ? Color.evryNavy.opacity(0.4) : Color.evryNavy)
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: straight)
        .animation(EvryMotion.spring, value: checked)
    }

    private func play() async {
        bubble = false; thinking = false; straight = false; checked = 0
        guard active else { return }
        if reduceMotion {
            straight = true
            checked = widths.count
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        withAnimation(EvryMotion.pop) { bubble = true }
        thinking = true
        try? await Task.sleep(for: .milliseconds(1900))
        if Task.isCancelled { return }
        // The thought becomes action: the bubble melts away…
        withAnimation(.easeIn(duration: 0.35)) { bubble = false }
        try? await Task.sleep(for: .milliseconds(320))
        if Task.isCancelled { return }
        // …and the scribbles straighten into a tidy list. (The shimmer keeps
        // running until they're flat, so the wiggle never jumps.)
        straight = true
        try? await Task.sleep(for: .milliseconds(650))
        thinking = false
        try? await Task.sleep(for: .milliseconds(150))
        for i in 1...widths.count {
            if Task.isCancelled { return }
            checked = i
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            try? await Task.sleep(for: .milliseconds(450))
        }
    }
}

/// A soft cloud-shaped thought bubble with two little trailing puffs.
private struct ThoughtBubble: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func puff(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x * w - r, y: y * h - r, width: r * 2, height: r * 2))
        }
        var cloud = Path(roundedRect: CGRect(x: w * 0.12, y: h * 0.22, width: w * 0.76, height: h * 0.5),
                         cornerRadius: h * 0.2)
        for p in [puff(0.24, 0.32, h * 0.22), puff(0.46, 0.22, h * 0.26), puff(0.7, 0.28, h * 0.23),
                  puff(0.86, 0.48, h * 0.2), puff(0.68, 0.66, h * 0.21), puff(0.42, 0.68, h * 0.22),
                  puff(0.16, 0.52, h * 0.2)] {
            cloud = cloud.union(p)
        }
        return cloud.union(puff(0.12, 0.9, h * 0.07)).union(puff(0.03, 1.0, h * 0.04))
    }
}

/// Slide 3: a detective wall. A string traces a tangled route between pinned
/// papers and dots; then it unravels into one straight arrow and the clutter
/// falls away. The arrow stretches as it sets off and stays put while wind
/// streaks rush past it — looping for as long as the slide is showing (until
/// "Get started").
private struct SimplerArt: View {
    let active: Bool
    let palette: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the tangled string has been traced (0…1).
    @State private var traced: CGFloat = 0
    /// 0 = tangled route, 1 = a straight line.
    @State private var straightened: Double = 0
    @State private var clutterGone = false
    @State private var arrowHead = false
    /// The arrow's "set off" stretch (it stays in place).
    @State private var stretch = false
    /// When the wind started (drives the looping wind effects).
    @State private var windStart: Date? = nil

    /// The wall: pins in a messy array; some hold a paper.
    private struct Pin { let x: CGFloat; let y: CGFloat; let paper: Bool; let tilt: Double }
    private let pins: [Pin] = [
        Pin(x: -92, y: -54, paper: true, tilt: -8),
        Pin(x: 30, y: -86, paper: false, tilt: 0),
        Pin(x: 88, y: -34, paper: true, tilt: 7),
        Pin(x: -24, y: -6, paper: false, tilt: 0),
        Pin(x: -100, y: 46, paper: false, tilt: 0),
        Pin(x: 6, y: 74, paper: true, tilt: -5),
        Pin(x: 50, y: 20, paper: false, tilt: 0),
        Pin(x: -46, y: -92, paper: false, tilt: 0),
        Pin(x: 82, y: 52, paper: true, tilt: 10),
    ]
    /// The order the detective's string visits the pins — deliberately tangled.
    private let route = [0, 3, 2, 7, 6, 4, 1, 5, 8]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: windStart == nil || reduceMotion)) { context in
            ZStack {
                ForEach(Array(pins.enumerated()), id: \.offset) { i, pin in
                    pinView(pin, index: i)
                }

                if let windStart, !reduceMotion {
                    wind(since: windStart, now: context.date)
                }

                Group {
                    StringShape(points: route.map { CGPoint(x: pins[$0].x, y: pins[$0].y) },
                                straightened: straightened)
                        .trim(from: 0, to: traced)
                        .stroke(Color.evryNavy, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    ArrowHeadShape()
                        .stroke(Color.evryNavy, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        .frame(width: 22, height: 26)
                        .offset(x: StringShape.straightHalfWidth + 4)
                        .scaleEffect(arrowHead ? 1 : 0.2, anchor: .leading)
                        .opacity(arrowHead ? 1 : 0)
                }
                // Setting off: a pull-back, then a long forward stretch that
                // settles — the arrow itself never moves.
                .scaleEffect(x: stretch ? 1.08 : 1, y: stretch ? 0.9 : 1, anchor: .leading)
                .offset(y: windStart != nil && !reduceMotion
                        ? sin(context.date.timeIntervalSince(windStart ?? context.date) * 5) * 1.5 : 0)
            }
            .frame(width: 290, height: 290)
            // Clipped to the white circle, so the arrow slips out one side and
            // back in the other.
            .clipShape(Circle())
        }
        .frame(width: 290, height: 250)
        .task(id: active) { await play() }
    }

    private func pinView(_ pin: Pin, index i: Int) -> some View {
        ZStack {
            if pin.paper {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<3, id: \.self) { line in
                        Capsule()
                            .fill(Color.evryNavy.opacity(0.25))
                            .frame(width: line == 2 ? 16 : 26, height: 3)
                    }
                }
                .padding(.top, 8)
                .frame(width: 38, height: 46, alignment: .top)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.evryNavy.opacity(0.18), lineWidth: 1))
                .rotationEffect(.degrees(pin.tilt))
                .offset(y: 16)
            }
            Circle()
                .fill(pin.paper ? Color.evrySky : Color.evryNavy)
                .overlay(Circle().strokeBorder(Color.evryNavy, lineWidth: pin.paper ? 2 : 0))
                .frame(width: 11, height: 11)
        }
        .offset(x: pin.x, y: pin.y + (clutterGone ? 26 : 0))
        .scaleEffect(clutterGone ? 0.5 : 1)
        .opacity(clutterGone ? 0 : 1)
        .animation(clutterGone ? .easeIn(duration: 0.45).delay(0.04 * Double(i)) : EvryMotion.pop.delay(0.05 * Double(i)),
                   value: clutterGone)
    }

    /// Wind rushing past the arrow, right to left, in loose looping streaks.
    private func wind(since start: Date, now: Date) -> some View {
        let t = now.timeIntervalSince(start)
        // (lane y, length, speed, phase)
        let streaks: [(CGFloat, CGFloat, Double, Double)] = [
            (-58, 46, 210, 0.0), (-30, 70, 260, 0.35), (-12, 34, 300, 0.7),
            (16, 58, 240, 0.15), (38, 40, 280, 0.55), (62, 64, 220, 0.85),
        ]
        let span: Double = 420
        return ZStack {
            ForEach(Array(streaks.enumerated()), id: \.offset) { i, s in
                let travel = (t * s.2 + s.3 * span).truncatingRemainder(dividingBy: span)
                // Fade in from nothing so streaks don't pop when the wind starts.
                let ease = min(1, t / 0.6)
                Capsule()
                    .fill(Color.evrySky.opacity(i.isMultiple(of: 2) ? 1 : 0.7))
                    .frame(width: s.1, height: i.isMultiple(of: 3) ? 5 : 4)
                    .offset(x: CGFloat(span / 2 - travel), y: s.0 + CGFloat(sin(t * 3 + Double(i)) * 3))
                    .opacity(ease)
            }
        }
    }

    private func play() async {
        traced = 0; straightened = 0; clutterGone = false; arrowHead = false; stretch = false; windStart = nil
        guard active else { return }
        if reduceMotion {
            traced = 1; straightened = 1; clutterGone = true; arrowHead = true
            return
        }
        try? await Task.sleep(for: .milliseconds(450))
        if Task.isCancelled { return }
        // The detective traces the tangled route…
        withAnimation(.easeInOut(duration: 1.8)) { traced = 1 }
        try? await Task.sleep(for: .milliseconds(2200))
        if Task.isCancelled { return }
        // …then it all unravels into one straight line, and the clutter drops away.
        withAnimation(.spring(response: 0.9, dampingFraction: 0.82)) { straightened = 1 }
        clutterGone = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        try? await Task.sleep(for: .milliseconds(750))
        if Task.isCancelled { return }
        withAnimation(EvryMotion.pop) { arrowHead = true }
        try? await Task.sleep(for: .milliseconds(450))
        if Task.isCancelled { return }
        // Setting off: a quick stretch, then the wind starts and keeps going
        // until setup starts.
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { stretch = true }
        try? await Task.sleep(for: .milliseconds(220))
        if Task.isCancelled { return }
        windStart = Date()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.45)) { stretch = false }
    }
}

/// The detective's string: a polyline through the pins that can straighten
/// into an evenly spaced horizontal line (`straightened` 0…1).
private struct StringShape: Shape {
    let points: [CGPoint]
    var straightened: Double

    static let straightHalfWidth: CGFloat = 96

    var animatableData: Double {
        get { straightened }
        set { straightened = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard points.count > 1 else { return Path() }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let s = CGFloat(straightened)
        let n = CGFloat(points.count - 1)
        var p = Path()
        for (i, pt) in points.enumerated() {
            let flatX = -Self.straightHalfWidth + 2 * Self.straightHalfWidth * CGFloat(i) / n
            let x = pt.x + (flatX - pt.x) * s
            let y = pt.y * (1 - s)
            let point = CGPoint(x: c.x + x, y: c.y + y)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        return p
    }
}

/// An open chevron arrowhead pointing right.
private struct ArrowHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

// MARK: - Happy mascot

/// Evry floating gently, with a happy hop-and-wiggle that plays each time
/// `happy` changes, and a small listening tilt while the person types.
private struct HappyMascot: View {
    let size: CGFloat
    let happy: Int
    var listening = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Pose {
        var y: CGFloat = 0
        var squash: CGFloat = 1
        var tilt: Double = 0
    }

    var body: some View {
        EvryMascot(size: size, float: true, shadow: true)
            .keyframeAnimator(initialValue: Pose(), trigger: happy) { view, pose in
                view
                    .scaleEffect(x: 2 - pose.squash, y: pose.squash, anchor: .bottom)
                    .offset(y: pose.y)
                    .rotationEffect(.degrees(pose.tilt), anchor: .bottom)
            } keyframes: { _ in
                // Two hops: crouch, spring up, land with a squish, a smaller
                // second hop, then settle.
                KeyframeTrack(\.y) {
                    CubicKeyframe(0, duration: 0.08)
                    SpringKeyframe(-size * 0.2, duration: 0.2, spring: .snappy)
                    CubicKeyframe(0, duration: 0.16)
                    SpringKeyframe(-size * 0.1, duration: 0.16, spring: .snappy)
                    CubicKeyframe(0, duration: 0.14)
                }
                KeyframeTrack(\.squash) {
                    CubicKeyframe(0.86, duration: 0.08)
                    CubicKeyframe(1.06, duration: 0.2)
                    CubicKeyframe(0.88, duration: 0.16)
                    CubicKeyframe(1.04, duration: 0.16)
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                }
                KeyframeTrack(\.tilt) {
                    CubicKeyframe(0, duration: 0.1)
                    CubicKeyframe(-9, duration: 0.18)
                    CubicKeyframe(8, duration: 0.18)
                    CubicKeyframe(-5, duration: 0.16)
                    SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                }
            }
            .rotationEffect(.degrees(listening && !reduceMotion ? -8 : 0), anchor: .bottom)
            .animation(EvryMotion.spring, value: listening)
            .frame(height: size * 1.25, alignment: .bottom)
            .accessibilityHidden(true)
    }
}

// MARK: - Speech bubble

/// Evry's line, in a sky-soft bubble whose tail points up at Evry. Each new
/// line is typed out; the bubble resizes smoothly between lines.
private struct SpeechBubble: View {
    let text: String
    let palette: Palette
    var onFinished: (() -> Void)? = nil

    var body: some View {
        TypewriterText(text: text, onFinished: onFinished)
            .font(.nunito(size: 17, weight: .semibold))
            .foregroundStyle(palette.text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .padding(.top, BubbleShape.tail)
            .background(BubbleShape().fill(palette.skySoft))
            .overlay(BubbleShape().stroke(Color.evrySky, lineWidth: 1))
            .animation(EvryMotion.settle, value: text)
            .accessibilityLabel("Evry says: \(text)")
    }
}

/// A rounded bubble with a small tail at the top centre.
private struct BubbleShape: Shape {
    static let tail: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let body = rect.inset(by: UIEdgeInsets(top: Self.tail, left: 0, bottom: 0, right: 0))
        let bubble = Path(roundedRect: body, cornerRadius: EvryRadius.field, style: .continuous)
        var tail = Path()
        tail.move(to: CGPoint(x: rect.midX - 11, y: body.minY + 1))
        tail.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.midX - 3, y: body.minY - 2))
        tail.addQuadCurve(to: CGPoint(x: rect.midX + 11, y: body.minY + 1),
                          control: CGPoint(x: rect.midX + 3, y: body.minY - 2))
        tail.closeSubpath()
        return bubble.union(tail)
    }
}

// MARK: - Rise-in

/// Fades and rises its content in after a short stagger.
private struct RiseIn: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(EvryMotion.settle.delay(0.15 + Double(index) * 0.1)) { shown = true }
            }
    }
}

#Preview {
    SetupFlowView()
        .environment(Appearance())
}
