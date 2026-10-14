//
//  BrainDumpSheet.swift
//  Evry
//
//  One Brain Dump engine, two outputs. Voice capture (LiveSpeechInput), the
//  typed/dictated input UI, and on-device language-model cleanup are shared; only what
//  happens with the final result differs, chosen by `BrainDumpContext`:
//    • .tasks  → the inbox extracts actionable tasks (unchanged behavior)
//    • .note   → the Notes tab tidies the dump into note text and hands it back
//                to a caller that creates a new note or appends to the open one
//
//  The experience is built around one emotional arc: a calm, forgiving place to
//  speak → Evry visibly sorting the rambling into structure (the transformation
//  moment) → quiet closure that confirms and gets out of the way.
//
//  Visually it's the brand's navy band (in light and dark mode): navy surface,
//  white / white-85 text, sky accents, sky / ghost-light buttons. Evry speaks
//  through EvryBubble lines in the first person.
//

import SwiftUI
import SwiftData
import UIKit
import FoundationModels

// MARK: - Output context

enum BrainDumpContext {
    /// Inbox: extract actionable tasks; the caller inserts them.
    case tasks(add: ([BrainPreviewTask]) -> Void)
    /// Notes: tidy the dump into note text; the caller creates/appends a note.
    case note(save: (String) -> Void)
}

struct BrainPreviewTask: Identifiable {
    let id = UUID()
    var title: String
    var dueDate: Date?
    var priority: TaskPriority
}

// MARK: - Sheet

struct BrainDumpSheet: View {
    let context: BrainDumpContext
    /// Screen point the fill-wipe grows from (the tapped tool bubble). Nil falls
    /// back to the top-right corner.
    var fillOrigin: CGPoint? = nil

    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.modelContext) private var modelContext

    private enum Phase { case input, preview, done }

    @State private var input = ""
    @State private var phase: Phase = .input
    @State private var previewTasks: [BrainPreviewTask] = []
    @State private var noteText = ""
    @State private var errorMessage = ""
    @State private var speech = LiveSpeechInput()
    @State private var genStart = Date()
    // Note mode: fades the tidied note in. Task mode uses `revealedCount`.
    @State private var revealed = false
    // Task mode: how many extracted tasks have crystallized in so far — bumped
    // one at a time so the list reveals sequentially, not all at once.
    @State private var revealedCount = 0
    // Drives the cross-fade in/out of the whole screen (the cover's own slide is
    // suppressed at the call site so this reads as a fade, not a pan).
    @State private var appeared = false
    // Staged entrance of the input screen's elements (orb slide-in, box opening).
    @State private var intro = false
    // Fill-wipe intro: an accent shape sweeps down from the top with a rounded
    // leading edge, the background sweeps down over it, then the content appears.
    @State private var loading = true
    @State private var accentFill: CGFloat = 0
    @State private var bgFill: CGFloat = 0
    // The transformation now happens in place on the input screen: pressing
    // Distill collapses the typed container and fades the buttons, while the orb
    // + caption morph into the "Distilling…" state. Stays true through analysis.
    @State private var distilling = false
    // Live natural height of the input container (tracked while typing so it
    // stays full-size and keyboard-adaptive), and the collapse driver: nil while
    // typing (no height constraint), then the captured height animating to 0.
    @State private var windowHeight: CGFloat? = nil
    @State private var collapseHeight: CGFloat? = nil
    // The orb + caption fade fully out, swap to the distilling content while
    // invisible, then fade back in. `headerVisible` drives the fade; `distillHeader`
    // is the content swap (flipped mid-fade so it happens off-screen).
    @State private var headerVisible = true
    @State private var distillHeader = false
    // Evry is never in two places at once: every Evry line on this screen
    // (caption, listening panel, preview, closure) shares one matched avatar,
    // so a crossfade between lines reads as a single Evry moving.
    @Namespace private var evryNS
    // Brain Dump is dictation-first. The typing box is a secondary path, revealed
    // only when the user taps "Type instead".
    @State private var typingMode = false
    // Transient dip + ripple when the mic orb is tapped.
    @State private var micPop = false
    @State private var rippleTrigger = 0
    // The listening *appearance* — flipped immediately on tap so the icon swap,
    // scale, and body change happen right away, decoupled from the audio engine
    // (which spins up in the background a moment later).
    @State private var dictating = false
    // Kept prepared so the mic-tap haptic fires crisply, even on the first tap.
    @State private var micHaptic = UIImpactFeedbackGenerator(style: .medium)
    @FocusState private var focused: Bool

    // First-run explainer: shown the very first time Brain Dump is opened.
    @AppStorage("braindump_intro_seen") private var introSeen = false
    @State private var showIntro = false

    /// The transformation reads for at least this long even if the model is
    /// instant — long enough for the collapse, the orb morph, and a beat of the
    /// distilling state to land before the preview takes over.
    private let minTransformSeconds: Double = 2.4

    /// Brain Dump is a navy band in both light and dark mode: navy surface,
    /// white / white-85 text, sky accents (the derived on-navy palette).
    private let palette = Palette(dark: true)
    private var aiAvailable: Bool { SystemLanguageModel.default.isAvailable }
    private var forNote: Bool { if case .note = context { return true } else { return false } }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background is always present so the foreground can cross-fade over
                // it without a black flash.
                accentBackground
                Group {
                    switch phase {
                    case .input:      inputView
                    case .preview:    previewView
                    case .done:       doneView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(appeared ? 1 : 0)

                // First-run explainer, over everything.
                if showIntro {
                    introScreen
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // Hide the nav bar (and its X / title) while the explainer is up.
            .toolbar(showIntro ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                // Only add the button (and its system background) once the content
                // has appeared — otherwise its container shows during the fill-wipe.
                if phase != .done && appeared {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            if phase == .preview { withAnimation { phase = .input; distilling = false; collapseHeight = nil; distillHeader = false; headerVisible = true } }
                            else { close() }
                        } label: {
                            Image(systemName: phase == .preview ? "chevron.left" : "xmark")
                                .font(.nunito(size: 15, weight: .bold))
                        }
                        .accessibilityLabel(phase == .preview ? "Back" : "Close")
                    }
                }
                ToolbarItem(placement: .principal) {
                    if !navTitle.isEmpty {
                        EyebrowPill(text: navTitle, palette: palette)
                            .opacity(appeared ? 1 : 0)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if phase == .preview && errorMessage.isEmpty && canConfirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle) { commit() }
                            .font(.evryLabel)
                    }
                }
            }
        }
        // System controls (nav items, editors, keyboard) render as on-navy.
        .environment(\.colorScheme, .dark)
        .overlay { if loading { fillLoader } }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear {
            micHaptic.prepare()
            // Fill-wipe intro: the accent sweeps out from the top-right corner
            // (down and to the left), the background sweeps over it, and only then
            // does the content appear.
            withAnimation(.easeInOut(duration: 0.42)) { accentFill = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.easeInOut(duration: 0.42)) { bgFill = 1 }
            }
            // Once the background fill covers the screen, drop the loader (its fill
            // is the same color as the real background, so it's seamless) and
            // animate the content in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                loading = false
                // First open ever → show the explainer first and hold the tool's
                // own entrance until it's dismissed, so the content doesn't animate
                // in behind (and clip through) the popup.
                if introSeen {
                    animateContentIn()
                } else {
                    withAnimation(.easeOut(duration: 0.35)) { showIntro = true }
                }
            }
        }
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { input = t } }
        // Keep the listening appearance in sync when recording ends on its own
        // (recognizer finished/errored) so the UI leaves listening mode.
        .onChange(of: speech.isListening) { _, listening in
            if !listening {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dictating = false }
            }
        }
        // Without mic / speech permission the engine never starts — leave the
        // listening appearance so Evry's caption can explain how to fix it.
        .onChange(of: speech.permissionDenied) { _, denied in
            if denied {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dictating = false }
            }
        }
        .onDisappear { speech.stop() }
    }

    /// Fades the screen out, then removes the cover with its slide suppressed —
    /// the mirror of the fade-in.
    private func close() {
        speech.stop()
        withAnimation(.easeIn(duration: 0.22)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { dismiss() }
        }
    }

    /// Full-screen background — the navy band, with the soft on-navy sky glow
    /// off the top-right corner (the system's one gradient).
    private var accentBackground: some View {
        ZStack {
            palette.bg
            EvryGlow(onNavy: true)
                .offset(x: 150, y: -280)
        }
        .ignoresSafeArea()
    }

    // MARK: First-run explainer

    private func dismissIntro() {
        introSeen = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeInOut(duration: 0.3)) { showIntro = false }
        // Play the tool's entrance only after the popup has fully faded out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { animateContentIn() }
    }

    /// The input screen's own entrance (screen fade + orb/box slide-in).
    private func animateContentIn() {
        withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        withAnimation(EvryMotion.settle.delay(0.05)) { intro = true }
    }

    /// One-time screen shown on the first Brain Dump open: what it is + how it
    /// works. Copy adapts to the tasks vs. note context and to whether the
    /// on-device language model is available.
    private var introScreen: some View {
        let sortDesc: String = {
            if aiAvailable {
                return forNote
                    ? "I tidy it into a clear, readable note and leave out the filler."
                    : "I pull out clear, action-first tasks for you. No editing needed."
            }
            return forNote
                ? "I tidy your words into note text."
                : "I split what you said into separate tasks."
        }()

        return ZStack {
            accentBackground
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                EvryMascot(size: 96, float: true)

                Text("Brain dump")
                    .font(.evryH2)
                    .tracking(EvryTracking.h2)
                    .foregroundStyle(palette.text)
                    .padding(.top, 20)
                    .accessibilityAddTraits(.isHeader)

                Text(forNote
                     ? "Empty your head out loud, and Evry turns it into a clean note."
                     : "Empty your head out loud, and Evry turns it into a clean task list.")
                    .font(.evryLead)
                    .lineSpacing(4)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)

                VStack(spacing: 20) {
                    introStep("mic.fill", "Say it all out loud",
                              "Messy, out of order, all of it. Or tap “Type instead.”")
                    introStep(nil, "Evry sorts it", sortDesc)
                    introStep("checkmark", "Review and keep",
                              forNote
                              ? "Edit anything you like, then save it to your notes."
                              : "Remove any you don’t want, then add the rest to your list.")
                }
                .padding(.top, 34)
                .padding(.horizontal, 30)

                Spacer(minLength: 12)

                Button { dismissIntro() } label: {
                    Text("Start my brain dump")
                }
                .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
                .padding(.horizontal, EvrySpace.grid)
                .padding(.bottom, 40)
            }
        }
    }

    /// A step row: a sky tile with a navy glyph (nil = Evry's star glyph).
    private func introStep(_ icon: String?, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.nunito(size: 18, weight: .bold))
                } else {
                    EvryStarGlyph(size: 20)
                }
            }
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

    /// Two stacked fills growing from the origin: sky first, then the navy
    /// surface over it.
    private var fillLoader: some View {
        ZStack {
            CornerFillShape(progress: accentFill, origin: fillOrigin).fill(Color.evrySky)
            CornerFillShape(progress: bgFill, origin: fillOrigin).fill(palette.bg)
        }
        .ignoresSafeArea()
    }

    private var navTitle: String {
        switch phase {
        case .preview: return forNote ? "Review note" : "Review tasks"
        case .done:    return ""
        default:       return "Brain dump"
        }
    }

    // MARK: Input

    private var inputView: some View {
        // Dictation-first: the mic orb is the hero and the primary tap target.
        // The orb stays centered in place; the listening panel lives at the bottom.
        ZStack {
            // Orb + caption + idle body, vertically centered.
            VStack(spacing: 0) {
                Spacer(minLength: 8)

                // The orb doubles as the "start dictating" button.
                Button {
                    // Water-drop tap: a quick dip as the "drop" lands, a bouncy
                    // rebound, and ripple rings spreading out. The haptic fires inside
                    // startDictation (the shared "start dictating" entry point).
                    rippleTrigger += 1
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.6)) { micPop = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // Low damping → overshoots past 1 and wobbles back (bouncy).
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.4)) { micPop = false }
                    }
                    startDictation()
                } label: {
                    modeOrb
                        .overlay { MicRipple(trigger: rippleTrigger, color: palette.sky) }
                }
                    .buttonStyle(PressScaleStyle())
                    .scaleEffect(micPop ? 0.9 : 1)
                    .disabled(dictating || distilling || typingMode)
                    .opacity((intro && headerVisible) ? 1 : 0)
                    .offset(y: intro ? 0 : -22)
                    .animation(.spring(response: 0.55, dampingFraction: 0.8), value: intro)

                captionArea
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 18)

                // Idle body (dictation hero / typing box). Its space is reserved
                // (hidden) while dictating so the orb doesn't shift; the listening
                // UI is a separate bottom panel below.
                Group {
                    if typingMode { typingBody }
                    else { dictationHero }
                }
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { g in
                        // Track the true natural height only while typing (no collapse
                        // constraint applied), so it stays full-size and adapts to the
                        // keyboard. Frozen once the collapse begins.
                        Color.clear
                            .onAppear { if collapseHeight == nil { windowHeight = g.size.height } }
                            .onChange(of: g.size.height) { _, h in if collapseHeight == nil { windowHeight = h } }
                    }
                )
                // nil = natural size while typing; on Distill it holds the captured
                // height and animates to 0 (a vertical collapse from top and bottom).
                .frame(height: collapseHeight, alignment: .center)
                .opacity(distilling || dictating ? 0 : 1)
                .clipped()
                .allowsHitTesting(!distilling && !dictating)

                Spacer(minLength: 8)
            }

            // Listening panel — pinned toward the bottom, slides up from below.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if dictating {
                    listeningBody
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Snappy transition into/out of the listening state, driven by the
        // immediate `dictating` intent rather than the delayed engine state.
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: dictating)
        .animation(.easeInOut(duration: 0.4), value: distilling)
    }

    /// The mode icon — a single persistent view. Only its size changes between
    /// modes; because it's centered in the VStack, it never moves horizontally.
    private var modeOrb: some View {
        let distillIcon = aiAvailable ? "star.fill" : "list.bullet"
        // Dictation-first: the idle orb is a large mic (the primary CTA). It swaps
        // to a waveform while listening, and to the process glyph while distilling.
        // The layout box stays a constant 128 and the size change is applied as a
        // centered scale, so the orb grows/shrinks *in place* instead of pushing
        // the surrounding layout (which made it drift upward).
        let base: CGFloat = 128
        let target: CGFloat = dictating ? 150 : (distillHeader ? 96 : 128)
        return BreathingOrb(
            level: dictating ? speech.level : (distillHeader ? 0.35 : 0),
            palette: palette,
            icon: distillHeader ? distillIcon : "mic.fill",
            activeIcon: "waveform",
            listening: dictating
        )
        .frame(width: base, height: base)
        .scaleEffect(target / base)
        .accessibilityLabel(distillHeader ? "Evry is sorting your thoughts" : "Start talking")
    }

    /// Evry's line for the current moment, in an EvryBubble — first person,
    /// short, ending with an offer where it can.
    private var captionArea: some View {
        let sub: String = {
            if distillHeader { return generatingTitle }
            // While listening the guidance lives in the bottom panel, not here.
            if dictating { return "" }
            if speech.permissionDenied && !typingMode {
                return "I can’t hear you yet. Please allow microphone and speech access in Settings, or type instead."
            }
            if typingMode {
                return forNote ? "Type it however it comes. I’ll tidy it into a note."
                               : "Type it however it comes. I’ll sort it into tasks."
            }
            if !input.isEmpty {
                return forNote ? "Got it. Shall I tidy that into a note?"
                               : "Got it. Shall I sort that into tasks?"
            }
            return forNote ? "Tell me what’s on your mind. I’ll turn it into a tidy note."
                           : "Tell me what’s on your mind. I’ll turn it into tasks."
        }()
        return HStack(alignment: .bottom, spacing: 8) {
            // One avatar outside the cross-fade, so only the words change.
            if !sub.isEmpty { movingEvry() }
            ZStack {
                if !sub.isEmpty {
                    EvryBubble(text: sub, showsAvatar: false, palette: palette)
                        .id(sub)                    // cross-fade when the line changes
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(headerVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: dictating)
        .animation(.easeInOut(duration: 0.3), value: typingMode)
        .animation(.easeInOut(duration: 0.3), value: input.isEmpty)
        .animation(.easeInOut(duration: 0.3), value: speech.permissionDenied)
    }

    // MARK: Dictation hero (default)

    @ViewBuilder
    private var dictationHero: some View {
        VStack(spacing: 16) {
            // While dictating this whole body is hidden but keeps its space, so
            // show the compact variant to hold a stable height (the orb stays put).
            if input.isEmpty || dictating {
                Button { startDictation() } label: {
                    Label("Start talking", systemImage: "mic.fill")
                }
                .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
                .padding(.horizontal, 36)

                typeInsteadButton
            } else {
                // What was dictated so far, shown for review before distilling.
                ScrollView(.vertical, showsIndicators: false) {
                    Text(input)
                        .font(.evryBody)
                        .lineSpacing(4)
                        .foregroundStyle(palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(16)
                .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                .padding(.horizontal, EvrySpace.gutter)

                Button { startDistill() } label: {
                    distillLabel
                }
                .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
                .padding(.horizontal, 36)

                HStack(spacing: 24) {
                    Button { startDictation() } label: {
                        Label("Record again", systemImage: "arrow.counterclockwise")
                            .font(.evrySmall)
                            .foregroundStyle(palette.primary)
                            .frame(minHeight: EvrySpace.tap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    typeInsteadButton
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .transition(.opacity)
    }

    /// The distill button's label: Evry's star + the action.
    private var distillLabel: some View {
        HStack(spacing: 8) {
            if aiAvailable { EvryStarGlyph(size: 18) }
            Text(analyzeTitle)
        }
    }

    private var typeInsteadButton: some View {
        Button { enterTyping() } label: {
            Text("Type instead")
                .font(.evrySmall)
                .foregroundStyle(palette.textSec)
                .underline(color: palette.textSec.opacity(0.5))
                .frame(minHeight: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Typing (secondary path)

    private var typingBody: some View {
        VStack(spacing: 14) {
            editorCard
                .padding(.horizontal, EvrySpace.gutter)

            HStack(spacing: 12) {
                Button { backToVoice() } label: {
                    Label("Use voice", systemImage: "mic.fill")
                }
                .buttonStyle(EvryGhostLightButtonStyle())

                Spacer()

                Button { startDistill() } label: {
                    distillLabel
                }
                .buttonStyle(EvrySkyButtonStyle())
                .opacity(inputEmpty ? 0.45 : 1)
                .disabled(inputEmpty)
            }
            .padding(.horizontal, EvrySpace.gutter)
        }
        .transition(.opacity)
    }

    private var editorCard: some View {
        ZStack(alignment: .topLeading) {
            if input.isEmpty {
                Text(placeholderText)
                    .font(.evryBody)
                    .foregroundStyle(palette.textPh)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $input)
                .font(.evryBody)
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .accessibilityLabel(forNote ? "Your note" : "Your tasks")
        }
        // Capped a bit shorter so the larger Dictate/Distill buttons have room.
        .frame(maxWidth: .infinity, maxHeight: 300)
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .overlay(
            // Focus ring on navy is sky (focus-ring-on-navy).
            RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
                .strokeBorder(focused ? palette.primary : palette.border, lineWidth: 1.5)
        )
    }

    // MARK: Actions

    /// Start (or restart) voice dictation — the primary Brain Dump action.
    private func startDictation() {
        // Fire on every tap so the mic circle always gives feedback, then
        // re-prepare for the next tap.
        micHaptic.impactOccurred()
        micHaptic.prepare()
        if typingMode { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { typingMode = false } }
        input = ""
        focused = false
        // Flip the listening appearance immediately (in sync with the water-drop
        // tap) — the icon swap, scale, and body fade happen right away. The actual
        // recording spins up off-main a moment later.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dictating = true }
        if !speech.isListening {
            speech.toggle()
        }
        // Permission already refused: the engine won't start, so drop straight
        // back out of the listening appearance (Evry's caption explains why).
        if speech.permissionDenied {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dictating = false }
        }
    }

    /// Reveal the secondary typing box.
    private func enterTyping() {
        if speech.isListening { speech.stop() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { typingMode = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
    }

    /// Leave the typing box back to the dictation hero (keeps whatever was typed).
    private func backToVoice() {
        focused = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { typingMode = false }
    }

    /// Kick off the distill/analyze transformation (shared by voice + typing).
    private func startDistill() {
        focused = false
        speech.stop()
        genStart = Date()
        errorMessage = ""
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // Snapshot the container's current height (no animation) so the collapse
        // animates cleanly from full size, then transform in place.
        var freeze = Transaction(); freeze.disablesAnimations = true
        withTransaction(freeze) { collapseHeight = windowHeight }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.7)) {
                collapseHeight = 0
                distilling = true
            }
            // Fade the orb + caption out, swap to the distilling content while
            // invisible, then fade it back in.
            withAnimation(.easeInOut(duration: 0.35)) { headerVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                distillHeader = true
                withAnimation(.easeInOut(duration: 0.45)) { headerVisible = true }
            }
        }
        Task { await analyze() }
    }

    /// The bottom listening panel — the guidance line, the live transcript, and
    /// the Stop button. Lives low on screen and slides up from the bottom.
    private var listeningBody: some View {
        VStack(spacing: 16) {
            // Live transcript, shown quietly so words register without a text box.
            if !input.isEmpty {
                Text(input)
                    .font(.evryBody)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 36)
            }

            evryLine("I’m listening. Say it however it comes out.")

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    dictating = false
                    speech.stop()
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(EvrySkyButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, EvrySpace.grid)
        .padding(.bottom, 40)
    }

    private var inputEmpty: Bool { input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholderText: String {
        forNote ? "For example, “Ideas for the launch: landing page, email teaser, and a short demo video…”"
                : "For example, “Call the dentist, buy groceries, email Sarah the report…”"
    }
    private var analyzeTitle: String {
        if aiAvailable { return forNote ? "Tidy my note" : "Sort my thoughts" }
        return forNote ? "Create note" : "Create tasks"
    }

    // MARK: Distilling — the transformation moment (in place on the input screen)

    /// Evry's line while it works, after the input container has collapsed and
    /// the orb has morphed into its processing state.
    private var generatingTitle: String {
        if aiAvailable { return forNote ? "I’m tidying this into a note…" : "I’m sorting your thoughts…" }
        return forNote ? "I’m saving your note…" : "I’m building your task list…"
    }

    // MARK: Evry (one at a time)

    /// Evry's bubble avatar, matched across every line on this screen.
    private func movingEvry() -> some View {
        EvryMascot(size: 40)
            .matchedGeometryEffect(id: "evry", in: evryNS)
    }

    /// An Evry line (the mascot beside an `EvryBubble`) using the shared avatar.
    private func evryLine(_ text: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            movingEvry()
            EvryBubble(text: text, showsAvatar: false, palette: palette)
        }
    }

    // MARK: Preview

    @ViewBuilder private var previewView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if !errorMessage.isEmpty {
                    errorBanner
                } else if forNote {
                    notePreview
                } else {
                    evryLine(previewTasks.isEmpty
                             ? "I didn’t find any tasks in that. Shall we try again?"
                             : "I found \(previewTasks.count) task\(previewTasks.count == 1 ? "" : "s"). Add \(previewTasks.count == 1 ? "it" : "them") to your list?")
                    previewHeader
                    previewTaskList
                    Text("Tap × to remove any you don’t need.")
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textMuted)
                        .padding(.horizontal, 4)
                }
            }
            .padding(EvrySpace.gutter)
            .padding(.top, 4)
        }
        .task { await runReveal() }
    }

    /// Reveals the results with intent. Notes fade in as one; tasks crystallize
    /// one at a time, ~¼s apart, each with a soft tick — a small drumroll that
    /// makes the extraction feel earned. Cancels cleanly if the view goes away.
    private func runReveal() async {
        if forNote {
            withAnimation(.easeOut(duration: 0.5)) { revealed = true }
            return
        }
        revealedCount = 0
        try? await Task.sleep(nanoseconds: 180_000_000)
        for _ in previewTasks.indices {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) { revealedCount += 1 }
            UISelectionFeedbackGenerator().selectionChanged()
            try? await Task.sleep(nanoseconds: reduceMotion ? 80_000_000 : 250_000_000)
            if Task.isCancelled { return }
        }
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 16) {
            evryLine(errorMessage)
            Button {
                errorMessage = ""
                withAnimation { phase = .input; distilling = false; collapseHeight = nil; distillHeader = false; headerVisible = true }
            } label: {
                Label("Try again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Preview — note

    private var notePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            evryLine("Here’s your note. Change anything you like, then save it?")
            HStack(spacing: 6) {
                Text("Your note")
                    .font(.evrySmall)
                    .foregroundStyle(palette.textSec)
                Spacer()
                // Marks that this was tidied from a raw dump.
                if aiAvailable {
                    EyebrowPill(text: "Tidied by Evry", palette: palette, size: 12)
                }
            }
            .padding(.horizontal, 4)
            TextEditor(text: $noteText)
                .font(.evryBody)
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                .opacity(revealed ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: revealed)
                .accessibilityLabel("Your note")
        }
    }

    // MARK: Preview — tasks

    private var previewHeader: some View {
        HStack(spacing: 8) {
            Text("Tasks")
                .font(.evrySmall)
                .foregroundStyle(palette.textSec)
            Spacer()
            // Counts up as tasks reveal.
            Text("\(revealedCount) of \(previewTasks.count)")
                .font(.evrySmall)
                .monospacedDigit()
                .foregroundStyle(palette.textSec)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    /// Individual task cards spaced like the inbox list. The flair lives in how
    /// each one arrives, not in recolouring it.
    private var previewTaskList: some View {
        VStack(spacing: 8) {
            ForEach(Array(previewTasks.enumerated()), id: \.element.id) { i, task in
                previewTaskRow(task: task, index: i)
            }
        }
    }

    private func previewTaskRow(task: BrainPreviewTask, index: Int) -> some View {
        // Revealed strictly in sequence (see runReveal). The flair is the
        // arrival — it crystallizes from blurred/shifted, its check disc pops a
        // tick, and a single sky ring radiates as it's pulled from the dump.
        let shown = index < revealedCount
        return HStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(shown ? Color.clear : palette.border, lineWidth: 2)
                Circle().fill(shown ? Palette.doneFill : .clear)
                Image(systemName: "checkmark")
                    .font(.nunito(size: 11, weight: .heavy))
                    .foregroundStyle(palette.onSky)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.2)
            }
            .frame(width: 22, height: 22)
            .overlay { if shown && !reduceMotion { ExtractionRing(color: palette.sky) } }
            .animation(EvryMotion.spring, value: shown)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if task.priority != .normal { priorityBadge(task.priority) }
                    if let due = task.dueDate, let label = formatDueDate(due) {
                        Label(label, systemImage: "calendar")
                            .font(.evryCaption)
                            .foregroundStyle(palette.textMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.spring(response: 0.3)) {
                    previewTasks = previewTasks.enumerated().filter { $0.offset != index }.map(\.element)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.nunito(size: 13, weight: .bold))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(task.title)")
        }
        .padding(.vertical, 8)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous).strokeBorder(palette.hairline, lineWidth: 1))
        // Flare: crystallize from blurred + shifted + scaled into place.
        .opacity(shown ? 1 : 0)
        .blur(radius: shown || reduceMotion ? 0 : 6)
        .scaleEffect(shown || reduceMotion ? 1 : 0.94, anchor: .leading)
        .offset(x: shown || reduceMotion ? 0 : -14)
    }

    /// Priority is carried by glyph + word on a sky-soft pill, never by hue.
    private func priorityBadge(_ priority: TaskPriority) -> some View {
        let (label, icon): (String, String?) = switch priority {
        case .high:   ("High",   "exclamationmark.circle.fill")
        case .medium: ("Medium", nil)
        case .low:    ("Low",    "arrow.down")
        case .normal: ("",       nil)
        }
        return HStack(spacing: 3) {
            if let icon { Image(systemName: icon).accessibilityHidden(true) }
            Text(label)
        }
        .font(.evryCaption)
        .foregroundStyle(palette.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.skySoft, in: Capsule())
        .accessibilityLabel("\(label) priority")
    }

    // MARK: Done — quiet closure

    /// A distinct, calm resolution: Evry confirms what got off the user's mind,
    /// then the screen gets out of the way.
    private var doneView: some View {
        VStack(spacing: 18) {
            Spacer()
            ClosureMascot()
                .matchedGeometryEffect(id: "evry", in: evryNS)
            VStack(spacing: 6) {
                Text("Off your mind.")
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text(closureSubtitle)
                    .font(.evryBody)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var closureSubtitle: String {
        switch context {
        case .tasks: return "\(previewTasks.count) task\(previewTasks.count == 1 ? "" : "s") added to your list."
        case .note:  return "Saved to your notes."
        }
    }

    // MARK: Confirm

    private var confirmTitle: String {
        switch context {
        case .tasks: return "Add \(previewTasks.count) task\(previewTasks.count == 1 ? "" : "s")"
        case .note:  return "Save"
        }
    }
    private var canConfirm: Bool {
        switch context {
        case .tasks: return !previewTasks.isEmpty
        case .note:  return !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func commit() {
        // Commit the data immediately, then hold on the closure beat briefly
        // before getting out of the way.
        switch context {
        case .tasks(let add): add(previewTasks)
        case .note(let save): save(noteText)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(EvryMotion.settle) { phase = .done }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { close() }
    }

    // MARK: Analysis (shared engine, context-specific output)

    private func analyze() async {
        if forNote { await analyzeNote() } else { await analyzeTasks() }
    }

    /// Holds the transformation on screen for a minimum beat so it reads, then
    /// crosses into preview with a soft "arrived" haptic. Never blocks longer
    /// than needed — if the model was slow, there's no extra wait.
    private func advanceToPreview() async {
        let elapsed = Date().timeIntervalSince(genStart)
        let remaining = minTransformSeconds - elapsed
        if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        await MainActor.run {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation(.easeInOut(duration: 0.4)) { phase = .preview }
        }
    }

    /// Extraction itself lives in `EvryAssistant` (shared with the Evry chat);
    /// this just drives the sheet's phases around it.
    private func analyzeTasks() async {
        do {
            let tasks = try await EvryAssistant.distill(input, usesPrioritiesOften: EvryAssistant.usesPrioritiesOften(modelContext))
            await MainActor.run { previewTasks = tasks }
            await advanceToPreview()
        } catch {
            await MainActor.run {
                errorMessage = "I couldn’t sort that one. Please try again, or say it a little differently."
                withAnimation { phase = .preview }
            }
        }
    }

    private func analyzeNote() async {
        if aiAvailable {
            do {
                let session = LanguageModelSession(instructions: """
                    You tidy a spoken or typed brain dump into a clean, readable note.
                    Rules:
                    - Remove ALL filler words and sounds (um, uh, hmm, like, you know, ahh, etc.)
                    - Fix fragmented speech into clear sentences and natural paragraphs
                    - Preserve every idea and detail — do NOT summarize away content
                    - Keep the writer's meaning and voice; don't turn it into a task list
                    - Return only the cleaned note text, with no preamble or commentary
                    """)
                let response = try await session.respond(to: input)
                await MainActor.run { noteText = response.content }
                await advanceToPreview()
            } catch {
                await MainActor.run {
                    errorMessage = "I couldn’t sort that one. Please try again, or say it a little differently."
                    withAnimation { phase = .preview }
                }
            }
        } else {
            let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run { noteText = cleaned }
            await advanceToPreview()
        }
    }
}

// MARK: - Mic ripple

/// Water-drop ripple: on each `trigger` bump, two concentric rings spread out
/// from the orb's edge and fade — like a drop landing in a puddle.
private struct MicRipple: View {
    let trigger: Int
    let color: Color

    /// 0 = at rest (rings at the orb edge), 1 = fully spread + faded.
    @State private var phase: CGFloat = 1

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .scaleEffect(1 + phase * (0.7 + CGFloat(i) * 0.5))
                    .opacity(Double(1 - phase) * 0.5)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            phase = 0
            withAnimation(.easeOut(duration: 0.6)) { phase = 1 }
        }
    }
}

// MARK: - Breathing orb

/// A calm, alive indicator: a sky disc with a navy glyph, a gentle looping
/// breath, and a soft sky halo that swells with the mic amplitude. Shared by the
/// listening state and the transformation state so the two feel like one motif.
/// Decorative motion (breath, sonar) stops under Reduce Motion.
private struct BreathingOrb: View {
    let level: Double
    let palette: Palette
    var icon: String = "mic.fill"
    /// Optional second glyph shown while `listening`. It cross-fades with `icon`
    /// in place (both centered, opacity only) so the icon never translates.
    var activeIcon: String? = nil
    /// When listening, the orb comes alive: sonar pulses + amplitude-driven glow.
    var listening: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    @State private var sonar = false

    var body: some View {
        ZStack {
            // Sonar rings — only while listening. Two staggered, slow pulses so it
            // reads as "hearing you" without becoming busy.
            if listening && !reduceMotion {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(palette.sky.opacity(0.4), lineWidth: 2)
                        .scaleEffect(sonar ? 1.9 : 1.0)
                        .opacity(sonar ? 0 : 0.5)
                        .animation(
                            .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.9),
                            value: sonar
                        )
                }
            }
            // Voice-responsive halo (calm: swells a little, never snaps).
            Circle()
                .fill(palette.sky.opacity(0.16))
                .scaleEffect(1.0 + CGFloat(min(1, max(0, level))) * 0.45)
                .animation(.easeOut(duration: 0.28), value: level)
            // The sky disc — the main action on navy.
            Circle().fill(palette.sky)
                .evryShadowLift(palette)
            // Two stacked glyphs: the base icon slides out to the left while the
            // active (listening) icon slides in from the right — a clean swap.
            ZStack {
                Image(systemName: icon)
                    .offset(x: (listening && activeIcon != nil && !reduceMotion) ? -46 : 0)
                    .opacity((listening && activeIcon != nil) ? 0 : 1)
                if let activeIcon {
                    Image(systemName: activeIcon)
                        .offset(x: listening || reduceMotion ? 0 : 46)
                        .opacity(listening ? 1 : 0)
                }
            }
            .font(.nunito(size: 24, weight: .bold))
            .foregroundStyle(palette.onSky)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: listening)
        }
        .scaleEffect(breathe ? 1.05 : 1)
        .animation(breathe ? .easeInOut(duration: 1.7).repeatForever(autoreverses: true) : nil, value: breathe)
        .onAppear {
            guard !reduceMotion else { return }
            breathe = true; sonar = true
        }
    }
}

// MARK: - Extraction ring

/// A single, gentle sky ring that expands and fades once — reused from the
/// app's completion-burst language to mark a task being pulled from the dump.
private struct ExtractionRing: View {
    let color: Color

    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                opacity = 0.6
                scale = 0.9
                withAnimation(.easeOut(duration: 0.55)) {
                    scale = 2.4
                    opacity = 0
                }
            }
    }
}

// MARK: - Closure mascot

/// The quiet success beat: Evry pops in with a small sky check disc tucked at
/// the corner. The pop is a "small delight" (EvryMotion.spring) and is skipped
/// under Reduce Motion.
private struct ClosureMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop: CGFloat = 0.6

    var body: some View {
        EvryMascot(size: 96)
            .overlay(alignment: .bottomTrailing) {
                EvryCheck(size: 28)
                    .offset(x: 4, y: 2)
            }
            .scaleEffect(reduceMotion ? 1 : pop)
            .onAppear {
                withAnimation(EvryMotion.spring) { pop = 1 }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Evry's star glyph

/// The star that stands for Evry, the assistant, in small UI (EvryIconStar,
/// a template image that tints with the surrounding foreground style).
private struct EvryStarGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        Image("EvryIconStar")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
