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
        /// What Evry just did in the app.
        case done([EvryDone])
        /// A deletion Evry was asked for, waiting on a tap.
        case confirmDelete(EvryPendingDelete)
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

// MARK: - Greetings

/// Evry's welcome lines. Each can be limited to a time of day; one is picked
/// each time the chat opens, from those that fit the current hour.
private enum EvryGreeting: CaseIterable {
    /// "Good morning / afternoon / evening, Alex".
    case timeOfDay
    case morning
    case howCanIHelp
    case lookWhatIFound
    case ayeAye

    /// TESTING: while true, every greeting is in the running at any hour so
    /// they can all be seen. Set to false to respect each one's hours.
    static let cycleAllForTesting = true

    /// The hours (24h) a greeting may appear in; nil = any time.
    var hours: Range<Int>? {
        switch self {
        case .morning: 5..<12
        default: nil
        }
    }

    static func pick(at date: Date = Date()) -> EvryGreeting {
        let hour = Calendar.current.component(.hour, from: date)
        let candidates = allCases.filter { g in
            cycleAllForTesting || (g.hours?.contains(hour) ?? true)
        }
        return candidates.randomElement() ?? .timeOfDay
    }

    static func text(_ g: EvryGreeting, name: String, timeGreeting: String) -> String {
        switch g {
        case .timeOfDay: name.isEmpty ? timeGreeting : "\(timeGreeting), \(name)"
        case .morning: "Morning (>_<)"
        case .howCanIHelp: "How can I help?"
        case .lookWhatIFound: "Look what I found! (>'.')>#"
        case .ayeAye: "Aye aye captain o7"
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
    @Environment(CalendarService.self) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// Carries out what Evry is asked to do (made on first use).
    @State private var desk: EvryActionDesk?
    @State private var openedNote: Note?
    /// The welcome greeting fades in a beat after the card arrives.
    @State private var greetingShown = false
    @State private var thinkingSpin = false
    /// Evry messages that have finished typing (their options show after).
    @State private var typed: Set<UUID> = []
    @Namespace private var mascotSpace
    @AppStorage("user_name") private var userName = ""
    @State private var greetingChoice: EvryGreeting = EvryGreeting.pick()
    @FocusState private var composerFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Presented as a system sheet (see ContentView): at its partial detent it
    // floats as a Liquid Glass card whose corners follow the display's, with the
    // system grabber, swipe-to-dismiss and keyboard handling. So the content
    // here draws no card chrome of its own.
    var body: some View {
        card
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
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .animation(EvryMotion.settle, value: started)
        .accessibilityAction(.escape) { close() }
    }

    /// Room for the system grabber and the close button.
    private var topBar: some View {
        // A fixed height: a bare Color.clear is greedy and would otherwise
        // soak up the sheet's spare height, pushing everything below it down.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .accessibilityHidden(true)
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

    /// Chosen once each time the chat opens.
    private var greetingLine: String {
        EvryGreeting.text(greetingChoice, name: firstName, timeGreeting: greeting)
    }

    private var firstName: String {
        userName.split(separator: " ").first.map(String.init) ?? ""
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
                    case .done(let items):
                        DonePopups(items: items, palette: palette)
                    case .confirmDelete(let pending):
                        deleteCard(pending, message: message, done: done)
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
                    Text(note.plainText.replacingOccurrences(of: "•\t", with: ""))
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

    /// "Delete “X”?" — Evry never deletes without this tap.
    private func deleteCard(_ pending: EvryPendingDelete, message: ChatMessage, done: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.nunito(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .accessibilityHidden(true)
                Text("Delete the \(pending.kindName) “\(pending.title)”?")
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .editCard(palette)
            if !done {
                HStack(spacing: 8) {
                    Button("Delete") { confirmDelete(pending, from: message) }
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
                    Button("Keep it") {
                        resolved.insert(message.id)
                        youSaid("Keep it")
                        reply("Okay, I’ve left it as it is.")
                    }
                    .buttonStyle(EvrySecondaryButtonStyle(palette: palette))
                }
            }
        }
    }

    private func confirmDelete(_ pending: EvryPendingDelete, from message: ChatMessage) {
        resolved.insert(message.id)
        actionDesk().confirm(pending)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        reply("Deleted “\(pending.title)”.")
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

    /// Free-typed messages: questions, summaries and actions on the person's
    /// tasks, notes, calendar and habits — "remind me to work out at 8p" makes
    /// the task. Anything else gets a polite "only the app".
    private func chat(_ text: String) {
        let data = appData()
        let desk = actionDesk()
        desk.beginTurn()
        withThinking {
            let result = await conversation.reply(to: text, data: data, desk: desk)
            switch result {
            case .answer(let answer):
                say(answer, attachment: desk.log.isEmpty ? nil : .done(desk.log))
            case .offTopic:
                say(EvryConversation.offTopicLine)
            }
            for pending in desk.pendingDeletes {
                say("Just to check:", attachment: .confirmDelete(pending))
            }
            if !desk.log.isEmpty || !desk.pendingDeletes.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            if let minutes = desk.focusMinutes { startFocus(minutes: minutes) }
        }
    }

    private func actionDesk() -> EvryActionDesk {
        if let desk { return desk }
        let made = EvryActionDesk(context: context, calendar: calendar)
        desk = made
        return made
    }

    /// The preset nearest the asked-for length, then into focus mode.
    private func startFocus(minutes: Int) {
        guard !pomodoro.running else { return }
        let preset = PomodoroPreset.all.min { abs($0.workMin - minutes) < abs($1.workMin - minutes) }
        if let preset { pomodoro.selectPreset(preset) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1800))
            closeThen(onEnterFocusMode)
        }
    }

    /// A snapshot of the person's things for Evry to answer from.
    private func appData() -> EvryAppData {
        let cal = Calendar.current
        let now = Date()
        func record(_ t: TaskItem) -> EvryAppData.Task {
            EvryAppData.Task(title: t.title, due: t.dueDate, priority: t.priority.rawValue,
                             folder: t.group?.name, notes: t.notes)
        }
        // Filtered in the store rather than fetching everything and filtering here.
        let openFetch = FetchDescriptor<TaskItem>(predicate: #Predicate {
            !$0.completed && !$0.isNote && $0.deletedAt == nil
        })
        let open = ((try? context.fetch(openFetch)) ?? [])
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let weekAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now
        let doneFetch = FetchDescriptor<TaskItem>(predicate: #Predicate { t in
            if let at = t.completedAt { t.completed && !t.isNote && t.deletedAt == nil && at >= weekAgo } else { false }
        }, sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
        let done = (try? context.fetch(doneFetch)) ?? []

        let notesFetch = FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil },
                                               sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)])
        let notes = ((try? context.fetch(notesFetch)) ?? [])
            .map { n in
                EvryAppData.Note(title: n.title, folder: n.folder?.name,
                                 text: n.plainText
                                    .replacingOccurrences(of: "•\t", with: "")
                                    .replacingOccurrences(of: "\n", with: " "))
            }

        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 14, to: start) ?? now
        let events = calendar.events(from: start, to: end).map {
            EvryAppData.Event(title: $0.title, start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay)
        }

        let habits = ((try? context.fetch(FetchDescriptor<Habit>())) ?? [])
            .filter { $0.isDue(on: start) }
            .map { EvryAppData.Habit(name: $0.name, doneToday: $0.isDoneToday) }

        return EvryAppData(openTasks: open.map(record), recentlyDone: done.map(record),
                           notes: notes, events: events, habitsToday: habits)
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
        isPresented = false
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

// MARK: - Done popups

/// What Evry just did, as popups after its reply: one card per thing, popping
/// in one after another, each ticking itself off with the same completion
/// check (pop, ring burst, tap) as finishing a task.
private struct DonePopups: View {
    let items: [EvryDone]
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                DonePopup(item: item, index: index, palette: palette)
            }
        }
    }
}

private struct DonePopup: View {
    let item: EvryDone
    let index: Int
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var ticked = false

    var body: some View {
        HStack(spacing: 10) {
            TaskCheckbox(checked: ticked, palette: palette, contentAlignment: .center) {}
                .allowsHitTesting(false)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.nunito(size: 16, weight: .bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.nunito(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.kind != .task {
                Image(systemName: item.icon)
                    .font(.nunito(size: 14, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .editCard(palette)
        .scaleEffect(shown || reduceMotion ? 1 : 0.8, anchor: .leading)
        .offset(y: shown || reduceMotion ? 0 : 12)
        .opacity(shown || reduceMotion ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.detail.isEmpty ? item.title : "\(item.title), \(item.detail)")
        .task {
            // One after another: pop in, then tick off.
            let stagger = reduceMotion ? 0 : 0.15 + Double(index) * 0.4
            try? await Task.sleep(for: .seconds(stagger))
            withAnimation(reduceMotion ? nil : EvryMotion.pop) { shown = true }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 220))
            ticked = true
        }
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
        .sheet(isPresented: $open) {
            EvryChatOverlay(isPresented: $open, onEnterFocusMode: {})
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.visible)
        }
        .environment(Appearance())
        .environment(PomodoroModel())
        .environment(CalendarService())
        .modelContainer(for: [TaskItem.self, Note.self, Folder.self, Habit.self], inMemory: true)
}
