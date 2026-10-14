//
//  Item.swift
//  Evry
//
//  SwiftData models — the Swift port of the EvryJS task/project shapes
//  (js/store.js). Folder colours are sky→navy shades (see `FolderShade`),
//  never free hues.
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - Priority

enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case high, medium, low, normal

    var id: String { rawValue }

    /// Sort rank — high first.
    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        case .normal: 3
        }
    }

    var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .normal: "Normal"
        }
    }

    /// Short chip text ("High", "Medium", "Low"). Priority is carried by the
    /// word and `symbol`, never by colour (the brand has no red/orange/green).
    var chipLabel: String? {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .normal: nil
        }
    }

    /// SF Symbol that marks a non-normal priority — drawn in navy ink; the
    /// glyph's shape (two marks, one mark, a down arrow) tells the levels apart.
    /// (Task cards mark high priority with a sky outline instead.)
    var symbol: String? {
        switch self {
        case .high: "exclamationmark.2"
        case .medium: "exclamationmark"
        case .low: "arrow.down"
        case .normal: nil
        }
    }
}

// MARK: - Recurrence

enum RecurrenceFreq: String, Codable, CaseIterable, Identifiable {
    case daily, weekdays, weekly, monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    /// The next occurrence after `date` — completing a recurring task spins
    /// off a fresh copy at this date.
    func nextOccurrence(after date: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .daily:
            return cal.date(byAdding: .day, value: 1, to: date) ?? date
        case .weekly:
            return cal.date(byAdding: .day, value: 7, to: date) ?? date
        case .monthly:
            return cal.date(byAdding: .month, value: 1, to: date) ?? date
        case .weekdays:
            var d = date
            repeat {
                d = cal.date(byAdding: .day, value: 1, to: d) ?? d
            } while cal.isDateInWeekend(d)
            return d
        }
    }
}

// MARK: - Subtask (embedded value, not a separate entity)

struct SubtaskData: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var completed: Bool = false
}

// MARK: - Task

@Model
final class TaskItem {
    var uid: UUID = UUID()
    var title: String = ""
    /// Always set: tasks default to today (see `init`) and older undated tasks are
    /// moved to today on launch (`TaskActions.assignMissingDueDates`). Optional
    /// only so the existing store needs no migration.
    var dueDate: Date?
    var tags: [String] = []
    var priorityRaw: String = TaskPriority.normal.rawValue
    var notes: String = ""
    var location: String = ""
    var isNote: Bool = false
    var pinned: Bool = false
    var completed: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date()
    var deletedAt: Date?
    var recurrenceRaw: String?
    var subtasks: [SubtaskData] = []
    var sortOrder: Int = 0
    /// Optional grouping — tasks sharing a `TaskGroup` render together inside a
    /// collapsible folder in the timeline.
    var group: TaskGroup?

    init(
        title: String,
        dueDate: Date? = nil,
        tags: [String] = [],
        priority: TaskPriority = .normal,
        notes: String = "",
        location: String = "",
        isNote: Bool = false,
        /// Fill the location from a saved place the title mentions ("go to the
        /// gym"). Off where the caller already decided (quick add).
        autoLocation: Bool = true
    ) {
        self.title = title
        // Every task has a due date — with none given it lands on today.
        self.dueDate = dueDate ?? Calendar.current.startOfDay(for: Date())
        self.tags = tags
        self.priorityRaw = priority.rawValue
        self.notes = notes
        if location.isEmpty && autoLocation && !isNote {
            self.location = FrequentPlaces.match(for: title)?.locationString ?? ""
        } else {
            self.location = location
        }
        self.isNote = isNote
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    var recurrence: RecurrenceFreq? {
        get { recurrenceRaw.flatMap(RecurrenceFreq.init(rawValue:)) }
        set { recurrenceRaw = newValue?.rawValue }
    }

    var isTrashed: Bool { deletedAt != nil }
}

// MARK: - Task group (a sky/navy-shaded folder of tasks)

@Model
final class TaskGroup {
    var uid: UUID = UUID()
    var name: String = ""
    /// Legacy folder tint (hex RGB) from when colours were picked. Kept only so
    /// the store needs no migration — it is no longer used for display.
    var colorHex: Int?
    /// Automatic colour: a position (0…1) between sky (0) and navy (1),
    /// assigned in sequence when the folder is created.
    var shade: Double?
    var createdAt: Date = Date()
    var sortOrder: Int = 0

    /// Detaching (not cascading) so ungrouping/deleting the folder keeps the tasks.
    @Relationship(deleteRule: .nullify, inverse: \TaskItem.group)
    var tasks: [TaskItem]? = []

    init(name: String = "", colorHex: Int? = nil) {
        self.name = name
        self.colorHex = colorHex
    }

    var color: Color? { colorHex.map { Color(hex: UInt32(truncatingIfNeeded: $0)) } }

    /// The folder's display colour in the current theme — always a sky/navy
    /// shade; the legacy `colorHex` is ignored so no off-brand hue can appear.
    func tint(_ palette: Palette) -> Color {
        if let shade { return palette.folderColor(shade: shade) }
        return palette.folderColor(shade: 0.5)
    }
}
