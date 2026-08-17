//
//  Note.swift
//  Evry
//
//  Notes module — data layer. A rich-text `Note` and its `Folder`, mirroring the
//  TaskItem / Project conventions (stable `uid`, created/modified timestamps,
//  soft delete, pinned, sortOrder) so the module is sync/backup-ready even
//  though sync isn't implemented yet.
//
//  The rich body is stored as archived `Data` behind `NoteBodyCodec`, kept
//  deliberately isolated so the rich-text backend (native AttributedString for
//  now) can be swapped later without touching the model or the views.
//

import Foundation
import SwiftData
import SwiftUI
import UIKit

// MARK: - Rich body storage (swappable)

/// Encodes/decodes a note's rich body to/from the `Data` persisted by SwiftData,
/// plus a plain-text projection for search and list previews.
///
/// This is the single seam between the storage format and everything else — a
/// future migration only edits this type. The body is archived as RTFD, which
/// preserves fonts, underline, and strikethrough from the UIKit editor.
enum NoteBodyCodec {
    static func encode(_ text: NSAttributedString) -> Data {
        guard text.length > 0 else { return Data() }
        let range = NSRange(location: 0, length: text.length)
        return (try? text.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )) ?? Data()
    }

    static func decode(_ data: Data) -> NSAttributedString {
        guard !data.isEmpty else { return NSAttributedString() }
        return (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )) ?? NSAttributedString()
    }

    /// Plain-text projection — used for fast, index-friendly search and previews.
    static func plainText(_ text: NSAttributedString) -> String {
        text.string
    }
}

// MARK: - Folder

/// Groups notes, mirroring `Project` for tasks (nullify delete rule so deleting
/// a folder detaches its notes rather than cascading).
@Model
final class Folder {
    var uid: UUID = UUID()
    var name: String = ""
    var icon: String = "folder"
    /// Optional folder tint (hex). `nil` falls back to the app accent.
    var colorHex: Int?
    var createdAt: Date = Date()
    var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]? = []

    init(name: String, icon: String = "folder", colorHex: Int? = nil) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
    }

    var color: Color? { colorHex.map { Color(hex: UInt32(truncatingIfNeeded: $0)) } }
}

// MARK: - Sticker

/// An emoji sticker placed on a note. Position is normalized (0…1) to the note's
/// canvas so it survives rotation/size changes; scale and rotation are free.
struct NoteSticker: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var emoji: String
    var x: Double            // normalized center X (0…1)
    var y: Double            // normalized center Y (0…1)
    var scale: Double = 1
    var rotation: Double = 0 // radians
}

// MARK: - Note

@Model
final class Note {
    var uid: UUID = UUID()
    var title: String = ""
    /// Archived rich body — access through `body`, never read directly.
    var bodyData: Data = Data()
    /// Denormalized plain text, kept in sync on every `body` write so search and
    /// list previews never have to decode the archive.
    var plainText: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var pinned: Bool = false
    /// Soft delete — the note goes to trash (retention handled like tasks) so an
    /// Undo can restore it.
    var deletedAt: Date?
    var tags: [String] = []
    var sortOrder: Int = 0
    var folder: Folder?
    /// JSON-encoded emoji stickers — access through `stickers`.
    var stickersData: Data = Data()

    init(title: String = "", body: NSAttributedString = NSAttributedString(), folder: Folder? = nil) {
        self.title = title
        self.bodyData = NoteBodyCodec.encode(body)
        self.plainText = NoteBodyCodec.plainText(body)
        self.folder = folder
    }

    /// Rich body accessor. Reads/writes the archived `bodyData` and keeps
    /// `plainText` in sync. Timestamp bumps are left to callers so programmatic
    /// edits don't count as user modifications.
    var body: NSAttributedString {
        get {
            let decoded = NoteBodyCodec.decode(bodyData)
            // Fallback for notes saved before the RTFD backend: the rich data
            // won't decode, but the plain text field still holds their content.
            if decoded.length == 0 && !plainText.isEmpty {
                return NSAttributedString(string: plainText)
            }
            return decoded
        }
        set {
            bodyData = NoteBodyCodec.encode(newValue)
            plainText = NoteBodyCodec.plainText(newValue)
        }
    }

    /// Emoji stickers placed on the note.
    var stickers: [NoteSticker] {
        get { (try? JSONDecoder().decode([NoteSticker].self, from: stickersData)) ?? [] }
        set { stickersData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var isTrashed: Bool { deletedAt != nil }

    /// True when there's nothing worth keeping — used to discard blank notes on
    /// editor dismiss.
    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && stickers.isEmpty
    }

    /// First non-empty body line, for the list-row preview.
    var preview: String {
        for line in plainText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
