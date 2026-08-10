//
//  ProjectsView.swift
//  Evry
//
//  Projects tab — tappable cards navigate into a full ProjectDetailView with
//  List, Board (Kanban), and Stats view modes. Long-press for multi-select
//  and drag-to-reorder at the project list level.
//

import SwiftUI
import SwiftData
import FoundationModels

// MARK: - AI template output type

@Generable(description: "A project template based on the user's description")
private struct ProjectTemplate {
    @Guide(description: "Short project name, 2–5 words")
    var name: String

    @Guide(description: "SF Symbols icon name, e.g. briefcase.fill, book.fill, heart.fill, cart.fill, house.fill, star.fill, dumbbell.fill, graduationcap.fill, paintbrush.fill, fork.knife")
    var icon: String

    @Guide(description: "Category key — exactly one of: work, personal, health, learning, finance, home")
    var categoryKey: String

    @Guide(description: "6 to 8 actionable starter tasks, each title starting with a verb", .maximumCount(8))
    var tasks: [String]
}

// MARK: - Projects list

struct ProjectsView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(ProjectNavigationState.self) private var projectNavState
    @Query(sort: [SortDescriptor(\Project.sortOrder), SortDescriptor(\Project.createdAt)]) private var projects: [Project]

    @State private var navPath = NavigationPath()
    @State private var isSelectingProjects = false
    @State private var selectedProjectIDs: Set<UUID> = []
    @State private var draggingProjectID: UUID? = nil
    @State private var projectDragOffset: CGFloat = 0

    var body: some View {
        NavigationStack(path: $navPath) {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Projects")
                                .font(.system(size: 34, weight: .heavy))
                                .tracking(-0.5)
                                .foregroundStyle(palette.text)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                        if projects.isEmpty {
                            EmptyStateView(
                                imageName: "GirlLaptopBench",
                                title: "No projects yet",
                                text: "Group related tasks into a project. Pull up below to create one.",
                                palette: palette
                            )
                            .padding(.top, 40)
                        } else {
                            let active = projects.filter { !isAllDone($0) }
                            let completed = projects.filter { isAllDone($0) }

                            VStack(spacing: 12) {
                                ForEach(active) { project in
                                    projectCardRow(project, in: active)
                                }
                                if !completed.isEmpty {
                                    SectionLabel(text: "Completed", palette: palette)
                                    ForEach(completed) { project in
                                        projectCardRow(project, in: completed)
                                            .opacity(0.72)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, isSelectingProjects ? 200 : 130)
                }
                .scrollDisabled(draggingProjectID != nil)
                .scrollDismissesKeyboard(.immediately)

                if isSelectingProjects {
                    MultiSelectBar(
                        selectedCount: selectedProjectIDs.count,
                        palette: palette,
                        onDelete: deleteSelectedProjects,
                        onMove: {},
                        onCancel: cancelProjectSelection,
                        showMove: false
                    )
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelectingProjects)
            .background(palette.bg)
            .navigationDestination(for: Project.self) { project in
                ProjectDetailView(project: project, onEdit: onEdit, onDelete: onDelete)
            }
        }
        .onAppear {
            if projects.count > 1 && projects.allSatisfy({ $0.sortOrder == 0 }) {
                for (i, project) in projects.sorted(by: { $0.createdAt < $1.createdAt }).enumerated() {
                    project.sortOrder = i
                }
            }
        }
        .onChange(of: projectNavState.requestedProject) { _, project in
            guard let project else { return }
            navPath.append(project)
            projectNavState.requestedProject = nil
        }
    }

    // MARK: Card row

    private func projectCardRow(_ project: Project, in list: [Project]) -> some View {
        let isSelf = draggingProjectID == project.uid
        let neighborOff = projectNeighborOffset(project, in: list)
        let isSelected = selectedProjectIDs.contains(project.uid)

        return Button {
            if isSelectingProjects { toggleSelectProject(project) }
            else { navPath.append(project) }
        } label: {
            projectCard(project)
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelf ? 1.02 : 1.0)
        .shadow(color: isSelf ? .black.opacity(0.18) : .clear, radius: isSelf ? 12 : 0, y: isSelf ? 5 : 0)
        .offset(y: isSelf ? projectDragOffset : neighborOff)
        .zIndex(isSelf ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelf)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: neighborOff)
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(isSelected ? palette.primary : .clear, lineWidth: 2.5)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
        )
        .overlay(alignment: .topTrailing) {
            if isSelectingProjects {
                selectionBadge(isSelected: isSelected) { toggleSelectProject(project) }
                    .padding(12)
            }
        }
        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10) {
            guard draggingProjectID == nil else { return }
            withAnimation(.spring(response: 0.3)) {
                isSelectingProjects = true
                selectedProjectIDs.insert(project.uid)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 5, coordinateSpace: .global))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag?):
                        guard !isSelectingProjects else { return }
                        if draggingProjectID == nil {
                            draggingProjectID = project.uid
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        projectDragOffset = drag.translation.height
                    default: break
                    }
                }
                .onEnded { _ in
                    if draggingProjectID != nil { finishProjectDrag(in: list, finalOffset: projectDragOffset) }
                }
        )
    }

    // MARK: Card visual

    private func projectCard(_ project: Project) -> some View {
        let tasks = (project.tasks ?? []).filter { !$0.isTrashed }
        let completable = tasks.filter { !$0.isNote }
        let done = completable.filter(\.completed).count
        let total = completable.count
        let allDone = isAllDone(project)
        let status = timelineStatus(project: project, allDone: allDone)
        let catColor = project.category?.color ?? palette.primary

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(catColor.opacity(palette.dark ? 0.22 : 0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: project.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(catColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .strikethrough(allDone, color: palette.textPh)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(total > 0 ? "\(done)/\(total) tasks" : "No tasks")
                        if let status {
                            Text("·")
                            Text(status.text)
                                .fontWeight(status.overdue || status.soon ? .semibold : .regular)
                                .foregroundStyle(status.overdue ? Palette.danger : status.soon ? palette.primary : palette.textSec)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textPh)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, total > 0 ? 8 : 14)

            if total > 0 {
                ProgressBarView(fraction: Double(done) / Double(total), palette: palette)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .evryCard(palette, cornerRadius: 26)
        .contextMenu {
            Button(role: .destructive) { withAnimation { context.delete(project) } } label: {
                Label("Delete Project", systemImage: "trash")
            }
        }
    }

    // MARK: Helpers

    private func isAllDone(_ project: Project) -> Bool {
        let completable = (project.tasks ?? []).filter { !$0.isTrashed && !$0.isNote }
        return !completable.isEmpty && completable.allSatisfy(\.completed)
    }

    private func selectionBadge(isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isSelected ? palette.primary : palette.card)
                Circle().strokeBorder(isSelected ? palette.primary : palette.border, lineWidth: 2)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
    }

    private func projectNeighborOffset(_ project: Project, in items: [Project]) -> CGFloat {
        guard let draggedID = draggingProjectID, project.uid != draggedID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }),
              let projectIdx = items.firstIndex(where: { $0.uid == project.uid }) else { return 0 }
        let rowH: CGFloat = 100
        let steps = Int((projectDragOffset / rowH).rounded())
        let targetIdx = max(0, min(items.count - 1, draggedIdx + steps))
        if projectIdx > draggedIdx && projectIdx <= targetIdx { return -rowH }
        if projectIdx < draggedIdx && projectIdx >= targetIdx { return rowH }
        return 0
    }

    private func finishProjectDrag(in items: [Project], finalOffset: CGFloat) {
        guard let draggedID = draggingProjectID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }) else {
            withAnimation(.spring(response: 0.35)) { draggingProjectID = nil; projectDragOffset = 0 }
            return
        }
        let steps = Int((finalOffset / 100).rounded())
        let targetIdx = max(0, min(items.count - 1, draggedIdx + steps))
        var reordered = items
        let moved = reordered.remove(at: draggedIdx)
        reordered.insert(moved, at: targetIdx)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            for (i, p) in reordered.enumerated() { p.sortOrder = i }
            draggingProjectID = nil; projectDragOffset = 0
        }
    }

    private func toggleSelectProject(_ project: Project) {
        withAnimation(.spring(response: 0.2)) {
            if selectedProjectIDs.contains(project.uid) { selectedProjectIDs.remove(project.uid) }
            else { selectedProjectIDs.insert(project.uid) }
        }
    }

    private func cancelProjectSelection() {
        withAnimation(.spring(response: 0.3)) { isSelectingProjects = false; selectedProjectIDs = [] }
    }

    private func deleteSelectedProjects() {
        let toDelete = projects.filter { selectedProjectIDs.contains($0.uid) }
        cancelProjectSelection()
        for project in toDelete { withAnimation { context.delete(project) } }
    }
}

// MARK: - Project detail

struct ProjectDetailView: View {
    @Bindable var project: Project
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(ProjectNavigationState.self) private var projectNavState

    @State private var viewMode: DetailMode = .list
    @State private var showEditProject = false
    @State private var showCompletedTasks = true
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showProjectPicker = false
    @State private var draggingID: UUID? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var sortOption: SortOption = .manual
    @State private var celebratingProjectID: UUID? = nil
    @State private var showCompletionPopup = false
    @State private var completionAnimating = false
    @State private var showAIProject = false

    enum DetailMode: String, CaseIterable {
        case list = "List", board = "Board", stats = "Stats"
        var icon: String {
            switch self { case .list: "list.bullet"; case .board: "rectangle.split.3x1"; case .stats: "chart.bar" }
        }
    }

    enum SortOption: String, CaseIterable {
        case manual = "Manual", dueDate = "Due Date", priority = "Priority", title = "Title"
    }

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var catColor: Color { project.category?.color ?? palette.primary }

    private var liveTasks: [TaskItem] { (project.tasks ?? []).filter { !$0.isTrashed } }
    private var completable: [TaskItem] { liveTasks.filter { !$0.isNote } }
    private var noteItems: [TaskItem] { liveTasks.filter { $0.isNote } }

    private var todoTasks: [TaskItem] {
        let unsorted = completable.filter { !$0.completed }
        switch sortOption {
        case .manual:    return unsorted.sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.createdAt > $1.createdAt }
        case .dueDate:   return unsorted.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        case .priority:  return unsorted.sorted { $0.priority.rank < $1.priority.rank }
        case .title:     return unsorted.sorted { $0.title < $1.title }
        }
    }

    private var doneTasks: [TaskItem] {
        completable.filter { $0.completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private var overdueTasks: [TaskItem] {
        let today = Calendar.current.startOfDay(for: Date())
        return todoTasks.filter { d in d.dueDate != nil && d.dueDate! < today }
    }

    private var urgentTasks: [TaskItem] {
        let soon = addDays(Date(), 2)
        return todoTasks.filter { d in
            guard let due = d.dueDate else { return false }
            return due <= soon
        }
    }

    private var futureTasks: [TaskItem] {
        let soon = addDays(Date(), 2)
        return todoTasks.filter { d in
            guard let due = d.dueDate else { return true }
            return due > soon
        }
    }

    private var completion: Double {
        guard !completable.isEmpty else { return 0 }
        return Double(doneTasks.count) / Double(completable.count)
    }

    private var velocity: Int {
        let cutoff = addDays(Date(), -7)
        return doneTasks.filter { ($0.completedAt ?? .distantPast) >= cutoff }.count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    headerSection
                    modePickerBar
                        .padding(.top, 4)

                    Group {
                        switch viewMode {
                        case .list:  listContent
                        case .board: boardContent
                        case .stats: statsContent
                        }
                    }
                    .padding(.bottom, isSelecting ? 220 : 60)
                }
            }
            .scrollDismissesKeyboard(.immediately)

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

            if showCompletionPopup {
                completionPopupOverlay
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .zIndex(20)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelecting)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: showCompletionPopup)
        .onChange(of: completion) { oldVal, newVal in
            if newVal >= 1.0 && oldVal < 1.0 && !completable.isEmpty {
                showCompletionPopup = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { completionAnimating = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.easeOut(duration: 0.35)) { showCompletionPopup = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completionAnimating = false }
                }
            }
        }
        .background(palette.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showEditProject = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textSec)
                }
            }
            if viewMode == .list {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { opt in
                            Button { sortOption = opt } label: {
                                HStack {
                                    Text(opt.rawValue)
                                    if sortOption == opt { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.textSec)
                    }
                }
            }
        }
        .sheet(isPresented: $showEditProject) { EditProjectSheet(project: project) }
        .sheet(isPresented: $showProjectPicker) {
            ProjectPickerSheet(palette: palette, onSelect: moveSelectedToProject)
        }
        .sheet(isPresented: $showAIProject) { AIProjectSheet(targetProject: project) }
        .onAppear { projectNavState.activeProject = project }
        .onDisappear { if projectNavState.activeProject?.uid == project.uid { projectNavState.activeProject = nil } }
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(catColor)
                .frame(height: 4)
                .ignoresSafeArea(edges: .horizontal)

            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(catColor.opacity(palette.dark ? 0.25 : 0.15))
                            .frame(width: 56, height: 56)
                        Image(systemName: project.icon)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(catColor)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.name)
                            .font(.system(size: 28, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(palette.text)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            Label(project.status.label, systemImage: project.status.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(project.status.tint)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(project.status.tint.opacity(0.12), in: Capsule())

                            if let due = project.dueDate {
                                let status = timelineStatus(project: project, allDone: completion == 1)
                                Text(status?.text ?? "Due \(due.formatted(.dateTime.month().day()))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(status?.overdue == true ? Palette.danger : palette.textSec)
                            }
                        }
                    }

                    Spacer()

                    if SystemLanguageModel.default.isAvailable {
                        Button { showAIProject = true } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(catColor)
                                .frame(width: 34, height: 34)
                                .background(catColor.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(PressScaleStyle())
                    }

                    completionRing(size: 52, lineWidth: 5)
                }

                HStack(spacing: 0) {
                    statPill(value: "\(todoTasks.count)", label: "To Do", color: palette.primary)
                    statPill(value: "\(doneTasks.count)", label: "Done", color: Palette.success)
                    statPill(value: "\(overdueTasks.count)", label: "Overdue", color: overdueTasks.isEmpty ? palette.textSec : Palette.danger)
                    statPill(value: "\(velocity)", label: "This Week", color: palette.textSec)
                }
                .evryCard(palette, cornerRadius: 14)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func completionRing(size: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle().stroke(palette.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: completion)
                .stroke(catColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: completion)
            Text("\(Int(completion * 100))%")
                .font(.system(size: size * 0.2, weight: .bold))
                .foregroundStyle(palette.text)
        }
        .frame(width: size, height: size)
    }

    private func statPill(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.textSec)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: Mode picker

    private var modePickerBar: some View {
        HStack(spacing: 0) {
            ForEach(DetailMode.allCases, id: \.self) { mode in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewMode = mode } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(mode.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(viewMode == mode ? catColor : palette.textSec)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        viewMode == mode ? catColor.opacity(palette.dark ? 0.18 : 0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: List view

    private var listContent: some View {
        VStack(spacing: 0) {
            if todoTasks.isEmpty && doneTasks.isEmpty && noteItems.isEmpty {
                emptyProjectState
            } else {
                if todoTasks.isEmpty && doneTasks.isEmpty {
                    // Only notes remain — skip the "all complete" banner
                } else if todoTasks.isEmpty {
                    Text("All tasks complete!")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.success)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 8) {
                        ForEach(todoTasks) { task in
                            taskRow(task: task, in: todoTasks)
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: todoTasks.map(\.uid))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }

                if !doneTasks.isEmpty {
                    completedSection
                }

                if !noteItems.isEmpty {
                    taskNotesSection
                }

                notesSection
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
        }
    }

    private var taskNotesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Notes", palette: palette)
                .padding(.horizontal, 20)
            VStack(spacing: 8) {
                ForEach(noteItems) { task in
                    taskRow(task: task, in: noteItems)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 16)
    }

    private var completedSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showCompletedTasks.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: showCompletedTasks ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Completed · \(doneTasks.count)")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(palette.textSec)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showCompletedTasks {
                VStack(spacing: 8) {
                    ForEach(doneTasks) { task in
                        TaskRowView(
                            task: task, palette: palette,
                            onToggle: { withAnimation { TaskActions.toggle(task, context: context) } },
                            onEdit: { onEdit(task) },
                            onDelete: { onDelete(task) },
                            onToggleSubtask: { subtask in
                                if let idx = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                                    var updated = task.subtasks; updated[idx].completed.toggle(); task.subtasks = updated
                                }
                            },
                            isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(task.uid),
                            onSelect: { toggleSelect(task) },
                            compact: true
                        )
                        .opacity(0.65)
                    }
                }
                .padding(.horizontal, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
    }

    private func taskRow(task: TaskItem, in list: [TaskItem]) -> some View {
        let isSelf = draggingID == task.uid
        let neighborOff = neighborOffset(task, in: list)

        return TaskRowView(
            task: task, palette: palette,
            onToggle: { withAnimation { TaskActions.toggle(task, context: context) } },
            onEdit: { onEdit(task) },
            onDelete: { onDelete(task) },
            onToggleSubtask: { subtask in
                if let idx = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                    var updated = task.subtasks; updated[idx].completed.toggle(); task.subtasks = updated
                }
            },
            isSelecting: isSelecting,
            isSelected: selectedIDs.contains(task.uid),
            onSelect: { toggleSelect(task) },
            compact: true
        )
        .scaleEffect(isSelf ? 1.04 : 1.0)
        .shadow(color: isSelf ? .black.opacity(0.2) : .clear, radius: isSelf ? 14 : 0, y: isSelf ? 6 : 0)
        .offset(y: isSelf ? dragOffset : neighborOff)
        .zIndex(isSelf ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelf)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: neighborOff)
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.96))))
        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 10) {
            guard draggingID == nil else { return }
            withAnimation(.spring(response: 0.3)) { isSelecting = true; selectedIDs.insert(task.uid) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 5, coordinateSpace: .global))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag?):
                        guard !isSelecting, sortOption == .manual else { return }
                        if draggingID == nil { draggingID = task.uid; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                        dragOffset = drag.translation.height
                    default: break
                    }
                }
                .onEnded { _ in if draggingID != nil { finishDrag(in: list, finalOffset: dragOffset) } }
        )
    }

    // MARK: Board view (Kanban)

    private var boardContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                kanbanColumn(title: "To Do", tasks: futureTasks, color: palette.primary, icon: "circle")
                kanbanColumn(title: "Urgent", tasks: urgentTasks, color: Palette.warning, icon: "exclamationmark.circle.fill")
                kanbanColumn(title: "Done", tasks: doneTasks, color: Palette.success, icon: "checkmark.circle.fill")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func kanbanColumn(title: String, tasks: [TaskItem], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Spacer()
                Text("\(tasks.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.border, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(color.opacity(palette.dark ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            if tasks.isEmpty {
                Text("No tasks")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPh)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
            } else {
                VStack(spacing: 6) {
                    ForEach(tasks) { task in
                        boardTaskCard(task)
                    }
                }
            }
        }
        .frame(width: 200)
    }

    private func boardTaskCard(_ task: TaskItem) -> some View {
        Button {
            withAnimation { TaskActions.toggle(task, context: context) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(task.completed ? Palette.success : palette.textPh)
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.text)
                        .strikethrough(task.completed, color: palette.textPh)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }

                HStack(spacing: 6) {
                    if task.priority != .normal, let chip = task.priority.chipLabel {
                        Text(chip)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.primary.opacity(0.12), in: Capsule())
                    }
                    if let due = task.dueDate {
                        Text(due.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 10))
                            .foregroundStyle(due < Date() && !task.completed ? Palette.danger : palette.textSec)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: Stats view

    private var statsContent: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(palette.border, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: completion)
                    .stroke(catColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.7, dampingFraction: 0.75), value: completion)
                VStack(spacing: 2) {
                    Text("\(Int(completion * 100))%")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text("Complete")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                }
            }
            .frame(width: 160, height: 160)
            .padding(.top, 20)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                metricCard(value: "\(todoTasks.count)", label: "Remaining", icon: "circle", color: palette.primary)
                metricCard(value: "\(doneTasks.count)", label: "Completed", icon: "checkmark.circle.fill", color: Palette.success)
                metricCard(value: "\(overdueTasks.count)", label: "Overdue", icon: "exclamationmark.circle.fill", color: overdueTasks.isEmpty ? palette.textSec : Palette.danger)
                metricCard(value: "\(velocity)", label: "Done This Week", icon: "flame.fill", color: velocity > 0 ? Palette.warning : palette.textSec)
            }
            .padding(.horizontal, 20)

            if let due = project.dueDate {
                let diff = Calendar.current.dateComponents([.day], from: startOfDay(Date()), to: startOfDay(due)).day ?? 0
                HStack(spacing: 14) {
                    Image(systemName: diff < 0 ? "exclamationmark.triangle.fill" : "calendar")
                        .font(.system(size: 22))
                        .foregroundStyle(diff < 0 ? Palette.danger : palette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diff < 0 ? "Overdue by \(abs(diff)) day\(abs(diff) == 1 ? "" : "s")" : diff == 0 ? "Due today" : "\(diff) day\(diff == 1 ? "" : "s") remaining")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(diff <= 0 ? Palette.danger : palette.text)
                        Text("Due \(due.formatted(.dateTime.weekday(.wide).month().day()))")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSec)
                    }
                    Spacer()
                }
                .padding(16)
                .evryCard(palette, cornerRadius: 24)
                .padding(.horizontal, 20)
            }

            if !project.projectDescription.isEmpty {
                notesSection.padding(.horizontal, 20)
            }
        }
        .padding(.top, 12)
    }

    private func metricCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(palette.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .evryCard(palette, cornerRadius: 24)
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "note.text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSec)
                Text("Notes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                Spacer()
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $project.projectDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72)
                if project.projectDescription.isEmpty {
                    Text("Add notes, links, or context for this project…")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textPh)
                        .allowsHitTesting(false)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
            }
            .padding(12)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        }
    }

    // MARK: Completion popup

    private var completionPopupOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.35)) { showCompletionPopup = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completionAnimating = false }
                }

            VStack(spacing: 20) {
                ZStack {
                    ForEach(0..<8, id: \.self) { i in
                        let angle = Double(i) * 45
                        let colors: [Color] = [Palette.success, .cyan, .blue, .purple, .pink, Palette.warning, Color(hex: 0x22C55E), Color(hex: 0xEC4899)]
                        Circle()
                            .fill(colors[i])
                            .frame(width: 10, height: 10)
                            .offset(
                                x: completionAnimating ? cos(angle * .pi / 180) * 64 : 0,
                                y: completionAnimating ? sin(angle * .pi / 180) * 64 : 0
                            )
                            .scaleEffect(completionAnimating ? 1 : 0.1)
                            .opacity(completionAnimating ? 1 : 0)
                    }

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Palette.success)
                        .scaleEffect(completionAnimating ? 1 : 0.1)
                        .opacity(completionAnimating ? 1 : 0)
                }
                .frame(width: 160, height: 160)

                VStack(spacing: 8) {
                    Text("Project Complete!")
                        .font(.system(size: 24, weight: .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(palette.text)
                    Text("All tasks done — great work!")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textSec)
                }

                Button {
                    withAnimation(.easeOut(duration: 0.35)) { showCompletionPopup = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { completionAnimating = false }
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 12)
                        .background(Palette.success, in: Capsule())
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(32)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 12)
            .padding(.horizontal, 32)
        }
    }

    // MARK: Empty state

    private var emptyProjectState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(palette.textPh)
            Text("No tasks yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.textSec)
            Text("Tap + in the Inbox to add tasks here")
                .font(.system(size: 14))
                .foregroundStyle(palette.textPh)
        }
        .padding(.top, 60)
    }

    // MARK: Task drag + multi-select

    private func neighborOffset(_ task: TaskItem, in items: [TaskItem]) -> CGFloat {
        guard let draggedID = draggingID, task.uid != draggedID,
              let draggedIdx = items.firstIndex(where: { $0.uid == draggedID }),
              let taskIdx = items.firstIndex(where: { $0.uid == task.uid }) else { return 0 }
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
        let steps = Int((finalOffset / 78).rounded())
        let targetIdx = max(0, min(items.count - 1, draggedIdx + steps))
        var reordered = items
        let moved = reordered.remove(at: draggedIdx)
        reordered.insert(moved, at: targetIdx)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            for (i, t) in reordered.enumerated() { t.sortOrder = i }
            draggingID = nil; dragOffset = 0
        }
    }

    private func toggleSelect(_ task: TaskItem) {
        withAnimation(.spring(response: 0.2)) {
            if selectedIDs.contains(task.uid) { selectedIDs.remove(task.uid) }
            else { selectedIDs.insert(task.uid) }
        }
    }

    private func cancelSelection() {
        withAnimation(.spring(response: 0.3)) { isSelecting = false; selectedIDs = [] }
    }

    private func deleteSelected() {
        let toDelete = (project.tasks ?? []).filter { selectedIDs.contains($0.uid) }
        cancelSelection()
        for task in toDelete { onDelete(task) }
    }

    private func moveSelectedToProject(_ target: Project?) {
        for task in (project.tasks ?? []) where selectedIDs.contains(task.uid) { task.project = target }
        cancelSelection()
    }
}

// MARK: - Edit project sheet

private struct EditProjectSheet: View {
    @Bindable var project: Project
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @State private var hasDueDate: Bool
    @State private var dueDate: Date

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private let icons = [
        "folder", "briefcase", "book.closed", "star", "heart", "flame",
        "house", "globe", "dollarsign.circle", "figure.run",
        "pencil", "camera", "music.note", "gamecontroller",
        "car", "airplane", "graduationcap", "wrench.and.screwdriver",
        "fork.knife", "lightbulb", "trophy", "target", "leaf", "megaphone"
    ]

    init(project: Project) {
        self.project = project
        self._hasDueDate = State(initialValue: project.dueDate != nil)
        self._dueDate = State(initialValue: project.dueDate ?? addDays(Date(), 7))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Project name", text: $project.name)
                }

                Section("Icon") {
                    let catColor = project.category?.color ?? palette.primary
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(icons, id: \.self) { icon in
                            Button { project.icon = icon } label: {
                                Image(systemName: icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(project.icon == icon ? .white : catColor)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        project.icon == icon ? catColor : catColor.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Color") {
                    HStack(spacing: 10) {
                        ForEach(ProjectCategory.all) { cat in
                            Button { project.categoryKey = project.categoryKey == cat.key ? nil : cat.key } label: {
                                Circle()
                                    .fill(cat.color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if project.categoryKey == cat.key {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                }

                Section("Status") {
                    Picker("Status", selection: $project.status) {
                        ForEach(ProjectStatus.allCases) { s in
                            Label(s.label, systemImage: s.icon).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(palette.primary)
                }

                Section("Timeline") {
                    Toggle("Due Date", isOn: $hasDueDate.animation())
                        .tint(palette.primary)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                }

                Section("Description") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $project.projectDescription)
                            .frame(minHeight: 80)
                        if project.projectDescription.isEmpty {
                            Text("Notes, goals, or context…")
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                    }
                }
            }
            .navigationTitle("Edit Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        project.dueDate = hasDueDate ? dueDate : nil
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}

// MARK: - Project picker sheet (move tasks to another project)

private struct ProjectPickerSheet: View {
    let palette: Palette
    var onSelect: (Project?) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @Query(sort: \Project.sortOrder) private var projects: [Project]

    private var effectivePalette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    Label("Inbox (no project)", systemImage: "tray").foregroundStyle(effectivePalette.text)
                }
                ForEach(projects) { project in
                    Button {
                        onSelect(project)
                        dismiss()
                    } label: {
                        Label(project.name, systemImage: project.icon).foregroundStyle(effectivePalette.text)
                    }
                }
            }
            .navigationTitle("Move to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(effectivePalette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}

// MARK: - Completion celebration border

// MARK: - AI Project Sheet

private struct AIProjectSheet: View {
    var targetProject: Project? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var speech = LiveSpeechInput()
    @State private var description = ""
    @State private var phase: Phase = .input
    @State private var projectName = ""
    @State private var generatedIcon = "folder"
    @State private var generatedCategoryKey = "work"
    @State private var taskList: [String] = []
    @State private var errorMessage = ""

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var catColor: Color { ProjectCategory.byKey(generatedCategoryKey)?.color ?? palette.primary }

    private enum Phase { case input, generating, preview }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input:      inputView
                case .generating: generatingView
                case .preview:    previewView
                }
            }
            .navigationTitle(targetProject != nil ? "AI Tasks" : (phase == .preview ? "AI Template" : "Evry Plan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .preview ? "Back" : "Cancel") {
                        if phase == .preview { withAnimation { phase = .input } }
                        else { speech.stop(); dismiss() }
                    }
                }
                if phase == .preview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(targetProject != nil ? "Add Tasks" : "Create") {
                            if targetProject != nil { addTasksToProject() } else { createProject() }
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { description = t } }
        .onDisappear { speech.stop() }
    }

    // MARK: Input

    private var inputView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(targetProject != nil ? "DESCRIBE THE TASKS" : "DESCRIBE YOUR PROJECT")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(palette.textSec)
                        .padding(.horizontal, 4)

                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text(targetProject != nil ? "Describe tasks to add to this project…" : "e.g. \"Plan our product launch for next month\"")
                                .font(.system(size: 15))
                                .foregroundStyle(palette.textPh)
                                .padding(.top, 14)
                                .padding(.horizontal, 14)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $description)
                            .font(.system(size: 15))
                            .foregroundStyle(palette.text)
                            .frame(minHeight: 110)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .scrollContentBackground(.hidden)
                    }
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                }

                // Voice dictation button
                VStack(spacing: 10) {
                    Button {
                        if speech.isListening { speech.stop() }
                        else { description = ""; speech.toggle() }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(speech.isListening ? Palette.danger.opacity(0.12) : palette.primaryLight)
                                .frame(width: 72, height: 72)
                            if speech.isListening {
                                Circle()
                                    .strokeBorder(Palette.danger, lineWidth: 1.5)
                                    .frame(width: 72, height: 72)
                                    .opacity(0.5)
                            }
                            Image(systemName: speech.isListening ? "stop.fill" : "mic.fill")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(speech.isListening ? Palette.danger : palette.primary)
                        }
                    }
                    .buttonStyle(PressScaleStyle())

                    Text(speech.isListening ? "Listening… tap to stop" : "Or describe by voice")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSec)
                }
                .frame(maxWidth: .infinity)

                if speech.permissionDenied {
                    Label("Enable Speech Recognition in Settings to use voice input.", systemImage: "mic.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                }

                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.danger)
                        .multilineTextAlignment(.center)
                }

                let trimmed = description.trimmingCharacters(in: .whitespaces)
                Button { generate() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text(targetProject != nil ? "Generate Tasks" : "Generate Template")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(trimmed.isEmpty ? palette.border : palette.primary,
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .disabled(trimmed.isEmpty)
            }
            .padding(20)
        }
        .background(palette.bg)
    }

    // MARK: Generating

    private var generatingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().scaleEffect(1.4).tint(palette.primary)
            Text("Apple Intelligence is thinking…")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.text)
            Text("Building your project template")
                .font(.system(size: 14))
                .foregroundStyle(palette.textSec)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(palette.bg)
    }

    // MARK: Preview

    private var previewView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                if targetProject == nil {
                    previewProjectCard
                }
                previewTaskSection
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .background(palette.bg)
    }

    private var previewProjectCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(catColor.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: generatedIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(catColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                TextField("Project name", text: $projectName)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(palette.text)
                if let cat = ProjectCategory.byKey(generatedCategoryKey) {
                    Text(cat.label)
                        .font(.system(size: 12))
                        .foregroundStyle(catColor)
                }
            }
        }
        .padding(16)
        .evryCard(palette, cornerRadius: 26)
    }

    private var previewTaskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STARTER TASKS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textSec)
                Spacer()
                Text("\(taskList.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(taskList.enumerated()), id: \.offset) { i, task in
                    previewTaskRow(title: task, index: i)
                }
            }
            .evryCard(palette, cornerRadius: 24)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            Text("Tap × to remove tasks before creating.")
                .font(.system(size: 12))
                .foregroundStyle(palette.textPh)
                .padding(.horizontal, 4)
        }
    }

    private func previewTaskRow(title: String, index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(palette.border, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.text)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        taskList = taskList.enumerated().filter { $0.offset != index }.map(\.element)
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
            if index < taskList.count - 1 {
                Divider().padding(.leading, 46)
            }
        }
    }

    // MARK: Actions

    private func generate() {
        speech.stop()
        let prompt = description.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        errorMessage = ""
        withAnimation { phase = .generating }

        Task {
            do {
                let instructions: String
                let userPrompt: String
                if let proj = targetProject {
                    instructions = """
                        You are a project planning assistant. Given a brief description, \
                        generate concise actionable task titles for an existing project.
                        Each task title must start with a verb.
                        """
                    userPrompt = "Generate tasks for the project \"\(proj.name)\": \(prompt)"
                } else {
                    instructions = """
                        You are a project planning assistant. Given a brief goal description, \
                        generate a practical project template with a clear name, a relevant \
                        SF Symbols icon, a category, and concise actionable task titles.
                        Each task title must start with a verb.
                        """
                    userPrompt = "Create a project template for: \(prompt)"
                }
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: userPrompt,
                    generating: ProjectTemplate.self
                )
                let t = response.content
                let safeIcon = UIImage(systemName: t.icon) != nil ? t.icon : "folder"
                let safeCat: String
                if let proj = targetProject, let key = proj.categoryKey {
                    safeCat = key
                } else {
                    safeCat = ProjectCategory.all.first(where: { $0.key == t.categoryKey })?.key ?? "work"
                }
                await MainActor.run {
                    projectName = targetProject?.name ?? t.name
                    generatedIcon = targetProject?.icon ?? safeIcon
                    generatedCategoryKey = safeCat
                    taskList = t.tasks
                    withAnimation { phase = .preview }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't generate. Try a more detailed description."
                    withAnimation { phase = .input }
                }
            }
        }
    }

    private func createProject() {
        let name = projectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let project = Project(name: name, categoryKey: generatedCategoryKey)
        project.icon = generatedIcon
        context.insert(project)
        for (i, title) in taskList.enumerated() {
            let task = TaskItem(title: title, project: project)
            task.sortOrder = i
            context.insert(task)
        }
        dismiss()
    }

    private func addTasksToProject() {
        guard let proj = targetProject else { return }
        let existingCount = (proj.tasks ?? []).filter { !$0.isTrashed }.count
        for (i, title) in taskList.enumerated() {
            let task = TaskItem(title: title, project: proj)
            task.sortOrder = existingCount + i
            context.insert(task)
        }
        dismiss()
    }
}

struct ProjectCompletionBorder: View {
    let cornerRadius: CGFloat
    var onFinished: () -> Void

    @State private var trim: CGFloat = 0
    @State private var rotation: Double = 0
    @State private var opacity: Double = 1

    private let colors: [Color] = [Palette.success, .cyan, .blue, .purple, .pink, Palette.warning, Palette.success]

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .trim(from: 0, to: trim)
            .stroke(AngularGradient(colors: colors, center: .center, angle: .degrees(rotation)),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            .shadow(color: Palette.success.opacity(0.5), radius: 6)
            .opacity(opacity)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { trim = 1 }
                withAnimation(.linear(duration: 1.5)) { rotation = 540 }
                withAnimation(.easeIn(duration: 0.4).delay(1.15)) { opacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onFinished() }
            }
    }
}

// MARK: - Add Project sheet

struct AddProjectSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedIcon = "folder"
    @State private var projectDescription = ""
    @State private var categoryKey: String?
    @State private var status: ProjectStatus = .active
    @State private var hasTimeline = false
    @State private var startDate = startOfDay(Date())
    @State private var dueDate = addDays(Date(), 7)
    @FocusState private var nameFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private let suggestedIcons = [
        "folder", "briefcase.fill", "book.fill", "heart.fill", "cart.fill",
        "house.fill", "star.fill", "dumbbell.fill", "graduationcap.fill",
        "paintbrush.fill", "fork.knife", "airplane", "car.fill", "music.note",
        "camera.fill", "gamecontroller.fill", "laptopcomputer", "chart.bar.fill",
        "leaf.fill", "building.2.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "dollarsign.circle.fill", "globe", "map.fill", "person.2.fill",
        "lightbulb.fill", "sparkles", "trophy.fill", "target",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .focused($nameFocused)
                    TextField("Description (optional)", text: $projectDescription, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(suggestedIcons, id: \.self) { icon in
                            Button {
                                selectedIcon = icon
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(selectedIcon == icon ? palette.primary : Color(.systemGray5))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: icon)
                                        .font(.system(size: 17))
                                        .foregroundStyle(selectedIcon == icon ? .white : palette.text)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section("Color") {
                    HStack(spacing: 10) {
                        ForEach(ProjectCategory.all) { category in
                            Button {
                                categoryKey = categoryKey == category.key ? nil : category.key
                            } label: {
                                Circle()
                                    .fill(category.color)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if categoryKey == category.key {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    Picker("Status", selection: $status) {
                        ForEach(ProjectStatus.allCases) { s in
                            Label(s.label, systemImage: s.icon).tag(s)
                        }
                    }
                }

                Section {
                    Toggle("Timeline", isOn: $hasTimeline.animation())
                        .tint(palette.primary)
                    if hasTimeline {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let project = Project(
                            name: name.trimmingCharacters(in: .whitespaces),
                            categoryKey: categoryKey,
                            startDate: hasTimeline ? startDate : nil,
                            dueDate: hasTimeline ? dueDate : nil
                        )
                        project.icon = selectedIcon
                        project.projectDescription = projectDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        project.status = status
                        context.insert(project)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .onAppear { nameFocused = true }
    }
}

// MARK: - Project completion burst

private struct ProjectCompletionBurst: View {
    let palette: Palette
    @State private var animating = false
    @State private var fading = false

    private let particleAngles: [Double] = [0, 45, 90, 135, 180, 225, 270, 315]
    private let particleColors: [Color] = [
        Color(hex: 0x22C55E), Color(hex: 0xF59E0B), Color(hex: 0x6366F1),
        Color(hex: 0xEC4899), Color(hex: 0x22C55E), Color(hex: 0xF59E0B),
        Color(hex: 0x6366F1), Color(hex: 0xEC4899),
    ]

    var body: some View {
        ZStack {
            Color(hex: 0x22C55E).opacity(fading ? 0 : (animating ? 0.1 : 0))

            ForEach(0..<8, id: \.self) { i in
                let angle = particleAngles[i]
                Circle()
                    .fill(particleColors[i])
                    .frame(width: 9, height: 9)
                    .offset(
                        x: animating ? cos(angle * .pi / 180) * 52 : 0,
                        y: animating ? sin(angle * .pi / 180) * 52 : 0
                    )
                    .opacity(fading ? 0 : (animating ? 1 : 0))
                    .scaleEffect(fading ? 0.3 : 1)
            }

            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Color(hex: 0x22C55E))
                    .scaleEffect(animating ? 1 : 0.1)
                    .opacity(fading ? 0 : (animating ? 1 : 0))
                Text("Complete!")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: 0x22C55E))
                    .opacity(fading ? 0 : (animating ? 1 : 0))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { animating = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.5)) { fading = true }
            }
        }
    }
}
