//
//  TaskSheets.swift
//  Evry
//
//  AddTaskSheet — the quick-add bottom sheet: natural-language title field
//  with live parse chips, optional notes, fixed-amber submit button.
//  EditTaskSheet — full task editor (title, notes, date, priority, repeat,
//  tags, project, pin, subtasks) plus duplicate/snooze/delete actions.
//

import CoreLocation
import MapKit
import SwiftUI
import SwiftData
import UIKit

// MARK: - Add sheet

struct AddTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    /// Preselected project when quick-adding from an open project card.
    var project: Project?

    @State private var text = ""
    @State private var notes = ""
    @State private var location = ""
    @State private var showNotes = false
    @State private var showLocationPicker = false
    @State private var sheetHeight: CGFloat = 86
    @State private var selectedDetent: PresentationDetent = .height(86)
    @State private var titleFocused: Bool = false
    @FocusState private var notesFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var parsed: ParsedTask? { text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : parseTaskInput(text) }

    var body: some View {
        // The whole card is the swipeable surface: type into it, then fling it
        // to a day. On commit it's sent off-screen and a fresh card slides up.
        ScheduleSwipeCard(
            palette: palette,
            onSchedule: { date, _ in submit(overrideDate: date) },
            isLocked: parsed == nil,
            sendsAway: true
        ) {
        VStack(spacing: 0) {
            Capsule()
                .fill(palette.border)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 4)

            HStack(spacing: 8) {
                HighlightedTaskTextField(
                    placeholder: "Add task… tod, #tag, !high, note",
                    text: $text,
                    palette: palette,
                    autoFocus: true,
                    onSubmit: { submit() },
                    focused: $titleFocused
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(palette.hover, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(titleFocused ? palette.primary : palette.border, lineWidth: 1.5)
                )

                if !showNotes {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showNotes = true
                        }
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

                Button {
                    showLocationPicker = true
                } label: {
                    Image(systemName: location.isEmpty ? "mappin" : "mappin.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(location.isEmpty ? palette.textSec : palette.primary)
                        .frame(width: 36, height: 36)
                        .background(location.isEmpty ? palette.hover : palette.primaryLight, in: Circle())
                        .overlay(Circle().strokeBorder(location.isEmpty ? palette.border : palette.primary.opacity(0.4), lineWidth: 1.5))
                }
                .buttonStyle(PressScaleStyle())
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: parsed == nil)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, parsed != nil || showNotes ? 0 : 16)

            if parsed != nil && !showNotes {
                swipeHint
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }

            if showNotes {
                TextField("Add notes…", text: $notes, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.text)
                    .lineLimit(3...6)
                    .focused($notesFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.hover, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(notesFocused ? palette.primary : palette.border, lineWidth: 1.5)
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, location.isEmpty ? 16 : 0)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !location.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.primary)
                    Text(location)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { location = "" }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.textSec)
                            .padding(5)
                            .background(palette.hover, in: Circle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(palette.primaryLight, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.primary.opacity(0.3), lineWidth: 1))
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Color.clear.frame(height: location.isEmpty && !showNotes ? 0 : 0)
        }
        // Card background lives inside the swipe surface so the whole card
        // (not just its contents) travels when flung.
        .background(palette.card, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
        } // ScheduleSwipeCard
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet(location: $location)
                .environment(appearance)
        }
        // fixedSize forces the VStack to resolve at its ideal height, escaping the
        // sheet's proposed-height constraint. onGeometryChange then reads that ideal
        // height as the view's actual laid-out size and drives the detent.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { h in
            guard h > 0, h != sheetHeight else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                sheetHeight = h
                selectedDetent = .height(h)
            }
        }
        .presentationDetents([.height(sheetHeight)], selection: $selectedDetent)
        .presentationBackground(.clear)
        .presentationDragIndicator(.hidden)
        .onAppear { }
        .onChange(of: showNotes) { _, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    notesFocused = true
                }
            }
        }
    }

    // Compact legend teaching the swipe-to-schedule directions.
    private var swipeHint: some View {
        HStack(spacing: 14) {
            Text("Swipe to schedule")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textPh)
            Spacer(minLength: 0)
            swipeHintItem(icon: "arrow.up", label: "Today", color: palette.primary)
            swipeHintItem(icon: "arrow.right", label: "Tmrw", color: Palette.success)
            swipeHintItem(icon: "arrow.left", label: "Wknd", color: Color(hex: 0x8B5CF6))
        }
    }

    private func swipeHintItem(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
    }

    /// `overrideDate` is supplied by the swipe-to-schedule gesture and wins over
    /// any date parsed from the typed keywords.
    private func submit(overrideDate: Date? = nil) {
        guard let parsed, !parsed.title.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let task = TaskItem(
            title: parsed.title,
            dueDate: overrideDate ?? parsed.date,
            tags: parsed.tags,
            priority: parsed.priority,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location,
            isNote: parsed.isNote,
            project: project
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            context.insert(task)
        }
        NotificationService.schedule(task)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showNotes = false
        }
        DispatchQueue.main.async {
            text = ""
            notes = ""
            location = ""
            titleFocused = true
        }
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
            NotificationService.schedule(task)
        }
        .onChange(of: task.dueDate) {
            NotificationService.schedule(task)
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

// MARK: - Location picker

@Observable
private final class CurrentLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var coordinate: CLLocationCoordinate2D?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }
}

struct LocationPickerSheet: View {
    @Binding var location: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var locationProvider = CurrentLocationProvider()

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty && query.isEmpty {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(palette.primaryLight)
                                .frame(width: 38, height: 38)
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(palette.primary)
                        }
                        Text("Search for a place or address")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.textSec)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if results.isEmpty && !query.isEmpty {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(palette.hover)
                                .frame(width: 38, height: 38)
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 16))
                                .foregroundStyle(palette.textSec)
                        }
                        Text("No results for \"\(query)\"")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.textSec)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(results, id: \.self) { item in
                        Button {
                            location = mapItemLabel(item, fallback: item.name ?? "")
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(palette.primaryLight)
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundStyle(palette.primary)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? "Unknown")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(palette.text)
                                    let subtitle = mapItemSubtitle(item)
                                    if !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(palette.textSec)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(palette.border)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search location…")
            .onChange(of: query) { _, new in scheduleSearch(new) }
            .navigationTitle("Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(palette.primary)
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            if let coord = locationProvider.coordinate {
                request.region = MKCoordinateRegion(center: coord, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
            }
            if let response = try? await MKLocalSearch(request: request).start() {
                await MainActor.run { results = response.mapItems }
            }
        }
    }

    private func mapItemLabel(_ item: MKMapItem, fallback: String) -> String {
        let name = item.name ?? fallback
        let city: String
        if #available(iOS 26.0, *) {
            city = item.addressRepresentations?.cityName ?? ""
        } else {
            city = item.placemark.locality ?? item.placemark.administrativeArea ?? ""
        }
        return city.isEmpty ? name : "\(name), \(city)"
    }

    private func mapItemSubtitle(_ item: MKMapItem) -> String {
        if #available(iOS 26.0, *) {
            return item.address?.shortAddress ?? item.placemark.title ?? ""
        } else {
            return item.placemark.title ?? ""
        }
    }
}
