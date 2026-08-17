//
//  NoteActions.swift
//  Evry
//
//  Shared note mutations — the Notes-module counterpart to TaskActions. Soft
//  delete with 30-day trash retention, restore, pin toggle, and a modified-at
//  "touch" for user edits.
//

import Foundation
import SwiftData

enum NoteActions {
    /// Soft delete — the note goes to trash so a delete toast's Undo can restore it.
    static func softDelete(_ note: Note) {
        note.deletedAt = Date()
    }

    static func restore(_ note: Note) {
        note.deletedAt = nil
    }

    /// Pinning isn't a content edit, so it doesn't bump `modifiedAt`.
    static func togglePin(_ note: Note) {
        note.pinned.toggle()
    }

    /// Marks a user-meaningful change (title/body edit).
    static func touch(_ note: Note) {
        note.modifiedAt = Date()
    }

    /// Creates a task from a note. The source (note title, or its first body
    /// line) runs through the same quick-add parser tasks use, so typed keywords
    /// like "tomorrow" / "next weekend" schedule it and #tags / !priority apply.
    /// The note's body is carried into the task's notes, and the note is kept.
    @discardableResult
    static func makeTask(from note: Note, context: ModelContext) -> TaskItem {
        let titleSource = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? note.preview
            : note.title
        let parsed = parseTaskInput(titleSource)
        let task = TaskItem(
            title: parsed.title.isEmpty ? titleSource : parsed.title,
            dueDate: parsed.date,
            tags: parsed.tags,
            priority: parsed.priority,
            notes: note.plainText
        )
        context.insert(task)
        NotificationService.schedule(task)
        return task
    }

    /// Purge trashed notes older than the 30-day retention window.
    static func purgeExpiredTrash(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.deletedAt != nil }
        )
        guard let trashed = try? context.fetch(descriptor) else { return }
        for note in trashed {
            guard let deletedAt = note.deletedAt, deletedAt < cutoff else { continue }
            context.delete(note)
        }
    }
}
