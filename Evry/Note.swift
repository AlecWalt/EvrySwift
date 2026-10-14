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
    /// Legacy folder tint (hex), from when colours were picked. Still decoded,
    /// but only ever rendered as a brand sky/navy shade.
    var colorHex: Int?
    /// Automatic colour: a position (0…1) between sky (0) and navy (1),
    /// assigned in sequence when the folder is created. Takes precedence over
    /// the legacy `colorHex`.
    var shade: Double?
    var createdAt: Date = Date()
    var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]? = []

    init(name: String, icon: String = "folder", colorHex: Int? = nil) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
    }

    /// Legacy accessor. Old picked hues (blue, pink, orange…) are never shown;
    /// any stored colour resolves to the brand's mid sky/navy shade.
    var color: Color? {
        colorHex.map { _ in Color.evrySky.mix(with: .evryNavy, by: 0.55) }
    }

    /// The folder's display colour in the current theme.
    func tint(_ palette: Palette) -> Color {
        if let shade { return palette.folderColor(shade: shade) }
        return palette.folderColor(shade: 0.5)
    }
}

// MARK: - Note background tints

/// The note background choices: steps of sky, from mist to a deeper sky/navy
/// mix, so notes differ by strength, never by a new hue. The stored value stays
/// an RGB hex in `Note.backgroundColorHex` so existing notes keep decoding.
enum NoteTint {
    /// Selectable tints, lightest to strongest (stored as these hex values).
    static let options: [UInt32] = [
        0xF1FBFF, // sky-mist
        0xE3F6FF, // sky-soft
        0xD0F0FF, // sky 60%
        0xB0E6FF, // sky
        0x99C9E1, // sky + 15% navy
    ]

    /// Hues offered before the brand palette (amber, coral, pink, violet, blue,
    /// teal, green, grey), each mapped onto a sky step so old notes still tint.
    private static let legacy: [UInt32: UInt32] = [
        0xF5B301: 0xE3F6FF, 0xF5847F: 0xD0F0FF, 0xF287AC: 0xD0F0FF, 0xB795EE: 0xB0E6FF,
        0x84BAEF: 0xB0E6FF, 0x77CEC4: 0xD0F0FF, 0x86D19C: 0xE3F6FF, 0x9CA3AF: 0x99C9E1,
    ]

    /// The brand step to show for whatever hex is stored.
    static func brandHex(forStoredHex stored: Int) -> UInt32 {
        let hex = UInt32(truncatingIfNeeded: stored) & 0xFFFFFF
        if options.contains(hex) { return hex }
        if let mapped = legacy[hex] { return mapped }
        return 0xE3F6FF
    }

    static func color(forStoredHex stored: Int) -> Color {
        Color(hex: brandHex(forStoredHex: stored))
    }
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
    /// Optional custom background color (hex RGB). nil = the default editor bg.
    var backgroundColorHex: Int?

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

    /// The note's custom background tint, if one was chosen — always a brand
    /// sky step (legacy multi-colour picks are mapped onto the same steps).
    var backgroundColor: Color? {
        backgroundColorHex.map { NoteTint.color(forStoredHex: $0) }
    }

    /// The surface to paint behind this note (editor and list row), or nil for
    /// the default. Light mode uses the sky step directly (navy text reads on
    /// all of them); dark mode lays it over navy as a soft wash.
    func backgroundSurface(_ palette: Palette) -> Color? {
        guard let tint = backgroundColor else { return nil }
        return palette.dark ? tint.opacity(0.16) : tint
    }

    var isTrashed: Bool { deletedAt != nil }

    /// True when there's nothing worth keeping — used to discard blank notes on
    /// editor dismiss.
    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
