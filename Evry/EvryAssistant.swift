//
//  EvryAssistant.swift
//  Evry
//
//  The on-device engine behind Evry, the assistant: turning a brain dump into
//  tasks (Distill), turning a spoken message into a formatted note (Write), and
//  short conversational replies in the chat. Everything runs on device through
//  FoundationModels; when the model isn't available each feature falls back to a
//  plain, predictable result so the user is never left empty-handed.
//
//  (User-facing copy never calls this "AI" — see the design system's banned
//  terms. Describe what Evry does instead.)
//

import Foundation
import FoundationModels
import UIKit

enum EvryAssistant {
    /// True when the on-device language model can be used right now.
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }
}

// MARK: - Distill (brain dump → tasks)

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

extension EvryAssistant {
    /// Extracts tasks from a free-form dump. `usesPrioritiesOften` reflects the
    /// user's own habit, so priorities are assigned freely only for people who
    /// lean on them. Throws only if the model fails outright.
    static func distill(_ input: String, usesPrioritiesOften: Bool) async throws -> [BrainPreviewTask] {
        // Too little to reason about — skip the model (which otherwise tends to
        // emit schema/instruction text as a task) and just use the raw text.
        let wordCount = input.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        guard isAvailable, wordCount >= 2 else { return fallbackTasks(input) }

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
            - Keep timing cues the user actually said in the title, but do \
            NOT add or infer any date they didn't say. If they gave only a \
            time (e.g. "7pm"), keep just the time — never turn it into \
            "today", "tomorrow", or any specific day.
            \(priorityGuidance(usesPrioritiesOften))
            - Merge duplicates into one task
            - Today's date is \(Date().formatted(.dateTime.weekday().day().month().year()))
            """)
        let response = try await session.respond(
            to: "Extract tasks from this brain dump:\n\n\(input)",
            generating: BrainDumpResult.self
        )
        let tasks: [BrainPreviewTask] = response.content.tasks.compactMap { dumped in
            guard !isSchemaArtifact(dumped.title) else { return nil }
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
        // If the model returned nothing usable, fall back to splitting the raw text.
        return tasks.isEmpty ? fallbackTasks(input) : tasks
    }

    /// Splits the raw dump into tasks without the model — for very short input
    /// and as a safety net when the model returns nothing usable.
    static func fallbackTasks(_ input: String) -> [BrainPreviewTask] {
        let pieces = input
            .components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { stripLeadingJoiner($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        let sources = pieces.isEmpty
            ? [input.trimmingCharacters(in: .whitespacesAndNewlines)]
            : pieces
        return sources.filter { !$0.isEmpty }.map { line in
            let parsed = parseTaskInput(line)
            return BrainPreviewTask(
                title: parsed.title.isEmpty ? line : parsed.title,
                dueDate: parsed.date ?? Calendar.current.startOfDay(for: Date()),
                priority: parsed.priority
            )
        }
    }

    /// "…, and book the dentist" → "book the dentist": drops the joining word a
    /// comma-separated list leaves at the start of a piece.
    private static func stripLeadingJoiner(_ piece: String) -> String {
        for joiner in ["and then ", "and ", "then ", "also ", "plus "]
        where piece.lowercased().hasPrefix(joiner) {
            return String(piece.dropFirst(joiner.count)).trimmingCharacters(in: .whitespaces)
        }
        return piece
    }

    /// Guards against the model echoing its own response schema/instructions as a
    /// "task" (e.g. "Response format in json") on very sparse input.
    private static func isSchemaArtifact(_ title: String) -> Bool {
        let l = title.lowercased()
        return l.contains("response format") || l.contains("json")
            || l.contains("schema") || l.contains("actionable task")
            || l.contains("brain dump")
    }

    /// Priority instructions for the extractor — sparing by default, generous only
    /// if the user's own habit shows they lean on priorities.
    private static func priorityGuidance(_ usesPrioritiesOften: Bool) -> String {
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
}

// MARK: - Write (spoken message → formatted note)

@Generable(description: "A well-organised note written from a person's spoken message")
private struct WrittenNote {
    @Guide(description: "A short, specific title in sentence case, 2 to 6 words. No trailing punctuation.")
    var title: String

    @Guide(description: "One or two sentences that open the note and say what it is about, in the speaker's own voice.")
    var intro: String

    @Guide(description: "The note's sections, in the order the ideas came up. Use one section for a short message.", .maximumCount(6))
    var sections: [WrittenSection]
}

@Generable(description: "One section of a note")
private struct WrittenSection {
    @Guide(description: "A short sentence-case heading for the section, 1 to 5 words.")
    var heading: String

    @Guide(description: "Paragraphs of clean prose for this section. Empty if the section is best as a list.", .maximumCount(4))
    var paragraphs: [String]

    @Guide(description: "Bullet points for lists, steps, items or action points mentioned. Empty if there are none.", .maximumCount(12))
    var bullets: [String]
}

/// A note produced by Write, ready to save: a title and the rich body in the
/// note editor's own styles (heading / body / bulleted list).
struct WrittenNoteDraft {
    var title: String
    var body: NSAttributedString
}

extension EvryAssistant {
    /// Turns a spoken (or typed) message into a properly formatted note that keeps
    /// every detail the person said.
    static func writeNote(from message: String) async throws -> WrittenNoteDraft {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, trimmed.split(separator: " ").count >= 4 else {
            return fallbackNote(trimmed)
        }
        let session = LanguageModelSession(instructions: """
            You turn a person's spoken message into a clear, well-organised note.
            Rules:
            - Use ONLY what the person said. Never invent facts, names, dates or items.
            - Keep EVERY idea, detail, number, name and date they mentioned — organise, don't summarise away.
            - Remove filler words and false starts (um, uh, like, you know, I mean).
            - Group related ideas into short sections with clear headings.
            - Use bullet points for lists, steps, items to buy or bring, and action points.
            - Write in the person's own voice (first person if they spoke that way).
            - Sentence case for the title and headings. No emoji.
            """)
        let response = try await session.respond(
            to: "Write a note from this message:\n\n\(trimmed)",
            generating: WrittenNote.self
        )
        let note = response.content
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return WrittenNoteDraft(
            title: title.isEmpty ? fallbackTitle(trimmed) : title,
            body: formattedBody(intro: note.intro, sections: note.sections)
        )
    }

    /// Without the model: the message as a single body paragraph, titled by its
    /// opening words.
    static func fallbackNote(_ message: String) -> WrittenNoteDraft {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: message, attributes: bodyAttributes))
        return WrittenNoteDraft(title: fallbackTitle(message), body: out)
    }

    private static func fallbackTitle(_ message: String) -> String {
        let words = message.split(separator: " ").prefix(5).joined(separator: " ")
        let cleaned = words.trimmingCharacters(in: .punctuationCharacters)
        guard let first = cleaned.first else { return "New note" }
        return first.uppercased() + cleaned.dropFirst()
    }

    // The note editor's styles (see NoteBodyEditor): heading = Nunito Bold 22,
    // body = Nunito Regular 16, bullets = "•\t" with a 26pt hanging indent.
    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 6
        return [.font: UIFont.nunito(size: 16), .paragraphStyle: p]
    }

    private static var headingAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 10
        p.paragraphSpacing = 4
        return [.font: UIFont.nunito(size: 22, weight: .bold), .paragraphStyle: p]
    }

    private static var bulletAttributes: [NSAttributedString.Key: Any] {
        let indent: CGFloat = 26
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        p.defaultTabInterval = indent
        p.headIndent = indent
        p.paragraphSpacing = 2
        return [.font: UIFont.nunito(size: 16), .paragraphStyle: p]
    }

    private static func formattedBody(intro: String, sections: [WrittenSection]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func line(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
            out.append(NSAttributedString(string: t, attributes: attrs))
        }
        line(intro, bodyAttributes)
        for section in sections {
            line(section.heading, headingAttributes)
            for paragraph in section.paragraphs { line(paragraph, bodyAttributes) }
            for bullet in section.bullets { line("•\t" + bullet, bulletAttributes) }
        }
        return out
    }
}

// MARK: - Chat replies

/// A compact, read-only picture of the person's things — what Evry may answer
/// questions about. Built on the main actor from SwiftData / EventKit, then
/// handed to the model as plain text.
struct EvryAppData: Sendable {
    struct Task: Sendable { let title: String; let due: Date?; let done: Bool; let priority: String; let folder: String?; let notes: String }
    struct Note: Sendable { let title: String; let folder: String?; let text: String; let modified: Date }
    struct Event: Sendable { let title: String; let start: Date; let end: Date; let allDay: Bool }
    struct Habit: Sendable { let name: String; let doneToday: Bool }

    var openTasks: [Task] = []
    var recentlyDone: [Task] = []
    var notes: [Note] = []
    var events: [Event] = []
    var habitsToday: [Habit] = []

    /// The data as compact text for the model (kept small for its context).
    var promptText: String {
        let day = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        var out = ["Today is \(day)."]
        func when(_ d: Date?) -> String {
            guard let d else { return "no date" }
            return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        }
        out.append("OPEN TASKS (\(openTasks.count)):")
        out += openTasks.prefix(30).map { t in
            var line = "- \(t.title) — due \(when(t.due))"
            if t.priority != "normal" { line += ", \(t.priority) priority" }
            if let f = t.folder { line += ", folder \(f)" }
            if !t.notes.isEmpty { line += ", notes: \(t.notes.prefix(80))" }
            return line
        }
        out.append("DONE IN THE LAST 7 DAYS (\(recentlyDone.count)):")
        out += recentlyDone.prefix(10).map { "- \($0.title)" }
        out.append("NOTES (\(notes.count)):")
        out += notes.prefix(12).map { n in
            "- \"\(n.title.isEmpty ? "Untitled" : n.title)\"\(n.folder.map { " in \($0)" } ?? ""): \(n.text.prefix(160))"
        }
        out.append("CALENDAR, NEXT 14 DAYS (\(events.count)):")
        out += events.prefix(25).map { e in
            e.allDay
                ? "- \(e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) all day: \(e.title)"
                : "- \(when(e.start))–\(e.end.formatted(.dateTime.hour().minute())): \(e.title)"
        }
        out.append("HABITS TODAY (\(habitsToday.count)):")
        out += habitsToday.map { "- \($0.name): \($0.doneToday ? "done" : "not done yet")" }
        return out.joined(separator: "\n")
    }
}

@Generable(description: "Evry's answer to a message in the chat")
private struct ChatAnswer {
    @Guide(description: "true if the message is about the person's own tasks, to-dos, reminders, notes, calendar, events, habits or focus — asking about them, summarising them, or asking Evry to add, change, complete, move or delete them — or a greeting, thanks, or a question about how to use the Evry app. false for anything else: general knowledge, news, weather, maths, coding, trivia, opinions, or advice unrelated to their own plans.")
    var aboutApp: Bool

    @Guide(description: "Evry's reply in the first person, warm and plain, using ONLY the person's data and what the tools reported. After using tools, ONLY a short friendly acknowledgment such as 'All set!' or 'Done, enjoy your workout.' — never list or repeat the tasks, events or changes, because the app shows them separately. Otherwise one or two short sentences; for a summary, a sentence then up to 5 lines, each on its own line starting with '• '. If the data doesn't contain the answer, say so kindly. Empty when aboutApp is false.")
    var reply: String
}

/// A running conversation with Evry for free-typed messages: questions,
/// summaries and actions on the person's tasks, notes, calendar and habits
/// (actions run through `EvryActionDesk`'s tools) — and nothing else.
@MainActor
final class EvryConversation {
    enum Reply {
        case answer(String)
        /// The message isn't about the app or the person's things.
        case offTopic
    }

    /// Evry's polite refusal for anything outside the app.
    static let offTopicLine = "I’m sorry, I can only help with questions about the app :("

    /// The last few turns, so follow-up questions make sense.
    private var history: [(you: String, evry: String)] = []

    func reply(to message: String, data: EvryAppData, desk: EvryActionDesk) async -> Reply {
        let result: Reply
        if EvryAssistant.isAvailable, let modelReply = await modelReply(to: message, data: data, desk: desk) {
            result = modelReply
        } else if let done = Self.fallbackAction(message, desk: desk) {
            result = .answer(done)
        } else {
            result = Self.fallbackReply(to: message, data: data)
        }
        if case .answer(let text) = result {
            history.append((message, text))
            if history.count > 3 { history.removeFirst() }
        }
        return result
    }

    private func modelReply(to message: String, data: EvryAppData, desk: EvryActionDesk) async -> Reply? {
        // A fresh session per turn: the data changes between questions, and the
        // on-device model's context is small. Recent turns ride along as text.
        let session = LanguageModelSession(tools: desk.tools, instructions: """
            You are Evry, the friendly assistant inside the Evry app, which brings \
            together tasks, habits, notes and a calendar. You ONLY help with the \
            person's own tasks, notes, calendar, habits and focus, and with how to \
            use Evry. Answer only from the data you're given — never invent tasks, \
            notes or events. Speak in the first person, warm, calm and plain. Never \
            describe yourself as an AI, artificial intelligence, a bot or a chatbot. \
            No emoji. No productivity pressure.
            You can act in the app with your tools. When the person asks you to add, \
            remind, change, complete, move, rename, delete, check in or start \
            something, call the matching tool, then reply with only a short \
            acknowledgment — don't list what you created or changed; the app shows \
            it. A reminder is a task with a time. Never say you did something without \
            calling a tool. Deleting needs the person's tap: say it's waiting for \
            them to confirm below. To summarise or answer about a note, read it first.
            """)
        let recent = history.map { "Person: \($0.you)\nEvry: \($0.evry)" }.joined(separator: "\n")
        let prompt = """
            The person's current data:
            \(data.promptText)

            \(recent.isEmpty ? "" : "Recent conversation:\n\(recent)\n")
            Their message: \(message)
            """
        do {
            let response = try await session.respond(to: prompt, generating: ChatAnswer.self)
            let answer = response.content
            guard answer.aboutApp else { return .offTopic }
            let text = Self.formatBullets(answer.reply.trimmingCharacters(in: .whitespacesAndNewlines))
            return text.isEmpty ? nil : .answer(text)
        } catch {
            return nil
        }
    }

    /// Every bullet on its own line: "Here's today: • A • B" →
    /// "Here's today:\n• A\n• B". Dash/star bullets become "•" too.
    static func formatBullets(_ text: String) -> String {
        var out = text
        // "- item" / "* item" at a line start → "• item".
        out = out.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
        // A bullet mid-line starts a new line.
        out = out.replacingOccurrences(of: #"[ \t]*•[ \t]*"#, with: "\n• ", options: .regularExpression)
        // Tidy: no blank lines between bullets, none at the very start.
        out = out.replacingOccurrences(of: #"\n\s*\n• "#, with: "\n• ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Without the model

    /// "Remind me to…", "add…": a task straight from the message, for when the
    /// model can't run. Returns Evry's line, or nil if it isn't a request.
    static func fallbackAction(_ message: String, desk: EvryActionDesk) -> String? {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let leads = ["remind me to ", "remind me ", "add a task to ", "add a task ", "add task ",
                     "new task ", "create a task to ", "create a task ", "add ", "i need to ", "todo ", "to do "]
        guard let lead = leads.first(where: { lower.hasPrefix($0) }) else { return nil }
        let rest = String(message.dropFirst(lead.count))
        // The date words go to the time; the rest is the title.
        var title = rest
        for word in [" today", " tomorrow", " tonight", " this evening"] {
            title = title.replacingOccurrences(of: word, with: "", options: .caseInsensitive)
        }
        title = parseTaskInput(title).title
        while title.lowercased().hasSuffix(" at") || title.lowercased().hasSuffix(" on") {
            title = String(title.dropLast(3))
        }
        guard !title.isEmpty else { return nil }
        _ = desk.createTask(title: title.prefix(1).uppercased() + title.dropFirst(),
                            when: rest, highPriority: false, notes: "")
        return "Done — it’s on your list."
    }

    /// Keyword answers, for when the on-device model can't run: plain summaries
    /// of whatever the message mentions, and a polite refusal for the rest.
    static func fallbackReply(to message: String, data: EvryAppData) -> Reply {
        let m = message.lowercased()
        func mentions(_ words: [String]) -> Bool { words.contains { m.contains($0) } }
        func list(_ items: [String]) -> String { items.prefix(5).map { "• \($0)" }.joined(separator: "\n") }

        if mentions(["calendar", "event", "meeting", "schedule", "appointment", "plans"]) {
            guard !data.events.isEmpty else { return .answer("Your calendar looks clear for the next two weeks.") }
            let items = data.events.map { e in
                "\(e.allDay ? e.start.formatted(.dateTime.weekday(.abbreviated).day()) : e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) \(e.title)"
            }
            return .answer("Here’s what’s coming up on your calendar:\n\(list(items))")
        }
        if mentions(["note"]) {
            guard !data.notes.isEmpty else { return .answer("You don’t have any notes yet.") }
            let items = data.notes.map { $0.title.isEmpty ? "Untitled" : $0.title }
            return .answer("You have \(data.notes.count) note\(data.notes.count == 1 ? "" : "s"). The latest:\n\(list(items))")
        }
        if mentions(["habit", "routine", "streak"]) {
            guard !data.habitsToday.isEmpty else { return .answer("No habits are due today.") }
            let done = data.habitsToday.filter(\.doneToday).count
            return .answer("You’ve done \(done) of \(data.habitsToday.count) habits today:\n\(list(data.habitsToday.map { "\($0.name)\($0.doneToday ? " (done)" : "")" }))")
        }
        if mentions(["task", "to-do", "todo", "to do", "due", "overdue", "inbox", "today", "tomorrow", "week", "finish", "done", "summar"]) {
            guard !data.openTasks.isEmpty else { return .answer("You’re all caught up — there are no open tasks.") }
            let items = data.openTasks.map { t in
                t.due.map { "\(t.title) (\($0.formatted(.dateTime.weekday(.abbreviated).day())))" } ?? t.title
            }
            return .answer("You have \(data.openTasks.count) open task\(data.openTasks.count == 1 ? "" : "s"):\n\(list(items))")
        }
        let words = Set(m.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if !words.isDisjoint(with: ["hi", "hello", "hey", "thanks", "thank", "evry", "help"]) || mentions(["what can you", "how do i"]) {
            return .answer("I can add and change your tasks, events and notes, or answer questions about them and summarise them for you.")
        }
        return .offTopic
    }
}
