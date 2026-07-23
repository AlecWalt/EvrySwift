//
//  ProjectsView.swift
//  Evry
//
//  Projects tab — expandable project cards with category color, timeline
//  status and progress bar. The nested quick-add sits at the TOP of the
//  expanded card so newly added tasks appear directly beneath it and animate
//  in without the input field ever having to relocate.
//

import SwiftUI
import SwiftData

struct ProjectsView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var openProjectID: UUID?
    @State private var addingToProject: Project?

    private func liveTasks(_ project: Project) -> [TaskItem] {
        (project.tasks ?? []).filter { !$0.isTrashed }.sorted { $0.createdAt > $1.createdAt }
    }

    private func isAllDone(_ project: Project) -> Bool {
        let completable = liveTasks(project).filter { !$0.isNote }
        return !completable.isEmpty && completable.allSatisfy(\.completed)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text("Projects")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(palette.text)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                let active = projects.filter { !isAllDone($0) }
                let completed = projects.filter { isAllDone($0) }

                if projects.isEmpty {
                    EmptyStateView(
                        imageName: "GirlEmptyState",
                        title: "No projects yet",
                        text: "Group related tasks into a project. Pull up below to create one.",
                        palette: palette
                    )
                    .padding(.top, 40)
                } else {
                    VStack(spacing: 12) {
                        ForEach(active) { project in
                            projectCard(project)
                        }
                        if !completed.isEmpty {
                            SectionLabel(text: "Completed", palette: palette)
                            ForEach(completed) { project in
                                projectCard(project)
                                    .opacity(0.72)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 130)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(palette.bg)
        .sheet(item: $addingToProject) { project in
            AddTaskSheet(project: project)
        }
    }

    // MARK: Card

    private func projectCard(_ project: Project) -> some View {
        let tasks = liveTasks(project)
        let completable = tasks.filter { !$0.isNote }
        let done = completable.filter(\.completed).count
        let total = completable.count
        let allDone = isAllDone(project)
        let status = timelineStatus(project: project, allDone: allDone)
        let isOpen = openProjectID == project.uid
        let categoryColor = project.category?.color ?? palette.primary

        return VStack(spacing: 0) {
            projectHeader(
                project: project,
                categoryColor: categoryColor,
                done: done,
                total: total,
                allDone: allDone,
                status: status,
                isOpen: isOpen
            )

            if total > 0 {
                ProgressBarView(fraction: Double(done) / Double(total), palette: palette)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }

            if isOpen {
                expandedBody(project: project, tasks: tasks)
            }
        }
        .evryCard(palette, cornerRadius: 18)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation {
                    context.delete(project)
                }
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
        }
    }

    private func projectHeader(
        project: Project,
        categoryColor: Color,
        done: Int,
        total: Int,
        allDone: Bool,
        status: TimelineStatus?,
        isOpen: Bool
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                openProjectID = isOpen ? nil : project.uid
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(categoryColor)
                    .frame(width: 36, height: 36)
                    .background(categoryColor.opacity(palette.dark ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

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

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.textSec)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(14)
        }
        .buttonStyle(.plain)
    }

    // MARK: Expanded body — tasks, then a colored "Add task" bar centered below.

    private func expandedBody(project: Project, tasks: [TaskItem]) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                ForEach(sortPinnedFirst(tasks)) { task in
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
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tasks.map(\.uid))

            addTaskBar(project: project)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Colored pill at the bottom-center of an open card. Tapping opens the normal
    /// add-task sheet with this project preselected.
    private func addTaskBar(project: Project) -> some View {
        let color = project.category?.color ?? palette.primary
        return Button {
            addingToProject = project
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                Text("Add task")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(color.opacity(palette.dark ? 0.22 : 0.12), in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Completion celebration

/// A one-shot celebratory border: colored lines sweep around the card's outline
/// (an angular gradient stroke that draws on and rotates) then fade out. Calls
/// `onFinished` when done so the parent can clear its trigger state.
struct ProjectCompletionBorder: View {
    let cornerRadius: CGFloat
    var onFinished: () -> Void

    @State private var trim: CGFloat = 0
    @State private var rotation: Double = 0
    @State private var opacity: Double = 1

    private let colors: [Color] = [
        Palette.success, .cyan, .blue, .purple, .pink, Palette.warning, Palette.success
    ]

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .trim(from: 0, to: trim)
            .stroke(
                AngularGradient(colors: colors, center: .center, angle: .degrees(rotation)),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
            )
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
    @State private var categoryKey: String?
    @State private var hasTimeline = false
    @State private var startDate = startOfDay(Date())
    @State private var dueDate = addDays(Date(), 7)
    @FocusState private var nameFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .focused($nameFocused)
                }

                Section("Color") {
                    HStack(spacing: 8) {
                        ForEach(ProjectCategory.all) { category in
                            Button {
                                categoryKey = categoryKey == category.key ? nil : category.key
                            } label: {
                                Circle()
                                    .fill(category.color)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if categoryKey == category.key {
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

                Section {
                    Toggle("Timeline", isOn: $hasTimeline.animation())
                        .tint(palette.primary)
                    if hasTimeline {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("New Project")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let project = Project(
                            name: name.trimmingCharacters(in: .whitespaces),
                            categoryKey: categoryKey,
                            startDate: hasTimeline ? startDate : nil,
                            dueDate: hasTimeline ? dueDate : nil
                        )
                        context.insert(project)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .tint(palette.primary)
        .onAppear { nameFocused = true }
    }
}
