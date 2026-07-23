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

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(PomodoroModel.self) private var pomodoro

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var selectedTab: AppTab = .inbox
    @State private var showAddTask = false
    @State private var showAddProject = false
    @State private var editingTask: TaskItem?
    @State private var toast: ToastData?
    @State private var toastDismissTask: Task<Void, Never>?

    // Focus Mode
    @AppStorage("focus_mode") private var focusMode = false
    @State private var confirmExitFocus = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    /// The swipe-up add bar only shows where adding makes sense — Inbox adds
    /// a task, Projects adds a project. (Webapp's NO_ADD_TABS.)
    private var showsAddHandle: Bool {
        selectedTab == .inbox || selectedTab == .projects
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.bg.ignoresSafeArea()

            if focusMode {
                focusModeView
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .opacity
                    ))
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
        .sheet(isPresented: $showAddTask) {
            AddTaskSheet()
        }
        .sheet(isPresented: $showAddProject) {
            AddProjectSheet()
        }
        .sheet(item: $editingTask) { task in
            EditTaskSheet(task: task, onDelete: deleteTask)
        }
        .confirmationDialog("Exit Focus Mode?", isPresented: $confirmExitFocus, titleVisibility: .visible) {
            Button("Exit Focus Mode") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    focusMode = false
                }
            }
        }
        .onAppear {
            TaskActions.purgeExpiredTrash(context: modelContext)
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
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .inbox:
                    InboxView(palette: palette, onEdit: { editingTask = $0 }, onDelete: deleteTask)
                case .focus:
                    FocusTabView(palette: palette, onEdit: { editingTask = $0 }, onDelete: deleteTask)
                case .projects:
                    ProjectsView(palette: palette, onEdit: { editingTask = $0 }, onDelete: deleteTask)
                case .profile:
                    ProfileView(palette: palette, onEnterFocusMode: enterFocusMode)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Floating bottom chrome: swipe handle + glass tab bar
            VStack(spacing: 0) {
                if showsAddHandle {
                    SwipeHandle(palette: palette) {
                        if selectedTab == .projects {
                            showAddProject = true
                        } else {
                            showAddTask = true
                        }
                    }
                }
                GlassTabBar(selection: $selectedTab, palette: palette)
            }
            .padding(.bottom, 8)
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

            // Exit button — top right
            Button {
                confirmExitFocus = true
            } label: {
                Text("Exit Focus Mode")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(palette.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.trailing, 14)
            .zIndex(1)
        }
    }

    // MARK: Shared handlers

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
        .modelContainer(for: [TaskItem.self, Project.self], inMemory: true)
}
