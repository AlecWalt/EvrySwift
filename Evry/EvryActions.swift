//
//  EvryActions.swift
//  Evry
//
//  What Evry can *do* from the chat. The on-device model (FoundationModels)
//  is given a small set of tools — create or change tasks, events and notes,
//  read a note, check in a habit, start a focus session — and calls them to
//  carry out what the person asks ("remind me to work out today at 8p").
//
//  Every tool runs through `EvryActionDesk`, on the main actor, against the
//  same models and helpers the rest of the app uses (TaskActions, the
//  calendar service, saved places, notifications). The desk keeps a log of
//  what it did so the chat can show it. Deleting is never done straight
//  away: it's queued for the person to confirm with a tap.
//

import Foundation
import EventKit
import FoundationModels
import SwiftData
import UIKit

// MARK: - What happened

/// One thing Evry did, shown as an animated popup after its reply: the
/// thing's name and what happened to it.
struct EvryDone: Identifiable, Equatable {
    enum Kind: Equatable { case task, event, note, habit, focus }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String

    /// One line, for the model's tool result.
    var text: String { detail.isEmpty ? title : "\(title) (\(detail))" }

    var icon: String {
        switch kind {
        case .task: "checkmark.square"
        case .event: "calendar"
        case .note: "note.text"
        case .habit: "arrow.triangle.2.circlepath"
        case .focus: "timer"
        }
    }
}

/// A deletion Evry was asked for, waiting on the person's tap.
struct EvryPendingDelete: Identifiable {
    enum Target {
        case task(TaskItem)
        case event(EKEvent)
        case note(Note)
    }
    let id = UUID()
    let target: Target
    let title: String

    var kindName: String {
        switch target {
        case .task: "task"
        case .event: "event"
        case .note: "note"
        }
    }
}

// MARK: - The desk

/// Carries out Evry's tool calls against the app's data.
@MainActor
final class EvryActionDesk {
    private let context: ModelContext
    private let calendar: CalendarService

    /// What was done this turn, in order.
    private(set) var log: [EvryDone] = []
    /// Deletions waiting on the person.
    private(set) var pendingDeletes: [EvryPendingDelete] = []
    /// Minutes of focus the person asked to start, if any.
    private(set) var focusMinutes: Int?

    init(context: ModelContext, calendar: CalendarService) {
        self.context = context
        self.calendar = calendar
    }

    /// Clears the turn's log before a new message.
    func beginTurn() {
        log = []
        pendingDeletes = []
        focusMinutes = nil
    }

    private func record(_ kind: EvryDone.Kind, _ title: String, _ detail: String = "") {
        log.append(EvryDone(kind: kind, title: title, detail: detail))
    }

    // MARK: Tasks

    func createTask(title: String, when: String, highPriority: Bool, notes: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "No task was created: the title was empty." }
        // Keywords in the title itself ("gym 8pm") are honoured too.
        let parsed = parseTaskInput(clean)
        let due = EvryWhen.parse(when) ?? parsed.date
        let task = TaskItem(title: parsed.title.isEmpty ? clean : parsed.title,
                            dueDate: due,
                            tags: parsed.tags,
                            priority: highPriority ? .high : parsed.priority,
                            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(task)
        // A timed task gets its reminder at that time.
        NotificationService.schedule(task)
        try? context.save()
        let whenText = EvryWhen.describe(task.dueDate)
        let reminder = EvryWhen.hasTime(task.dueDate) ? ", reminder set" : ""
        let place = task.location.isEmpty ? "" : ", at \(task.location)"
        record(.task, task.title, [whenText.capitalizedFirst,
                                   EvryWhen.hasTime(task.dueDate) ? "Reminder set" : nil]
            .compactMap { $0 }.joined(separator: " · "))
        return "Created the task \"\(task.title)\" due \(whenText)\(reminder)\(place)."
    }

    /// `action`: complete, reopen, reschedule, rename, delete, high priority, normal priority.
    func changeTask(named name: String, action: String, value: String) -> String {
        guard let task = find(name, in: openAndRecentTasks(), title: \.title) else {
            return "There's no task matching \"\(name)\"."
        }
        switch action.lowercased() {
        case let a where a.contains("complete") || a.contains("done") || a.contains("finish"):
            guard !task.completed else { return "\"\(task.title)\" is already done." }
            TaskActions.toggle(task, context: context)
            record(.task, task.title, "Completed")
        case let a where a.contains("reopen") || a.contains("undo"):
            guard task.completed else { return "\"\(task.title)\" isn't done yet." }
            TaskActions.toggle(task, context: context)
            record(.task, task.title, "Reopened")
        case let a where a.contains("resched") || a.contains("move") || a.contains("date") || a.contains("time"):
            guard let date = EvryWhen.parse(value) else { return "Couldn't understand the new time \"\(value)\"." }
            TaskActions.reschedule(task, to: date)
            record(.task, task.title, "Moved to \(EvryWhen.describe(date))")
        case let a where a.contains("rename") || a.contains("title"):
            let newTitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newTitle.isEmpty else { return "No new name was given." }
            let old = task.title
            task.title = newTitle
            record(.task, newTitle, "Renamed from “\(old)”")
        case let a where a.contains("delete") || a.contains("remove"):
            pendingDeletes.append(EvryPendingDelete(target: .task(task), title: task.title))
            return "Asked the person to confirm deleting \"\(task.title)\". It is not deleted yet."
        case let a where a.contains("normal") || a.contains("remove priority") || a.contains("low"):
            task.priority = .normal
            record(.task, task.title, "Normal priority")
        case let a where a.contains("high") || a.contains("priority") || a.contains("important"):
            task.priority = .high
            NotificationService.schedule(task)
            record(.task, task.title, "High priority")
        case let a where a.contains("note"):
            task.notes = value
            record(.task, task.title, "Notes updated")
        default:
            return "Unknown task action \"\(action)\"."
        }
        try? context.save()
        return "Done: \(log.last?.text ?? action)."
    }

    // MARK: Events

    func createEvent(title: String, when: String, minutes: Int, place: String) -> String {
        guard calendar.isAuthorized else { return "The calendar isn't connected, so no event was made." }
        guard let start = EvryWhen.parse(when) else { return "Couldn't understand the time \"\(when)\"." }
        let store = calendar.eventStore
        let event = EKEvent(eventStore: store)
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New event" : title
        let allDay = !EvryWhen.hasTime(start)
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = allDay ? start : start.addingTimeInterval(TimeInterval(max(5, minutes == 0 ? 60 : minutes) * 60))
        // A saved place the title mentions ("gym") fills in the location.
        let spot = place.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = spot.isEmpty ? FrequentPlaces.match(for: event.title)?.locationString : spot
        event.calendar = store.defaultCalendarForNewEvents
        do { try store.save(event, span: .thisEvent) } catch { return "Saving the event failed." }
        let whenText = EvryWhen.describe(start)
        record(.event, event.title ?? "Event", whenText.capitalizedFirst)
        return "Created the event \"\(event.title ?? "")\" on \(whenText)."
    }

    /// `action`: move, rename, set place, delete.
    func changeEvent(named name: String, action: String, value: String) -> String {
        guard calendar.isAuthorized else { return "The calendar isn't connected." }
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let to = Calendar.current.date(byAdding: .day, value: 60, to: now) ?? now
        let events = calendar.events(from: from, to: to).compactMap { $0.ekEvent ?? calendar.ekEvent(withIdentifier: $0.id) }
        // The nearest upcoming match first.
        let ordered = events.sorted { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
        guard let event = find(name, in: ordered, title: { $0.title ?? "" }) else {
            return "There's no event matching \"\(name)\"."
        }
        guard event.calendar?.allowsContentModifications ?? false else { return "That event's calendar is read-only." }
        let title = event.title ?? "Event"
        switch action.lowercased() {
        case let a where a.contains("delete") || a.contains("cancel") || a.contains("remove"):
            pendingDeletes.append(EvryPendingDelete(target: .event(event), title: title))
            return "Asked the person to confirm deleting \"\(title)\". It is not deleted yet."
        case let a where a.contains("move") || a.contains("resched") || a.contains("time"):
            guard let start = EvryWhen.parse(value) else { return "Couldn't understand the new time \"\(value)\"." }
            let length = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = start
            event.endDate = start.addingTimeInterval(length)
            record(.event, title, "Moved to \(EvryWhen.describe(start))")
        case let a where a.contains("rename") || a.contains("title"):
            event.title = value
            record(.event, value, "Renamed from “\(title)”")
        case let a where a.contains("place") || a.contains("location"):
            let spot = value.trimmingCharacters(in: .whitespacesAndNewlines)
            event.location = FrequentPlaces.match(for: spot)?.locationString ?? spot
            record(.event, title, "At \(event.location ?? spot)")
        default:
            return "Unknown event action \"\(action)\"."
        }
        do { try calendar.eventStore.save(event, span: .thisEvent) } catch { return "Saving the event failed." }
        return "Done: \(log.last?.text ?? action)."
    }

    // MARK: Notes

    func createNote(title: String, content: String) -> String {
        let body = NSAttributedString(string: content, attributes: [.font: UIFont.nunito(size: 16)])
        let note = Note(title: title.isEmpty ? "New note" : title, body: body)
        context.insert(note)
        try? context.save()
        record(.note, note.title, "Note saved")
        return "Created the note \"\(note.title)\"."
    }

    func readNote(named name: String) -> String {
        let notes = ((try? context.fetch(FetchDescriptor<Note>())) ?? []).filter { !$0.isTrashed }
        guard let note = find(name, in: notes, title: \.title) else { return "There's no note matching \"\(name)\"." }
        let text = NoteBodyCodec.plainText(note.body).replacingOccurrences(of: "•\t", with: "- ")
        return "Note \"\(note.title)\":\n\(text.prefix(1500))"
    }

    // MARK: Habits & focus

    func checkInHabit(named name: String) -> String {
        let habits = ((try? context.fetch(FetchDescriptor<Habit>())) ?? []).filter { !$0.isFormed }
        guard let habit = find(name, in: habits, title: \.name) else { return "There's no habit matching \"\(name)\"." }
        guard !HabitStats(habit: habit).todayDone else { return "\"\(habit.name)\" is already done today." }
        HabitActions.checkIn(habit, context: context)
        record(.habit, habit.name, "Done for today")
        return "Checked in \"\(habit.name)\"."
    }

    func startFocus(minutes: Int) -> String {
        focusMinutes = max(5, minutes == 0 ? 25 : minutes)
        record(.focus, "Focus session", "\(focusMinutes ?? 25) minutes")
        return "A \(focusMinutes ?? 25)-minute focus session will start."
    }

    // MARK: Confirmed deletes

    func confirm(_ pending: EvryPendingDelete) {
        switch pending.target {
        case .task(let task):
            TaskActions.delete(task)
        case .event(let event):
            try? calendar.eventStore.remove(event, span: .thisEvent, commit: true)
        case .note(let note):
            note.deletedAt = Date()
        }
        try? context.save()
    }

    // MARK: Finding things by name

    private func openAndRecentTasks() -> [TaskItem] {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return ((try? context.fetch(FetchDescriptor<TaskItem>())) ?? [])
            .filter { !$0.isTrashed && (!$0.completed || ($0.completedAt ?? .distantPast) >= weekAgo) }
            // Open ones first, then the soonest due.
            .sorted { a, b in
                if a.completed != b.completed { return !a.completed }
                return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
            }
    }

    /// The item whose name best matches: exact, then containing, then the
    /// most shared words.
    private func find<T>(_ name: String, in items: [T], title: (T) -> String) -> T? {
        let q = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let exact = items.first(where: { title($0).lowercased() == q }) { return exact }
        if let contains = items.first(where: { title($0).lowercased().contains(q) || q.contains(title($0).lowercased()) && !title($0).isEmpty }) {
            return contains
        }
        let qWords = Set(PlaceLabels.words(q).filter { $0.count > 2 })
        guard !qWords.isEmpty else { return nil }
        let scored = items.map { ($0, qWords.intersection(PlaceLabels.words(title($0))).count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Dates from words

/// Turns "today at 8p", "tomorrow", "friday 3pm" or "Oct 20 at 9:30" into a
/// date — midnight when no time is given (the app's "no time" convention).
enum EvryWhen {
    static func parse(_ raw: String) -> Date? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != "none", s != "no date" else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        var base: Date?
        if s.contains("tomorrow") { base = addDays(today, 1) }
        else if s.contains("today") || s.contains("tonight") || s.contains("this evening") { base = today }

        // The app's own parser handles "8p", "3:30 pm", "fri", "next week", "oct 20".
        let parsed = parseTaskInput(s)
        var result = parsed.date
        if let base {
            if let d = result, hasTime(d) {
                let t = cal.dateComponents([.hour, .minute], from: d)
                result = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: base)
            } else {
                result = base
            }
        }
        // "In 20 minutes", "in 2 hours", "in 3 days".
        if result == nil,
           let m = s.range(of: #"\bin\s+(\d+)\s*(minute|min|hour|hr|day|week)s?\b"#, options: .regularExpression) {
            let parts = s[m].split(separator: " ").filter { !$0.isEmpty }
            let digits = s[m].filter(\.isNumber)
            if let n = Int(digits), let unit = parts.last {
                let u = unit.lowercased()
                let seconds: Double = u.hasPrefix("min") ? 60 : u.hasPrefix("h") ? 3600 : u.hasPrefix("d") ? 86_400 : 604_800
                let target = Date().addingTimeInterval(Double(n) * seconds)
                // Whole days and weeks land on the day; minutes and hours keep the time.
                result = seconds >= 86_400 ? cal.startOfDay(for: target) : target
            }
        }
        // Anything else ("next Tuesday at noon"): the system's detector.
        if result == nil,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let date = match.date {
            result = date
        }
        // "Tonight" with no time: the evening.
        if let r = result, !hasTime(r), s.contains("tonight") || s.contains("this evening") {
            result = cal.date(bySettingHour: 20, minute: 0, second: 0, of: r)
        }
        return result
    }

    static func hasTime(_ date: Date?) -> Bool {
        guard let date else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }

    /// "today at 8:00 PM", "Fri, Oct 17".
    static func describe(_ date: Date?) -> String {
        guard let date else { return "today" }
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(date) { day = "today" }
        else if cal.isDateInTomorrow(date) { day = "tomorrow" }
        else { day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return hasTime(date) ? "\(day) at \(date.formatted(date: .omitted, time: .shortened))" : day
    }
}

// MARK: - Tools

nonisolated struct CreateTaskTool: Tool {
    let desk: EvryActionDesk
    let name = "createTask"
    let description = "Add a task or reminder. Use for 'remind me to…', 'add…', 'I need to…'."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Short action-first task title, without the date or time words")
        var title: String
        @Guide(description: "When it's due, in the person's words, e.g. 'today at 8pm', 'tomorrow', 'friday 3pm'. Empty if not said.")
        var when: String
        @Guide(description: "true only if they said it's important or urgent")
        var highPriority: Bool
        @Guide(description: "Extra details they gave, or empty")
        var notes: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.createTask(title: arguments.title, when: arguments.when,
                              highPriority: arguments.highPriority, notes: arguments.notes)
    }
}

nonisolated struct ChangeTaskTool: Tool {
    let desk: EvryActionDesk
    let name = "changeTask"
    let description = "Change an existing task: complete, reopen, reschedule, rename, delete, high priority, normal priority, or notes."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The task's title as listed in the data")
        var task: String
        @Guide(description: "One of: complete, reopen, reschedule, rename, delete, high priority, normal priority, notes")
        var action: String
        @Guide(description: "The new time for reschedule ('tomorrow 9am'), the new title for rename, the text for notes; otherwise empty")
        var value: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.changeTask(named: arguments.task, action: arguments.action, value: arguments.value)
    }
}

nonisolated struct CreateEventTool: Tool {
    let desk: EvryActionDesk
    let name = "createEvent"
    let description = "Add a calendar event (a meeting, appointment or plan at a set time)."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The event's title")
        var title: String
        @Guide(description: "When it starts, in the person's words, e.g. 'tomorrow at 2pm'")
        var when: String
        @Guide(description: "How long it lasts in minutes; 0 if not said")
        var minutes: Int
        @Guide(description: "Where it is, or empty")
        var place: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.createEvent(title: arguments.title, when: arguments.when,
                               minutes: arguments.minutes, place: arguments.place)
    }
}

nonisolated struct ChangeEventTool: Tool {
    let desk: EvryActionDesk
    let name = "changeEvent"
    let description = "Change an existing calendar event: move, rename, place, or delete."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The event's title as listed in the data")
        var event: String
        @Guide(description: "One of: move, rename, place, delete")
        var action: String
        @Guide(description: "The new start for move ('friday 10am'), new title for rename, new place for place; otherwise empty")
        var value: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.changeEvent(named: arguments.event, action: arguments.action, value: arguments.value)
    }
}

nonisolated struct CreateNoteTool: Tool {
    let desk: EvryActionDesk
    let name = "createNote"
    let description = "Save a new note with the text the person gives."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "A short sentence-case title")
        var title: String
        @Guide(description: "The note's text")
        var content: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.createNote(title: arguments.title, content: arguments.content)
    }
}

nonisolated struct ReadNoteTool: Tool {
    let desk: EvryActionDesk
    let name = "readNote"
    let description = "Read a note's full text, e.g. to summarise it or answer about it."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The note's title as listed in the data")
        var note: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.readNote(named: arguments.note)
    }
}

nonisolated struct CheckInHabitTool: Tool {
    let desk: EvryActionDesk
    let name = "checkInHabit"
    let description = "Mark a habit as done for today."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "The habit's name as listed in the data")
        var habit: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.checkInHabit(named: arguments.habit)
    }
}

nonisolated struct StartFocusTool: Tool {
    let desk: EvryActionDesk
    let name = "startFocus"
    let description = "Start a focus (pomodoro) session."

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Minutes of focus; 0 if not said")
        var minutes: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await desk.startFocus(minutes: arguments.minutes)
    }
}

extension EvryActionDesk {
    /// Every tool, sharing this desk.
    var tools: [any Tool] {
        [CreateTaskTool(desk: self), ChangeTaskTool(desk: self),
         CreateEventTool(desk: self), ChangeEventTool(desk: self),
         CreateNoteTool(desk: self), ReadNoteTool(desk: self),
         CheckInHabitTool(desk: self), StartFocusTool(desk: self)]
    }
}
