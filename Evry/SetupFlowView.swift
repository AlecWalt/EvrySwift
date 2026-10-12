//
//  SetupFlowView.swift
//  Evry
//
//  Onboarding / setup flow — ported from authScreen.js. Stages:
//  Welcome → Sign In or Registration (3-step carousel) → Location.
//

import SwiftUI
import CoreLocation
import UIKit

// MARK: - Stage

private enum SetupStage: Hashable {
    case welcome, signIn, register, location
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

// MARK: - Main view

struct SetupFlowView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("user_name") private var savedName = ""
    @AppStorage("user_email") private var savedEmail = ""

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    @State private var stage: SetupStage = .welcome
    @State private var insertionEdge: Edge = .trailing
    @State private var regStep = 0
    @State private var regInsertionEdge: Edge = .trailing

    // Sign-in fields
    @State private var signInEmail = ""
    @State private var signInPassword = ""
    @State private var focusSignInPassword = false

    // Registration fields
    @State private var regName = ""
    @State private var regEmail = ""
    @State private var regPassword = ""
    @State private var regConfirm = ""
    @State private var passwordError = false
    @State private var focusRegConfirm = false

    @State private var locationHelper = LocationHelper()
    @State private var showWelcome = false
    @State private var welcomeAnim = false

    // Intro (welcome stage only): a plain white screen where the "Evry" logo is
    // revealed left-to-right, then scales + translates into its resting spot as
    // the tagline and buttons fade in — all within the welcome page (no page swap).
    @State private var writeProgress: CGFloat = 0       // mask reveal 0→1
    @State private var logoScale: CGFloat = 1.7         // hero size → 1
    @State private var contentPresent = false           // reserves layout space (logo settles)
    @State private var contentVisible = false           // tagline + buttons opacity

    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: insertionEdge == .trailing ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var regSlideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: regInsertionEdge).combined(with: .opacity),
            removal: .move(edge: regInsertionEdge == .trailing ? .leading : .trailing).combined(with: .opacity)
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Plain white during the intro reveal; settles to the app background
            // as the welcome content appears.
            (contentVisible ? palette.bg : Color.evryWhite)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: contentVisible)

            // The soft sky glow, off-canvas behind the top of every stage.
            EvryGlow(onNavy: palette.dark)
                .offset(x: 140, y: -200)
                .opacity(contentVisible ? 1 : 0)
                .ignoresSafeArea()

            stageView
                .id(stage)
                .transition(slideTransition)

            // Skip is hidden until the intro finishes.
            if stage != .location && contentVisible {
                Button("Skip") { dismiss() }
                    .font(.evryLabel)
                    .foregroundStyle(palette.textSec)
                    .frame(minWidth: EvrySpace.tap, minHeight: EvrySpace.tap)
                    .contentShape(Rectangle())
                    .padding(.top, 50)
                    .padding(.trailing, 16)
            }

            if showWelcome {
                welcomeOverlay
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .onAppear(perform: runIntroIfNeeded)
    }

    // MARK: Intro

    /// Left-to-right reveal mask with a soft "pen tip" edge, driven by
    /// `writeProgress`. Applied to the welcome logo so it appears to be written on.
    private func writeOnMask() -> some View {
        GeometryReader { g in
            let w = g.size.width
            let feather: CGFloat = 22
            HStack(spacing: 0) {
                Rectangle().fill(.black)
                    .frame(width: max(0, w * writeProgress - feather))
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: feather)
                Spacer(minLength: 0)
            }
        }
    }

    /// The one-time welcome intro: reveal the logo (centered + enlarged), then
    /// scale + translate it into its resting spot, then fade the content in — all
    /// on the welcome page itself, so there's no page transition.
    private func runIntroIfNeeded() {
        guard !contentVisible, stage == .welcome else { return }
        // Reduce Motion: skip the choreography and show the settled page.
        if reduceMotion {
            writeProgress = 1
            logoScale = 1
            contentPresent = true
            contentVisible = true
            return
        }
        // 1. Write the logo on.
        withAnimation(.easeInOut(duration: 1.5)) { writeProgress = 1 }
        // 2. Settle: shrink to normal size and let the (invisible) content reserve
        //    space, which glides the logo up to its natural position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(EvryMotion.settle) {
                logoScale = 1
                contentPresent = true
            }
        }
        // 3. Reveal the tagline + buttons.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeOut(duration: 0.4)) { contentVisible = true }
        }
    }

    // MARK: Welcome animation (plays as setup finishes)

    private var welcomeOverlay: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            EvryGlow(onNavy: palette.dark)
            VStack(spacing: 20) {
                ZStack {
                    // A small burst of sky dots around Evry.
                    ForEach(0..<8, id: \.self) { i in
                        let angle = Double(i) * 45
                        EvryBullet(size: 10)
                            .offset(
                                x: welcomeAnim ? cos(angle * .pi / 180) * 90 : 0,
                                y: welcomeAnim ? sin(angle * .pi / 180) * 90 : 0
                            )
                            .opacity(welcomeAnim || reduceMotion ? 0 : 1)
                    }
                    EvryMascot(size: 112, float: true)
                        .scaleEffect(welcomeAnim || reduceMotion ? 1 : 0.3)
                        .opacity(welcomeAnim ? 1 : 0)
                }
                .frame(width: 200, height: 200)

                VStack(spacing: 12) {
                    Text(savedName.isEmpty ? "Welcome to Evry" : "Welcome, \(savedName)")
                        .font(.evryH2)
                        .tracking(EvryTracking.h2)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.center)
                    Text("Everything’s ready. Let’s start with today.")
                        .font(.evryLead)
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, EvrySpace.grid)
                .opacity(welcomeAnim ? 1 : 0)
            }
        }
    }

    /// Plays the welcome beat, then dismisses into the app.
    private func finishSetup() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.3)) { showWelcome = true }
        withAnimation(reduceMotion ? .easeOut(duration: 0.3) : EvryMotion.spring.delay(0.08)) { welcomeAnim = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { dismiss() }
    }

    // MARK: Stage router

    @ViewBuilder
    private var stageView: some View {
        switch stage {
        case .welcome:    welcomeView
        case .signIn:     signInView
        case .register:   registrationView
        case .location:   locationView
        }
    }

    // MARK: Welcome

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Enlarged + write-on masked during the intro; settles to 1.5×.
                EvryLogo(palette: palette)
                    .mask(writeOnMask())
                    .scaleEffect(logoScale * 1.5)
                    .padding(.vertical, 12)

                if contentPresent {
                    VStack(spacing: 24) {
                        Text("Evrything in its place.")
                            .font(.evryLead)
                            .foregroundStyle(palette.textSec)

                        // The four tools, each in its own tile shape.
                        HStack(spacing: 20) {
                            ForEach(EvryTool.allCases, id: \.self) { tool in
                                VStack(spacing: 8) {
                                    ToolIcon(tool: tool, tile: 48, palette: palette)
                                    Text(tool.label)
                                        .font(.evryCaption)
                                        .foregroundStyle(palette.textSec)
                                }
                            }
                        }
                    }
                    .opacity(contentVisible ? 1 : 0)
                }
            }

            Spacer()

            // Present (reserving space) once the logo settles; faded in last.
            if contentPresent {
                VStack(spacing: 20) {
                    SetupBubble(text: "Hi, I’m Evry. I’ll keep your tasks, habits, notes and calendar together. Shall we set you up?",
                                palette: palette)
                    VStack(spacing: 12) {
                        Button("Get started") {
                            // Small first tap; the haptic builds as setup progresses.
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            advance(to: .register)
                        }
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                        Button("Sign in") { advance(to: .signIn) }
                            .buttonStyle(EvrySecondaryButtonStyle(palette: palette, fullWidth: true))
                    }
                }
                .padding(.horizontal, EvrySpace.grid)
                .padding(.bottom, 32)
                .opacity(contentVisible ? 1 : 0)
            }

            Spacer().frame(height: 20)
        }
        // Always fill the width so the logo stays screen-centered even during the
        // intro, when it's the only content (otherwise the VStack shrinks to the
        // logo and the top-trailing ZStack pins it off-center).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sign In

    private var signInView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Text("Welcome back")
                    .font(.evryH2)
                    .tracking(EvryTracking.h2)
                    .foregroundStyle(palette.text)
                Text("Sign in to pick up where you left off.")
                    .font(.evryLead)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, EvrySpace.grid)
            .padding(.bottom, EvrySpace.heading)

            VStack(spacing: 16) {
                SetupFieldLabel("Email", palette: palette) {
                    SetupTextField("you@example.com", text: $signInEmail, palette: palette,
                                   keyboard: .emailAddress, autocap: .never,
                                   submitLabel: .next) {
                        focusSignInPassword = true
                    }
                }
                SetupFieldLabel("Password", palette: palette) {
                    SetupSecureField("Your password", text: $signInPassword, palette: palette,
                                     shouldFocus: $focusSignInPassword,
                                     submitLabel: .go) {
                        guard !signInEmail.isEmpty, !signInPassword.isEmpty else { return }
                        savedEmail = signInEmail
                        advance(to: .location)
                    }
                }

                Button("Sign in") {
                    savedEmail = signInEmail
                    advance(to: .location)
                }
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                .disabled(signInEmail.isEmpty || signInPassword.isEmpty)
                .padding(.top, 8)
            }
            .padding(.horizontal, EvrySpace.grid)
            .padding(.bottom, 12)

            Button("New to Evry? Create an account") { retreat(to: .register) }
                .font(.evryLabel)
                .foregroundStyle(palette.primary)
                .frame(minHeight: EvrySpace.tap)

            Spacer()
        }
    }

    // MARK: Registration carousel

    private var registrationView: some View {
        VStack(spacing: 0) {
            Spacer()
            regStepView
                .id(regStep)
                .transition(regSlideTransition)
            Spacer()
        }
    }

    @ViewBuilder
    private var regStepView: some View {
        switch regStep {
        case 0: regNameStep
        case 1: regEmailStep
        default: regPasswordStep
        }
    }

    private var firstName: String {
        regName.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
    }

    private var regNameStep: some View {
        VStack(alignment: .leading, spacing: EvrySpace.grid) {
            SetupBubble(text: "Hi, I’m Evry. What should I call you?", palette: palette)
            SetupFieldLabel("Name", palette: palette) {
                SetupTextField("Your name", text: $regName, palette: palette,
                               submitLabel: .continue) {
                    if !regName.trimmingCharacters(in: .whitespaces).isEmpty { advanceReg() }
                }
            }
            Button("Continue") { advanceReg() }
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                .disabled(regName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, EvrySpace.grid)
    }

    private var regEmailStep: some View {
        VStack(alignment: .leading, spacing: EvrySpace.grid) {
            SetupBubble(text: firstName.isEmpty
                            ? "Nice to meet you. What’s your email?"
                            : "Nice to meet you, \(firstName). What’s your email?",
                        palette: palette)
            SetupFieldLabel("Email", palette: palette) {
                SetupTextField("you@example.com", text: $regEmail, palette: palette,
                               keyboard: .emailAddress, autocap: .never,
                               submitLabel: .continue) {
                    advanceReg()
                }
            }
            VStack(spacing: 8) {
                Button("Continue") { advanceReg() }
                    .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                    .disabled(regEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                SetupBackButton(palette: palette) { retreatReg() }
            }
        }
        .padding(.horizontal, EvrySpace.grid)
    }

    private var passwordsMatch: Bool {
        isPasswordValid && !regConfirm.isEmpty && regPassword == regConfirm
    }

    private var regPasswordStep: some View {
        VStack(alignment: .leading, spacing: EvrySpace.grid) {
            SetupBubble(text: "Last step: choose a password to keep your things safe.", palette: palette)
            VStack(alignment: .leading, spacing: 16) {
                SetupFieldLabel("Password", palette: palette) {
                    SetupSecureField("Choose a password", text: $regPassword, palette: palette,
                                     autoFocus: true,
                                     submitLabel: .next,
                                     matched: passwordsMatch) {
                        if isPasswordValid { focusRegConfirm = true }
                    }
                }
                if !regPassword.isEmpty {
                    passwordRequirements
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                SetupFieldLabel("Confirm password", palette: palette) {
                    VStack(alignment: .leading, spacing: 0) {
                        SetupSecureField("Type it once more", text: $regConfirm, palette: palette,
                                         shouldFocus: $focusRegConfirm,
                                         submitLabel: .done,
                                         matched: passwordsMatch,
                                         error: passwordError) {
                            guard isPasswordValid, regPassword == regConfirm else {
                                withAnimation { passwordError = true }
                                return
                            }
                            // The heaviest tap before the completion firework.
                            let gen = UIImpactFeedbackGenerator(style: .heavy)
                            gen.impactOccurred()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { gen.impactOccurred() }
                            savedName = regName
                            savedEmail = regEmail
                            advance(to: .location)
                        }
                        if passwordError {
                            FieldError(message: "Those passwords don’t match. Please type the same one twice.",
                                       palette: palette)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: passwordError)
            .animation(.easeInOut(duration: 0.2), value: regPassword.isEmpty)
            VStack(spacing: 8) {
                Button("Create account") {
                    guard regPassword == regConfirm else {
                        withAnimation { passwordError = true }
                        return
                    }
                    // The heaviest tap before the completion firework.
                    let gen = UIImpactFeedbackGenerator(style: .heavy)
                    gen.impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { gen.impactOccurred() }
                    savedName = regName
                    savedEmail = regEmail
                    advance(to: .location)
                }
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                .disabled(!isPasswordValid || regConfirm.isEmpty)
                SetupBackButton(palette: palette) {
                    passwordError = false
                    retreatReg()
                }
            }
        }
        .padding(.horizontal, EvrySpace.grid)
    }

    // MARK: Location

    private var locationView: some View {
        VStack(spacing: 0) {
            Spacer()
            locationStateView
            Spacer()
        }
    }

    @ViewBuilder
    private var locationStateView: some View {
        if locationHelper.status == .authorizedWhenInUse || locationHelper.status == .authorizedAlways {
            VStack(spacing: 16) {
                EvryCheck(size: 56)
                Text("Location is on")
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { finishSetup() }
            }
        } else if locationHelper.status == .denied || locationHelper.status == .restricted {
            VStack(spacing: EvrySpace.grid) {
                Image(systemName: "location.slash")
                    .font(.nunito(size: 40, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text("Location is off")
                        .font(.evryH3)
                        .foregroundStyle(palette.text)
                    Text("That’s fine. You can turn it on any time in Settings, under Privacy & Security.")
                        .font(.evryBody)
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                }
                Button("Continue without location") { finishSetup() }
                    .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
            }
            .padding(.horizontal, EvrySpace.grid)
        } else {
            VStack(spacing: EvrySpace.grid) {
                EvryMascot(size: 96, float: true)
                VStack(spacing: 16) {
                    Text("Use your location?")
                        .font(.evryH2)
                        .tracking(EvryTracking.h2)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.center)
                    Text("When you add a place to a task, I’ll show nearby spots first. Shall I ask for access?")
                        .font(.evryLead)
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 8) {
                    Button("Turn on location") { locationHelper.requestAccess() }
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                    Button("Skip for now") { finishSetup() }
                        .font(.evryLabel)
                        .foregroundStyle(palette.textSec)
                        .frame(minHeight: EvrySpace.buttonHeight)
                }
            }
            .padding(.horizontal, EvrySpace.grid)
        }
    }

    // MARK: Password validation

    private static let specialChars = CharacterSet(charactersIn: "!@#$%^&*()_+-=[]{}|;':\",./<>?\\~`")

    private var isPasswordValid: Bool {
        regPassword.count >= 6 &&
        regPassword.unicodeScalars.contains(where: Self.specialChars.contains) &&
        regPassword.contains(where: \.isUppercase) &&
        regPassword.contains(where: \.isLowercase)
    }

    private func requirementRow(_ label: String, met: Bool) -> some View {
        HStack(spacing: 8) {
            if met {
                EvryCheck(size: 16)
            } else {
                Circle()
                    .strokeBorder(palette.textPh, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.nunito(size: 14))
                .foregroundStyle(met ? palette.text : palette.textSec)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(met ? "Done" : "Not yet")
    }

    private var passwordRequirements: some View {
        VStack(alignment: .leading, spacing: 6) {
            requirementRow("At least 6 characters", met: regPassword.count >= 6)
            requirementRow("Uppercase and lowercase letters",
                           met: regPassword.contains(where: \.isUppercase) && regPassword.contains(where: \.isLowercase))
            requirementRow("A special character (!, @, #…)",
                           met: regPassword.unicodeScalars.contains(where: Self.specialChars.contains))
        }
    }

    // MARK: Navigation helpers

    private func advance(to next: SetupStage) {
        insertionEdge = .trailing
        withAnimation(EvryMotion.settle) { stage = next }
    }

    private func retreat(to prev: SetupStage) {
        insertionEdge = .leading
        withAnimation(EvryMotion.settle) { stage = prev }
    }

    private func advanceReg() {
        // Escalate the haptic as the user moves deeper into setup: name → email
        // is medium, email → password is heavy (the final "create" tap is rigid,
        // then the completion plays the firework).
        UIImpactFeedbackGenerator(style: regStep == 0 ? .medium : .heavy).impactOccurred()
        regInsertionEdge = .trailing
        withAnimation(EvryMotion.settle) { regStep += 1 }
    }

    private func retreatReg() {
        regInsertionEdge = .leading
        withAnimation(EvryMotion.settle) { regStep -= 1 }
    }
}

// MARK: - Setup UI components

/// Evry's line in setup: the mascot beside a sky-soft bubble (1pt sky ring,
/// tail bottom-left), matching `EvryBubble`. Kept local because `EvryBubble`
/// sizes its bubble to 85% of the *screen* width, which overflows padded layouts.
private struct SetupBubble: View {
    let text: String
    let palette: Palette

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: EvryRadius.field, bottomLeadingRadius: EvryRadius.tail,
                               bottomTrailingRadius: EvryRadius.field, topTrailingRadius: EvryRadius.field,
                               style: .continuous)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            EvryMascot(size: 40)
            Text(text)
                .font(.evryBubble)
                .lineSpacing(5)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(palette.skySoft, in: shape)
                .overlay(shape.strokeBorder(Color.evrySky, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Evry says: " + text)
    }
}

/// FormField label: bold, above the field.
private struct SetupFieldLabel<Field: View>: View {
    let label: String
    let palette: Palette
    @ViewBuilder var field: () -> Field

    init(_ label: String, palette: Palette, @ViewBuilder field: @escaping () -> Field) {
        self.label = label
        self.palette = palette
        self.field = field
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.evryLabel)
                .foregroundStyle(palette.text)
            field()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SetupTextField: View {
    let placeholder: String
    @Binding var text: String
    let palette: Palette
    var keyboard: UIKeyboardType = .default
    var autocap: TextInputAutocapitalization = .sentences
    var submitLabel: SubmitLabel = .continue
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    init(_ placeholder: String, text: Binding<String>, palette: Palette,
         keyboard: UIKeyboardType = .default,
         autocap: TextInputAutocapitalization = .sentences,
         submitLabel: SubmitLabel = .continue,
         onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.palette = palette
        self.keyboard = keyboard
        self.autocap = autocap
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(palette.textPh))
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocap)
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .focused($isFocused)
            .frame(minHeight: 24)
            .evryTextField(palette, focused: isFocused)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isFocused = true
                }
            }
    }
}

private struct SetupSecureField: View {
    let placeholder: String
    @Binding var text: String
    let palette: Palette
    var autoFocus: Bool = false
    var shouldFocus: Binding<Bool>? = nil
    var submitLabel: SubmitLabel = .done
    /// When true, a check disc springs in — used to confirm the passwords match.
    var matched: Bool = false
    var error: Bool = false
    var onSubmit: (() -> Void)? = nil

    @State private var visible = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ placeholder: String, text: Binding<String>, palette: Palette,
         autoFocus: Bool = false,
         shouldFocus: Binding<Bool>? = nil,
         submitLabel: SubmitLabel = .done,
         matched: Bool = false,
         error: Bool = false,
         onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.palette = palette
        self.autoFocus = autoFocus
        self.shouldFocus = shouldFocus
        self.submitLabel = submitLabel
        self.matched = matched
        self.error = error
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                let prompt = Text(placeholder).foregroundStyle(palette.textPh)
                if visible {
                    TextField("", text: $text, prompt: prompt)
                } else {
                    SecureField("", text: $text, prompt: prompt)
                }
            }
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .focused($isFocused)
            .frame(minHeight: 24)

            if matched {
                EvryCheck(size: 20)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .accessibilityLabel("Passwords match")
                    .accessibilityHidden(false)
            }

            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundStyle(palette.textMuted)
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(visible ? "Hide password" : "Show password")
        }
        .animation(reduceMotion ? nil : EvryMotion.spring, value: matched)
        .evryTextField(palette, focused: isFocused, error: error)
        .onAppear {
            if autoFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { isFocused = true }
            }
        }
        .onChange(of: shouldFocus?.wrappedValue ?? false) { _, triggered in
            if triggered {
                isFocused = true
                shouldFocus?.wrappedValue = false
            }
        }
    }
}

private struct SetupBackButton: View {
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.nunito(size: 14, weight: .bold))
                Text("Back")
            }
            .font(.evryLabel)
            .foregroundStyle(palette.textSec)
            .frame(maxWidth: .infinity, minHeight: EvrySpace.buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
