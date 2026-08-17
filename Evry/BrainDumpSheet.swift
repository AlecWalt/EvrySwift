//
//  BrainDumpSheet.swift
//  Evry
//
//  One Brain Dump engine, two outputs. Voice capture (LiveSpeechInput), the
//  typed/dictated input UI, and on-device AI cleanup are shared; only what
//  happens with the final result differs, chosen by `BrainDumpContext`:
//    • .tasks  → the inbox extracts actionable tasks (unchanged behavior)
//    • .note   → the Notes tab tidies the dump into note text and hands it back
//                to a caller that creates a new note or appends to the open one
//
//  The experience is built around one emotional arc: a calm, forgiving place to
//  speak → the rambling visibly distilling into structure (the theme-colored
//  transformation moment) → quiet closure that confirms and gets out of the way.
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

// MARK: - AI extraction types (task mode)

@Generable(description: "A single actionable task extracted from a brain dump")
private struct DumpedTask {
    @Guide(description: "Concise action-first task title. No filler words. Include timing naturally in the title.")
    var title: String

    @Guide(description: "Priority: one of high, medium, low, or normal. Default to 'normal' — only deviate when the text clearly signals unusual importance or unimportance.")
    var priority: String
}

@Generable(description: "Actionable tasks extracted and cleaned from a free-form brain dump")
private struct BrainDumpResult {
    @Guide(description: "All actionable tasks, filler words removed, max 20.", .maximumCount(20))
    var tasks: [DumpedTask]
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

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    /// The user's own tasks — used to gauge how often they actually use priorities,
    /// so extraction can mirror their habit rather than over-labeling.
    @Query private var allTasks: [TaskItem]

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
    @FocusState private var focused: Bool

    /// The transformation reads for at least this long even if the model is
    /// instant — long enough for the collapse, the orb morph, and a beat of the
    /// distilling state to land before the preview takes over.
    private let minTransformSeconds: Double = 2.4

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var aiAvailable: Bool { SystemLanguageModel.default.isAvailable }
    private var forNote: Bool { if case .note = context { return true } else { return false } }

    /// True when the user labels a meaningful share of their own tasks with a
    /// priority — a signal that extraction should use priorities freely too.
    /// Requires a small sample so a brand-new user defaults to sparing.
    private var usesPrioritiesOften: Bool {
        let real = allTasks.filter { !$0.isTrashed && !$0.isNote }
        guard real.count >= 5 else { return false }
        let labeled = real.filter { $0.priority != .normal }.count
        return Double(labeled) / Double(real.count) >= 0.4
    }

    /// Priority instructions for the extractor — sparing by default, generous only
    /// if the user's own habit shows they lean on priorities.
    private var priorityGuidance: String {
        if usesPrioritiesOften {
            return """
            - This user relies on priorities. Assign one to most tasks, inferring \
            high / medium / low from urgency and importance cues. Use 'normal' only \
            when there is genuinely no signal.
            """
        }
        return """
        - Assign priority VERY sparingly. Default every task to 'normal'. Only use \
        'high' when the text clearly signals something is unusually urgent or \
        important (e.g. "urgent", "asap", "critical", "really important", a hard \
        deadline), and only use 'low' when it clearly signals something minor or \
        optional (e.g. "someday", "whenever", "no rush", "if I get to it"). \
        Avoid 'medium' unless the user explicitly says so. When in doubt, use 'normal'.
        """
    }

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
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if phase != .done {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            if phase == .preview { withAnimation { phase = .input; distilling = false; collapseHeight = nil; distillHeader = false; headerVisible = true } }
                            else { close() }
                        } label: {
                            Image(systemName: phase == .preview ? "chevron.left" : "xmark")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(navTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(palette.text)
                }
                if phase == .preview && errorMessage.isEmpty && canConfirm {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle) { commit() }.fontWeight(.semibold)
                    }
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear {
            // Defer one runloop so the layout (and the orb's matched geometry) is
            // established at rest first — otherwise the animated flip makes elements
            // fly in from the top-left origin instead of animating in place.
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) { appeared = true }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { intro = true }
            }
        }
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { input = t } }
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

    /// Full-screen background — the selected accent color washes down from the top
    /// (stronger while listening) into the neutral app background. Subtle and
    /// legible; it's atmosphere, not decoration.
    private var accentBackground: some View {
        let top = speech.isListening ? 0.34 : (palette.dark ? 0.26 : 0.18)
        return ZStack {
            palette.bg
            LinearGradient(
                colors: [palette.primary.opacity(top), palette.primary.opacity(0.04), .clear],
                startPoint: .top, endPoint: .center
            )
            RadialGradient(
                colors: [palette.primary.opacity(speech.isListening ? 0.22 : 0.12), .clear],
                center: .init(x: 0.5, y: 0.08), startRadius: 0, endRadius: 460
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: speech.isListening)
    }

    private var navTitle: String {
        switch phase {
        case .preview: return forNote ? "Review Note" : "Review Tasks"
        case .done:    return ""
        default:       return "Brain Dump"
        }
    }

    // MARK: Input

    private var inputView: some View {
        // One persistent orb, always horizontally centered — so switching to
        // dictation only ever moves it vertically (and scales it), never sideways.
        // The content below the caption swaps between typing and dictating.
        VStack(spacing: 0) {
            // Orb sits a little lower in dictation; this shift is purely vertical.
            Spacer().frame(height: distilling ? 0 : (speech.isListening ? 44 : 10))

            modeOrb
                .opacity((intro && headerVisible) ? 1 : 0)
                .offset(y: intro ? 0 : -22)
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: intro)

            captionArea
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)

            // The typed / dictation container. On Distill its height animates to
            // zero — a real vertical collapse from top and bottom (content pinned
            // center + clipped + faded). As it shrinks, the centered stack
            // alignment draws the orb + caption down into the middle of the screen.
            Group {
                if speech.isListening { listeningBody } else { typingBody }
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
            .opacity(distilling ? 0 : 1)
            .clipped()
            .allowsHitTesting(!distilling)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: distilling ? .center : .top)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: speech.isListening)
        .animation(.easeInOut(duration: 0.4), value: distilling)
    }

    /// The mode icon — a single persistent view. Only its size changes between
    /// modes; because it's centered in the VStack, it never moves horizontally.
    private var modeOrb: some View {
        let distillIcon = aiAvailable ? "sparkles" : "list.bullet.clipboard.fill"
        // While distilling the orb grows and switches to the process glyph, with a
        // gentle self-glow (level) so it reads as actively working. The swap
        // happens while the orb is faded out, so it's an out-then-in change.
        let size: CGFloat = speech.isListening ? 140 : (distillHeader ? 96 : 66)
        return BreathingOrb(
            level: speech.isListening ? speech.level : (distillHeader ? 0.35 : 0),
            palette: palette,
            icon: distillHeader ? distillIcon : "brain.head.profile",
            activeIcon: "waveform",
            listening: speech.isListening
        )
        .frame(width: size, height: size)
    }

    /// Accent pill + one line of guidance — the same header structure the Pomodoro
    /// screen uses (its phase pill + encouragement), so the two features read as a
    /// matched pair. The pill names the current mode; the line encourages.
    private var captionArea: some View {
        let pill = distillHeader ? "DISTILLING"
            : (speech.isListening ? "LISTENING" : (forNote ? "NOTES" : "TASKS"))
        let sub = distillHeader ? generatingTitle
            : (speech.isListening ? "No rush — say it however it comes out." : hintText)
        return VStack(spacing: 10) {
            Text(pill)
                .font(.system(size: 13, weight: .bold))
                .tracking(1)
                .foregroundStyle(palette.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(palette.primary.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(palette.primary.opacity(0.35), lineWidth: 1))
                .contentTransition(.opacity)

            Text(sub)
                .font(.system(size: 14))
                .foregroundStyle(palette.textSec)
                .multilineTextAlignment(.center)
                .id(sub)                        // cross-fade when the mode changes
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .opacity(headerVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: speech.isListening)
    }

    private var typingBody: some View {
        VStack(spacing: 0) {
            editorCard
                // Starts closed in place and expands vertically to fill on first
                // appear; the vertical transition closes/opens it on dictate toggle
                // and collapses it away when distilling (it's removed from layout).
                .scaleEffect(x: 1, y: intro ? 1 : 0.05, anchor: .top)
                .opacity(intro ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(0.12), value: intro)
                .transition(.verticalOpen)
                .padding(.horizontal, 16)

            buttonsRow
                .opacity(intro ? 1 : 0)
                .offset(y: intro ? 0 : 16)
                .animation(.easeOut(duration: 0.4).delay(0.3), value: intro)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .transition(.opacity)
        // Keyboard waits until the box has opened, and only when there's nothing yet
        // (so returning from dictation with a transcript doesn't shove it back up).
        .onAppear {
            guard input.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if input.isEmpty && !speech.isListening { focused = true }
            }
        }
    }

    private var editorCard: some View {
        ZStack(alignment: .topLeading) {
            if input.isEmpty {
                Text(placeholderText)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textPh)
                    .padding(.top, 14)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $input)
                .font(.system(size: 16))
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(focused ? palette.primary : palette.border, lineWidth: 1.5)
        )
    }

    private var buttonsRow: some View {
        HStack(spacing: 12) {
            Button {
                input = ""
                focused = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { speech.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold))
                    Text("Dictate").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(palette.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(palette.primary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(PressScaleStyle())

            if speech.permissionDenied {
                Text("Enable microphone in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                focused = false
                speech.stop()
                genStart = Date()
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                // Snapshot the container's current height (no animation) so the
                // collapse animates cleanly from full size, then transform in
                // place: collapse vertically, fade the buttons, and morph the orb
                // + caption into the distilling state.
                var freeze = Transaction(); freeze.disablesAnimations = true
                withTransaction(freeze) { collapseHeight = windowHeight }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.7)) {
                        collapseHeight = 0
                        distilling = true
                    }
                    // Fade the orb + caption out, swap to the distilling content
                    // while invisible, then fade it back in.
                    withAnimation(.easeInOut(duration: 0.35)) { headerVisible = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        distillHeader = true
                        withAnimation(.easeInOut(duration: 0.45)) { headerVisible = true }
                    }
                }
                Task { await analyze() }
            } label: {
                HStack(spacing: 6) {
                    if aiAvailable {
                        Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                    }
                    Text(analyzeTitle).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(inputEmpty ? palette.textSec : palette.onPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(inputEmpty ? palette.hover : palette.primary, in: Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(inputEmpty)
        }
    }

    /// Dictation mode body — the orb and caption live in the shared parent; this
    /// is just the quiet live transcript and the Stop button.
    private var listeningBody: some View {
        VStack(spacing: 0) {
            // Live transcript, shown quietly so words register without a text box.
            if !input.isEmpty {
                Text(input)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 36)
                    .padding(.top, 4)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { speech.stop() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                    Text("Stop").font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(Palette.danger, in: Capsule())
            }
            .buttonStyle(PressScaleStyle())
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private var inputEmpty: Bool { input.trimmingCharacters(in: .whitespaces).isEmpty }

    private var hintText: String {
        if aiAvailable {
            return forNote ? "Speak or type freely — AI will tidy it into a clean note."
                           : "Speak or type freely — AI will extract your tasks."
        } else {
            return forNote ? "Speak or type freely — we'll save it as a note."
                           : "Speak or type freely — we'll build your task list."
        }
    }
    private var placeholderText: String {
        forNote ? "e.g. \"Ideas for the launch — landing page, email teaser, and a short demo video…\""
                : "e.g. \"Call dentist, buy groceries, email Sarah the report…\""
    }
    private var analyzeTitle: String {
        if aiAvailable { return "Distill" }
        return forNote ? "Create Note" : "Create Tasks"
    }

    // MARK: Distilling — the transformation moment (in place on the input screen)

    /// The caption shown while the model works, after the input container has
    /// collapsed and the orb has morphed into its processing state.
    private var generatingTitle: String {
        if aiAvailable { return forNote ? "Distilling into a note…" : "Distilling your thoughts…" }
        return forNote ? "Saving your note…" : "Building your task list…"
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
                    previewHeader
                    previewTaskList
                    Text("Tap × to remove tasks before adding.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textPh)
                        .padding(.horizontal, 4)
                }
            }
            .padding(20)
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
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
        }
    }

    private var errorBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Palette.warning)
            Text(errorMessage)
                .font(.system(size: 15))
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
            Button("Try Again") { errorMessage = ""; withAnimation { phase = .input; distilling = false; collapseHeight = nil; distillHeader = false; headerVisible = true } }
                .fontWeight(.semibold)
                .foregroundStyle(palette.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Preview — note

    private var notePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("NOTE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textSec)
                Spacer()
                // Theme-colored marker that this was tidied from a raw dump.
                if aiAvailable {
                    Text("TIDIED")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.primaryLight, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
            TextEditor(text: $noteText)
                .font(.system(size: 16))
                .foregroundStyle(palette.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 260)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                .opacity(revealed ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: revealed)
            Text("Edit if you like, then save.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textPh)
                .padding(.horizontal, 4)
        }
    }

    // MARK: Preview — tasks

    private var previewHeader: some View {
        HStack(spacing: 8) {
            Text("TASKS")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textSec)
            Spacer()
            // Counts up as tasks reveal.
            Text("\(revealedCount)/\(previewTasks.count)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(palette.textSec)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 4)
    }

    /// Individual neutral task cards — the app's standard look — spaced like the
    /// inbox list. The flair lives in how each one arrives, not in recoloring it.
    private var previewTaskList: some View {
        VStack(spacing: 8) {
            ForEach(Array(previewTasks.enumerated()), id: \.element.id) { i, task in
                previewTaskRow(task: task, index: i)
            }
        }
    }

    private func previewTaskRow(task: BrainPreviewTask, index: Int) -> some View {
        // Revealed strictly in sequence (see runReveal). The card itself is the
        // ordinary neutral task card; the flair is the arrival — it crystallizes
        // from blurred/shifted, its checkbox pops a check, and a single theme ring
        // radiates to mark the moment it was pulled from the dump.
        let shown = index < revealedCount
        return HStack(spacing: 12) {
            ZStack {
                Circle().strokeBorder(shown ? palette.primary : palette.border, lineWidth: 2)
                Circle().fill(shown ? palette.primary : .clear)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.2)
            }
            .frame(width: 22, height: 22)
            .overlay { if shown { ExtractionRing(color: palette.primary) } }
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: shown)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 16.5))
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if task.priority != .normal { priorityBadge(task.priority) }
                    if let due = task.dueDate, let label = formatDueDate(due) {
                        Label(label, systemImage: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.textSec)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.5)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Flare: crystallize from blurred + shifted + scaled into place.
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : 6)
        .scaleEffect(shown ? 1 : 0.94, anchor: .leading)
        .offset(x: shown ? 0 : -14)
    }

    private func priorityBadge(_ priority: TaskPriority) -> some View {
        let (label, color): (String, Color) = switch priority {
        case .high:   ("High",   Palette.danger)
        case .medium: ("Medium", Palette.warning)
        case .low:    ("Low",    Palette.success)
        case .normal: ("",       .clear)
        }
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: Done — quiet closure

    /// A distinct, calm resolution: confirm what got off the user's mind, then
    /// auto-dismiss. Rewards externalizing the thought — not "using the feature".
    private var doneView: some View {
        VStack(spacing: 18) {
            Spacer()
            ClosureCheck(palette: palette)
                .frame(width: 64, height: 64)
            VStack(spacing: 6) {
                Text("Off your mind.")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.text)
                Text(closureSubtitle)
                    .font(.system(size: 14))
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
        case .tasks: return "\(previewTasks.count) task\(previewTasks.count == 1 ? "" : "s") captured."
        case .note:  return "Saved to your notes."
        }
    }

    // MARK: Confirm

    private var confirmTitle: String {
        switch context {
        case .tasks: return "Add \(previewTasks.count) Task\(previewTasks.count == 1 ? "" : "s")"
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
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { phase = .done }
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

    private func analyzeTasks() async {
        if aiAvailable {
            do {
                let session = LanguageModelSession(instructions: """
                    You are a productivity assistant. Extract clear, actionable tasks \
                    ONLY from the user's own free-form brain dump (spoken or typed).
                    Rules:
                    - Use ONLY the content the user provided. NEVER invent, assume, or add \
                    tasks that are not in their text. Do not use any example tasks.
                    - If the input contains no actionable tasks, return an empty list.
                    - Remove ALL filler words and sounds (um, uh, hmm, like, you know, ahh, etc.)
                    - Combine fragmented thoughts into concise, self-contained task titles
                    - Rewrite each task in action-first phrasing (start with a verb, drop \
                    "I need to"/"I should"/"I have to")
                    - Keep any timing cues the user mentioned in the title
                    \(priorityGuidance)
                    - Merge duplicates into one task
                    - Today's date is \(Date().formatted(.dateTime.weekday().day().month().year()))
                    """)
                let response = try await session.respond(
                    to: "Extract tasks from this brain dump:\n\n\(input)",
                    generating: BrainDumpResult.self
                )
                let tasks: [BrainPreviewTask] = response.content.tasks.map { dumped in
                    let parsed = parseTaskInput(dumped.title)
                    let priority: TaskPriority = switch dumped.priority.lowercased() {
                    case "high":   .high
                    case "medium": .medium
                    case "low":    .low
                    default:       parsed.priority
                    }
                    return BrainPreviewTask(
                        title: parsed.title.isEmpty ? dumped.title : parsed.title,
                        dueDate: parsed.date ?? Calendar.current.startOfDay(for: Date()),
                        priority: priority
                    )
                }
                await MainActor.run { previewTasks = tasks }
                await advanceToPreview()
            } catch {
                await MainActor.run {
                    errorMessage = "Apple Intelligence couldn't process your request. Try again or rephrase your input."
                    withAnimation { phase = .preview }
                }
            }
        } else {
            let lines = input
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 2 }
            let tasks: [BrainPreviewTask] = lines.map { line in
                let parsed = parseTaskInput(line)
                return BrainPreviewTask(
                    title: parsed.title.isEmpty ? line : parsed.title,
                    dueDate: parsed.date ?? Calendar.current.startOfDay(for: Date()),
                    priority: parsed.priority
                )
            }
            await MainActor.run { previewTasks = tasks }
            await advanceToPreview()
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
                    errorMessage = "Apple Intelligence couldn't process your request. Try again or rephrase your input."
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

// MARK: - Breathing orb

/// A calm, alive indicator: a soft theme-tinted disc with a gentle looping
/// breath and an outer glow that swells with the mic amplitude. Shared by the
/// listening state and the transformation state so the two feel like one motif.
private struct BreathingOrb: View {
    let level: Double
    let palette: Palette
    var icon: String = "mic.fill"
    /// Optional second glyph shown while `listening`. It cross-fades with `icon`
    /// in place (both centered, opacity only) so the icon never translates.
    var activeIcon: String? = nil
    /// When listening, the orb comes alive: sonar pulses + amplitude-driven glow.
    var listening: Bool = false

    @State private var breathe = false
    @State private var sonar = false

    var body: some View {
        ZStack {
            // Sonar rings — only while listening. Two staggered, slow pulses so it
            // reads as "hearing you" without becoming busy.
            if listening {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(palette.primary.opacity(0.28), lineWidth: 2)
                        .scaleEffect(sonar ? 1.9 : 1.0)
                        .opacity(sonar ? 0 : 0.4)
                        .animation(
                            .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.9),
                            value: sonar
                        )
                }
            }
            // Voice-responsive glow (calm: swells a little, never snaps). Kept
            // restrained so it reads as a soft halo rather than a bloom.
            Circle()
                .fill(palette.primary.opacity(0.11))
                .scaleEffect(1.0 + CGFloat(min(1, max(0, level))) * 0.45)
                .animation(.easeOut(duration: 0.28), value: level)
            Circle().fill(palette.primaryLight)
            Circle().strokeBorder(palette.primary.opacity(0.25), lineWidth: 1)
            // Two stacked glyphs, both centered — cross-fade by opacity so the icon
            // swaps in place (no slide/translate).
            ZStack {
                Image(systemName: icon)
                    .opacity(listening && activeIcon != nil ? 0 : 1)
                if let activeIcon {
                    Image(systemName: activeIcon)
                        .opacity(listening ? 1 : 0)
                }
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(palette.primary)
            .animation(.easeInOut(duration: 0.3), value: listening)
        }
        .scaleEffect(breathe ? 1.05 : 0.97)
        .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true; sonar = true }
    }
}

// MARK: - Typewriter text

/// Reveals its text one character at a time, as if typed. Reserves the full size
/// up front (hidden) so surrounding layout doesn't jump as characters appear.
private struct TypewriterText: View {
    let text: String
    var font: Font
    var color: Color
    var perChar: Double = 0.02
    var startDelay: Double = 0

    @State private var count = 0

    var body: some View {
        ZStack {
            Text(text).opacity(0)
            Text(String(text.prefix(count)))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(font)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: text) {
            count = 0
            if startDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
            }
            while count < text.count {
                try? await Task.sleep(nanoseconds: UInt64(perChar * 1_000_000_000))
                if Task.isCancelled { return }
                count += 1
            }
        }
    }
}

// MARK: - Extraction ring

/// A single, gentle theme-colored ring that expands and fades once — reused from
/// the app's completion-burst language to mark a task being pulled from the dump.
private struct ExtractionRing: View {
    let color: Color
    var delay: Double = 0

    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                opacity = 0.5
                scale = 0.9
                withAnimation(.easeOut(duration: 0.55).delay(delay)) {
                    scale = 2.4
                    opacity = 0
                }
            }
    }
}

// MARK: - Closure check

/// The quiet completion mark: a theme-filled check that pops once with a single
/// radiating ring, echoing `TaskCheckbox` without the green (this is closure for
/// the whole dump, tied to the app's identity color).
private struct ClosureCheck: View {
    let palette: Palette

    @State private var pop: CGFloat = 0.6
    @State private var ringScale: CGFloat = 0.7
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(palette.primary, lineWidth: 2.5)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
            Circle().fill(palette.primary)
            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(palette.onPrimary)
        }
        .scaleEffect(pop)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { pop = 1 }
            ringOpacity = 0.6
            ringScale = 0.9
            withAnimation(.easeOut(duration: 0.6)) {
                ringScale = 2.1
                ringOpacity = 0
            }
        }
    }
}

// MARK: - Vertical open/close transition

private extension AnyTransition {
    /// Collapses/expands vertically from the top — the text box "opening" and
    /// "closing" in place rather than scaling uniformly from a corner.
    static var verticalOpen: AnyTransition {
        .modifier(
            active: VerticalScaleModifier(scaleY: 0.05),
            identity: VerticalScaleModifier(scaleY: 1)
        )
    }
}

private struct VerticalScaleModifier: ViewModifier {
    let scaleY: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: scaleY, anchor: .top)
            .opacity(Double(scaleY))
    }
}

