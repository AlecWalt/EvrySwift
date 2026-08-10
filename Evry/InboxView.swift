//
//  InboxView.swift
//  Evry
//
//  Inbox tab — Today/All dropdown header, progress bar, and the grouped
//  task list, ported from the webapp's inboxTab.js.
//

import SwiftUI
import SwiftData
import FoundationModels

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

enum InboxLayout: String {
    case inbox, timeline, calendar
}

struct InboxView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void
    var inFocusMode: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(Appearance.self) private var appearance
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @Query(sort: \Project.name) private var allProjects: [Project]
    @AppStorage("inbox_view") private var viewModeRaw = InboxViewMode.today.rawValue
    @State private var showCompleted = false
    @State private var emptyMessage = emptyMessages.randomElement()!
    @State private var showBrainDump = false
    @State private var showLayoutPicker = false
    @State private var aiPickIDs: Set<UUID> = []
    @State private var aiPicksDone = false
    @AppStorage("inbox_layout") private var layoutRaw = InboxLayout.inbox.rawValue
    @AppStorage("membership_plan") private var membershipPlan = ""
    @AppStorage("inbox_hide_completed") private var hideCompleted = false
    @AppStorage("inbox_sort_by") private var sortBy = "created"
    @AppStorage("inbox_hide_notes") private var hideNotes = false
    @AppStorage("inbox_hide_reschedule") private var hideReschedule = false
    // Multi-select
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showProjectPicker = false
    // Drag reorder
    @State private var draggingID: UUID? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var collapsedProjects: Set<UUID> = []
    // Accomplishments
    @State private var showAccomplishments = false
    // Reschedule on 0.2s hold
    @State private var showRescheduleFor: TaskItem? = nil

    private var viewMode: InboxViewMode { InboxViewMode(rawValue: viewModeRaw) ?? .today }
    private var inboxLayout: InboxLayout { InboxLayout(rawValue: layoutRaw) ?? .inbox }
    private var isPro: Bool { membershipPlan == "pro" }
    // Falls back to .inbox if a Pro-only layout is stored without a Pro plan.
    private var effectiveLayout: InboxLayout {
        isPro ? inboxLayout : .inbox
    }
    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed && (!hideNotes || !$0.isNote) } }
    /// Just the today progress-bar counts. The header is the only render-path
    /// consumer, so we avoid the full `computeStats` (streaks, week/month
    /// rollups) that would otherwise run on every redraw.
    private var todayProgress: (done: Int, total: Int) {
        let todayCompletable = tasks.filter { isTodayTask($0) && !$0.isNote }
        return (todayCompletable.filter(\.completed).count, todayCompletable.count)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if !inFocusMode {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                }

                if !globalOverdueTasks.isEmpty {
                    overdueBanner(count: globalOverdueTasks.count)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: globalOverdueTasks.count)
                }

                switch effectiveLayout {
                case .inbox:
                    ScrollView {
                        VStack(spacing: 0) {
                            if !aiPickIDs.isEmpty { aiPicksSection }
                            switch viewMode {
                            case .today: todayList
                            case .all: allList
                            }
                        }
                        .padding(.bottom, inFocusMode ? 20 : (isSelecting ? 200 : 130))
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .scrollDisabled(draggingID != nil)
                    .frame(maxHeight: .infinity)
                case .timeline:
                    InboxTimelineView(
                        tasks: tasks, palette: palette, onEdit: onEdit, onDelete: onDelete,
                        isSelecting: $isSelecting, selectedIDs: $selectedIDs,
                        draggingID: $draggingID, dragOffset: $dragOffset,
                        onToggleSelect: toggleSelect
                    )
                case .calendar:
                    InboxCalendarLayout(
                        tasks: tasks, palette: palette, onEdit: onEdit, onDelete: onDelete,
                        isSelecting: $isSelecting, selectedIDs: $selectedIDs,
                        draggingID: $draggingID, dragOffset: $dragOffset,
                        onToggleSelect: toggleSelect
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(inFocusMode ? Color.clear : palette.bg)

            if isSelecting {
                MultiSelectBar(
                    selectedCount: selectedIDs.count,
                    palette: palette,
                    onDelete: deleteSelected,
                    onMove: { showProjectPicker = true },
                    onCancel: cancelSelection
                )
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelecting)
        .sheet(isPresented: $showBrainDump) { BrainDumpSheet() }
        .sheet(isPresented: $showLayoutPicker) { LayoutPickerSheet(selection: $layoutRaw) }
        .sheet(isPresented: $showProjectPicker) {
            InboxProjectPickerSheet(projects: allProjects, onSelect: moveSelectedToProject)
        }
        .sheet(isPresented: $showAccomplishments) {
            let completedToday = tasks.filter { task in
                guard task.completed, let completedAt = task.completedAt else { return false }
                return Calendar.current.isDateInToday(completedAt)
            }
            AccomplishmentsView(completedTasks: completedToday, date: Date())
                .environment(appearance)
        }
        .confirmationDialog(
            showRescheduleFor.map { "Reschedule \"\($0.title)\"" } ?? "Reschedule",
            isPresented: Binding(
                get: { showRescheduleFor != nil },
                set: { if !$0 { showRescheduleFor = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let task = showRescheduleFor {
                Button("Tomorrow") { TaskActions.reschedule(task, to: addDays(Date(), 1)); showRescheduleFor = nil }
                Button("This Weekend") { TaskActions.reschedule(task, to: TaskActions.nextWeekdayDate(6)); showRescheduleFor = nil }
                Button("Next Week") { TaskActions.reschedule(task, to: TaskActions.nextWeekdayDate(1)); showRescheduleFor = nil }
                Button("Cancel", role: .cancel) { showRescheduleFor = nil }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                if effectiveLayout == .inbox {
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
                        HStack(spacing: 6) {
                            Text(viewMode.label)
                                .font(.system(size: 34, weight: .heavy))
                                .tracking(-0.5)
                                .foregroundStyle(palette.text)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.textSec)
                                .padding(.top, 4)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(effectiveLayout == .timeline ? "Timeline" : "Calendar")
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(palette.text)
                }

                Spacer()

                HStack(spacing: 6) {
                    Button { showBrainDump = true } label: {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSec)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)

                    Button { runAiPicks() } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSec)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)

                    Button { showLayoutPicker = true } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textSec)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                }
            }

            if effectiveLayout == .inbox && viewMode == .today && todayProgress.total > 0 {
                ProgressArea(done: todayProgress.done, total: todayProgress.total, palette: palette)
            }

        }
    }

    // MARK: Overdue helpers

    private var globalOverdueTasks: [TaskItem] {
        let today = Calendar.current.startOfDay(for: Date())
        return tasks.filter { !$0.completed && !$0.isNote && $0.deletedAt == nil }
            .filter { d in guard let due = d.dueDate else { return false }; return due < today }
    }

    private func overdueBanner(count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.danger)

            Text("\(count) overdue task\(count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)

            Spacer()

            if !hideReschedule {
                Button {
                    let today = Calendar.current.startOfDay(for: Date())
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        for task in globalOverdueTasks { task.dueDate = today }
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Text("Reschedule all")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.danger, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.danger.opacity(palette.dark ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.danger.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Today view

    private var todayTasks: [TaskItem] { tasks.filter(isTodayTask) }

    private var todayList: some View {
        let items = sortPinnedFirst(todayTasks)
        let overdue = items.filter { !$0.completed && !$0.isNote && isOverdueDate($0.dueDate) }
        let overdueIDs = Set(overdue.map(\.uid))
        let active = items.filter { !$0.completed && !overdueIDs.contains($0.uid) }
        let completed = items.filter { $0.completed && !$0.isNote && isTodayDate($0.completedAt) }

        let allUncompleted = overdue + active
        let groups = groupedByProject(allUncompleted)
        let groupedIDs = Set(groups.flatMap { $0.tasks }.map { $0.uid })
        let standaloneOverdue = overdue.filter { !groupedIDs.contains($0.uid) }
        let standaloneActive = active.filter { !groupedIDs.contains($0.uid) }

        return VStack(spacing: 0) {
            if groups.isEmpty && standaloneOverdue.isEmpty && standaloneActive.isEmpty && completed.isEmpty {
                if !inFocusMode {
                    EmptyStateView(
                        imageName: "Cat",
                        title: emptyMessage,
                        text: "No tasks match right now. Pull up below to add one.",
                        palette: palette
                    )
                    .padding(.top, 40)
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    projectSection(group.project, tasks: group.tasks)
                }
                if !standaloneOverdue.isEmpty {
                    SectionLabel(text: "Overdue", palette: palette, danger: true)
                        .padding(.horizontal, 20)
                    taskRows(standaloneOverdue)
                }
                if !standaloneActive.isEmpty {
                    if !standaloneOverdue.isEmpty || !groups.isEmpty {
                        SectionLabel(text: "Today", palette: palette)
                            .padding(.horizontal, 20)
                    }
                    taskRows(standaloneActive)
                }
                if !completed.isEmpty && !hideCompleted {
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
        let completed = items.filter { $0.completed && !$0.isNote && isTodayDate($0.completedAt) }

        let groups = groupedByProject(active)
        let groupedIDs = Set(groups.flatMap { $0.tasks }.map { $0.uid })
        let standalone = active.filter { !groupedIDs.contains($0.uid) }

        let buckets: [(String, [TaskItem], Bool)] = [
            ("Overdue", standalone.filter { dateCategory($0.dueDate) == .overdue && !$0.isNote }, true),
            ("Today", standalone.filter { dateCategory($0.dueDate) == .today }, false),
            ("Tomorrow", standalone.filter { dateCategory($0.dueDate) == .tomorrow }, false),
            ("This Week", standalone.filter { dateCategory($0.dueDate) == .week }, false),
            ("Next Week", standalone.filter { dateCategory($0.dueDate) == .nextweek }, false),
            ("Later", standalone.filter { dateCategory($0.dueDate) == .later }, false),
            ("No Date", standalone.filter { $0.dueDate == nil && !$0.isNote }, false),
            ("Notes", standalone.filter { $0.isNote && $0.dueDate == nil }, false),
        ]

        return VStack(spacing: 0) {
            if groups.isEmpty && active.isEmpty && completed.isEmpty {
                if !inFocusMode {
                    EmptyStateView(
                        imageName: "Cat",
                        title: emptyMessage,
                        text: "No tasks match right now. Pull up below to add one.",
                        palette: palette
                    )
                    .padding(.top, 40)
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    projectSection(group.project, tasks: group.tasks)
                }
                ForEach(buckets, id: \.0) { label, bucket, danger in
                    if !bucket.isEmpty {
                        SectionLabel(text: label, palette: palette, danger: danger)
                            .padding(.horizontal, 20)
                        taskRows(bucket)
                    }
                }
                if !completed.isEmpty && !hideCompleted {
                    HStack {
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
                        Button { showAccomplishments = true } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                                .foregroundStyle(palette.primary)
                                .frame(width: 28, height: 28)
                                .background(palette.primaryLight, in: Circle())
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                    .padding(.horizontal, 20)
                    if showCompleted {
                        taskRows(completed)
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func sortItems(_ items: [TaskItem]) -> [TaskItem] {
        switch sortBy {
        case "priority":
            return items.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                if a.priority.rank != b.priority.rank { return a.priority.rank < b.priority.rank }
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.createdAt > b.createdAt
            }
        case "due":
            return items.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                let da = a.dueDate ?? Date.distantFuture
                let db = b.dueDate ?? Date.distantFuture
                if da != db { return da < db }
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.createdAt > b.createdAt
            }
        default:
            return items.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.createdAt > b.createdAt
            }
        }
    }

    private func taskRows(_ items: [TaskItem]) -> some View {
        let sorted = sortItems(items)

        return VStack(spacing: 8) {
            ForEach(sorted, id: \.uid) { task in
                let isSelf = draggingID == task.uid
                let neighborOff = neighborOffset(task, in: sorted)
                SwipeActionRow(
                    leadingAction: task.isNote || task.completed ? nil : SwipeActionRow.Action(
                        label: "Done", icon: "checkmark", color: Palette.success,
                        action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { TaskActions.toggle(task, context: context) } }
                    ),
                    trailingAction: SwipeActionRow.Action(
                        label: "Delete", icon: "trash.fill", color: Palette.danger,
                        action: { onDelete(task) }
                    ),
                    isDragging: draggingID != nil
                ) {
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
                    },
                    isSelecting: isSelecting,
                    isSelected: selectedIDs.contains(task.uid),
                    onSelect: { toggleSelect(task) }
                )
                } // SwipeActionRow
                .scaleEffect(isSelf ? 1.04 : 1.0)
                .shadow(color: isSelf ? .black.opacity(0.2) : .clear, radius: isSelf ? 14 : 0, y: isSelf ? 6 : 0)
                .offset(y: isSelf ? dragOffset : neighborOff)
                .zIndex(isSelf ? 1 : 0)
                // isSelf animation: handles scale/shadow when entering or leaving drag state
                // neighborOff animation: fires whenever a neighbor crosses a step boundary,
                // making tasks slide smoothly rather than teleporting
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelf)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: neighborOff)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.96))
                ))
                // Still hold (≥ 0.5 s, < 10 pt movement) → multi-select
                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10) {
                    guard draggingID == nil else { return }
                    showRescheduleFor = nil
                    withAnimation(.spring(response: 0.3)) {
                        isSelecting = true
                        selectedIDs.insert(task.uid)
                    }
                    let gen = UIImpactFeedbackGenerator(style: .heavy)
                    gen.impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        gen.impactOccurred(intensity: 0.7)
                    }
                }
                // Hold then move (≥ 0.3 s lock-in, ≥ 5 pt drag) → reorder
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.3)
                        .sequenced(before: DragGesture(minimumDistance: 5, coordinateSpace: .global))
                        .onChanged { value in
                            switch value {
                            case .first(true):
                                break
                            case .second(true, let drag?):
                                if !isSelecting {
                                    if draggingID == nil {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            draggingID = task.uid
                                        }
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                    dragOffset = drag.translation.height
                                }
                            default:
                                break
                            }
                        }
                        .onEnded { _ in
                            if draggingID != nil {
                                finishDrag(in: sorted, finalOffset: dragOffset)
                            }
                        }
                )
                // Hold 0.3–0.5 s → reschedule menu
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.3, maximumDistance: 10)
                        .onEnded { _ in
                            guard !isSelecting, draggingID == nil,
                                  !task.isNote, !task.completed else { return }
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            showRescheduleFor = task
                        }
                )
            }
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: items.count)
    }

    // MARK: Drag-to-reorder helpers

    private func neighborOffset(_ task: TaskItem, in items: [TaskItem]) -> CGFloat {
        guard let draggedID = draggingID,
              task.uid != draggedID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }),
              let taskIdx = items.firstIndex(where: { $0.uid == task.uid }) else {
            return 0
        }
        let rowH: CGFloat = 78
        let steps = Int((dragOffset / rowH).rounded())
        let targetIdx = max(0, min(items.count - 1, draggedIdx + steps))
        if taskIdx > draggedIdx && taskIdx <= targetIdx { return -rowH }
        if taskIdx < draggedIdx && taskIdx >= targetIdx { return rowH }
        return 0
    }

    private func finishDrag(in items: [TaskItem], finalOffset: CGFloat) {
        guard let draggedID = draggingID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }) else {
            withAnimation(.spring(response: 0.35)) { draggingID = nil; dragOffset = 0 }
            return
        }
        let rowH: CGFloat = 78
        let steps = Int((finalOffset / rowH).rounded())
        let targetIdx = max(0, min(items.count - 1, draggedIdx + steps))
        var reordered = items
        let moved = reordered.remove(at: draggedIdx)
        reordered.insert(moved, at: targetIdx)
        // Commit new order and reset drag state in a single animation so SwiftUI
        // collapses the offset-based visual position into the real layout position.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            for (i, task) in reordered.enumerated() { task.sortOrder = i }
            draggingID = nil
            dragOffset = 0
        }
    }

    // MARK: Multi-select helpers

    private func toggleSelect(_ task: TaskItem) {
        withAnimation(.spring(response: 0.2)) {
            if selectedIDs.contains(task.uid) {
                selectedIDs.remove(task.uid)
            } else {
                selectedIDs.insert(task.uid)
            }
        }
    }

    private func cancelSelection() {
        withAnimation(.spring(response: 0.3)) {
            isSelecting = false
            selectedIDs = []
        }
    }

    private func deleteSelected() {
        let toDelete = tasks.filter { selectedIDs.contains($0.uid) }
        cancelSelection()
        for task in toDelete { onDelete(task) }
    }

    private func moveSelectedToProject(_ project: Project?) {
        for task in tasks where selectedIDs.contains(task.uid) {
            task.project = project
        }
        cancelSelection()
    }

    // MARK: AI picks section

    private var aiPicksSection: some View {
        let pickTasks = tasks.filter { aiPickIDs.contains($0.uid) }
        let donePicks = pickTasks.filter(\.completed).count
        let total = pickTasks.count

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: aiPicksDone ? "checkmark.circle.fill" : "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(aiPicksDone ? Palette.success : palette.primary)
                Text(aiPicksDone ? "ALL DONE!" : "GET STARTED")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(aiPicksDone ? Palette.success : palette.primary)
                if !aiPicksDone && total > 0 {
                    Text("·").foregroundStyle(palette.textSec)
                    Text("\(donePicks)/\(total)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSec)
                }
                Spacer()
                if !aiPicksDone {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            aiPickIDs = []
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.textSec)
                            .frame(width: 22, height: 22)
                            .background(palette.hover, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if !aiPicksDone {
                taskRows(pickTasks)
            }

            Divider()
                .background(palette.border)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
        .onChange(of: donePicks) { _, new in
            guard total > 0, new == total, !aiPicksDone else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { aiPicksDone = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeOut(duration: 0.4)) { aiPickIDs = []; aiPicksDone = false }
            }
        }
    }

    // MARK: Project grouping

    private func groupedByProject(_ items: [TaskItem]) -> [(project: Project, tasks: [TaskItem])] {
        // Single pass: bucket tasks by project while remembering first-seen order,
        // so projects and their tasks keep the same ordering as the input list.
        var order: [UUID] = []
        var buckets: [UUID: (project: Project, tasks: [TaskItem])] = [:]
        for task in items {
            guard let proj = task.project else { continue }
            if buckets[proj.uid] == nil {
                buckets[proj.uid] = (proj, [])
                order.append(proj.uid)
            }
            buckets[proj.uid]?.tasks.append(task)
        }
        return order.compactMap { buckets[$0] }
    }

    private func projectSection(_ project: Project, tasks: [TaskItem]) -> some View {
        let collapsed = collapsedProjects.contains(project.uid)
        let color = project.category?.color ?? palette.primary
        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if collapsed {
                        collapsedProjects.remove(project.uid)
                    } else {
                        collapsedProjects.insert(project.uid)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                    Text(project.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text("\(tasks.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color, in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .buttonStyle(.plain)

            if !collapsed {
                taskRows(tasks)
            }
        }
    }

    // MARK: Actions

    private func runAiPicks() {
        let active = tasks.filter { !$0.completed && !$0.isNote }
        guard !active.isEmpty else { return }
        var seen: Set<UUID> = []
        var picks: [TaskItem] = []
        func add(_ items: [TaskItem]) {
            for t in items where picks.count < 5 && !seen.contains(t.uid) {
                picks.append(t); seen.insert(t.uid)
            }
        }
        add(active.filter { isOverdueDate($0.dueDate) && $0.priority == .high })
        add(active.filter { isOverdueDate($0.dueDate) })
        add(active.filter { isTodayTask($0) && $0.priority == .high })
        add(active.filter { isTodayTask($0) })
        add(active.filter { $0.priority == .high })
        add(active)
        aiPicksDone = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            aiPickIDs = Set(picks.map(\.uid))
        }
    }

}

// MARK: - Brain Dump sheet

@Generable(description: "A single actionable task extracted from a brain dump")
private struct DumpedTask {
    @Guide(description: "Concise action-first task title. No filler words. Include timing naturally in the title.")
    var title: String

    @Guide(description: "Priority level: high, medium, low, or normal")
    var priority: String
}

@Generable(description: "Actionable tasks extracted and cleaned from a free-form brain dump")
private struct BrainDumpResult {
    @Guide(description: "All actionable tasks, filler words removed, max 20.", .maximumCount(20))
    var tasks: [DumpedTask]
}

private struct BrainPreviewTask: Identifiable {
    let id = UUID()
    var title: String
    var dueDate: Date?
    var priority: TaskPriority
}

private struct BrainDumpSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case input, generating, preview }

    @State private var input = ""
    @State private var phase: Phase = .input
    @State private var previewTasks: [BrainPreviewTask] = []
    @State private var errorMessage = ""
    @State private var speech = LiveSpeechInput()
    @FocusState private var focused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var aiAvailable: Bool { SystemLanguageModel.default.isAvailable }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input:      inputView
                case .generating: generatingView
                case .preview:    previewView
                }
            }
            .navigationTitle(phase == .preview ? "Review Tasks" : "Brain Dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .preview ? "Back" : "Cancel") {
                        if phase == .preview { withAnimation { phase = .input } }
                        else { speech.stop(); dismiss() }
                    }
                }
                if phase == .preview && errorMessage.isEmpty && !previewTasks.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(previewTasks.count) Task\(previewTasks.count == 1 ? "" : "s")") {
                            addTasks()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { input = t } }
        .onDisappear { speech.stop() }
    }

    // MARK: Input

    private var inputView: some View {
        VStack(spacing: 0) {
            // AI hint banner
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(palette.primaryLight)
                        .frame(width: 34, height: 34)
                    Image(systemName: aiAvailable ? "sparkles" : "list.bullet.clipboard.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.primary)
                }
                Text(aiAvailable
                     ? "Speak or type freely — AI will extract your tasks."
                     : "Speak or type freely — we'll build your task list.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSec)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.primaryLight.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.primary.opacity(0.18), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Text editor in a card
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text(speech.isListening
                         ? "Listening… speak freely."
                         : "e.g. \"Call dentist, buy groceries, email Sarah the report…\"")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textPh)
                        .padding(.top, 14)
                        .padding(.horizontal, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $input)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(focused ? palette.primary : palette.border, lineWidth: 1.5)
            )
            .padding(.horizontal, 16)

            // Action bar
            HStack(spacing: 12) {
                Button {
                    if speech.isListening { speech.stop() }
                    else { input = ""; speech.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(speech.isListening ? "Stop" : "Dictate")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(speech.isListening ? Palette.danger : palette.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        (speech.isListening ? Palette.danger : palette.primary).opacity(0.1),
                        in: Capsule()
                    )
                }
                .buttonStyle(PressScaleStyle())

                if speech.permissionDenied {
                    Text("Enable microphone in Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    focused = false
                    speech.stop()
                    withAnimation { phase = .generating }
                    Task { await analyze() }
                } label: {
                    HStack(spacing: 6) {
                        if aiAvailable {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(aiAvailable ? "Analyze" : "Create Tasks")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty ? palette.textSec : .white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(
                        input.trimmingCharacters(in: .whitespaces).isEmpty ? palette.hover : palette.primary,
                        in: Capsule()
                    )
                }
                .buttonStyle(PressScaleStyle())
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(palette.bg)
        .onAppear { focused = true }
    }

    // MARK: Generating

    private var generatingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(palette.primaryLight)
                    .frame(width: 72, height: 72)
                Image(systemName: aiAvailable ? "sparkles" : "list.bullet.clipboard.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(palette.primary)
            }
            VStack(spacing: 8) {
                Text(aiAvailable ? "Apple Intelligence is thinking…" : "Building your task list…")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                Text(aiAvailable ? "Extracting tasks from your thoughts" : "Parsing your brain dump")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
            }
            ProgressView()
                .scaleEffect(1.2)
                .tint(palette.primary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .background(palette.bg)
    }

    // MARK: Preview

    private var previewView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                if !errorMessage.isEmpty {
                    errorBanner
                } else {
                    previewHeader
                    previewTaskList
                    Text("Tap × to remove tasks before adding.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textPh)
                        .padding(.horizontal, 4)
                }
            }
            .padding(20)
        }
        .background(palette.bg)
    }

    private var errorBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Palette.warning)
            Text(errorMessage)
                .font(.system(size: 15))
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                errorMessage = ""
                withAnimation { phase = .input }
            }
            .fontWeight(.semibold)
            .foregroundStyle(palette.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var previewHeader: some View {
        HStack {
            Text("TASKS")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textSec)
            Spacer()
            Text("\(previewTasks.count)")
                .font(.system(size: 12))
                .foregroundStyle(palette.textSec)
        }
        .padding(.horizontal, 4)
    }

    private var previewTaskList: some View {
        VStack(spacing: 0) {
            ForEach(Array(previewTasks.enumerated()), id: \.offset) { i, task in
                previewTaskRow(task: task, index: i)
            }
        }
        .evryCard(palette, cornerRadius: 24)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func previewTaskRow(task: BrainPreviewTask, index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(palette.border, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.text)
                    HStack(spacing: 6) {
                        if task.priority != .normal {
                            priorityBadge(task.priority)
                        }
                        if let due = task.dueDate, let label = formatDueDate(due) {
                            Label(label, systemImage: "calendar")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                }
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        previewTasks = previewTasks.enumerated().filter { $0.offset != index }.map(\.element)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.textPh)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if index < previewTasks.count - 1 {
                Divider().padding(.leading, 46)
            }
        }
    }

    private func priorityBadge(_ priority: TaskPriority) -> some View {
        let (label, color): (String, Color) = switch priority {
        case .high:   ("High",   Palette.danger)
        case .medium: ("Medium", Palette.warning)
        case .low:    ("Low",    Palette.success)
        case .normal: ("",       .clear)
        }
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: Actions

    private func analyze() async {
        if aiAvailable {
            do {
                let session = LanguageModelSession(instructions: """
                    You are a productivity assistant. Extract clear, actionable tasks \
                    from the user's free-form brain dump (spoken or typed).
                    Rules:
                    - Remove ALL filler words and sounds (um, uh, hmm, like, you know, ahh, etc.)
                    - Combine fragmented thoughts into concise, self-contained task titles
                    - Use action-first phrasing (e.g., "Call dentist" not "I need to call the dentist")
                    - Include timing cues directly in the title if mentioned (e.g., "Call dentist tomorrow at 2pm")
                    - Infer priority from urgency language: urgent/important/asap = high; soon/probably/maybe = low; else normal
                    - Merge duplicates into one task
                    - Today's date is \(Date().formatted(.dateTime.weekday().day().month().year()))
                    """)
                let response = try await session.respond(
                    to: "Extract tasks from this brain dump:\n\n\(input)",
                    generating: BrainDumpResult.self
                )
                let tasks: [BrainPreviewTask] = response.content.tasks.map { dumped in
                    let parsed = parseTaskInput(dumped.title)
                    let priority: TaskPriority = switch dumped.priority.lowercased() {
                    case "high":   .high
                    case "medium": .medium
                    case "low":    .low
                    default:       parsed.priority
                    }
                    return BrainPreviewTask(
                        title: parsed.title.isEmpty ? dumped.title : parsed.title,
                        dueDate: parsed.date,
                        priority: priority
                    )
                }
                await MainActor.run {
                    previewTasks = tasks
                    withAnimation { phase = .preview }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Apple Intelligence couldn't process your request. Try again or rephrase your input."
                    withAnimation { phase = .preview }
                }
            }
        } else {
            // Fallback without AI: split by newline
            let lines = input
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 2 }
            let tasks: [BrainPreviewTask] = lines.map { line in
                let parsed = parseTaskInput(line)
                return BrainPreviewTask(
                    title: parsed.title.isEmpty ? line : parsed.title,
                    dueDate: parsed.date,
                    priority: parsed.priority
                )
            }
            await MainActor.run {
                previewTasks = tasks
                withAnimation { phase = .preview }
            }
        }
    }

    private func addTasks() {
        for task in previewTasks {
            let item = TaskItem(title: task.title)
            item.dueDate = task.dueDate
            item.priority = task.priority
            context.insert(item)
        }
        dismiss()
    }
}

// MARK: - Project picker sheet (move selected tasks)

private struct InboxProjectPickerSheet: View {
    let projects: [Project]
    let onSelect: (Project?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    Label("Inbox (no project)", systemImage: "tray")
                        .foregroundStyle(palette.text)
                }
                ForEach(projects) { project in
                    Button {
                        onSelect(project)
                        dismiss()
                    } label: {
                        Label(project.name, systemImage: "folder.fill")
                            .foregroundStyle(palette.text)
                    }
                }
            }
            .navigationTitle("Move to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}

// MARK: - Layout picker sheet

private struct LayoutPickerSheet: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @AppStorage("membership_plan") private var membershipPlan = ""
    @AppStorage("inbox_hide_completed") private var hideCompleted = false
    @AppStorage("inbox_hide_notes") private var hideNotes = false
    @AppStorage("inbox_hide_reschedule") private var hideReschedule = false
    @AppStorage("inbox_sort_by") private var sortBy = "created"

    @State private var showMembershipPromo = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var isPro: Bool { membershipPlan == "pro" }

    private let sortOptions: [(String, String)] = [
        ("created", "Date Created"),
        ("due", "Due Date"),
        ("priority", "Priority"),
    ]

    private var sortLabel: String {
        sortOptions.first { $0.0 == sortBy }?.1 ?? "Date Created"
    }

    private func displayToggleRow(icon: String, label: String, color: Color, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.text)
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(palette.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
    }

    // (layout, name, icon, description, requiresPro)
    private let options: [(InboxLayout, String, String, String, Bool)] = [
        (.inbox,    "Inbox",    "list.bullet.rectangle.portrait", "Task list grouped by date sections", false),
        (.timeline, "Timeline", "calendar.day.timeline.left",     "Swipe through days one at a time",  true),
        (.calendar, "Calendar", "calendar",                       "Month view with task dots and day detail", true),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ForEach(options, id: \.0.rawValue) { layout, name, icon, desc, requiresPro in
                    let locked = requiresPro && !isPro
                    let isSelected = selection == layout.rawValue && !locked
                    Button {
                        if locked {
                            showMembershipPromo = true
                        } else {
                            selection = layout.rawValue
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: icon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(locked ? palette.textSec.opacity(0.4) : (isSelected ? palette.primary : palette.textSec))
                                .frame(width: 44, height: 44)
                                .background(
                                    locked ? palette.hover.opacity(0.6) : (isSelected ? palette.primaryLight : palette.hover),
                                    in: Circle()
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(locked ? palette.text.opacity(0.4) : palette.text)
                                    if locked {
                                        Text("PRO")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(palette.primary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(palette.primaryLight, in: Capsule())
                                    }
                                }
                                Text(desc)
                                    .font(.system(size: 13))
                                    .foregroundStyle(locked ? palette.textSec.opacity(0.4) : palette.textSec)
                            }
                            Spacer()
                            if locked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textPh)
                            } else if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(palette.primary)
                            }
                        }
                        .padding(16)
                        .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(
                                    isSelected ? palette.primary : palette.border,
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                // DISPLAY section
                VStack(alignment: .leading, spacing: 6) {
                    Text("DISPLAY")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(palette.textSec)
                        .padding(.horizontal, 4)

                    VStack(spacing: 8) {
                        displayToggleRow(icon: "eye.slash", label: "Hide Completed Tasks", color: palette.primary, binding: $hideCompleted)
                        displayToggleRow(icon: "note.text", label: "Hide Notes", color: Color(hex: 0xF97316), binding: $hideNotes)
                        displayToggleRow(icon: "calendar.badge.exclamationmark", label: "Hide Overdue Banner", color: Palette.danger, binding: $hideReschedule)
                    }
                }

                // SORT section
                VStack(alignment: .leading, spacing: 6) {
                    Text("SORT")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(palette.textSec)
                        .padding(.horizontal, 4)

                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color(hex: 0x8B5CF6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("Sort By")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.text)
                        Spacer()
                        Menu {
                            ForEach(sortOptions, id: \.0) { key, label in
                                Button {
                                    sortBy = key
                                } label: {
                                    if sortBy == key {
                                        Label(label, systemImage: "checkmark")
                                    } else {
                                        Text(label)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(sortLabel)
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textSec)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.textSec)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                }

                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.bg)
            .navigationTitle("Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .sheet(isPresented: $showMembershipPromo) {
            MembershipPromoView()
        }
    }
}

// MARK: - Timeline layout

private struct InboxTimelineView: View {
    let tasks: [TaskItem]
    let palette: Palette
    let onEdit: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<UUID>
    @Binding var draggingID: UUID?
    @Binding var dragOffset: CGFloat
    var onToggleSelect: (TaskItem) -> Void

    @State private var dayOffset = 0
    @State private var swipeDelta: CGFloat = 0
    @State private var swipeAxis: Axis? = nil
    @State private var pendingDayChange: Task<Void, Never>? = nil
    @State private var pendingDirection: Int = 0
    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .top) {
                // Adjacent page — visible as the current page slides away
                if swipeDelta != 0 {
                    let adjOff = dayOffset + (swipeDelta < 0 ? 1 : -1)
                    let adjDate = cal.date(byAdding: .day, value: adjOff, to: today) ?? today
                    let adjTasks = tasks.filter { t in
                        guard let due = t.dueDate else { return false }
                        return cal.isDate(due, inSameDayAs: adjDate) && !t.isTrashed
                    }
                    TimelineDayPage(
                        date: adjDate,
                        isToday: adjOff == 0,
                        dayTasks: adjTasks,
                        palette: palette,
                        onEdit: onEdit,
                        onDelete: onDelete,
                        isSelecting: $isSelecting,
                        selectedIDs: $selectedIDs,
                        draggingID: $draggingID,
                        dragOffset: $dragOffset,
                        onToggleSelect: onToggleSelect,
                        scrollLocked: swipeAxis == .horizontal
                    )
                    .frame(width: w)
                    .offset(x: swipeDelta < 0 ? w + swipeDelta : -w + swipeDelta)
                }
                // Current page
                let date = cal.date(byAdding: .day, value: dayOffset, to: today) ?? today
                let dayTasks = tasks.filter { t in
                    guard let due = t.dueDate else { return false }
                    return cal.isDate(due, inSameDayAs: date) && !t.isTrashed
                }
                TimelineDayPage(
                    date: date,
                    isToday: dayOffset == 0,
                    dayTasks: dayTasks,
                    palette: palette,
                    onEdit: onEdit,
                    onDelete: onDelete,
                    isSelecting: $isSelecting,
                    selectedIDs: $selectedIDs,
                    draggingID: $draggingID,
                    dragOffset: $dragOffset,
                    onToggleSelect: onToggleSelect,
                    scrollLocked: swipeAxis == .horizontal
                )
                .frame(width: w)
                .offset(x: swipeDelta)
            }
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard draggingID == nil else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        if swipeAxis == nil {
                            if pendingDayChange != nil {
                                pendingDayChange?.cancel()
                                pendingDayChange = nil
                                dayOffset += pendingDirection
                                pendingDirection = 0
                            }
                            swipeDelta = 0
                            guard abs(dx) > 8 || abs(dy) > 8 else { return }
                            swipeAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                        }
                        guard swipeAxis == .horizontal else { return }
                        swipeDelta = dx
                    }
                    .onEnded { value in
                        defer { swipeAxis = nil }
                        guard draggingID == nil, swipeAxis == .horizontal else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { swipeDelta = 0 }
                            return
                        }
                        let dx = value.translation.width
                        let threshold = w * 0.3
                        let velocityX = value.velocity.width
                        if abs(dx) > threshold || abs(velocityX) > 500 {
                            let direction = dx > 0 ? -1 : 1
                            let targetDelta: CGFloat = dx > 0 ? w : -w
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                swipeDelta = targetDelta
                            }
                            pendingDirection = direction
                            pendingDayChange = Task { @MainActor in
                                do {
                                    try await Task.sleep(nanoseconds: 260_000_000)
                                    dayOffset += direction
                                    swipeDelta = 0
                                    pendingDirection = 0
                                } catch {}
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { swipeDelta = 0 }
                        }
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct TimelineDayPage: View {
    let date: Date
    let isToday: Bool
    let dayTasks: [TaskItem]
    let palette: Palette
    let onEdit: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<UUID>
    @Binding var draggingID: UUID?
    @Binding var dragOffset: CGFloat
    var onToggleSelect: (TaskItem) -> Void
    var scrollLocked: Bool = false

    @AppStorage("inbox_hide_completed") private var hideCompleted = false
    @State private var showCompleted = false
    @Environment(\.modelContext) private var context

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Date header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(date.formatted(.dateTime.weekday(.wide)).uppercased())
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(isToday ? palette.primary : palette.textSec)
                        if isToday {
                            Text("TODAY")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(palette.onPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(palette.primary, in: Capsule())
                        }
                    }
                    Text(date.formatted(.dateTime.month(.wide).day()))
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(palette.text)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)

                // Swipe hint
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left")
                    Text("Swipe to navigate days")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.textPh)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)

                // Tasks
                let sorted = dayTasks.sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.createdAt > $1.createdAt
                }
                let activeTasks = sorted.filter { !$0.completed }
                let completedDayTasks = sorted.filter { $0.completed && !$0.isNote }
                let hasVisible = !activeTasks.isEmpty || (!completedDayTasks.isEmpty && !hideCompleted)

                if !hasVisible {
                    VStack(spacing: 10) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 36))
                            .foregroundStyle(palette.border)
                        Text("No tasks due this day")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.textSec)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    if !activeTasks.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(activeTasks) { task in
                                let isSelf = draggingID == task.uid
                                let neighborOff = neighborOffset(task, in: activeTasks)
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
                                            var updated = task.subtasks
                                            updated[idx].completed.toggle()
                                            task.subtasks = updated
                                        }
                                    },
                                    isSelecting: isSelecting,
                                    isSelected: selectedIDs.contains(task.uid),
                                    onSelect: { onToggleSelect(task) }
                                )
                                .scaleEffect(isSelf ? 1.04 : 1.0)
                                .shadow(color: isSelf ? .black.opacity(0.2) : .clear, radius: isSelf ? 14 : 0, y: isSelf ? 6 : 0)
                                .offset(y: isSelf ? dragOffset : neighborOff)
                                .zIndex(isSelf ? 1 : 0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelf)
                                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: neighborOff)
                                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10) {
                                    guard draggingID == nil else { return }
                                    withAnimation(.spring(response: 0.3)) {
                                        isSelecting = true
                                        selectedIDs.insert(task.uid)
                                    }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                }
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.3)
                                        .sequenced(before: DragGesture(minimumDistance: 5, coordinateSpace: .global))
                                        .onChanged { value in
                                            switch value {
                                            case .first(true):
                                                break
                                            case .second(true, let drag?):
                                                if !isSelecting {
                                                    if draggingID == nil {
                                                        draggingID = task.uid
                                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    }
                                                    dragOffset = drag.translation.height
                                                }
                                            default: break
                                            }
                                        }
                                        .onEnded { _ in
                                            if draggingID != nil { finishDrag(in: activeTasks, finalOffset: dragOffset) }
                                        }
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                    }

                    if !completedDayTasks.isEmpty && !hideCompleted {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { showCompleted.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                SectionLabel(text: "Completed (\(completedDayTasks.count))", palette: palette)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(palette.textSec)
                                    .rotationEffect(.degrees(showCompleted ? 180 : 0))
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        if showCompleted {
                            VStack(spacing: 8) {
                                ForEach(completedDayTasks) { task in
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
                                                var updated = task.subtasks
                                                updated[idx].completed.toggle()
                                                task.subtasks = updated
                                            }
                                        },
                                        isSelecting: isSelecting,
                                        isSelected: selectedIDs.contains(task.uid),
                                        onSelect: { onToggleSelect(task) }
                                    )
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                }
            }
            .padding(.bottom, 130)
        }
        .scrollDisabled(draggingID != nil || scrollLocked)
    }

    private func neighborOffset(_ task: TaskItem, in items: [TaskItem]) -> CGFloat {
        guard let draggedID = draggingID,
              task.uid != draggedID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }),
              let taskIdx   = items.firstIndex(where: { $0.uid == task.uid }) else { return 0 }
        let rowH: CGFloat = 78
        let steps  = Int((dragOffset / rowH).rounded())
        let target = max(0, min(items.count - 1, draggedIdx + steps))
        if taskIdx > draggedIdx && taskIdx <= target { return -rowH }
        if taskIdx < draggedIdx && taskIdx >= target { return  rowH }
        return 0
    }

    private func finishDrag(in items: [TaskItem], finalOffset: CGFloat) {
        guard let draggedID = draggingID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }) else {
            withAnimation(.spring(response: 0.35)) { draggingID = nil; dragOffset = 0 }
            return
        }
        let rowH: CGFloat = 78
        let steps  = Int((finalOffset / rowH).rounded())
        let target = max(0, min(items.count - 1, draggedIdx + steps))
        var reordered = items
        let moved = reordered.remove(at: draggedIdx)
        reordered.insert(moved, at: target)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            for (i, t) in reordered.enumerated() { t.sortOrder = i }
            draggingID = nil
            dragOffset = 0
        }
    }
}

// MARK: - Calendar layout

private struct InboxCalendarLayout: View {
    let tasks: [TaskItem]
    let palette: Palette
    let onEdit: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<UUID>
    @Binding var draggingID: UUID?
    @Binding var dragOffset: CGFloat
    var onToggleSelect: (TaskItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(CalendarService.self) private var calendarService
    @State private var displayMonth: Date = .now
    @State private var selectedDay: Date = .now
    @AppStorage("inbox_hide_completed") private var hideCompleted = false
    @State private var showCalCompleted = false
    @State private var calendarExpanded = false
    @State private var dragProgress: CGFloat = 0

    private let cal = Calendar.current
    private let weekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]
    private var dueTasks: [TaskItem] { tasks.filter { $0.dueDate != nil && !$0.isNote } }

    private var weekRows: [[Date?]] {
        stride(from: 0, to: gridDays.count, by: 7).map { i in
            Array(gridDays[i..<min(i+7, gridDays.count)])
        }
    }

    private var currentWeekIndex: Int {
        weekRows.firstIndex { week in
            week.compactMap { $0 }.contains { cal.isDate($0, inSameDayAs: selectedDay) }
        } ?? 0
    }

    private var cellRowHeight: CGFloat { 52 }
    private var collapsedGridHeight: CGFloat { 50 }
    private var expandedGridHeight: CGFloat { CGFloat(weekRows.count) * cellRowHeight - 2 }
    private var currentGridHeight: CGFloat {
        collapsedGridHeight + (expandedGridHeight - collapsedGridHeight) * dragProgress
    }
    private var gridYOffset: CGFloat {
        -CGFloat(currentWeekIndex) * cellRowHeight * (1 - dragProgress)
    }

    private var currentWeekDays: [Date] {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDay)
        guard let weekStart = cal.date(from: comps) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var firstOfMonth: Date {
        let c = cal.dateComponents([.year, .month], from: displayMonth)
        return cal.date(from: c) ?? displayMonth
    }

    private var lastOfMonth: Date {
        cal.date(byAdding: DateComponents(month: 1, second: -1), to: firstOfMonth) ?? firstOfMonth
    }

    private var gridDays: [Date?] {
        let leadingPad = cal.component(.weekday, from: firstOfMonth) - 1
        let count = cal.range(of: .day, in: .month, for: firstOfMonth)!.count
        var days: [Date?] = Array(repeating: nil, count: leadingPad)
        for d in 0..<count { days.append(cal.date(byAdding: .day, value: d, to: firstOfMonth)) }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var monthEvents: [CalendarEvent] {
        calendarService.events(from: firstOfMonth, to: lastOfMonth)
    }

    private func dayTasks(_ day: Date) -> [TaskItem] {
        dueTasks.filter { cal.isDate($0.dueDate!, inSameDayAs: day) }
    }

    private func calendarEvents(on day: Date) -> [CalendarEvent] {
        monthEvents.filter { cal.isDate($0.startDate, inSameDayAs: day) }
    }

    private func dotColors(for day: Date) -> [Color] {
        let dots: [Color] = [palette.primary, Color(hex: 0x22C55E), Color(hex: 0xEC4899), Color(hex: 0xF97316)]
        return dayTasks(day).prefix(4).map { t in
            var h = 0; for s in t.uid.uuidString.unicodeScalars { h = Int(s.value) &+ ((h << 5) &- h) }
            return dots[abs(h) % dots.count]
        }
    }

    private func eventDotColors(for day: Date) -> [Color] {
        calendarEvents(on: day).prefix(3).map(\.calendarColor)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Month nav
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            if calendarExpanded {
                                displayMonth = cal.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
                            } else {
                                selectedDay = cal.date(byAdding: .day, value: -7, to: selectedDay) ?? selectedDay
                                displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: selectedDay)) ?? displayMonth
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .frame(width: 34, height: 34)
                            .background(palette.card, in: Circle())
                            .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(firstOfMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.text)
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            if calendarExpanded {
                                displayMonth = cal.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
                            } else {
                                selectedDay = cal.date(byAdding: .day, value: 7, to: selectedDay) ?? selectedDay
                                displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: selectedDay)) ?? displayMonth
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .frame(width: 34, height: 34)
                            .background(palette.card, in: Circle())
                            .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                // Weekday labels
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(weekdayLabels[i])
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.textSec)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 4)

                // Grid + drag handle
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        // Collapsed: direct week row — no month dependency
                        HStack(spacing: 0) {
                            ForEach(Array(currentWeekDays.enumerated()), id: \.offset) { _, day in
                                InboxDayCell(
                                    day: day,
                                    isToday: cal.isDateInToday(day),
                                    isSelected: cal.isDate(day, inSameDayAs: selectedDay),
                                    dots: dotColors(for: day),
                                    eventDots: eventDotColors(for: day),
                                    palette: palette
                                ) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedDay = day }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 50, alignment: .top)
                        .opacity(Double(1 - dragProgress))

                        // Expanded: full month grid, fades in as calendar opens
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                            ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                                if let day {
                                    InboxDayCell(
                                        day: day,
                                        isToday: cal.isDateInToday(day),
                                        isSelected: cal.isDate(day, inSameDayAs: selectedDay),
                                        dots: dotColors(for: day),
                                        eventDots: eventDotColors(for: day),
                                        palette: palette
                                    ) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selectedDay = day }
                                    }
                                } else {
                                    Color.clear.frame(height: 50)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .offset(y: gridYOffset)
                        .opacity(Double(dragProgress))
                    }
                    .frame(height: currentGridHeight, alignment: .top)
                    .clipped()

                    Capsule()
                        .fill(palette.border)
                        .frame(width: 32, height: 3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    let range = expandedGridHeight - collapsedGridHeight
                                    guard range > 0 else { return }
                                    let startProgress = calendarExpanded ? 1.0 : 0.0
                                    dragProgress = max(0, min(1, startProgress + v.translation.height / range))
                                }
                                .onEnded { v in
                                    let isTap = abs(v.translation.height) < 8 && abs(v.translation.width) < 8
                                    let shouldExpand: Bool
                                    if isTap {
                                        shouldExpand = !calendarExpanded
                                    } else {
                                        let velocity = v.predictedEndTranslation.height - v.translation.height
                                        shouldExpand = dragProgress > 0.45 || velocity > 150
                                    }
                                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                        calendarExpanded = shouldExpand
                                        dragProgress = shouldExpand ? 1 : 0
                                        if shouldExpand {
                                            displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: selectedDay)) ?? displayMonth
                                        }
                                    }
                                }
                        )
                }

                Divider().background(palette.border)

                // Selected day tasks + events
                let selected = dayTasks(selectedDay)
                let selectedEvents = calendarEvents(on: selectedDay)
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(palette.textSec)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                    if !selectedEvents.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(selectedEvents) { event in
                                EventRow(
                                    event: event,
                                    palette: palette,
                                    isImported: calendarService.importedEventIDs.contains(event.id)
                                ) {
                                    calendarService.importEvent(event, context: context)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }

                    let activeSorted = selected
                        .filter { !$0.completed }
                        .sorted {
                            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                            return $0.createdAt > $1.createdAt
                        }
                    let completedSorted = selected
                        .filter { $0.completed && !$0.isNote }
                        .sorted { $0.createdAt > $1.createdAt }

                    if activeSorted.isEmpty && completedSorted.isEmpty && selectedEvents.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "calendar.badge.checkmark")
                                .font(.system(size: 28)).foregroundStyle(palette.border)
                            Text("No tasks due this day")
                                .font(.system(size: 14)).foregroundStyle(palette.textSec)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(activeSorted) { task in
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
                                            var updated = task.subtasks
                                            updated[idx].completed.toggle()
                                            task.subtasks = updated
                                        }
                                    },
                                    isSelecting: isSelecting,
                                    isSelected: selectedIDs.contains(task.uid),
                                    onSelect: { onToggleSelect(task) },
                                    compact: true
                                )
                                .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10) {
                                    withAnimation(.spring(response: 0.3)) {
                                        isSelecting = true
                                        selectedIDs.insert(task.uid)
                                    }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                }
                            }

                            if !hideCompleted && !completedSorted.isEmpty {
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        showCalCompleted.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: showCalCompleted ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("Completed (\(completedSorted.count))")
                                            .font(.system(size: 13, weight: .medium))
                                        Spacer()
                                    }
                                    .foregroundStyle(palette.textSec)
                                    .padding(.top, 4)
                                }
                                .buttonStyle(.plain)

                                if showCalCompleted {
                                    ForEach(completedSorted) { task in
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
                                                    var updated = task.subtasks
                                                    updated[idx].completed.toggle()
                                                    task.subtasks = updated
                                                }
                                            },
                                            isSelecting: isSelecting,
                                            isSelected: selectedIDs.contains(task.uid),
                                            onSelect: { onToggleSelect(task) },
                                            compact: true
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 130)
        }
        .onAppear { calendarService.refreshStatus() }
    }

    private func neighborOffset(_ task: TaskItem, in items: [TaskItem]) -> CGFloat {
        guard let draggedID = draggingID,
              task.uid != draggedID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }),
              let taskIdx   = items.firstIndex(where: { $0.uid == task.uid }) else { return 0 }
        let rowH: CGFloat = 78
        let steps  = Int((dragOffset / rowH).rounded())
        let target = max(0, min(items.count - 1, draggedIdx + steps))
        if taskIdx > draggedIdx && taskIdx <= target { return -rowH }
        if taskIdx < draggedIdx && taskIdx >= target { return  rowH }
        return 0
    }

    private func finishDrag(in items: [TaskItem], finalOffset: CGFloat) {
        guard let draggedID = draggingID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }) else {
            withAnimation(.spring(response: 0.35)) { draggingID = nil; dragOffset = 0 }
            return
        }
        let rowH: CGFloat = 78
        let steps  = Int((finalOffset / rowH).rounded())
        let target = max(0, min(items.count - 1, draggedIdx + steps))
        var reordered = items
        let moved = reordered.remove(at: draggedIdx)
        reordered.insert(moved, at: target)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            for (i, t) in reordered.enumerated() { t.sortOrder = i }
            draggingID = nil
            dragOffset = 0
        }
    }
}

private struct InboxDayCell: View {
    let day: Date
    let isToday: Bool
    let isSelected: Bool
    let dots: [Color]
    var eventDots: [Color] = []
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    if isSelected { Circle().fill(palette.primary).frame(width: 30, height: 30) }
                    else if isToday { Circle().fill(palette.primaryLight).frame(width: 30, height: 30) }
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.system(size: 13, weight: isToday || isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? palette.onPrimary : isToday ? palette.primary : palette.text)
                }
                .frame(width: 34, height: 34)
                HStack(spacing: 2) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(isSelected ? palette.onPrimary.opacity(0.6) : color)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
                HStack(spacing: 2) {
                    ForEach(Array(eventDots.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isSelected ? palette.onPrimary.opacity(0.5) : color)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(height: 50).frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
