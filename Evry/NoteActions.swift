//
//  NoteActions.swift
//  Evry
//
//  Shared note mutations — the Notes-module counterpart to TaskActions. Soft
//  delete with 30-day trash retention and a pin toggle.
//

import Foundation
import SwiftData

enum NoteActions {
    /// Soft delete — the note goes to trash so a delete toast's Undo can restore it.
    static func softDelete(_ note: Note) {
        note.deletedAt = Date()
    }

    /// Pinning isn't a content edit, so it doesn't bump `modifiedAt`.
    static func togglePin(_ note: Note) {
        note.pinned.toggle()
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
