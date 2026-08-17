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
            palette.bg.ignoresSafeArea()

            stageView
                .id(stage)
                .transition(slideTransition)

            if stage != .location {
                Button("Skip") { dismiss() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .padding(.top, 60)
                    .padding(.trailing, 24)
            }

            if showWelcome {
                welcomeOverlay
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
    }

    // MARK: Welcome animation (plays as setup finishes)

    private var welcomeOverlay: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    ForEach(0..<8, id: \.self) { i in
                        let angle = Double(i) * 45
                        Circle()
                            .fill(palette.primary)
                            .frame(width: 9, height: 9)
                            .offset(
                                x: welcomeAnim ? cos(angle * .pi / 180) * 70 : 0,
                                y: welcomeAnim ? sin(angle * .pi / 180) * 70 : 0
                            )
                            .opacity(welcomeAnim ? 0 : 1)
                    }
                    Image(systemName: "sparkles")
                        .font(.system(size: 72))
                        .foregroundStyle(palette.primary)
                        .scaleEffect(welcomeAnim ? 1 : 0.2)
                        .opacity(welcomeAnim ? 1 : 0)
                }
                .frame(width: 160, height: 160)

                Text(savedName.isEmpty ? "Welcome to Evry!" : "Welcome, \(savedName)!")
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(palette.text)
                    .opacity(welcomeAnim ? 1 : 0)
                Text("Time to get Evrything done!")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSec)
                    .opacity(welcomeAnim ? 1 : 0)
            }
        }
    }

    /// Plays the welcome beat, then dismisses into the app.
    private func finishSetup() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeOut(duration: 0.3)) { showWelcome = true }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.08)) { welcomeAnim = true }
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
            Image("Sofa")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 320)
                .padding(.top, 60)

            Spacer()

            VStack(spacing: 16) {
                Image("TextLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 44)

                Text("Everything in its place.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.textSec)
            }
            .padding(.bottom, 40)

            VStack(spacing: 12) {
                SetupPrimaryButton("Get Started", palette: palette) {
                    advance(to: .register)
                }
                Button("Sign in") { advance(to: .signIn) }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primary)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: Sign In

    private var signInView: some View {
        VStack(spacing: 0) {
            Image("GirlLooking")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .padding(.top, 60)

            Spacer()

            VStack(spacing: 6) {
                Text("Welcome back")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(palette.text)
                Text("Sign in to your account")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSec)
            }
            .padding(.bottom, 36)

            VStack(spacing: 12) {
                SetupTextField("Email", text: $signInEmail, palette: palette,
                               keyboard: .emailAddress, autocap: .never,
                               submitLabel: .next) {
                    focusSignInPassword = true
                }
                SetupSecureField("Password", text: $signInPassword, palette: palette,
                                 shouldFocus: $focusSignInPassword,
                                 submitLabel: .go) {
                    guard !signInEmail.isEmpty, !signInPassword.isEmpty else { return }
                    savedEmail = signInEmail
                    advance(to: .location)
                }

                SetupPrimaryButton("Sign in", palette: palette,
                                   disabled: signInEmail.isEmpty || signInPassword.isEmpty) {
                    savedEmail = signInEmail
                    advance(to: .location)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)

            Button("Don't have an account? Register") { retreat(to: .register) }
                .font(.system(size: 14))
                .foregroundStyle(palette.primary)

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

    private var regNameStep: some View {
        VStack(spacing: 24) {
            Image("GirlLaptopBench")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .padding(.bottom, 4)

            Text("What should we call you?")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.text)
            SetupTextField("Your name", text: $regName, palette: palette,
                           submitLabel: .continue) {
                if !regName.trimmingCharacters(in: .whitespaces).isEmpty { advanceReg() }
            }
            .padding(.horizontal, 32)
            SetupPrimaryButton("Continue", palette: palette,
                               disabled: regName.trimmingCharacters(in: .whitespaces).isEmpty) {
                advanceReg()
            }
            .padding(.horizontal, 32)
        }
    }

    private var regEmailStep: some View {
        VStack(spacing: 24) {
            Image("Dog")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .padding(.bottom, 4)

            Text("What's your email?")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.text)
            SetupTextField("Email", text: $regEmail, palette: palette,
                           keyboard: .emailAddress, autocap: .never,
                           submitLabel: .continue) {
                advanceReg()
            }
            .padding(.horizontal, 32)
            VStack(spacing: 10) {
                SetupPrimaryButton("Continue", palette: palette,
                                   disabled: regEmail.trimmingCharacters(in: .whitespaces).isEmpty) {
                    advanceReg()
                }
                SetupBackButton(palette: palette) { retreatReg() }
            }
            .padding(.horizontal, 32)
        }
    }

    private var regPasswordStep: some View {
        VStack(spacing: 24) {
            Image("Cat")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .padding(.bottom, 4)

            Text("Choose a password")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.text)
            VStack(spacing: 12) {
                SetupSecureField("Password", text: $regPassword, palette: palette,
                                 autoFocus: true,
                                 submitLabel: .next) {
                    if isPasswordValid { focusRegConfirm = true }
                }
                if !regPassword.isEmpty {
                    passwordRequirements
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                SetupSecureField("Confirm password", text: $regConfirm, palette: palette,
                                 shouldFocus: $focusRegConfirm,
                                 submitLabel: .done,
                                 matched: isPasswordValid && !regConfirm.isEmpty && regPassword == regConfirm) {
                    guard isPasswordValid, regPassword == regConfirm else {
                        withAnimation { passwordError = true }
                        return
                    }
                    savedName = regName
                    savedEmail = regEmail
                    advance(to: .location)
                }
                if passwordError {
                    Text("Passwords don't match")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.danger)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 32)
            .animation(.easeInOut(duration: 0.2), value: passwordError)
            .animation(.easeInOut(duration: 0.2), value: regPassword.isEmpty)
            VStack(spacing: 10) {
                SetupPrimaryButton("Create account", palette: palette,
                                   disabled: !isPasswordValid || regConfirm.isEmpty) {
                    guard regPassword == regConfirm else {
                        withAnimation { passwordError = true }
                        return
                    }
                    savedName = regName
                    savedEmail = regEmail
                    advance(to: .location)
                }
                SetupBackButton(palette: palette) {
                    passwordError = false
                    retreatReg()
                }
            }
            .padding(.horizontal, 32)
        }
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
                Image("SideTable")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(palette.primary)
                Text("Location saved!")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(palette.text)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { finishSetup() }
            }
        } else if locationHelper.status == .denied || locationHelper.status == .restricted {
            VStack(spacing: 20) {
                Image("SideTable")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                Image(systemName: "location.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(palette.textSec)
                Text("Location access was denied. You can enable it later in your device settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                SetupPrimaryButton("Continue without location", palette: palette) { finishSetup() }
                    .padding(.horizontal, 32)
            }
        } else {
            VStack(spacing: 20) {
                Image("SideTable")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                VStack(spacing: 8) {
                    Text("Use your location?")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text("We'll show nearby places first when you add a location to a task.")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                VStack(spacing: 10) {
                    SetupPrimaryButton("Enable location", palette: palette) {
                        locationHelper.requestAccess()
                    }
                    Button("Skip for now") { finishSetup() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textSec)
                }
                .padding(.horizontal, 32)
            }
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
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(met ? palette.primary : palette.textPh)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(met ? palette.text : palette.textSec)
        }
    }

    private var passwordRequirements: some View {
        VStack(alignment: .leading, spacing: 5) {
            requirementRow("At least 6 characters", met: regPassword.count >= 6)
            requirementRow("Uppercase and lowercase letters",
                           met: regPassword.contains(where: \.isUppercase) && regPassword.contains(where: \.isLowercase))
            requirementRow("Special character (!, @, #…)",
                           met: regPassword.unicodeScalars.contains(where: Self.specialChars.contains))
        }
    }

    // MARK: Navigation helpers

    private func advance(to next: SetupStage) {
        insertionEdge = .trailing
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { stage = next }
    }

    private func retreat(to prev: SetupStage) {
        insertionEdge = .leading
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { stage = prev }
    }

    private func advanceReg() {
        regInsertionEdge = .trailing
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { regStep += 1 }
    }

    private func retreatReg() {
        regInsertionEdge = .leading
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { regStep -= 1 }
    }
}

// MARK: - Setup UI components

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
        TextField(placeholder, text: $text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocap)
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .focused($isFocused)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .evryField(palette)
            .foregroundStyle(palette.text)
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
    /// When true, a green checkmark springs in — used to confirm the passwords match.
    var matched: Bool = false
    var onSubmit: (() -> Void)? = nil

    @State private var visible = false
    @FocusState private var isFocused: Bool

    init(_ placeholder: String, text: Binding<String>, palette: Palette,
         autoFocus: Bool = false,
         shouldFocus: Binding<Bool>? = nil,
         submitLabel: SubmitLabel = .done,
         matched: Bool = false,
         onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.palette = palette
        self.autoFocus = autoFocus
        self.shouldFocus = shouldFocus
        self.submitLabel = submitLabel
        self.matched = matched
        self.onSubmit = onSubmit
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if visible {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
            .focused($isFocused)
            .foregroundStyle(palette.text)

            if matched {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.success)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }

            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundStyle(palette.textPh)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.55), value: matched)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .evryField(palette)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(matched ? Palette.success.opacity(0.6) : .clear, lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.2), value: matched)
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

private struct SetupPrimaryButton: View {
    let label: String
    let palette: Palette
    var disabled: Bool = false
    let action: () -> Void

    init(_ label: String, palette: Palette, disabled: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.palette = palette
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(disabled ? palette.textPh : palette.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(disabled ? palette.border : palette.primary)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct SetupBackButton: View {
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("← Back")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textSec)
        }
    }
}
