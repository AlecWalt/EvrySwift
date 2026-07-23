//
//  TaskSheets.swift
//  Evry
//
//  AddTaskSheet — the quick-add bottom sheet: natural-language title field
//  with live parse chips, optional notes, fixed-amber submit button.
//  EditTaskSheet — full task editor (title, notes, date, priority, repeat,
//  tags, project, pin, subtasks) plus duplicate/snooze/delete actions.
//

import SwiftUI
import SwiftData

// MARK: - Add sheet

struct AddTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    /// Preselected project when quick-adding from an open project card.
    var project: Project?

    @State private var text = ""
    @State private var notes = ""
    @State private var showNotes = false
    @FocusState private var titleFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var parsed: ParsedTask? { text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : parseTaskInput(text) }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(palette.border)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if let parsed, parsed.date != nil || parsed.priority != .normal || !parsed.tags.isEmpty || parsed.isNote {
                chipsRow(parsed)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {
                HighlightedTaskTextField(
                    placeholder: "Add task… tod, #tag, !high, note",
                    text: $text,
                    palette: palette,
                    onSubmit: submit,
                    focused: $titleFocused
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(palette.hover, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(titleFocused ? palette.primary : palette.border, lineWidth: 1.5)
                )

                if !showNotes {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showNotes = true }
                    } label: {
                        Image(systemName: "note.text")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.textSec)
                            .frame(width: 36, height: 36)
                            .background(palette.hover, in: Circle())
                            .overlay(Circle().strokeBorder(palette.border, lineWidth: 1.5))
                    }
                    .buttonStyle(PressScaleStyle())
                }

                if parsed != nil {
                    // Always brand amber, never the accent — the one fixed
                    // brand moment in the app.
                    Button(action: submit) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.onAmber)
                            .frame(width: 42, height: 42)
                            .background(Palette.amber, in: Circle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: parsed == nil)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, showNotes ? 0 : 16)

            if showNotes {
                TextField("Add notes…", text: $notes, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.text)
                    .lineLimit(3...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.hover, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 1.5)
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(showNotes ? 240 : 140)])
        .presentationBackground(palette.card)
        .presentationDragIndicator(.hidden)
        .onAppear { titleFocused = true }
    }

    private func chipsRow(_ parsed: ParsedTask) -> some View {
        HStack(spacing: 5) {
            if parsed.isNote {
                ChipView(text: "📝 Note", foreground: palette.card, background: palette.text)
            }
            if let date = parsed.date, let label = formatDueDate(date) {
                ChipView(text: "📅 \(label)", foreground: palette.primary, background: palette.primaryLight)
            }
            if let label = parsed.priority.chipLabel {
                ChipView(
                    text: label,
                    foreground: parsed.priority == .high ? Palette.danger : parsed.priority == .medium ? Palette.warning : Palette.success,
                    background: parsed.priority == .high ? palette.dangerLight : parsed.priority == .medium ? palette.warningLight : palette.successLight
                )
            }
            ForEach(parsed.tags, id: \.self) { tag in
                ChipView(text: "#\(tag)", foreground: palette.textSec, background: palette.hover)
            }
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        guard let parsed, !parsed.title.isEmpty else { return }
        let task = TaskItem(
            title: parsed.title,
            dueDate: parsed.date,
            tags: parsed.tags,
            priority: parsed.priority,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            isNote: parsed.isNote,
            project: project
        )
        withAnimation {
            context.insert(task)
        }
        // Stay open for rapid entry, same as the webapp's add sheet.
        text = ""
        notes = ""
        showNotes = false
        titleFocused = true
    }
}

// MARK: - Edit sheet

struct EditTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @Bindable var task: TaskItem
    var onDelete: (TaskItem) -> Void

    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var hasDate: Bool = false
    @State private var newSubtask = ""
    @State private var tagsText = ""

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $task.title, axis: .vertical)
                        .font(.system(size: 16.5))
                    TextField("Notes", text: $task.notes, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(2...8)
                }

                if !task.isNote {
                    Section {
                        Toggle("Due date", isOn: $hasDate.animation())
                            .tint(palette.primary)
                        if hasDate {
                            DatePicker(
                                "Date",
                                selection: Binding(
                                    get: { task.dueDate ?? startOfDay(Date()) },
                                    set: { task.dueDate = $0 }
                                )
                            )
                            Picker("Repeat", selection: Binding(
                                get: { task.recurrence },
                                set: { task.recurrence = $0 }
                            )) {
                                Text("Never").tag(RecurrenceFreq?.none)
                                ForEach(RecurrenceFreq.allCases) { freq in
                                    Text(freq.label).tag(RecurrenceFreq?.some(freq))
                                }
                            }
                        }
                    }

                    Section {
                        Picker("Priority", selection: Binding(
                            get: { task.priority },
                            set: { task.priority = $0 }
                        )) {
                            ForEach([TaskPriority.normal, .low, .medium, .high]) { p in
                                Text(p.label).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("Tags (comma separated)", text: $tagsText)
                            .autocorrectionDisabled()
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onChange(of: tagsText) {
                                task.tags = tagsText
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                    .filter { !$0.isEmpty }
                            }

                        Picker("Project", selection: Binding(
                            get: { task.project?.uid },
                            set: { uid in task.project = projects.first { $0.uid == uid } }
                        )) {
                            Text("None").tag(UUID?.none)
                            ForEach(projects) { project in
                                Text(project.name).tag(UUID?.some(project.uid))
                            }
                        }

                        Toggle("Pinned", isOn: $task.pinned)
                            .tint(palette.primary)
                    }

                    Section("Subtasks") {
                        ForEach(task.subtasks) { subtask in
                            HStack {
                                Button {
                                    setSubtask(subtask, completed: !subtask.completed)
                                } label: {
                                    Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(subtask.completed ? Palette.success : palette.border)
                                }
                                .buttonStyle(.plain)
                                Text(subtask.title)
                                    .strikethrough(subtask.completed, color: palette.textPh)
                                    .foregroundStyle(subtask.completed ? palette.textSec : palette.text)
                            }
                        }
                        .onDelete { offsets in
                            task.subtasks.remove(atOffsets: offsets)
                        }

                        HStack {
                            TextField("Add subtask…", text: $newSubtask)
                                .onSubmit(addSubtask)
                            Button(action: addSubtask) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(palette.primary)
                            }
                            .disabled(newSubtask.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Section {
                        Button {
                            TaskActions.duplicate(task, context: context)
                            dismiss()
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        if task.dueDate != nil {
                            Button {
                                TaskActions.snooze(task)
                                dismiss()
                            } label: {
                                Label("Snooze to tomorrow", systemImage: "zzz")
                            }
                        }
                        Button(role: .destructive) {
                            dismiss()
                            onDelete(task)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(task.isNote ? "Edit Note" : "Edit Task")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .onAppear {
            hasDate = task.dueDate != nil
            tagsText = task.tags.joined(separator: ", ")
        }
        .onChange(of: hasDate) {
            if !hasDate {
                task.dueDate = nil
                task.recurrence = nil
            } else if task.dueDate == nil {
                task.dueDate = startOfDay(Date())
            }
        }
    }

    private func setSubtask(_ subtask: SubtaskData, completed: Bool) {
        if let idx = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
            task.subtasks[idx].completed = completed
        }
    }

    private func addSubtask() {
        let title = newSubtask.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        task.subtasks.append(SubtaskData(title: title))
        newSubtask = ""
    }
}
