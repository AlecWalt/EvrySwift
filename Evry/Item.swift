//
//  Item.swift
//  Evry
//
//  SwiftData models — the Swift port of the EvryJS task/project shapes
//  (js/store.js) plus the project category palette
//  (js/utils/projectCategories.js).
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

    /// Chip text matching the webapp ("↑ High", "→ Med", "↓ Low").
    var chipLabel: String? {
        switch self {
        case .high: "↑ High"
        case .medium: "→ Med"
        case .low: "↓ Low"
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
    var dueDate: Date?
    var tags: [String] = []
    var priorityRaw: String = TaskPriority.normal.rawValue
    var notes: String = ""
    var isNote: Bool = false
    var pinned: Bool = false
    var completed: Bool = false
    var completedAt: Date?
    var createdAt: Date = Date()
    var deletedAt: Date?
    var recurrenceRaw: String?
    var subtasks: [SubtaskData] = []
    var project: Project?

    init(
        title: String,
        dueDate: Date? = nil,
        tags: [String] = [],
        priority: TaskPriority = .normal,
        notes: String = "",
        isNote: Bool = false,
        project: Project? = nil
    ) {
        self.uid = UUID()
        self.title = title
        self.dueDate = dueDate
        self.tags = tags
        self.priorityRaw = priority.rawValue
        self.notes = notes
        self.isNote = isNote
        self.pinned = false
        self.completed = false
        self.createdAt = Date()
        self.project = project
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

// MARK: - Project

@Model
final class Project {
    var uid: UUID = UUID()
    var name: String = ""
    var categoryKey: String?
    var startDate: Date?
    var dueDate: Date?
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \TaskItem.project)
    var tasks: [TaskItem]? = []

    init(name: String, categoryKey: String? = nil, startDate: Date? = nil, dueDate: Date? = nil) {
        self.uid = UUID()
        self.name = name
        self.categoryKey = categoryKey
        self.startDate = startDate
        self.dueDate = dueDate
        self.createdAt = Date()
    }

    var category: ProjectCategory? { ProjectCategory.byKey(categoryKey) }
}

// MARK: - Project categories

struct ProjectCategory: Identifiable, Equatable {
    let key: String
    let label: String
    let color: Color

    var id: String { key }

    static let all: [ProjectCategory] = [
        ProjectCategory(key: "work",     label: "Work",     color: Color(hex: 0x6366F1)),
        ProjectCategory(key: "personal", label: "Personal", color: Color(hex: 0xEC4899)),
        ProjectCategory(key: "health",   label: "Health",   color: Color(hex: 0x22C55E)),
        ProjectCategory(key: "learning", label: "Learning", color: Color(hex: 0xF97316)),
        ProjectCategory(key: "finance",  label: "Finance",  color: Color(hex: 0x14B8A6)),
        ProjectCategory(key: "home",     label: "Home",     color: Color(hex: 0x0EA5E9)),
    ]

    static func byKey(_ key: String?) -> ProjectCategory? {
        guard let key else { return nil }
        return all.first { $0.key == key }
    }
}
