//
//  ContentView.swift
//  Evry
//
//  App shell — the Swift port of the webapp's main.js: four tabs behind a
//  floating glass tab bar, the accent swipe-up handle that opens quick add,
//  the shared edit sheet, delete toasts with Undo, and Focus Mode (the Path
//  front and center with the Inbox in a pull-up drawer).
//

import SwiftUI
import SwiftData
import UserNotifications
import AppIntents
import UIKit

// Shared observable used by GlobalSearchSheet to request a tab switch (e.g.
// jump to the Inbox when a search result is tapped).
@Observable
final class ProjectNavigationState {
    /// Set by GlobalSearchSheet to request a tab switch.
    var requestedTab: AppTab? = nil
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Appearance.self) private var appearance
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(TourCoordinator.self) private var tourCoordinator

    @Query private var allFolders: [Folder]
    @AppStorage("membership_plan") private var membershipPlan = ""

    @State private var projectNavState = ProjectNavigationState()
    @State private var notesNavState = NotesNavigationState()
    @State private var showFolderLimitPromo = false
    @State private var selectedTab: AppTab = .inbox
    @State private var showAddTask = false
    /// Bumped on each open so the add-task overlay is rebuilt with a fresh
    /// identity — otherwise a quick close/reopen reuses the view and its text
    /// field never re-focuses (keyboard stays down).
    @State private var addTaskSession = 0
    @State private var addingNote: Note?
    @State private var showNewFolder = false
    @State private var editingTask: TaskItem?
    @State private var toast: ToastData?
    @State private var toastDismissTask: Task<Void, Never>?

    // Tab visibility
    @AppStorage("tab_inbox_visible")    private var tabInboxVisible    = true
    @AppStorage("tab_calendar_visible") private var tabCalendarVisible = true
    @AppStorage("tab_notes_visible")    private var tabNotesVisible    = true
    @AppStorage("tab_profile_visible")  private var tabProfileVisible  = true

    // Focus Mode
    @AppStorage("focus_mode") private var focusMode = false
    @State private var confirmExitFocus = false
    @State private var showPomodoro = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    /// The swipe-up add bar only shows where adding makes sense — Inbox adds
    /// a task, Notes adds a note. (The Calendar tab has its own add button.)
    private var showsAddHandle: Bool {
        selectedTab == .inbox || selectedTab == .notes
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.bg.ignoresSafeArea()

            if focusMode {
                focusModeView
                    .transition(.opacity)
            } else {
                normalShell
                    .transition(.opacity)
            }

            // Toast
            if let toast {
                ToastView(toast: toast, palette: palette) {
                    self.toast = nil
                }
                .padding(.bottom, 120)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .environment(projectNavState)
        .environment(notesNavState)
        .preferredColorScheme(appearance.preferredColorScheme)
        .overlay {
            if tourCoordinator.isActive {
                TourOverlayView()
            }
        }
        .onChange(of: tourCoordinator.currentStep) { _, _ in
            guard tourCoordinator.isActive else { return }
            withAnimation(.easeInOut(duration: 0.3)) { selectedTab = tourCoordinator.currentTab }
        }
        .onChange(of: tourCoordinator.isActive) { _, active in
            if active {
                insertTourSampleData()
                withAnimation(.easeInOut(duration: 0.3)) { selectedTab = tourCoordinator.currentTab }
            } else {
                deleteTourSampleData()
            }
        }
        .onChange(of: projectNavState.requestedTab) { _, tab in
            guard let tab else { return }
            withAnimation(.easeInOut(duration: 0.25)) { selectedTab = tab }
            projectNavState.requestedTab = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { processPendingSiriTasks() }
        }
        .overlay {
            if showAddTask {
                AddTaskSheet(isPresented: $showAddTask)
                    .id(addTaskSession)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showAddTask)
        .onChange(of: showAddTask) { _, open in if open { addTaskSession += 1 } }
        .sheet(item: $editingTask) { task in
            EditTaskSheet(task: task, onDelete: deleteTask)
        }
        .sheet(item: $addingNote) { note in
            NoteEditorView(note: note)
                .environment(appearance)
        }
        .sheet(isPresented: $showNewFolder) {
            NewFolderSheet().environment(appearance)
        }
        .sheet(isPresented: $showFolderLimitPromo) {
            MembershipPromoView()
        }
        .confirmationDialog("Are you sure you want to exit focus mode?", isPresented: $confirmExitFocus, titleVisibility: .visible) {
            Button("Exit Focus Mode") {
                // Distinct haptics: a warning buzz when a running timer is being
                // cancelled, a softer tap when simply leaving an idle session.
                if pomodoro.running {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                } else {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                pomodoro.reset()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        focusMode = false
                    }
                }
            }
        }
        .task { await NotificationService.requestPermission() }
        .onAppear {
            EvryShortcuts.updateAppShortcutParameters()
            TaskActions.purgeExpiredTrash(context: modelContext)
            cleanupLeftoverTourSampleData()
            pomodoro.onPhaseChange = { phase in
                switch phase {
                case .work: showToast("Break's over — back to focus")
                case .shortBreak: showToast("Focus session done — take a short break")
                case .longBreak: showToast("Great work! Time for a long break")
                }
            }
        }
    }

    // MARK: Normal shell (tabs + bottom chrome)

    private var normalShell: some View {
        TabView(selection: $selectedTab) {
            if tabInboxVisible {
                InboxView(palette: palette, onEdit: { editingTask = $0 }, onDelete: deleteTask, onEnterFocusMode: enterFocusMode)
                    .tabItem { Label("Inbox", systemImage: "tray") }
                    .tag(AppTab.inbox)
            }
            if tabCalendarVisible {
                CalendarTabView(palette: palette, onEdit: { editingTask = $0 }, onDelete: deleteTask)
                    .tabItem { Label("Calendar", systemImage: "calendar") }
                    .tag(AppTab.calendar)
            }
            if tabNotesVisible {
                NotesView(palette: palette)
                    .tabItem { Label("Notes", systemImage: "note.text") }
                    .tag(AppTab.notes)
            }
            if tabProfileVisible {
                ProfileView(palette: palette, onEnterFocusMode: enterFocusMode)
                    .tabItem { Label("Profile", systemImage: "person") }
                    .tag(AppTab.profile)
            }
        }
        .tint(palette.primary)
        .onChange(of: selectedTab) { _, _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .onChange(of: tabInboxVisible)    { _, v in if !v && selectedTab == .inbox    { jumpToFirstVisible() } }
        .onChange(of: tabCalendarVisible) { _, v in if !v && selectedTab == .calendar { jumpToFirstVisible() } }
        .onChange(of: tabNotesVisible)    { _, v in if !v && selectedTab == .notes    { jumpToFirstVisible() } }
        .onChange(of: tabProfileVisible)  { _, v in if !v && selectedTab == .profile  { jumpToFirstVisible() } }
        .overlay(alignment: .bottom) {
            if showsAddHandle {
                SwipeHandle(palette: palette) {
                    switch selectedTab {
                    case .notes:
                        switch notesNavState.activeScope {
                        case .none:
                            // On the Folders screen → create a folder. Free users
                            // are capped at 3 folders; beyond that, upsell Pro.
                            if membershipPlan != "pro" && allFolders.count >= 3 {
                                showFolderLimitPromo = true
                            } else {
                                showNewFolder = true
                            }
                        case .some(let scope):
                            // Inside a folder / All Notes → create a note there.
                            createNoteFromHandle(folder: scope.folder)
                        }
                    default:
                        showAddTask = true
                    }
                }
                .padding(.bottom, 42)
            }
        }
    }

    // MARK: Tour sample data

    private static let tourSampleKey = "tourSampleUIDs"

    private func insertTourSampleData() {
        let today = startOfDay(Date())

        let tasks: [TaskItem] = [
            TaskItem(title: "Design new homepage layout",
                     dueDate: today,
                     tags: ["design"], priority: .high),
            TaskItem(title: "Team standup",
                     dueDate: today),
            TaskItem(title: "Write API documentation",
                     dueDate: addDays(today, 3),
                     tags: ["dev"], priority: .medium),
            TaskItem(title: "Buy groceries"),
            TaskItem(title: "Prepare Q3 report",
                     dueDate: addDays(today, 5),
                     tags: ["work"], priority: .high),
        ]
        for task in tasks { modelContext.insert(task) }
        try? modelContext.save()

        let ids = tasks.map(\.uid).map(\.uuidString)
        UserDefaults.standard.set(ids, forKey: Self.tourSampleKey)
    }

    private func deleteTourSampleData() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.tourSampleKey) ?? []
        guard !stored.isEmpty else { return }
        let ids = Set(stored.compactMap(UUID.init(uuidString:)))
        let allTasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
        for t in allTasks where ids.contains(t.uid) { modelContext.delete(t) }
        try? modelContext.save()
        UserDefaults.standard.removeObject(forKey: Self.tourSampleKey)
    }

    // Cleans up sample data left behind by a previous force-quit during a tour.
    private func cleanupLeftoverTourSampleData() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.tourSampleKey) ?? []
        guard !stored.isEmpty else { return }
        deleteTourSampleData()
    }

    // Processes any tasks queued by AddTaskIntent via UserDefaults.
    private func processPendingSiriTasks() {
        let key = "pendingSiriTasks"
        guard let pending = UserDefaults.standard.array(forKey: key) as? [[String: Any]],
              !pending.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key)
        for entry in pending {
            guard let title = entry["title"] as? String, !title.isEmpty else { continue }
            let dueDate = (entry["dueDate"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            let task = TaskItem(title: title, dueDate: dueDate)
            modelContext.insert(task)
            NotificationService.schedule(task)
        }
        try? modelContext.save()
    }

    private func jumpToFirstVisible() {
        let order: [AppTab] = [.inbox, .calendar, .notes, .profile]
        let flags = [tabInboxVisible, tabCalendarVisible, tabNotesVisible, tabProfileVisible]
        if let idx = flags.firstIndex(of: true) {
            selectedTab = order[idx]
        }
    }

    // MARK: Focus Mode — Path front and center

    private var focusModeView: some View {
        ZStack(alignment: .topTrailing) {
            PathView(
                palette: palette,
                onEdit: { editingTask = $0 },
                onDelete: deleteTask,
                inFocusMode: true
            )
            .zIndex(0)

            // Top-right button row: timer + exit
            HStack(spacing: 8) {
                Button {
                    showPomodoro = true
                } label: {
                    Image(systemName: "timer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(pomodoro.running ? palette.primary : palette.textSec)
                        .frame(width: 32, height: 32)
                        .background(palette.card, in: Circle())
                        .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .fullScreenCover(isPresented: $showPomodoro) {
                    PomodoroView()
                }

                Button {
                    confirmExitFocus = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textSec)
                        .frame(width: 32, height: 32)
                        .background(palette.card, in: Circle())
                        .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
            .zIndex(1)
        }
    }

    // MARK: Shared handlers

    /// Swipe-up / tap inside a notes scope creates a blank note there and opens
    /// the editor. Blank notes are discarded on dismiss by the editor itself.
    private func createNoteFromHandle(folder: Folder?) {
        let note = Note(folder: folder)
        modelContext.insert(note)
        try? modelContext.save()
        addingNote = note
    }

    private func enterFocusMode() {
        // Focus only happens on the clock — entering from anywhere (Profile's
        // Focus Mode card included) starts the pomodoro if it isn't running.
        if !pomodoro.running {
            pomodoro.start()
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            focusMode = true
        }
    }

    private func deleteTask(_ task: TaskItem) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            TaskActions.delete(task)
        }
        showToast("\"\(task.title)\" deleted") {
            withAnimation {
                TaskActions.restore(task)
            }
        }
    }

    private func showToast(_ message: String, undo: (() -> Void)? = nil) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toast = ToastData(message: message, undo: undo)
        }
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                toast = nil
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(Appearance())
        .environment(PomodoroModel())
        .environment(CalendarService())
        .environment(TourCoordinator())
        .modelContainer(for: [TaskItem.self, Note.self, Folder.self], inMemory: true)
}
