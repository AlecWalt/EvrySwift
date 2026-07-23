//
//  TaskRowView.swift
//  Evry
//
//  The task card — port of the webapp's TaskItem row: rounded card, circle
//  checkbox, strikethrough title, notes preview, colored meta chips,
//  embedded subtasks, trailing trash button.
//

import SwiftUI

struct TaskRowView: View {
    let task: TaskItem
    let palette: Palette
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onToggleSubtask: (SubtaskData) -> Void

    private var hasMeta: Bool {
        !task.isNote && (task.dueDate != nil || !task.tags.isEmpty || task.priority != .normal || task.recurrence != nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if task.isNote {
                // A note has nothing to "complete" — same footprint so notes
                // and tasks still line up in a mixed list.
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPh)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
            } else {
                TaskCheckbox(checked: task.completed, palette: palette, action: onToggle)
                    .padding(.top, 2)
            }

            // Body — tapping opens the edit sheet
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if task.pinned {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.primary)
                        }
                        Text(task.title)
                            .font(.system(size: 16.5))
                            .foregroundStyle(task.completed ? palette.textSec : palette.text)
                            .strikethrough(task.completed, color: palette.textPh)
                            .multilineTextAlignment(.leading)
                    }

                    if !task.notes.isEmpty {
                        Text(task.notes)
                            .font(.system(size: task.isNote ? 13.5 : 12))
                            .foregroundStyle(task.isNote ? palette.text : palette.textSec)
                            .lineLimit(task.isNote ? 8 : 2)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 3)
                    }

                    if hasMeta {
                        metaChips
                            .padding(.top, 5)
                    }

                    if !task.subtasks.isEmpty {
                        subtaskList
                            .padding(.top, 7)
                            .padding(.leading, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSec)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .opacity(0.3)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .evryCard(palette)
        .opacity(task.completed ? 0.62 : 1)
    }

    private var metaChips: some View {
        HStack(spacing: 4) {
            if let due = task.dueDate {
                DateChip(date: due, palette: palette)
            }
            if let recurrence = task.recurrence {
                ChipView(text: "🔁 \(recurrence.label)", foreground: palette.primary, background: palette.primaryLight)
            }
            if let priorityLabel = task.priority.chipLabel {
                ChipView(
                    text: priorityLabel,
                    foreground: priorityColor,
                    background: priorityBackground
                )
            }
            ForEach(task.tags, id: \.self) { tag in
                ChipView(text: "#\(tag)", foreground: palette.textSec, background: palette.hover)
            }
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: Palette.danger
        case .medium: Palette.warning
        case .low: Palette.success
        case .normal: palette.textSec
        }
    }

    private var priorityBackground: Color {
        switch task.priority {
        case .high: palette.dangerLight
        case .medium: palette.warningLight
        case .low: palette.successLight
        case .normal: palette.hover
        }
    }

    private var subtaskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(task.subtasks) { subtask in
                HStack(spacing: 8) {
                    if !task.isNote {
                        Button {
                            onToggleSubtask(subtask)
                        } label: {
                            ZStack {
                                Circle().fill(subtask.completed ? Palette.success : .clear)
                                Circle().strokeBorder(subtask.completed ? Palette.success : palette.border, lineWidth: 1.5)
                                if subtask.completed {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(subtask.title)
                        .font(.system(size: 13))
                        .foregroundStyle(subtask.completed ? palette.textSec : palette.text)
                        .strikethrough(subtask.completed, color: palette.textPh)
                }
            }
        }
    }
}
