//
//  InboxView.swift
//  Evry
//
//  Inbox tab — Today/All dropdown header, progress bar, and the grouped
//  task list, ported from the webapp's inboxTab.js.
//

import SwiftUI
import SwiftData

enum InboxViewMode: String, CaseIterable, Identifiable {
    case today, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .all: "All Tasks"
        }
    }
}

struct InboxView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void
    var inFocusMode: Bool = false

    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @AppStorage("inbox_view") private var viewModeRaw = InboxViewMode.today.rawValue
    @State private var showCompleted = false
    @State private var emptyMessage = emptyMessages.randomElement()!

    private var viewMode: InboxViewMode { InboxViewMode(rawValue: viewModeRaw) ?? .today }
    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed } }
    private var stats: TaskStats { computeStats(tasks) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !inFocusMode {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                }

                switch viewMode {
                case .today: todayList
                case .all: allList
                }
            }
            .padding(.bottom, inFocusMode ? 20 : 130)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(inFocusMode ? Color.clear : palette.bg)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Menu {
                    ForEach(InboxViewMode.allCases) { mode in
                        Button {
                            viewModeRaw = mode.rawValue
                        } label: {
                            if mode == viewMode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(viewMode.label)
                            .font(.system(size: 38, weight: .heavy))
                            .tracking(-1)
                            .foregroundStyle(palette.text)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(palette.textSec)
                            .padding(.top, 8)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if viewMode == .today {
                    RoundIconButton(systemName: "checklist", palette: palette) {
                        showCompleted.toggle()
                    }
                }
            }

            if viewMode == .today && stats.todayTotal > 0 {
                ProgressArea(done: stats.todayDone, total: stats.todayTotal, palette: palette)
            }
        }
    }

    // MARK: Today view

    private var todayTasks: [TaskItem] { tasks.filter(isTodayTask) }

    private var todayList: some View {
        let items = sortPinnedFirst(todayTasks)
        let overdue = items.filter { !$0.completed && !$0.isNote && isOverdueDate($0.dueDate) }
        let active = items.filter { !$0.completed && !overdue.contains($0) }
        let completed = items.filter { $0.completed && !$0.isNote }

        return VStack(spacing: 0) {
            if overdue.isEmpty && active.isEmpty && completed.isEmpty {
                if !inFocusMode {
                    EmptyStateView(
                        imageName: "CatEmptyState",
                        title: emptyMessage,
                        text: "No tasks match right now. Pull up below to add one.",
                        palette: palette
                    )
                    .padding(.top, 40)
                }
            } else {
                if !overdue.isEmpty {
                    SectionLabel(text: "Overdue", palette: palette, danger: true)
                        .padding(.horizontal, 20)
                    taskRows(overdue)
                }
                if !active.isEmpty {
                    if !overdue.isEmpty {
                        SectionLabel(text: "Today", palette: palette)
                            .padding(.horizontal, 20)
                    }
                    taskRows(active)
                }
                if !completed.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { showCompleted.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            SectionLabel(text: "Completed (\(completed.count))", palette: palette)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(palette.textSec)
                                .rotationEffect(.degrees(showCompleted ? 180 : 0))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    if showCompleted {
                        taskRows(completed)
                    }
                }
            }
        }
    }

    // MARK: All view

    private var allList: some View {
        let items = sortPinnedFirst(tasks)
        let active = items.filter { !$0.completed }
        let completed = items.filter { $0.completed && !$0.isNote }

        let buckets: [(String, [TaskItem], Bool)] = [
            ("Overdue", active.filter { dateCategory($0.dueDate) == .overdue && !$0.isNote }, true),
            ("Today", active.filter { dateCategory($0.dueDate) == .today }, false),
            ("Tomorrow", active.filter { dateCategory($0.dueDate) == .tomorrow }, false),
            ("This Week", active.filter { dateCategory($0.dueDate) == .week }, false),
            ("Next Week", active.filter { dateCategory($0.dueDate) == .nextweek }, false),
            ("Later", active.filter { dateCategory($0.dueDate) == .later }, false),
            ("No Date", active.filter { $0.dueDate == nil && !$0.isNote }, false),
            ("Notes", active.filter { $0.isNote && $0.dueDate == nil }, false),
        ]

        return VStack(spacing: 0) {
            if active.isEmpty && completed.isEmpty {
                if !inFocusMode {
                    EmptyStateView(
                        imageName: "CatEmptyState",
                        title: emptyMessage,
                        text: "No tasks match right now. Pull up below to add one.",
                        palette: palette
                    )
                    .padding(.top, 40)
                }
            } else {
                ForEach(buckets, id: \.0) { label, bucket, danger in
                    if !bucket.isEmpty {
                        SectionLabel(text: label, palette: palette, danger: danger)
                            .padding(.horizontal, 20)
                        taskRows(bucket)
                    }
                }
                if !completed.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { showCompleted.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            SectionLabel(text: "Completed (\(completed.count))", palette: palette)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(palette.textSec)
                                .rotationEffect(.degrees(showCompleted ? 180 : 0))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    if showCompleted {
                        taskRows(completed)
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func taskRows(_ items: [TaskItem]) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { task in
                TaskRowView(
                    task: task,
                    palette: palette,
                    onToggle: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            TaskActions.toggle(task, context: context)
                        }
                    },
                    onEdit: { onEdit(task) },
                    onDelete: { onDelete(task) },
                    onToggleSubtask: { subtask in
                        if let idx = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                            var updatedSubtasks = task.subtasks
                            updatedSubtasks[idx].completed.toggle()
                            task.subtasks = updatedSubtasks
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.96))
                ))
            }
        }
        .padding(.horizontal, 12)
    }
}
