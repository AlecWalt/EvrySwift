//
//  ContentView.swift
//  Evry
//
//  App shell — the Swift port of the webapp's main.js: the tabs behind the
//  system tab bar (Evry-styled, see EvryTabBarAppearance), the navy swipe-up
//  handle that opens quick add, the shared edit sheet, delete toasts with Undo,
//  and Focus Mode (the Path front and center).
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
    /// A task picked in search. The Inbox pages to its day, and that day's list
    /// scrolls it into view, highlights it, then clears this.
    var focusTaskID: UUID? = nil
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(Appearance.self) private var appearance
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(TourCoordinator.self) private var tourCoordinator
    @Environment(MembershipRouter.self) private var membershipRouter

    @Query private var allFolders: [Folder]
    @Query private var allNotes: [Note]
    @Query private var allTasks: [TaskItem]
    @AppStorage("membership_plan") private var membershipPlan = ""
    // Trial clock (first launch) + the hard-wall state derived from it.
    @AppStorage("app_first_used") private var firstUsed = ""
    @State private var showTrialWall = false
    // The user's daily goals (set in Profile), surfaced in the daily recap.
    @AppStorage("daily_pomo_goal") private var dailyPomoGoal = 60

    // Pro welcome + guided setup (shown once, right after upgrading).
    @AppStorage("pro_welcomed") private var proWelcomed = false
    @State private var showProWelcome = false
    @State private var showWelcomeBrainDump = false

    // Tools launched from the add-handle's press-and-hold radial menu.
    @State private var showHandleBrainDump = false
    @State private var showHandlePomodoro = false
    // Screen point of the tapped add-handle bubble, so the cover's fill-wipe grows from it.
    @State private var handleFillOrigin: CGPoint? = nil

    // Start-of-day recap (shown once per day summarizing yesterday).
    @AppStorage("last_recap_day") private var lastRecapDay = ""
    @State private var showDailyRecap = false
    @State private var recapDate = Date()
    @State private var recapTasks = 0
    /// Tasks that were due on the recap day — the day's task goal.
    @State private var recapTaskGoal = 0
    @State private var recapFocus = 0

    @State private var projectNavState = ProjectNavigationState()
    @State private var notesNavState = NotesNavigationState()
    @State private var selectedTab: AppTab = .inbox
    @State private var showAddTask = false
    /// Bumped on each open so the add-task overlay is rebuilt with a fresh
    /// identity — otherwise a quick close/reopen reuses the view and its text
    /// field never re-focuses (keyboard stays down).
    @State private var addTaskSession = 0
    // Habits quick-add, opened from the same swipe-up handle on the Habits tab.
    @State private var showAddHabit = false
    @State private var addHabitSession = 0
    @State private var addingNote: Note?
    @State private var showNewFolder = false
    @State private var editingTask: TaskItem?
    @State private var toast: ToastData?
    @State private var toastDismissTask: Task<Void, Never>?

    // Tab visibility
    @AppStorage("tab_inbox_visible")    private var tabInboxVisible    = true
    @AppStorage("tab_habits_visible")   private var tabHabitsVisible   = true
    // Calendar is hidden by default now that Habits has its spot; it can be
    // re-enabled from Settings → Layout.
    @AppStorage("tab_calendar_visible") private var tabCalendarVisible = false
    @AppStorage("tab_notes_visible")    private var tabNotesVisible    = true

    // Focus Mode
    @AppStorage("focus_mode") private var focusMode = false
    @State private var confirmExitFocus = false
    @State private var showPomodoro = false
    @State private var showChat = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    /// The swipe-up add bar only shows where adding makes sense — Inbox adds
    /// a task, Habits adds a habit, Notes adds a note. (The Calendar tab has its
    /// own add button.)
    private var showsAddHandle: Bool {
        selectedTab == .inbox || selectedTab == .habits || selectedTab == .notes
    }

    var body: some View {
        // @Bindable gives a properly-observed binding into the router so the plans
        // cover below actually presents when `showPlans` flips (a hand-built
        // Binding's getter isn't tracked during body, so the cover never appeared).
        @Bindable var router = membershipRouter
        return ZStack(alignment: .bottom) {
            palette.bg.ignoresSafeArea()

            if focusMode {
                focusModeView
                    .transition(.opacity)
            } else {
                normalShell
                    .safeAreaInset(edge: .top) {
                        if showCountdown {
                            TrialCountdownBar(daysLeft: trialDaysLeft, palette: palette) {
                                membershipRouter.showPlans = true
                            }
                        }
                    }
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
        .tint(palette.primary)
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
            if phase == .active { processPendingSiriTasks(); checkDailyRecap(); evaluateAccess() }
        }
        .task { checkDailyRecap() }
        // Subscribing (or its removal) flips access — re-check the wall. The trial
        // clock changing (e.g. the dev reset/expire tools) does too.
        .onChange(of: membershipPlan) { _, _ in evaluateAccess() }
        .onChange(of: firstUsed) { _, _ in evaluateAccess() }
        // Celebrate + guide the user right after they upgrade to Pro.
        .onChange(of: membershipPlan) { _, plan in
            guard plan == "pro", !proWelcomed else { return }
            // Upgrading from the promo dismisses two stacked presentations (the
            // plans cover, then the promo sheet). Wait for that whole chain to
            // finish, otherwise this cover is presented into a still-dismissing
            // hierarchy and silently dropped (the celebration never plays).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { showProWelcome = true }
        }
        .fullScreenCover(isPresented: $showProWelcome) {
            ProWelcomeView(
                onBrainDump: {
                    proWelcomed = true
                    showProWelcome = false
                    selectedTab = .inbox
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showWelcomeBrainDump = true }
                },
                onFinish: {
                    proWelcomed = true
                    showProWelcome = false
                }
            )
        }
        .fullScreenCover(isPresented: $showWelcomeBrainDump) {
            BrainDumpSheet(context: .tasks(add: insertBrainDumpTasks))
        }
        // Add-handle radial menu tools — the fill-wipe grows from the tapped bubble.
        .fullScreenCover(isPresented: $showHandleBrainDump) {
            BrainDumpSheet(context: .tasks(add: insertBrainDumpTasks), fillOrigin: handleFillOrigin)
        }
        .fullScreenCover(isPresented: $showHandlePomodoro) {
            PomodoroView(onStart: enterFocusMode, fillOrigin: handleFillOrigin)
        }
        // Start-of-day recap of yesterday.
        .sheet(isPresented: $showDailyRecap) {
            DailyRecapView(date: recapDate, tasksCompleted: recapTasks, focusMinutes: recapFocus,
                           taskGoal: max(1, recapTaskGoal), focusGoal: dailyPomoGoal)
        }
        .overlay {
            if showAddTask {
                AddTaskSheet(isPresented: $showAddTask)
                    .id(addTaskSession)
                    // The card runs its own upward glide on appear; a plain fade
                    // here keeps that translation from being doubled up.
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showAddTask)
        .onChange(of: showAddTask) { _, open in if open { addTaskSession += 1 } }
        .overlay {
            if showAddHabit {
                AddHabitSheet(isPresented: $showAddHabit)
                    .id(addHabitSession)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showAddHabit)
        .onChange(of: showAddHabit) { _, open in if open { addHabitSession += 1 } }
        // Folder quick-add — the same bottom card as the habit one.
        .overlay {
            if showNewFolder {
                NewFolderSheet(isPresented: $showNewFolder)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showNewFolder)
        // The chat with Evry — rises from the bottom over the current page.
        .overlay {
            if showChat {
                EvryChatOverlay(isPresented: $showChat, onEnterFocusMode: enterFocusMode)
            }
        }
        .sheet(item: $editingTask) { task in
            EditTaskSheet(task: task, onDelete: deleteTask)
        }
        .sheet(item: $addingNote) { note in
            NoteEditorView(note: note)
                .environment(appearance)
        }
        // Presented from the root so a promo card can close itself and hand off to
        // the full-screen plans page.
        .fullScreenCover(isPresented: $router.showPlans) {
            MembershipPlansView()
        }
        // Hard wall: once the free month is over (and not subscribed), the app is
        // blocked behind an undismissable paywall until the user subscribes.
        .fullScreenCover(isPresented: $showTrialWall) {
            MembershipPromoView(isHardWall: true)
                .interactiveDismissDisabled(true)
        }
        // Themed, animated exit-focus confirmation (replaces the system dialog).
        .overlay {
            if confirmExitFocus { focusExitPrompt }
        }
        .task { await NotificationService.requestPermission() }
        .onAppear {
            // Stamp the trial clock on first launch, then check the wall.
            if firstUsed.isEmpty { firstUsed = ISO8601DateFormatter().string(from: Date()) }
            evaluateAccess()
            EvryShortcuts.updateAppShortcutParameters()
            TaskActions.purgeExpiredTrash(context: modelContext)
            TaskActions.assignMissingDueDates(context: modelContext)
            TaskActions.pruneFinishedGroups(context: modelContext)
            cleanupLeftoverTourSampleData()
            pomodoro.onPhaseChange = { phase in
                switch phase {
                case .work: showToast("Break’s over. Ready when you are.")
                case .shortBreak: showToast("Focus session done. Enjoy a short break.")
                case .longBreak: showToast("Nice work! Time for a longer break.")
                }
            }
        }
    }

    // MARK: Normal shell (tabs + bottom chrome)

    private var normalShell: some View {
        TabView(selection: $selectedTab) {
            if tabInboxVisible {
                InboxView(palette: palette, onEdit: { editingTask = $0 }, onDelete: deleteTask, onEnterFocusMode: enterFocusMode,
                          onOpenChat: { showChat = true })
                    .tabPageBackground(palette)
                    .tabItem { EvryTabLabel(tab: .inbox) }
                    .tag(AppTab.inbox)
            }
            if tabHabitsVisible {
                HabitsView(palette: palette)
                    .tabPageBackground(palette)
                    .tabItem { EvryTabLabel(tab: .habits) }
                    .tag(AppTab.habits)
            }
            if tabCalendarVisible {
                CalendarTabView(palette: palette, onEdit: { editingTask = $0 })
                    .tabPageBackground(palette)
                    .tabItem { EvryTabLabel(tab: .calendar) }
                    .tag(AppTab.calendar)
            }
            if tabNotesVisible {
                NotesView(palette: palette)
                    .tabPageBackground(palette)
                    .tabItem { EvryTabLabel(tab: .notes) }
                    .tag(AppTab.notes)
            }
            // Profile is always available — it's the only way to reach settings,
            // so it can't be turned off in the Layout screen.
            ProfileView(palette: palette, onEnterFocusMode: enterFocusMode)
                .tabPageBackground(palette)
                .tabItem { EvryTabLabel(tab: .profile) }
                .tag(AppTab.profile)
        }
        .tint(palette.primary)
        .onChange(of: selectedTab) { _, _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        .onChange(of: tabInboxVisible)    { _, v in if !v && selectedTab == .inbox    { jumpToFirstVisible() } }
        .onChange(of: tabHabitsVisible)   { _, v in if !v && selectedTab == .habits   { jumpToFirstVisible() } }
        .onChange(of: tabCalendarVisible) { _, v in if !v && selectedTab == .calendar { jumpToFirstVisible() } }
        .onChange(of: tabNotesVisible)    { _, v in if !v && selectedTab == .notes    { jumpToFirstVisible() } }
        .overlay(alignment: .bottom) {
            // Hidden while a quick-add card is open. Its removal is the pill's
            // "launch" (stretch + lift + fade) as the card rises in its place,
            // and it pops back in when the card closes.
            if showsAddHandle && !showAddHabit && !showAddTask && !showNewFolder {
                SwipeHandle(
                    palette: palette,
                    action: {
                        switch selectedTab {
                        case .notes:
                            switch notesNavState.activeScope {
                            case .none:
                                // On the Folders screen → create a folder.
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { showNewFolder = true }
                            case .some(let scope):
                                // Inside a folder / All Notes → create a note there.
                                createNoteFromHandle(folder: scope.folder)
                            }
                        case .habits:
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { showAddHabit = true }
                        default:
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { showAddTask = true }
                        }
                    },
                    onBrainDump: { origin in handleFillOrigin = origin; showHandleBrainDump = true },
                    onPomodoro: { origin in handleFillOrigin = origin; showHandlePomodoro = true }
                )
                .padding(.bottom, 42)
                // Pinned above the tab bar regardless of the keyboard, so when a
                // quick-add card closes the pill always pops back in at its home
                // spot (instead of riding the keyboard down or up from below).
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .transition(.handleLaunch)
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
        let order: [AppTab] = [.inbox, .habits, .calendar, .notes, .profile]
        // Profile is always present, so it's the guaranteed fallback.
        let flags = [tabInboxVisible, tabHabitsVisible, tabCalendarVisible, tabNotesVisible, true]
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
                // The standard header tiles (44pt, white, hairline, navy glyph);
                // the timer tile fills sky-soft while a session is running.
                Button {
                    showPomodoro = true
                } label: {
                    HeaderIconLabel(systemName: "timer", palette: palette, active: pomodoro.running)
                        .evryShadowSoft(palette)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Open focus timer")
                .fullScreenCover(isPresented: $showPomodoro) {
                    PomodoroView()
                }

                Button {
                    withAnimation(EvryMotion.settle) { confirmExitFocus = true }
                } label: {
                    HeaderIconLabel(systemName: "xmark", palette: palette)
                        .evryShadowSoft(palette)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Leave focus mode")
            }
            .padding(.top, 12)
            .padding(.trailing, EvrySpace.gutter)
            .zIndex(1)
        }
    }

    /// Themed exit-focus confirmation — a centered card over a dimmed backdrop,
    /// springing in and fading out to match the app's style.
    private var focusExitPrompt: some View {
        ZStack {
            Color.evryNavy.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { confirmExitFocus = false } }

            VStack(spacing: EvrySpace.grid) {
                VStack(spacing: 8) {
                    Text("Leave focus mode?")
                        .font(.evryH3)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.center)
                    Text(pomodoro.running ? "Your current session will end." : "You can come back anytime.")
                        .font(.evryBody)
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button("Keep focusing") {
                        withAnimation(.easeInOut(duration: 0.2)) { confirmExitFocus = false }
                    }
                    .buttonStyle(EvrySecondaryButtonStyle(palette: palette, fullWidth: true))

                    Button("Leave") { exitFocus() }
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .padding(EvrySpace.grid)
            .frame(maxWidth: 360)
            .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1))
            .evryShadowLift(palette)
            .padding(.horizontal, 32)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
        .zIndex(30)
    }

    private func exitFocus() {
        // Distinct haptics: a warning buzz when a running timer is being cancelled,
        // a softer tap when simply leaving an idle session.
        if pomodoro.running {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        pomodoro.reset()
        withAnimation(.easeInOut(duration: 0.2)) { confirmExitFocus = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.3)) { focusMode = false }
        }
    }

    // MARK: Shared handlers

    /// Swipe-up / tap inside a notes scope creates a blank note there and opens
    /// the editor. Blank notes are discarded on dismiss by the editor itself.
    /// Inserts tasks produced by a Brain Dump into the store.
    private func insertBrainDumpTasks(_ tasks: [BrainPreviewTask]) {
        for task in tasks {
            let item = TaskItem(title: task.title)
            item.dueDate = task.dueDate ?? Calendar.current.startOfDay(for: Date())
            item.priority = task.priority
            modelContext.insert(item)
        }
    }

    private func createNoteFromHandle(folder: Folder?) {
        let note = Note(folder: folder)
        modelContext.insert(note)
        try? modelContext.save()
        addingNote = note
    }

    /// Shows the hard wall when the free month has ended and the user hasn't
    /// subscribed; hides it the moment access is (re)granted.
    private func evaluateAccess() {
        showTrialWall = !MembershipAccess.hasAccess()
    }

    // Countdown surfaces only in the last stretch of the free month.
    private var trialDaysLeft: Int { MembershipAccess.daysRemaining() }
    private var showCountdown: Bool { MembershipAccess.inTrial() && trialDaysLeft <= 7 }

    /// Once per day, if yesterday had any activity, surface the recap popup.
    private func checkDailyRecap() {
        let cal = Calendar.current
        let todayKey = AccomplishmentsStore.dateKey(Date())
        guard lastRecapDay != todayKey else { return }
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) ?? Date()
        let tasks = allTasks.filter { t in
            guard t.completed, let done = t.completedAt else { return false }
            return cal.isDate(done, inSameDayAs: yesterday)
        }.count
        let focus = FocusLog.minutes(on: yesterday)
        // Evaluate only once per day, whether or not we end up showing it.
        lastRecapDay = todayKey
        guard tasks > 0 || focus > 0 else { return }
        recapDate = yesterday
        recapTasks = tasks
        // The task goal follows the day: however many tasks were due then.
        recapTaskGoal = allTasks.filter { t in
            !t.isTrashed && !t.isNote && (t.dueDate.map { cal.isDate($0, inSameDayAs: yesterday) } ?? false)
        }.count
        recapFocus = focus
        showDailyRecap = true
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
        // A single smooth fade-out (the row's removal transition) rather than a
        // bouncy spring, so the task doesn't stutter as it leaves.
        withAnimation(.easeInOut(duration: 0.28)) {
            TaskActions.delete(task)
        }
        showToast("“\(task.title)” deleted") {
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

/// Slim tappable bar reminding the user their free month is nearly up. Slides +
/// fades in shortly after the app opens rather than popping in.
private struct TrialCountdownBar: View {
    let daysLeft: Int
    let palette: Palette
    let onTap: () -> Void

    @State private var appeared = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.nunito(size: 12, weight: .bold))
                    .accessibilityHidden(true)
                Text("\(daysLeft) day\(daysLeft == 1 ? "" : "s") left in your free month")
                    .font(.nunito(size: 13, weight: .semibold))
                Text("See plans")
                    .font(.nunito(size: 13, weight: .bold))
                    .underline(true, color: palette.dark ? .evryWhite35 : .evryNavy28)
            }
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 36)
            .padding(.horizontal, EvrySpace.gutter)
            .background(palette.skySoft)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -14)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.3)) {
                appeared = true
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
        .environment(MembershipRouter())
        .modelContainer(for: [TaskItem.self, Note.self, Folder.self], inMemory: true)
}

extension View {
    /// Paints the app background behind a tab page *including* the keyboard
    /// region. Pages shrink above the keyboard, and without this the tab
    /// container's system background (black in dark mode) showed through
    /// behind the keyboard instead of the app's grey.
    func tabPageBackground(_ palette: Palette) -> some View {
        background(palette.bg.ignoresSafeArea())
    }
}
