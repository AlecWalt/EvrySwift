//
//  CoreFacts.swift
//  Evry
//
//  Structured facts from notes — a recurring appointment, a named project, a
//  person, a stated preference — kept with a pointer to the source note and
//  never the note's text. Extraction is pluggable: `RuleFactExtractor` reads
//  plain patterns; `ModelFactExtractor` asks the on-device model and falls back
//  to the rules. Either only runs when note-extraction consent is on.
//

import Foundation
import FoundationModels

/// One fact as an extractor found it, before merging into the Core.
struct ExtractedFact: Equatable {
    var kind: CoreFact.Kind
    /// Short and structured — at most a few words, never a copied sentence.
    var summary: String
    var confidence: Double
}

protocol NoteFactExtracting {
    func extract(from text: String) async -> [ExtractedFact]
}

/// Trims a summary to a few words so nothing sentence-length is ever stored.
func coreFactSummary(_ raw: String, maxWords: Int = 6) -> String {
    let words = raw.split(whereSeparator: { $0.isWhitespace }).prefix(maxWords)
    let joined = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    return String(joined.prefix(60))
}

// MARK: - Rules

struct RuleFactExtractor: NoteFactExtracting {
    func extract(from text: String) async -> [ExtractedFact] { Self.facts(in: text) }

    private static let weekday = "(monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?"
    private static let things = "dentist|doctor|therapy|therapist|physio|checkup|check-up|haircut|appointment|meeting|class|lesson|practice|standup|stand-up|rehearsal|training"
    private static let roles = "wife|husband|partner|girlfriend|boyfriend|fianc[eé]e?|mom|mum|mother|dad|father|boss|manager|sister|brother|son|daughter|roommate|coworker|co-worker|friend|therapist|kids?"
    /// Capitalised words that start sentences or name days — never a project or person.
    private static let notNames: Set<String> = [
        "the", "a", "an", "it", "this", "that", "my", "our", "i", "we", "and", "but", "on", "at", "for", "to",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "is", "was", "who", "has", "will",
    ]

    static func facts(in text: String) -> [ExtractedFact] {
        var out: [ExtractedFact] = []
        func add(_ kind: CoreFact.Kind, _ summary: String, _ confidence: Double) {
            let s = coreFactSummary(summary)
            guard s.count >= 3, !out.contains(where: { $0.kind == kind && $0.summary.lowercased() == s.lowercased() })
            else { return }
            out.append(ExtractedFact(kind: kind, summary: s, confidence: confidence))
        }

        // Recurring appointments: "dentist every Tuesday", "piano lesson on Mondays".
        for m in matches("(?i)\\b(\(things))\\b[^.\\n]{0,30}?\\b(?:every|on)\\s+\(weekday)\\b", in: text) {
            add(.appointment, "\(m[1].lowercased()) · \(m[2].capitalized)s", 0.6)
        }
        // "weekly team meeting", "monthly checkup".
        for m in matches("(?i)\\b(weekly|biweekly|monthly|daily)\\s+((?:[a-z]+\\s){0,2}?(?:\(things)))\\b", in: text) {
            add(.appointment, "\(m[2].lowercased()) · \(m[1].lowercased())", 0.55)
        }
        // Named projects: "Project Atlas", "working on Atlas Redesign".
        for pattern in ["\\b[Pp]roject[:\\s]+\"?([A-Z][\\w-]*(?:\\s+[A-Z][\\w-]*){0,3})",
                        "\\b(?:[Ww]orking on|[Ll]aunching|[Bb]uilding)\\s+(?:the\\s+|my\\s+|our\\s+)?([A-Z][\\w-]*(?:\\s+[A-Z][\\w-]*){0,3})"] {
            for m in matches(pattern, in: text) {
                let words = m[1].split(separator: " ").filter { !notNames.contains($0.lowercased()) }
                guard !words.isEmpty else { continue }
                add(.project, "project: \(words.joined(separator: " "))", 0.5)
            }
        }
        // People by role, with a first name when one follows: "my boss Dana".
        for m in matches("(?i)\\bmy\\s+(\(roles))\\b(?:,?\\s+(\\w+))?", in: text) {
            let role = m[1].lowercased()
            let name = m.count > 2 ? m[2] : ""
            if let first = name.first, first.isUppercase, name.count >= 2, !notNames.contains(name.lowercased()) {
                add(.person, "\(role): \(name)", 0.5)
            } else {
                add(.person, role, 0.35)
            }
        }
        // Stated preferences: "I prefer mornings for deep work", "I hate phone calls".
        let pref = "(?i)\\bI\\s+(?:really\\s+|much\\s+)?(prefer|like|love|enjoy|hate|dislike|don't like|do not like|can't stand)\\s+(?:to\\s+)?([a-z][a-z' -]{2,40}?)(?=[.,;!?\\n]|$|\\sbecause|\\sbut|\\sand)"
        for m in matches(pref, in: text) {
            let verb = m[1].lowercased()
            let lead = ["prefer"].contains(verb) ? "prefers"
                : ["like", "love", "enjoy"].contains(verb) ? "likes" : "avoids"
            add(.preference, "\(lead) \(m[2].lowercased())", 0.45)
        }
        return out
    }

    /// Every match of `pattern`, as [whole, group1, group2…] ("" for a group that didn't take part).
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { m in
            (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

// MARK: - On-device model

@Generable(description: "Short structured facts about the writer's life found in their note")
private struct NoteFactList {
    @Guide(description: "Facts worth remembering to help plan their days. Empty if there are none.", .maximumCount(6))
    var facts: [NoteFactItem]
}

@Generable(description: "One structured fact")
private struct NoteFactItem {
    @Guide(description: "One of: appointment (a recurring or dated commitment), project (a named piece of work), person (someone by role and first name), preference (how they like to do things)")
    var kind: String

    @Guide(description: "The fact in at most 6 words, as a label rather than a sentence, e.g. 'dentist · Tuesdays', 'project: Atlas', 'boss: Dana', 'prefers mornings for deep work'. Never copy a sentence from the note.")
    var summary: String
}

/// Asks the on-device model (FoundationModels — nothing leaves the device),
/// falling back to the rules when the model isn't available or fails.
struct ModelFactExtractor: NoteFactExtracting {
    var fallback = RuleFactExtractor()

    func extract(from text: String) async -> [ExtractedFact] {
        guard EvryAssistant.isAvailable, text.split(separator: " ").count >= 6 else {
            return await fallback.extract(from: text)
        }
        let session = LanguageModelSession(instructions: """
            Read a person's note and list only clear, lasting facts about their own life: \
            recurring appointments, named projects, people they mention by role, and \
            preferences they state. Never invent anything. Never copy sentences.
            """)
        guard let list = try? await session.respond(to: "Note:\n\(text.prefix(2000))",
                                                    generating: NoteFactList.self).content
        else { return await fallback.extract(from: text) }
        return list.facts.compactMap { item in
            guard let kind = CoreFact.Kind(rawValue: item.kind.lowercased()), kind != .other else { return nil }
            let summary = coreFactSummary(item.summary)
            return summary.count >= 3 ? ExtractedFact(kind: kind, summary: summary, confidence: 0.5) : nil
        }
    }
}

// MARK: - Merging

extension CoreLearner {
    /// Folds a note's extracted facts into the profile. A fact seen again (in
    /// another note, or the same note on a later day) gains confidence; a fact
    /// this note used to support but no longer does loses it.
    static func mergeFacts(_ found: [ExtractedFact], fromNote noteId: String, into p: inout CoreProfile,
                           at now: Date, config: CoreConfig) {
        var supported = Set<String>()
        for f in found {
            if let i = p.facts.firstIndex(where: { $0.kind == f.kind && $0.summary.lowercased() == f.summary.lowercased() }) {
                var fact = p.facts[i]
                let current = confidence(evidence: fact.evidence, lastSeen: fact.lastSeen, now: now,
                                         halfLifeDays: config.factHalfLifeDays)
                let corroborated = fact.sourceNoteId != noteId || now.timeIntervalSince(fact.lastSeen) > 86_400
                fact.evidence = corroborated ? current + (1 - current) * 0.3 : max(current, f.confidence)
                fact.lastSeen = now
                fact.sourceNoteId = noteId
                fact.confidence = fact.userConfirmed ? 1 : fact.evidence
                p.facts[i] = fact
                supported.insert(fact.id)
            } else {
                let fact = CoreFact(id: UUID().uuidString, kind: f.kind, summary: f.summary, sourceNoteId: noteId,
                                    firstSeen: now, lastSeen: now, confidence: f.confidence, evidence: f.confidence)
                p.facts.append(fact)
                supported.insert(fact.id)
            }
        }
        for i in p.facts.indices
        where p.facts[i].sourceNoteId == noteId && !supported.contains(p.facts[i].id) && !p.facts[i].userConfirmed {
            p.facts[i].evidence *= 0.5
            p.facts[i].confidence = p.facts[i].evidence
        }
        p.facts.removeAll { !$0.userConfirmed && $0.confidence < config.pruneThreshold }
        if p.facts.count > config.maxFacts {
            p.facts.sort { ($0.userConfirmed ? 2 : $0.confidence) > ($1.userConfirmed ? 2 : $1.confidence) }
            p.facts.removeLast(p.facts.count - config.maxFacts)
        }
        p.meta.updatedAt = now
    }
}
