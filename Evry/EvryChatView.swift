//
//  EvryChatView.swift
//  Evry
//
//  The chat with Evry, opened from the Evry mark in the Inbox header. A white
//  panel rises from the bottom over the current page; Evry greets the person and
//  offers three things it can do right here in the conversation:
//
//  - Distill: talk or type a jumble of thoughts; Evry turns it into tasks.
//  - Pomo:    pick a session length; Evry starts focus mode.
//  - Write:   leave Evry a voice message; it becomes a tidy, formatted note.
//
//  Free-typed messages get a short reply from Evry (on device), which can point
//  back to these three.
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - Messages

private struct ChatMessage: Identifiable, Equatable {
    enum Role { case evry, you }

    enum Attachment {
        /// The three feature chips (Distill, Pomo, Write).
        case suggestions
        /// Tasks extracted by Distill, waiting to be added.
        case tasks([BrainPreviewTask])
        /// Pomodoro session choices.
        case pomoPresets
        /// A note created by Write.
        case note(Note)
        /// A single follow-up action chip.
        case action(String)
    }

    let id = UUID()
    let role: Role
    let text: String
    var attachment: Attachment? = nil

    static func == (a: ChatMessage, b: ChatMessage) -> Bool { a.id == b.id }
}

/// What the next thing the person sends is for.
private enum ChatMode: Equatable { case chat, distill, write }

private enum ChatFeature: CaseIterable {
    case distill, pomo, write

    var title: String {
        switch self {
        case .distill: "Distill"
        case .pomo: "Pomo"
        case .write: "Write"
        }
    }

    var icon: String {
        switch self {
        case .distill: "list.bullet.indent"
        case .pomo: "timer"
        case .write: "waveform"
        }
    }

    var hint: String {
        switch self {
        case .distill: "Turn your thoughts into tasks"
        case .pomo: "Start a focus session"
        case .write: "Turn a voice message into a note"
        }
    }
}

// MARK: - Overlay

struct EvryChatOverlay: View {
    @Binding var isPresented: Bool
    /// Starts the pomodoro (if needed) and enters focus mode.
    var onEnterFocusMode: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var dragY: CGFloat = 0
    @State private var messages: [ChatMessage] = []
    /// Messages whose chips have been used, so they can't be tapped twice.
    @State private var resolved: Set<UUID> = []
    @State private var thinking = false
    @State private var mode: ChatMode = .chat
    @State private var draft = ""
    /// Text already in the field when dictation began; speech appends to it.
    @State private var draftBeforeSpeech = ""
    @State private var speech = LiveSpeechInput()
    @State private var conversation = EvryConversation()
    @State private var openedNote: Note?
    /// The welcome greeting fades in a beat after the card arrives.
    @State private var greetingShown = false
    @State private var thinkingSpin = false
    /// Evry messages that have finished typing (their options show after).
    @State private var typed: Set<UUID> = []
    @Namespace private var mascotSpace
    @AppStorage("user_name") private var userName = ""
    @FocusState private var composerFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // A scrim so the page behind reads as "underneath" the card.
                Color.evryNavy.opacity(appeared ? 0.25 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityHidden(true)

                // A floating bottom card: inset from the edges, rounded all round,
                // and it rides above the keyboard (the frame shrinks with it).
                card
                    .frame(height: max(0, min(geo.size.height - 56, 700)))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .offset(y: appeared ? max(0, dragY) : geo.size.height + geo.safeAreaInsets.bottom)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .onAppear(perform: open)
        .onChange(of: speech.transcript) { _, spoken in
            guard speech.isListening else { return }
            draft = draftBeforeSpeech.isEmpty ? spoken : draftBeforeSpeech + " " + spoken
        }
        // The field grows to several lines, so Return arrives as a newline rather
        // than a submit — treat it as "send".
        .onChange(of: draft) { _, text in
            guard text.contains("\n"), !speech.isListening else { return }
            draft = text.replacingOccurrences(of: "\n", with: " ")
            send()
        }
        .onChange(of: speech.permissionDenied) { _, denied in
            guard denied else { return }
            say("Please allow the microphone in Settings, or type to me instead.")
        }
        .onDisappear { speech.stop() }
        .sheet(item: $openedNote) { note in
            NoteEditorView(note: note).environment(appearance)
        }
    }

    /// The conversation has begun once the person has said something; until then
    /// the card shows the welcome (Evry centred, the greeting and the options).
    private var started: Bool { messages.contains { $0.role == .you } }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            topBar
            if started {
                ListeningMascot(size: composerFocused ? 52 : 72, listening: isListeningToUser)
                    .matchedGeometryEffect(id: "evry", in: mascotSpace)
                    .padding(.bottom, 4)
                    .animation(EvryMotion.settle, value: composerFocused)
                transcript
            } else {
                welcome
            }
            composer
        }
        .background(palette.bg, in: RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous)
            .strokeBorder(palette.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.nunito(size: 14, weight: .bold))
                    .foregroundStyle(palette.text)
                    .frame(width: 34, height: 34)
                    .background(palette.hover, in: Circle())
                    .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Close chat")
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .evryShadowLift(palette)
        .animation(EvryMotion.settle, value: started)
        // A modal container: VoiceOver reaches every control inside, stays on
        // the card, and the two-finger scrub closes it.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
    }

    /// Grabber and close button. Swipe here to close the card.
    private var topBar: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(palette.border)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .accessibilityHidden(true)

        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragY = $0.translation.height }
                .onEnded { v in
                    if v.translation.height > 110 || v.predictedEndTranslation.height > 260 {
                        close()
                    } else {
                        withAnimation(EvryMotion.settle) { dragY = 0 }
                    }
                }
        )
    }

    /// Evry leans in while the person is talking or typing to it.
    private var isListeningToUser: Bool {
        speech.isListening || (composerFocused && !trimmedDraft.isEmpty)
    }

    // MARK: Welcome

    /// The empty state: Evry centred with a large greeting, then the three things
    /// Evry can do. Messages Evry sends before the person speaks (e.g. a
    /// permission note) show under the options.
    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ListeningMascot(size: composerFocused ? 88 : 120, listening: isListeningToUser)
                .matchedGeometryEffect(id: "evry", in: mascotSpace)
                .animation(EvryMotion.settle, value: composerFocused)

            if greetingShown {
                TypewriterText(text: greetingLine)
                    .font(.nunito(size: 28, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, EvrySpace.grid)
                    .transition(.opacity.combined(with: .offset(y: 14)))

                HStack(spacing: 8) {
                    ForEach(Array(ChatFeature.allCases.enumerated()), id: \.offset) { index, feature in
                        StaggeredAppear(index: index) { featurePill(feature) }
                    }
                }
                .padding(.top, 20)

                ForEach(messages) { message in
                    Text(message.text)
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                        .padding(.horizontal, EvrySpace.grid)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { composerFocused = false }
    }

    private var greetingLine: String {
        let first = userName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(greeting)" : "\(greeting), \(first)"
    }

    private func featurePill(_ feature: ChatFeature, message: ChatMessage? = nil, disabled: Bool = false) -> some View {
        Button { choose(feature, from: message) } label: {
            HStack(spacing: 6) {
                Image(systemName: feature.icon)
                    .font(.nunito(size: 14, weight: .bold))
                Text(feature.title)
                    .font(.nunito(size: 15, weight: .bold))
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 16)
            .frame(minHeight: EvrySpace.tap)
            .background(palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityHint(feature.hint)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(messages) { message in
                        messageView(message)
                            .id(message.id)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 12)),
                                removal: .opacity))
                    }
                    if thinking {
                        typingIndicator
                            .id("typing")
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, EvrySpace.grid)
                .padding(.top, 16)
                .padding(.bottom, 28)
                // Scrolling targets this, so the bottom padding is always shown.
                Color.clear.frame(height: 1).id("bottom")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            // Messages fade out under Evry and above the composer instead of
            // being cut off at a hard edge.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            }
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: thinking) { _, _ in scrollToEnd(proxy) }
            // Options appear when a line finishes typing — keep them in view.
            .onChange(of: typed.count) { _, _ in scrollToEnd(proxy) }
            // The keyboard shrinks the list; follow the conversation once it's up.
            .onChange(of: composerFocused) { _, focused in
                guard focused else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    scrollToEnd(proxy)
                }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(EvryMotion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// Evry's replies are plain text across the card; the person's messages sit
    /// in a soft rounded bubble on the right.
    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        switch message.role {
        case .you:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .font(.evryBody)
                    .lineSpacing(3)
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(palette.skySoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(message.text)")
        case .evry:
            VStack(alignment: .leading, spacing: 12) {
                TypewriterText(text: message.text) {
                    withAnimation(EvryMotion.settle) { _ = typed.insert(message.id) }
                }
                    .font(.nunito(size: 17))
                    .lineSpacing(5)
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Evry says: \(message.text)")

                // Options arrive once Evry has finished "typing" the line.
                if let attachment = message.attachment, typed.contains(message.id) {
                    let done = resolved.contains(message.id)
                    switch attachment {
                    case .suggestions:
                        HStack(spacing: 8) {
                            ForEach(Array(ChatFeature.allCases.enumerated()), id: \.offset) { index, feature in
                                StaggeredAppear(index: index) {
                                    featurePill(feature, message: message, disabled: done)
                                }
                            }
                        }
                    case .tasks(let tasks):
                        taskList(tasks, message: message, done: done)
                    case .pomoPresets:
                        pomoChips(for: message, disabled: done)
                    case .note(let note):
                        noteCard(note)
                    case .action(let title):
                        actionChip(title, message: message, disabled: done)
                    }
                }
            }
        }
    }

    /// Evry's star turning gently while it works on a reply.
    private var typingIndicator: some View {
        HStack(spacing: 8) {
            Image("EvryIconStar")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(palette.text)
                .rotationEffect(.degrees(thinkingSpin && !reduceMotion ? 360 : 0))
                .scaleEffect(thinkingSpin && !reduceMotion ? 0.85 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: false),
                           value: thinkingSpin)
                .onAppear { thinkingSpin = true }
                .onDisappear { thinkingSpin = false }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evry is writing")
    }

    // MARK: Attachments

    private func pomoChips(for message: ChatMessage, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(PomodoroPreset.all.enumerated()), id: \.element.id) { index, preset in
                StaggeredAppear(index: index) {
                    Button { startPomo(preset, from: message) } label: {
                        HStack(spacing: 8) {
                            Text(preset.label)
                                .font(.evryLabel)
                            Text("\(preset.workMin) min")
                                .font(.nunito(size: 14, weight: .semibold))
                                .foregroundStyle(palette.textSec)
                        }
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 18)
                        .frame(minHeight: EvrySpace.tap)
                        .background(palette.skySoft, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.evrySky, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(disabled)
                    .opacity(disabled ? 0.5 : 1)
                }
            }
        }
    }

    private func taskList(_ tasks: [BrainPreviewTask], message: ChatMessage, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Rectangle().fill(palette.hairline).frame(height: 1) }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if done { EvryCheck(size: 18) } else { EvryBullet(size: 10) }
                        Text(task.title)
                            .font(.evryBody)
                            .foregroundStyle(palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if task.priority != .normal, let symbol = task.priority.symbol {
                            Image(systemName: symbol)
                                .font(.nunito(size: 12, weight: .bold))
                                .foregroundStyle(palette.text)
                                .accessibilityLabel("\(task.priority.label) priority")
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            .evryCard(palette, cornerRadius: EvryRadius.field)

            if !done {
                HStack(spacing: 8) {
                    Button("Add them") { addTasks(tasks, from: message) }
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
                    Button("Not now") { skipTasks(from: message) }
                        .buttonStyle(EvrySecondaryButtonStyle(palette: palette))
                }
            }
        }
    }

    private func noteCard(_ note: Note) -> some View {
        Button { openedNote = note } label: {
            HStack(spacing: 12) {
                ToolIcon(tool: .notes, tile: 40, palette: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? "New note" : note.title)
                        .font(.evryLabel)
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Text(NoteBodyCodec.plainText(note.body).replacingOccurrences(of: "•\t", with: ""))
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.nunito(size: 14, weight: .bold))
                    .foregroundStyle(palette.text)
            }
            .padding(12)
            .evryCard(palette, cornerRadius: EvryRadius.field)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityHint("Opens the note")
    }

    private func actionChip(_ title: String, message: ChatMessage, disabled: Bool) -> some View {
        Button(title) {
            resolved.insert(message.id)
            closeThen(onEnterFocusMode)
        }
        .buttonStyle(EvrySecondaryButtonStyle(palette: palette))
        .disabled(disabled)
    }

    // MARK: Composer

    /// One rounded card: the message field on top, and a row of controls below —
    /// the feature menu, the mode pill, dictation, and the main button (send when
    /// there's text, otherwise start a voice note with Write).
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .font(.nunito(size: 17))
                .foregroundStyle(palette.text)
                .tint(palette.primary)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 8) {
                featureMenu
                modePill
                Spacer(minLength: 0)
                micButton
                primaryButton
            }
        }
        .padding(12)
        .background(palette.skyMist, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(composerFocused || speech.isListening ? palette.border : palette.hairline, lineWidth: 1))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(EvryMotion.settle, value: mode)
        .animation(EvryMotion.hover, value: trimmedDraft.isEmpty)
    }

    /// "+" — everything Evry can do, from anywhere in the conversation.
    private var featureMenu: some View {
        Menu {
            ForEach(ChatFeature.allCases, id: \.self) { feature in
                Button { choose(feature, from: nil) } label: {
                    Label(feature.title, systemImage: feature.icon)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.nunito(size: 17, weight: .bold))
                .foregroundStyle(palette.text)
                .frame(width: 40, height: 40)
                .background(palette.card, in: Circle())
                .overlay(Circle().strokeBorder(palette.hairline, lineWidth: 1))
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .contentShape(Circle())
        }
        .accessibilityLabel("Things Evry can do")
    }

    /// What the next message is for — like a model picker. Tap to switch.
    private var modePill: some View {
        Menu {
            Button { setMode(.chat) } label: { Label("Chat", systemImage: "bubble.left") }
            Button { setMode(.distill) } label: { Label("Distill", systemImage: ChatFeature.distill.icon) }
            Button { setMode(.write) } label: { Label("Write", systemImage: ChatFeature.write.icon) }
        } label: {
            HStack(spacing: 5) {
                Text("Evry")
                    .font(.nunito(size: 15, weight: .bold))
                    .foregroundStyle(palette.text)
                Text(modeName)
                    .font(.nunito(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 1))
            .frame(minHeight: EvrySpace.tap)
            .contentShape(Capsule())
        }
        .accessibilityLabel("Mode: \(modeName)")
    }

    private var modeName: String {
        switch mode {
        case .chat: "Chat"
        case .distill: "Distill"
        case .write: "Write"
        }
    }

    private var micButton: some View {
        Button(action: toggleListening) {
            ZStack {
                if speech.isListening {
                    // A soft ring that breathes with the voice.
                    Circle()
                        .fill(Color.evrySky.opacity(0.55))
                        .frame(width: 40, height: 40)
                        .scaleEffect(reduceMotion ? 1.15 : 1.05 + speech.level * 0.45)
                        .animation(.easeOut(duration: 0.12), value: speech.level)
                }
                Image(systemName: speech.isListening ? "stop.fill" : "mic")
                    .font(.nunito(size: 16, weight: .bold))
                    .foregroundStyle(speech.isListening ? Color.evryNavy : palette.text)
                    .frame(width: 40, height: 40)
                    .background(speech.isListening ? Color.evrySky : palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(speech.isListening ? .clear : palette.hairline, lineWidth: 1))
            }
            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(speech.isListening ? "Stop listening" : "Dictate")
    }

    /// Send when there's something to send; otherwise start a voice note (Write).
    private var primaryButton: some View {
        let canSend = !trimmedDraft.isEmpty
        return Button {
            if canSend { send() } else { choose(.write, from: nil) }
        } label: {
            Image(systemName: canSend ? "arrow.up" : "waveform")
                .font(.nunito(size: 17, weight: .heavy))
                .foregroundStyle(palette.onPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(palette.primary, in: Circle())
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(thinking)
        .opacity(thinking ? 0.4 : 1)
        .accessibilityLabel(canSend ? "Send" : "Leave Evry a voice note")
    }

    private var placeholder: String {
        if speech.isListening { return "Listening…" }
        switch mode {
        case .chat: return "Chat with Evry"
        case .distill: return "What’s on your mind?"
        case .write: return "Say or type your note"
        }
    }

    // MARK: Flow

    private func open() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : EvryMotion.settle) { appeared = true }
        guard !greetingShown else { return }
        // The card settles, then Evry's greeting rises in and the options pop in.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 420))
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : EvryMotion.settle) { greetingShown = true }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hi there"
        }
    }

    private func say(_ text: String, attachment: ChatMessage.Attachment? = nil) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : EvryMotion.spring) {
            messages.append(ChatMessage(role: .evry, text: text, attachment: attachment))
        }
    }

    private func youSaid(_ text: String) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : EvryMotion.settle) {
            messages.append(ChatMessage(role: .you, text: text))
        }
    }

    /// Shows Evry "typing" while `work` runs, holding it for a short minimum so
    /// the reply never snaps in.
    private func withThinking(_ work: @escaping () async -> Void) {
        Task { @MainActor in
            withAnimation(EvryMotion.settle) { thinking = true }
            let start = Date()
            await work()
            let elapsed = Date().timeIntervalSince(start)
            if elapsed < 0.6 { try? await Task.sleep(for: .milliseconds(Int((0.6 - elapsed) * 1000))) }
            withAnimation(EvryMotion.settle) { thinking = false }
        }
    }

    private func choose(_ feature: ChatFeature, from message: ChatMessage?) {
        UISelectionFeedbackGenerator().selectionChanged()
        if let message { resolved.insert(message.id) }
        youSaid(feature.title)
        switch feature {
        case .distill:
            mode = .distill
            reply("Tell me what’s on your mind and I’ll turn it into tasks.")
            composerFocused = true
        case .pomo:
            if pomodoro.running {
                reply("You’re already focusing — want to jump back in?",
                      attachment: .action("Open focus mode"))
            } else {
                reply("Which session feels right?", attachment: .pomoPresets)
            }
        case .write:
            mode = .write
            reply("I’m listening — what would you like to note down?")
            // Write is a voice message — start listening straight away.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                if mode == .write && !speech.isListening { toggleListening() }
            }
        }
    }

    /// Evry's reply after a short typing beat.
    private func reply(_ text: String, attachment: ChatMessage.Attachment? = nil) {
        withThinking { }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 620))
            say(text, attachment: attachment)
        }
    }

    private func toggleListening() {
        if speech.isListening {
            speech.stop()
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            draftBeforeSpeech = trimmedDraft
            speech.transcript = ""
            composerFocused = false
            speech.toggle()
        }
    }

    /// Switches what the next message is for, from the mode pill — quietly,
    /// without adding to the conversation.
    private func setMode(_ newMode: ChatMode) {
        guard newMode != mode else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        mode = newMode
        switch newMode {
        case .chat:
            speech.stop()
        case .distill:
            composerFocused = true
        case .write:
            if !speech.isListening { toggleListening() }
        }
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty, !thinking else { return }
        speech.stop()
        draft = ""
        youSaid(text)
        let sentMode = mode
        mode = .chat

        switch sentMode {
        case .distill: distill(text)
        case .write: write(text)
        case .chat: chat(text)
        }
    }

    private func chat(_ text: String) {
        withThinking {
            let answer = await conversation.reply(to: text)
            if let answer {
                say(answer)
            } else {
                say("Here’s what I can help with.", attachment: .suggestions)
            }
        }
    }

    // MARK: Distill

    private func distill(_ text: String) {
        withThinking {
            let tasks: [BrainPreviewTask]
            do {
                tasks = try await EvryAssistant.distill(text, usesPrioritiesOften: usesPrioritiesOften)
            } catch {
                // The model couldn't run this time — split the text instead, so
                // the person still gets their tasks.
                tasks = EvryAssistant.fallbackTasks(text)
            }
            if tasks.isEmpty {
                say("I didn’t spot any tasks in that — want to try again?", attachment: .suggestions)
            } else {
                let count = tasks.count == 1 ? "1 task" : "\(tasks.count) tasks"
                say("I found \(count) — add \(tasks.count == 1 ? "it" : "them") to your inbox?",
                    attachment: .tasks(tasks))
            }
        }
    }

    /// True when the user labels a meaningful share of their own tasks with a
    /// priority (matches Brain dump's behaviour).
    private var usesPrioritiesOften: Bool {
        let all = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        let real = all.filter { !$0.isTrashed && !$0.isNote }
        guard real.count >= 5 else { return false }
        let labeled = real.filter { $0.priority != .normal }.count
        return Double(labeled) / Double(real.count) >= 0.4
    }

    private func addTasks(_ tasks: [BrainPreviewTask], from message: ChatMessage) {
        for task in tasks {
            let item = TaskItem(title: task.title)
            // Every task needs a due date — default to today when none was said.
            item.dueDate = task.dueDate ?? Calendar.current.startOfDay(for: Date())
            item.priority = task.priority
            context.insert(item)
        }
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(EvryMotion.settle) { _ = resolved.insert(message.id) }
        reply(tasks.count == 1 ? "Done, it’s in your inbox." : "Done, all \(tasks.count) are in your inbox.",
              attachment: .suggestions)
    }

    private func skipTasks(from message: ChatMessage) {
        resolved.insert(message.id)
        youSaid("Not now")
        reply("No problem, I’ve left them out.", attachment: .suggestions)
    }

    // MARK: Pomo

    private func startPomo(_ preset: PomodoroPreset, from message: ChatMessage) {
        resolved.insert(message.id)
        UISelectionFeedbackGenerator().selectionChanged()
        youSaid("\(preset.label), \(preset.workMin) min")
        pomodoro.selectPreset(preset)
        reply("Starting \(preset.workMin) minutes of focus — enjoy the quiet.")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1700))
            closeThen(onEnterFocusMode)
        }
    }

    // MARK: Write

    private func write(_ text: String) {
        withThinking {
            let draft: WrittenNoteDraft
            do {
                draft = try await EvryAssistant.writeNote(from: text)
            } catch {
                draft = EvryAssistant.fallbackNote(text)
            }
            let note = Note(title: draft.title, body: draft.body)
            context.insert(note)
            try? context.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            say("Saved “\(draft.title)” to your notes.", attachment: .note(note))
        }
    }

    // MARK: Close

    private func close() {
        speech.stop()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : EvryMotion.settle) {
            appeared = false
            dragY = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            isPresented = false
        }
    }

    private func closeThen(_ action: @escaping () -> Void) {
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            action()
        }
    }
}

// MARK: - Listening mascot

/// Evry floating gently (the passive idle loop), leaning in with a small tilt
/// while the person talks or types to it. Decorative motion stops under
/// Reduce Motion.
private struct ListeningMascot: View {
    let size: CGFloat
    let listening: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        EvryMascot(size: size, float: true)
            .rotationEffect(.degrees(listening && !reduceMotion ? -10 : 0), anchor: .bottom)
            .offset(x: listening && !reduceMotion ? -4 : 0)
            .scaleEffect(listening ? 1.04 : 1, anchor: .bottom)
            .animation(EvryMotion.spring, value: listening)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

// MARK: - Staggered pop-in

/// Pops its content in (scale from 0.3 with a small overshoot) after a short
/// delay based on `index`, so a row of options arrives one after another.
private struct StaggeredAppear<Content: View>: View {
    let index: Int
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        content()
            .scaleEffect(shown || reduceMotion ? 1 : 0.6, anchor: .leading)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(EvryMotion.pop.delay(0.12 + Double(index) * 0.08)) { shown = true }
            }
    }
}

#Preview {
    @Previewable @State var open = true
    Color.white
        .overlay {
            if open { EvryChatOverlay(isPresented: $open, onEnterFocusMode: {}) }
        }
        .environment(Appearance())
        .environment(PomodoroModel())
        .modelContainer(for: [TaskItem.self, Note.self, Folder.self], inMemory: true)
}
