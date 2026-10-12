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

/// A running conversation with Evry, for free-typed messages in the chat.
/// Keeps one session so Evry remembers what was said earlier in the chat.
@MainActor
final class EvryConversation {
    private var session: LanguageModelSession?

    /// Evry's short reply, or nil when the model isn't available (the chat then
    /// offers its three features instead).
    func reply(to message: String) async -> String? {
        guard EvryAssistant.isAvailable else { return nil }
        if session == nil {
            session = LanguageModelSession(instructions: """
                You are Evry, the friendly assistant inside the Evry app, which brings \
                together tasks, habits, notes and a calendar. Speak in the first person, \
                warm, calm and plain. Reply in ONE short sentence; use two only when \
                truly necessary. \
                Never describe yourself as an AI, artificial intelligence, a bot or a \
                chatbot — you're simply Evry, the person's assistant. No emoji. No \
                productivity pressure. You can help in three ways, and may suggest the \
                one that fits: Distill (turn a jumble of thoughts into tasks), Pomo \
                (start a focus session), and Write (turn a voice message into a tidy \
                note). Today's date is \(Date().formatted(.dateTime.weekday().day().month().year())).
                """)
        }
        do {
            let response = try await session?.respond(to: message)
            let text = response?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        } catch {
            // A failed turn can leave the session unusable — start fresh next time.
            session = nil
            return nil
        }
    }
}
