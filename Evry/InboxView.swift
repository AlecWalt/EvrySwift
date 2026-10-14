//
//  InboxView.swift
//  Evry
//
//  Inbox tab — Today/All dropdown header, progress bar, and the grouped
//  task list, ported from the webapp's inboxTab.js.
//

import SwiftUI
import SwiftData

struct InboxView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void
    var inFocusMode: Bool = false
    /// Opens the chat with Evry (presented from the root, over everything).
    var onOpenChat: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(Appearance.self) private var appearance
    @Environment(ProjectNavigationState.self) private var projectNavState
    /// Set by ContentView while the chat (with Evry) is open above this page.
    @Environment(\.evryAway) private var evryAwayAbove
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    // Current timeline day (0 = today). Owned here so the shared header can show
    // the day title; the paging drag itself lives in InboxTimelineView.
    @State private var timelineDayOffset = 0
    /// Tasks or Schedule — Schedule by default.
    @State private var mode: InboxMode = .schedule
    /// How far the main card has slid aside for the menu (shared with the root,
    /// so the add handle rides along).
    @Environment(InboxDrawerState.self) private var drawer
    private var menuProgress: CGFloat { drawer.progress }
    @State private var menuAtDragStart: CGFloat = 0
    /// The finger's offset at the moment a swipe was recognised — subtracted, so
    /// the card starts moving from where it is instead of jumping ahead.
    @State private var lockDX: CGFloat = 0
    /// The menu has settled fully open (the tab bar steps away only then, and
    /// returns once it's fully closed — so nothing reflows mid-swipe).
    @State private var menuSettledOpen = false
    @State private var openHapticFired = false
    /// The tab bar can be faded directly (see TabBarFader).
    @State private var tabBarFades = true
    /// Length of the current settle (open/close after release), so the tab bar
    /// fade finishes with the card.
    @State private var settleDuration: Double = 0.26
    /// Safe-area insets measured while the menu is closed. The menu and card lay
    /// out with these, so the tab bar hiding/returning never reflows them.
    @State private var restInsets = EdgeInsets()
    /// Live finger offset while swiping between Schedule and Tasks.
    @State private var pageDrag = InboxPageDrag()
    @State private var navDrag: NavDrag = .none
    /// Bottom of the header, in global space — swipes that start up there
    /// belong to the header (e.g. swiping the day's name).
    @State private var headerMaxY: CGFloat = 0
    /// Bottom of the task list, in global space — swipes that start below it
    /// (empty space) switch views from anywhere, not just the outer thirds.
    @State private var tasksListMaxY: CGFloat = .infinity
    private enum NavDrag { case none, ignored, page, menu }
    /// The week strip, opened by tapping the day's name.
    @State private var weekOpen = false
    /// Direction of the last day change, so the title slides the right way.
    @State private var dayForward = true
    @AppStorage("inbox_hide_notes") private var hideNotes = false
    @AppStorage("inbox_hide_reschedule") private var hideReschedule = false
    // Multi-select
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    // Grouping the selection into a shaded folder.
    @State private var showGroupSheet = false
    @State private var pendingGroupTasks: [TaskItem] = []
    // Drag reorder
    @State private var draggingID: UUID? = nil
    // A task being dragged from Tasks onto the Schedule.
    @State private var scheduleDrag = ScheduleDragState()

    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed && (!hideNotes || !$0.isNote) } }

    var body: some View {
        swipeLayoutBody
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if !inFocusMode {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerMaxY = $0 }
                        // Raise above the timeline so the tools menu's floating
                        // bubbles fan down over the content.
                        .zIndex(1)
                }

                // Schedule and Tasks side by side; the visible one follows
                // the finger while swiping between them.
                GeometryReader { geo in
                    let w = geo.size.width
                    HStack(spacing: 0) {
                        schedulePage
                            .frame(width: w)
                        tasksPage
                            .frame(width: w)
                    }
                    .modifier(PageDragOffset(base: mode == .tasks ? -w : 0, drag: pageDrag))
                    // While a view swipe is underway the page rides along
                    // under the finger — so a swipe that began on a checkbox
                    // would end on it and count as a tap. No taps mid-swipe.
                    // (Page swipes only — the menu swipe moves the whole card,
                    // so nothing shifts under the finger, and disabling would
                    // briefly dim buttons as it ends.)
                    .disabled(navDrag == .page)
                    // Hold the page's own vertical scroll still during any
                    // sideways swipe, so it can't nudge or bounce underneath.
                    .scrollDisabled(navDrag == .page || navDrag == .menu)
                }
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(inFocusMode ? Color.clear : palette.bg)
            .overlay {
                if scheduleDrag.isActive {
                    ScheduleDragOverlay(drag: scheduleDrag, palette: palette, mode: mode,
                                        onSwitch: { setMode($0) })
                }
            }

            if isSelecting {
                MultiSelectBar(
                    selectedCount: selectedIDs.count,
                    palette: palette,
                    onDelete: deleteSelected,
                    onCancel: cancelSelection,
                    onGroup: startGroupSelected,
                    showGroup: true
                )
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelecting)
        // A task picked in search: page the timeline to that task's day (the
        // day's list then scrolls to and highlights it).
        .onChange(of: projectNavState.focusTaskID) { _, id in pageToFocusedTask(id) }
        .onAppear { pageToFocusedTask(projectNavState.focusTaskID) }
        // The recap sheet brings its own Evry; the header mark peeking out
        // behind it steps away meanwhile (Evry is never in two places at once).
        .environment(\.evryAway, evryAwayAbove)
        .sheet(isPresented: $showGroupSheet) {
            NewTaskGroupSheet(
                taskCount: pendingGroupTasks.count,
                palette: palette,
                onCreate: { name in createGroup(name: name) },
                onAddToExisting: { group in addToGroup(group) }
            )
            .environment(appearance)
        }
    }

    private var schedulePage: some View {
        ScheduleView(dayOffset: timelineDayOffset, palette: palette,
                     tasks: tasks, drag: scheduleDrag, onEditTask: onEdit)
    }

    private var tasksPage: some View {
        VStack(spacing: 0) {
            let overdueCount = globalOverdueTasks.count
            if overdueCount > 0 {
                overdueBanner(count: overdueCount)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: overdueCount)
            }

            InboxTimelineView(
                tasks: tasks, palette: palette, onEdit: onEdit, onDelete: onDelete,
                isSelecting: $isSelecting, selectedIDs: $selectedIDs,
                draggingID: $draggingID,
                scheduleDrag: scheduleDrag,
                dayOffset: $timelineDayOffset,
                onToggleSelect: toggleSelect,
                onListBottomChange: { tasksListMaxY = $0 }
            )
        }
    }

    // MARK: Swipe layout

    /// The main screen as a card over the menu. Swiping right on Schedule slides
    /// the card aside (shrinking into a rounded Liquid Glass card) to reveal the
    /// menu on the left; swiping left goes to Tasks. On Tasks, swipes in the
    /// middle third act on the task rows, and swipes in the outer thirds go back
    /// to Schedule.
    private var swipeLayoutBody: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let insets = restInsets
            let fullHeight = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            ZStack(alignment: .topLeading) {
                palette.bg

                // The menu: a wheel of days. Turning it moves the card's day.
                InboxDateWheel(dayOffset: $timelineDayOffset, palette: palette)
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
                // Still, like Claude's: the card simply slides over it.
                .modifier(DrawerMenuVisibility())

                // The card spans the whole screen — its white runs under the status
                // bar and home indicator, with the insets applied inside — so as it
                // slides aside it's a full-height card, not one that stops short.
                mainContent
                    .padding(.top, insets.top)
                    .padding(.bottom, insets.bottom)
                    .frame(width: w, height: fullHeight)
                    .modifier(GlassCardModifier(palette: palette))
                    .modifier(DrawerCardSlide(onClose: { closeMenu() }))
            }
            .ignoresSafeArea()
            .simultaneousGesture(navGesture(width: w))
            .onAppear { restInsets = geo.safeAreaInsets }
            .onChange(of: geo.safeAreaInsets) { _, new in
                // Only track insets while closed (tab bar in its usual place).
                if !menuSettledOpen && menuProgress <= 0.001 { restInsets = new }
            }
        }
        // The tab bar fades with the menu, in step with the finger (and eases
        // over the settle when released). If it can't be faded, it's hidden
        // once the menu is fully open instead.
        .toolbar(menuSettledOpen && !tabBarFades ? .hidden : .automatic, for: .tabBar)
        .background(DrawerTabBarSync(settleDuration: settleDuration,
                                     settledOpen: $menuSettledOpen, tabBarFades: $tabBarFades))
        .onAppear { RowSwipeZone.middleThirdOnly = mode == .tasks }
        .onDisappear {
            RowSwipeZone.middleThirdOnly = false
            TabBarFader.set(alpha: 1, animated: false)
        }
        .onChange(of: mode) { _, m in RowSwipeZone.middleThirdOnly = m == .tasks }
    }

    private var currentDayHasTasks: Bool {
        let day = addDays(Date(), timelineDayOffset)
        return tasks.contains { t in
            guard let due = t.dueDate else { return false }
            return Calendar.current.isDate(due, inSameDayAs: day)
        }
    }

    private func setMode(_ m: InboxMode) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            mode = m
            pageDrag.x = 0
        }
    }

    private func closeMenu(then action: (() -> Void)? = nil) {
        let duration = settle(to: 0, velocity: 0)
        if let action {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 20))
                action()
            }
        }
    }

    /// Finishes the slide carrying the finger's momentum: a critically damped
    /// spring (no bounce) that starts at exactly the release speed, then glides
    /// to rest — no speed break when you let go, no overshoot or wobble at the
    /// end. Returns roughly how long it takes.
    @discardableResult
    private func settle(to target: CGFloat, velocity: CGFloat) -> Double {
        let remaining = target - drawer.progress
        // The spring's initial velocity is relative to the distance left:
        // (points/s ÷ menu width) = progress/s, ÷ remaining = "remainings"/s.
        let progressPerSecond = velocity / InboxDrawerState.menuWidth
        let relative = abs(remaining) > 0.001 ? Double(progressPerSecond / remaining) : 0
        // Only carry momentum that's heading the right way.
        let initial = max(relative, 0)
        // A critically damped spring overshoots (and snaps back — the jitter at
        // high speeds) once its starting speed passes its natural frequency
        // ω = 2π / duration. So a faster flick gets a *shorter* spring, keeping
        // the release speed while staying just under that limit.
        let base = 0.38
        let limit = 0.85 * 2 * Double.pi / base
        let duration = initial > limit ? max(0.14, 0.85 * 2 * Double.pi / initial) : base
        // At the shortest spring, cap the speed too, so it can never overshoot.
        let startSpeed = min(initial, 0.85 * 2 * Double.pi / duration)
        settleDuration = duration * 0.75
        withAnimation(.interpolatingSpring(duration: duration, bounce: 0, initialVelocity: startSpeed)) {
            drawer.progress = target
        }
        return duration
    }

    private func navGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                let dx = v.translation.width, dy = v.translation.height
                if navDrag == .none {
                    // Decide once, at the start: header swipes, vertical drags,
                    // reorders and multi-select are left alone.
                    guard abs(dx) > abs(dy) * 1.2 else {
                        if abs(dy) > 10 { navDrag = .ignored }
                        return
                    }
                    if isSelecting || draggingID != nil || scheduleDrag.isEngaged || v.startLocation.y < headerMaxY {
                        navDrag = .ignored
                    } else if menuProgress > 0.5 {
                        navDrag = .menu
                    } else if mode == .schedule {
                        navDrag = dx > 0 ? .menu : .page
                    } else {
                        // Tasks: over the rows, only the outer thirds switch
                        // views (the middle third swipes the task). Below the
                        // list, or on a day with no tasks, anywhere does.
                        let x = v.startLocation.x
                        let overRows = currentDayHasTasks && v.startLocation.y < tasksListMaxY
                        navDrag = (!overRows || x < w / 3 || x > w * 2 / 3) ? .page : .ignored
                    }
                    menuAtDragStart = menuProgress
                    lockDX = dx
                    openHapticFired = menuAtDragStart >= 0.999
                }
                // Measured from where the swipe was recognised: 1:1 and linear,
                // no leap at the start.
                let travel = dx - lockDX
                switch navDrag {
                case .menu:
                    let p = min(max(menuAtDragStart + travel / InboxDrawerState.menuWidth, 0), 1)
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { drawer.progress = p }
                    // The open tap lands just before it's all the way out.
                    if p >= 0.9 && !openHapticFired {
                        openHapticFired = true
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                    if p < 0.8 { openHapticFired = false }
                case .page:
                    // Schedule can only move towards Tasks (left); Tasks only back
                    // towards Schedule (right). The other way rubber-bands.
                    let toward = mode == .schedule ? min(travel, 0) : max(travel, 0)
                    let away = mode == .schedule ? max(travel, 0) : min(travel, 0)
                    pageDrag.x = toward + away * 0.2
                default:
                    break
                }
            }
            .onEnded { v in
                let kind = navDrag
                navDrag = .none
                switch kind {
                case .menu:
                    // A deliberate flick decides on its own; otherwise go by where
                    // the momentum would carry the card.
                    let projected = menuAtDragStart + (v.predictedEndTranslation.width - lockDX) / InboxDrawerState.menuWidth
                    let open = abs(v.velocity.width) > 350 ? v.velocity.width > 0 : projected > 0.5
                    // Carries on at the finger's speed, in a straight line — and a
                    // single soft tap as it opens (unless the drag already gave it).
                    settle(to: open ? 1 : 0, velocity: v.velocity.width)
                    if open && !openHapticFired {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                    openHapticFired = false
                case .page:
                    let dx = v.predictedEndTranslation.width - lockDX
                    let flip = mode == .schedule ? dx < -w * 0.3 : dx > w * 0.3
                    if flip { UISelectionFeedbackGenerator().selectionChanged() }
                    setMode(flip ? (mode == .schedule ? .tasks : .schedule) : mode)
                default:
                    break
                }
            }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Day ⇄ week: tapping the day pushes it off to the left and the week
            // slides in from the right; the chevron flips and moves to the edge.
            ZStack(alignment: .leading) {
                if weekOpen {
                    InboxWeekStrip(dayOffset: $timelineDayOffset, palette: palette)
                        .padding(.leading, EvrySpace.tap - 14)   // room for the chevron at the edge
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            // Fades quickly on the way out, so it's gone before the
                            // Evry mark returns.
                            removal: .move(edge: .trailing)
                                .combined(with: .opacity.animation(.easeOut(duration: 0.16)))))
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        timelineHeaderTitle
                        Spacer(minLength: EvrySpace.tap)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            // One chevron for both states: just after the day's name pointing
            // right, or at the screen's edge pointing left. It slides and turns.
            .overlay(alignment: .leading) {
                weekChevron
                    .offset(x: weekOpen ? -14 : titleWidth + 2)
                    .animation(.spring(response: 0.45, dampingFraction: 0.86), value: weekOpen)
                    .animation(EvryMotion.settle, value: titleWidth)
            }
            // The Evry mark stays put and simply fades while the week is shown —
            // coming back only once the week strip has cleared.
            .overlay(alignment: .trailing) {
                evryButton
                    .opacity(weekOpen ? 0 : 1)
                    .scaleEffect(weekOpen ? 0.8 : 1)
                    .animation(weekOpen ? .easeOut(duration: 0.15) : .easeOut(duration: 0.22).delay(0.3),
                               value: weekOpen)
                    .allowsHitTesting(!weekOpen)
                    .accessibilityHidden(weekOpen)
            }

            pageHint
        }
        .onChange(of: timelineDayOffset) { old, new in dayForward = new >= old }
        .onChange(of: mode) { _, m in
            // Multi-select belongs to the task list.
            if m == .schedule && isSelecting { cancelSelection() }
        }
    }

    /// Which view is showing, in the swipe layout: the view's name and two dots.
    private var pageHint: some View {
        HStack(spacing: 8) {
            Text(mode.title)
                .font(.evrySmall)
                .foregroundStyle(palette.textSec)
                .contentTransition(.opacity)
            HStack(spacing: 4) {
                ForEach(InboxMode.allCases.reversed()) { m in
                    Capsule()
                        .fill(m == mode ? palette.primary : palette.border)
                        .frame(width: m == mode ? 14 : 6, height: 6)
                }
            }
        }
        .animation(EvryMotion.settle, value: mode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.title) view")
        .accessibilityHint("Swipe left for Tasks, or right for the menu.")
    }

    /// Width of the day's name, so the chevron can sit just after it.
    @State private var titleWidth: CGFloat = 0

    private func toggleWeek() {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { weekOpen.toggle() }
    }

    /// The chevron: points right beside the day's name, flips to point left at
    /// the screen's edge while the week is showing. Tapping it goes back.
    private var weekChevron: some View {
        Button(action: toggleWeek) {
            Image(systemName: "chevron.right")
                .font(.nunito(size: 16, weight: .heavy))
                .foregroundStyle(palette.textSec)
                .rotationEffect(.degrees(weekOpen ? 180 : 0))
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(weekOpen ? "Back to the day" : "Show the week")
    }

    // Evry's mark: opens the chat with Evry (Distill, Pomo, Write).
    private var evryButton: some View {
        Button(action: onOpenChat) {
            Image("EvryPlainMark")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                // Leaves while the chat is open — Evry is there instead.
                .evryPresence()
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.88))
        .accessibilityLabel("Chat with Evry")
    }

    /// The day's name, then the chevron. Tap to show the week; swipe the name to
    /// go a day forward or back. (Other days add their date, so it's clear which
    /// Monday this is.)
    private var timelineHeaderTitle: some View {
        let date = addDays(Date(), timelineDayOffset)
        let isToday = timelineDayOffset == 0
        return HStack(alignment: .center, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(date.formatted(.dateTime.weekday(.wide)))
                    .font(.evryH2)
                    .tracking(EvryTracking.h2)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .id(timelineDayOffset)
                    .transition(.push(from: dayForward ? .trailing : .leading))
                if !isToday {
                    Text(date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.nunito(size: 16, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                        .transition(.opacity)
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleWeek)
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { v in
                        guard abs(v.translation.width) > 40, abs(v.translation.width) > abs(v.translation.height) else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(EvryMotion.settle) { timelineDayOffset += v.translation.width < 0 ? 1 : -1 }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isToday ? "Today, \(date.formatted(.dateTime.weekday(.wide)))"
                                        : date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .accessibilityHint("Swipe to change the day.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: timelineDayOffset += 1
                case .decrement: timelineDayOffset -= 1
                @unknown default: break
                }
            }
        }
        // Leaves room for the chevron, which sits just after the name.
        .padding(.trailing, EvrySpace.tap)
        .animation(EvryMotion.settle, value: timelineDayOffset)
    }

    // MARK: Overdue helpers

    private var globalOverdueTasks: [TaskItem] {
        let today = Calendar.current.startOfDay(for: Date())
        return tasks.filter { !$0.completed && !$0.isNote && $0.deletedAt == nil }
            .filter { d in guard let due = d.dueDate else { return false }; return due < today }
    }

    private func overdueBanner(count: Int) -> some View {
        // No red: urgency is carried by the alert glyph and the words, on a calm
        // sky-soft panel with a sky ring.
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(Palette.danger)
                .accessibilityHidden(true)

            Text("\(count) overdue task\(count == 1 ? "" : "s")")
                .font(.evrySmall)
                .foregroundStyle(palette.text)

            Spacer()

            if !hideReschedule {
                BurstPillButton(title: "Move all to today", color: Palette.danger) {
                    let today = Calendar.current.startOfDay(for: Date())
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        for task in globalOverdueTasks { task.dueDate = today }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: EvrySpace.tap + 8)
        .background(palette.skySoft, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous).strokeBorder(Color.evrySky, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: Search focus

    /// Moves the timeline to the day the focused (searched-for) task is due.
    private func pageToFocusedTask(_ id: UUID?) {
        guard let id, let due = allTasks.first(where: { $0.uid == id })?.dueDate else { return }
        if isSelecting { cancelSelection() }
        let cal = Calendar.current
        let offset = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                        to: cal.startOfDay(for: due)).day ?? 0
        guard offset != timelineDayOffset else { return }
        withAnimation(.easeInOut(duration: 0.3)) { timelineDayOffset = offset }
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

    /// Open the folder sheet for the current selection.
    private func startGroupSelected() {
        let sel = tasks.filter { selectedIDs.contains($0.uid) }
        guard !sel.isEmpty else { return }
        pendingGroupTasks = sel
        showGroupSheet = true
    }

    /// Create a folder from the pending selection and drop the selected tasks in.
    private func createGroup(name: String) {
        guard !pendingGroupTasks.isEmpty else { return }
        // Colour is automatic: the next sky→navy shade in sequence.
        let group = TaskGroup(name: name)
        group.shade = FolderShade.next(FolderShade.taskGroupsKey)
        group.sortOrder = (allTasks.compactMap { $0.group?.sortOrder }.max() ?? -1) + 1
        context.insert(group)
        addPendingTasks(to: group)
    }

    /// Drop the pending selection into an existing folder.
    private func addToGroup(_ group: TaskGroup) {
        guard !pendingGroupTasks.isEmpty else { return }
        addPendingTasks(to: group)
    }

    private func addPendingTasks(to group: TaskGroup) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            for task in pendingGroupTasks { task.group = group }
        }
        try? context.save()
        pendingGroupTasks = []
        cancelSelection()
    }

}

// MARK: - Brain Dump sheet
//
// The Brain Dump engine + UI now live in BrainDumpSheet.swift (shared by the
// Inbox and Notes). The inbox presents it with a `.tasks` context.


// MARK: - Timeline layout

private struct InboxTimelineView: View {
    let tasks: [TaskItem]
    let palette: Palette
    let onEdit: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<UUID>
    @Binding var draggingID: UUID?
    let scheduleDrag: ScheduleDragState
    @Binding var dayOffset: Int
    var onToggleSelect: (TaskItem) -> Void
    /// Reports where the task list ends (global y), for the swipe layout.
    var onListBottomChange: (CGFloat) -> Void = { _ in }

    // Measured content height of the current day page — the container sizes to it
    // (capped) so it adapts as tasks / subtask lists expand and collapse.
    @State private var contentHeight: CGFloat = 170

    private let cal = Calendar.current
    private var today: Date { cal.startOfDay(for: Date()) }


    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let curDate = cal.date(byAdding: .day, value: dayOffset, to: today) ?? today
            // In multi-select the container expands to the full height so there's
            // room to see where tasks are being reordered; otherwise it fits the
            // measured content (so it grows/shrinks with expanded subtasks), capped
            // to the available height — keeping the list's bottom edge clear of the
            // floating add-task handle and tab bar.
            let bottomGutter: CGFloat = 132
            let fitted = min(max(contentHeight, 120), max(200, geo.size.height - bottomGutter))
            let listH = isSelecting ? geo.size.height : fitted
            VStack(spacing: 0) {
                // Capped, self-contained vertical-scroll list.
                dayPage(for: curDate, off: dayOffset)
                    .frame(width: w, height: listH)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { onListBottomChange($0) }
                // The task region is flat — no inner-shadow well darkening the
                // rows; rows soften out at the edges via `timelineScrollFade`.
                .clipShape(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))

                // Blank space below the list (a swipe here switches views).
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(edges: .bottom)
        // Leaving multi-select can tear down a reorder handle mid-drag (its
        // onEnded never fires) — clear any lingering drag so rows don't float.
        .onChange(of: isSelecting) { _, selecting in
            if !selecting && draggingID != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    draggingID = nil
                }
            }
        }
        // Grow/shrink the container as the visible day's content changes (tasks
        // added/removed, subtasks expanded/collapsed).
        .onPreferenceChange(TimelinePageHeightKey.self) { h in
            guard h > 0 else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { contentHeight = h }
        }
    }

    @ViewBuilder
    private func dayPage(for date: Date, off: Int) -> some View {
        let dayTasks = tasks.filter { t in
            guard let due = t.dueDate else { return false }
            return cal.isDate(due, inSameDayAs: date) && !t.isTrashed
        }
        TimelineDayPage(
            date: date,
            isToday: off == 0,
            dayTasks: dayTasks,
            palette: palette,
            onEdit: onEdit,
            onDelete: onDelete,
            isSelecting: $isSelecting,
            selectedIDs: $selectedIDs,
            draggingID: $draggingID,
            scheduleDrag: scheduleDrag,
            onToggleSelect: onToggleSelect,
            allTaskCount: tasks.count,
            reportsHeight: off == dayOffset
        )
    }
}

/// Carries the current day page's intrinsic content height up to the timeline
/// container so it can size to the visible day (collapsed or with subtasks open).
private struct TimelinePageHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    let scheduleDrag: ScheduleDragState
    var onToggleSelect: (TaskItem) -> Void
    /// Live finger offset of a reorder drag. Local to this page (not a binding up
    /// to InboxView) so each drag frame only re-renders this list, not the page.
    @State private var dragOffset: CGFloat = 0
    /// Total task count (changes on add/delete, not on day-switch) — drives the
    /// add/remove row animation without re-animating on every day change.
    var allTaskCount: Int = 0
    /// Only the current (front) page reports its content height up to the parent,
    /// so the container can size to the visible day (incl. expanded subtasks).
    var reportsHeight: Bool = false
    /// True while a task is being swiped (complete/delete) — suppresses the row's
    /// taps/holds so a finger-lift can't also fire them. Local to this page.
    @State private var taskSwiping = false
    // Tap-and-drag select state for this day page.
    @State private var dragSel = DragSelector()
    // Row step (measured once at the start of a reorder) so the drag math stays
    // stable instead of recomputing from live frames every frame.
    @State private var dragStride: CGFloat = 78

    @AppStorage("inbox_hide_completed") private var hideCompleted = false
    @State private var showCompleted = false
    @State private var showRescheduleFor: TaskItem? = nil
    @State private var multiSelectArm: DispatchWorkItem? = nil
    @State private var suppressTapAction = false
    // Which task-group folders are expanded (collapsed by default).
    @State private var expandedGroups: Set<UUID> = []
    // Per-task nonce bumped on swipe-to-complete so the checkbox plays the same
    // completion animation + delayed commit as a tap.
    @State private var completeTokens: [UUID: Int] = [:]
    @Environment(\.modelContext) private var context
    @Environment(ProjectNavigationState.self) private var projectNavState
    /// The task being spotlighted after it was picked in search.
    @State private var highlightID: UUID? = nil

    var body: some View {
        ScrollViewReader { proxy in
            pageScroll
                .onAppear { focusSearchedTask(proxy) }
                .onChange(of: projectNavState.focusTaskID) { _, _ in focusSearchedTask(proxy) }
                // The Inbox pages to the task's day first; act once it's showing.
                .onChange(of: date) { _, _ in focusSearchedTask(proxy) }
        }
    }

    /// If the task picked in search is on this (front) day: reveal it — opening
    /// its folder or the Completed section if it's tucked away — scroll it into
    /// view, and play a brief highlight.
    private func focusSearchedTask(_ proxy: ScrollViewProxy) {
        guard reportsHeight, let id = projectNavState.focusTaskID,
              let task = dayTasks.first(where: { $0.uid == id }) else { return }
        projectNavState.focusTaskID = nil
        if task.completed {
            showCompleted = true
        } else if let group = task.group {
            expandedGroups.insert(group.uid)
        }
        // Let the search sheet finish closing and the day finish paging in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.25)) { highlightID = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                guard highlightID == id else { return }
                withAnimation(.easeOut(duration: 0.5)) { highlightID = nil }
            }
        }
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Tasks — manual order (sortOrder, then newest), with pinned tasks
                // floated to the top. The partition is stable, and the loose list
                // and each folder are filtered from it, so a pinned task tops the
                // Inbox list or its own folder.
                let sorted = sortPinnedFirst(dayTasks.sorted {
                    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                    return $0.createdAt > $1.createdAt
                })
                let activeTasks = sorted.filter { !$0.completed }
                let completedDayTasks = sorted.filter { $0.completed && !$0.isNote }
                let hasVisible = !activeTasks.isEmpty || (!completedDayTasks.isEmpty && !hideCompleted)

                if !hasVisible {
                    // Shared empty state, matching Habits and Notes — but no
                    // mascot: the header's Evry mark is always on screen here.
                    EmptyStateView(
                        icon: "tray",
                        title: "Nothing due this day",
                        text: isToday ? "Swipe up on the handle below to add a task." : "Enjoy the free day.",
                        palette: palette
                    )
                    .padding(.top, 28)
                    .transition(.opacity)
                } else {
                    let ungrouped = activeTasks.filter { $0.group == nil }
                    let groupSections = groupedSections(activeTasks)
                    if !activeTasks.isEmpty {
                        VStack(spacing: 8) {
                            // Loose tasks reorder among themselves.
                            ForEach(ungrouped) { task in
                                timelineRow(task, in: ungrouped)
                            }
                            // Grouped tasks live inside collapsible folders.
                            ForEach(groupSections, id: \.group.uid) { section in
                                groupFolder(section.group, members: section.members)
                            }
                        }
                        // Same 20pt page margin as the title and every other tab.
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        // When this list first appears (the day's first task,
                        // replacing the empty state) it enters like a row does.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                            removal: .opacity
                        ))
                    }

                    if !completedDayTasks.isEmpty && !hideCompleted {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { showCompleted.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                SectionLabel(text: "Completed (\(completedDayTasks.count))", palette: palette)
                                Image(systemName: "chevron.down")
                                    .font(.nunito(size: 11, weight: .bold))
                                    .foregroundStyle(palette.textSec)
                                    .rotationEffect(.degrees(showCompleted ? 180 : 0))
                                    .accessibilityHidden(true)
                                Spacer()
                            }
                            // A taller, full-width hit area so the toggle is easy to
                            // tap without catching the first completed row.
                            .padding(.vertical, 4)
                            .frame(minHeight: EvrySpace.tap)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(showCompleted ? "Hides completed tasks" : "Shows completed tasks")
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .timelineScrollFade()
                        if showCompleted {
                            VStack(spacing: 8) {
                                ForEach(completedDayTasks) { task in
                                    timelineRow(task, in: completedDayTasks)
                                }
                            }
                            .padding(.horizontal, 20)
                            // Breathing room below the toggle so the first row isn't
                            // crowding the header text.
                            .padding(.top, 12)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, minHeight: 10, alignment: .top)
            // Animate rows in/out when a task is added or removed. Lives on this
            // always-present container (not the list itself) so the very first
            // task — which swaps the empty state for the list — animates too.
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: allTaskCount)
            // Pinning / unpinning glides the row to (or from) the top.
            .animation(EvryMotion.settle, value: pinnedIDs)
            // Report the intrinsic content height so the container can grow/shrink
            // to fit (e.g. when a task's subtasks expand). Only the front page emits.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TimelinePageHeightKey.self,
                        value: reportsHeight ? proxy.size.height : 0
                    )
                }
            )
        }
        // Lock vertical scroll while reordering or mid swipe-to-complete/delete so
        // the container doesn't scroll under an active horizontal swipe.
        .scrollDisabled(draggingID != nil || taskSwiping || dragSel.isActive || scheduleDrag.isEngaged)
        .onChange(of: isSelecting) { _, selecting in if !selecting { dragOffset = 0 } }
        // Leading, accent-coloured indicator instead of the grey system one.
        .evryScrollIndicator(palette)
        .coordinateSpace(.named("dragSelect"))
        .onPreferenceChange(SelectRowFrameKey.self) { dragSel.frames = $0 }
    }

    /// The day's pinned task ids — drives the pin/unpin move animation.
    private var pinnedIDs: Set<UUID> { Set(dayTasks.filter(\.pinned).map(\.uid)) }

    // MARK: Task groups

    /// The day's grouped tasks, bucketed by folder in folder sort order.
    private func groupedSections(_ active: [TaskItem]) -> [(group: TaskGroup, members: [TaskItem])] {
        let withGroup = active.filter { $0.group != nil }
        var order: [UUID] = []
        for t in withGroup where !order.contains(t.group!.uid) { order.append(t.group!.uid) }
        return order.compactMap { id -> (group: TaskGroup, members: [TaskItem])? in
            guard let group = withGroup.first(where: { $0.group?.uid == id })?.group else { return nil }
            return (group, withGroup.filter { $0.group?.uid == id })
        }
        .sorted { $0.group.sortOrder < $1.group.sortOrder }
    }

    /// A collapsible folder holding grouped tasks, marked with its sky/navy shade.
    @ViewBuilder
    private func groupFolder(_ group: TaskGroup, members: [TaskItem]) -> some View {
        let expanded = expandedGroups.contains(group.uid)
        let tint = group.tint(palette)
        // Opens like the "Completed" section: an easeInOut reveal of the members
        // below the header (no drawer/tuck).
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if expanded { expandedGroups.remove(group.uid) } else { expandedGroups.insert(group.uid) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.nunito(size: 18))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name.isEmpty ? "Folder" : group.name)
                            .font(.evryLabel)
                            .foregroundStyle(palette.text)
                        Text("\(members.count) task\(members.count == 1 ? "" : "s")")
                            .font(.nunito(size: 13))
                            .foregroundStyle(palette.textSec)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.nunito(size: 12, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 12)
                // Flat like the task rows: white fill + hairline, no shadow.
                .evryField(palette)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) { ungroup(members) } label: {
                    Label("Ungroup", systemImage: "folder.badge.minus")
                }
            }
            .timelineScrollFade()

            if expanded {
                VStack(spacing: 8) {
                    ForEach(members) { task in
                        timelineRow(task, in: members)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Not indented — instead a faint rail in the folder's colour runs
                // down the page margin, continuous along every task in the folder.
                .background(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: 3)
                        .offset(x: -11)
                }
                .padding(.top, 8)
            }
        }
    }

    /// Detach the given tasks from their folder (and delete a now-empty folder).
    private func ungroup(_ members: [TaskItem]) {
        let group = members.first?.group
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            for task in members { task.group = nil }
        }
        if let group, (group.tasks ?? []).isEmpty { context.delete(group) }
        try? context.save()
    }

    /// A task row with the full inbox interaction set: swipe to complete/delete,
    /// hold-and-release to reschedule, longer hold to multi-select. Reorder is
    /// handle-only (multi-select) so a plain drag never blocks vertical scroll.
    /// A horizontal swipe sets `taskSwiping` so the day filmstrip stands down and
    /// the swipe doesn't page the day.
    @ViewBuilder
    private func timelineRow(_ task: TaskItem, in items: [TaskItem]) -> some View {
        let isSelf = draggingID == task.uid
        // Live reorder preview: work out where every row sits in the previewed new
        // order, so non-dragged rows shift to open a gap under the hovered spot.
        let plan = draggingID.map { reorderPlan(draggedID: $0, in: items, offset: dragOffset) }
        let inGroup = plan?.group.contains { $0.uid == task.uid } ?? false
        let stride = dragStride
        let neighborShift: CGFloat = {
            guard let plan, !inGroup,
                  let newIdx = plan.newItems.firstIndex(where: { $0.uid == task.uid }),
                  let origIdx = items.firstIndex(where: { $0.uid == task.uid }) else { return 0 }
            return CGFloat(newIdx - origIdx) * stride
        }()
        // Selected rows gather into a contiguous stack under the finger; everyone
        // else steps to its previewed slot.
        let yOff: CGFloat = {
            guard inGroup, let plan, let draggedID = draggingID,
                  let gi = plan.group.firstIndex(where: { $0.uid == task.uid }),
                  let gd = plan.group.firstIndex(where: { $0.uid == draggedID }),
                  let oi = items.firstIndex(where: { $0.uid == task.uid }),
                  let od = items.firstIndex(where: { $0.uid == draggedID })
            else { return neighborShift }
            return dragOffset + CGFloat((od - oi) + (gi - gd)) * stride
        }()
        let elevated = inGroup
        let isLifted = scheduleDrag.liftedID == task.uid
        let isCarried = isLifted && scheduleDrag.task?.uid == task.uid
        SwipeActionRow(
            leadingAction: task.isNote || task.completed ? nil : SwipeActionRow.Action(
                label: "Done", icon: "checkmark", color: Palette.doneFill,
                action: { completeTokens[task.uid, default: 0] += 1 }
            ),
            trailingAction: SwipeActionRow.Action(
                label: "Delete", icon: "trash.fill", color: Palette.danger,
                action: { onDelete(task) }
            ),
            isDragging: draggingID != nil || scheduleDrag.isEngaged,
            onHorizontalSwipeChanged: { active in
                taskSwiping = active
                if active {
                    // Suppress the row's own buttons/taps so the finger-lift that
                    // ends a swipe can't also fire the trash button or open the editor.
                    suppressTapAction = true
                    multiSelectArm?.cancel()
                    multiSelectArm = nil
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { suppressTapAction = false }
                }
            }
        ) {
            TaskRowView(
                task: task,
                palette: palette,
                onToggle: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        TaskActions.toggle(task, context: context)
                    }
                },
                onEdit: { rowTap { onEdit(task) } },
                onDelete: { rowTap { onDelete(task) } },
                onToggleSubtask: { subtask in
                    if let idx = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                        var updated = task.subtasks
                        updated[idx].completed.toggle()
                        task.subtasks = updated
                    }
                },
                isSelecting: isSelecting,
                isSelected: selectedIDs.contains(task.uid),
                onSelect: { rowTap { onToggleSelect(task) } },
                onDragSelect: { loc in
                    applyDragSelect(&dragSel, anchor: task, location: loc,
                                    ordered: items, selected: &selectedIDs)
                },
                onDragSelectEnd: { dragSel.end() },
                hideDueDate: true,
                centered: true,
                cornerRadius: EvryRadius.card,
                completeToken: completeTokens[task.uid] ?? 0
            )
        }
        // Insertion stays gentle; removal (delete) shrinks + fades away — a clear
        // but quiet exit, deliberately softer than the completion burst.
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.82, anchor: .center))
        ))
        // Search spotlight: a navy outline (the focus-ring treatment) with a faint
        // glow, fading out after a moment — the row itself is left untouched.
        .overlay {
            RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
                .strokeBorder(palette.primary, lineWidth: 2)
                .shadow(color: palette.primary.opacity(0.25), radius: 3)
                .opacity(highlightID == task.uid ? 1 : 0)
                .allowsHitTesting(false)
        }
        .id(task.uid)
        // Multi-select reorder handle (trailing) — drag to reorder the selection.
        // Attached BEFORE .offset so the handle travels with the row as it moves.
        .overlay(alignment: .trailing) {
            if isSelecting {
                Image(systemName: "line.3.horizontal")
                    .font(.nunito(size: 16, weight: .semibold))
                    .foregroundStyle(elevated ? palette.primary : palette.textSec)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .highPriorityGesture(reorderHandleGesture(task, in: items))
                    .padding(.trailing, 6)
            }
        }
        .scaleEffect(isSelf || (isLifted && !isCarried) ? 1.04 : 1.0)
        // While it's carried to the Schedule, the row stays behind as a faint ghost.
        .opacity(isCarried ? 0.35 : 1)
        // Rows are flat at rest; only rows being dragged get a very subtle lift
        // (navy-tinted; black only in dark mode). `elevated` is only true mid-drag.
        .shadow(color: elevated || isLifted ? (palette.dark ? Color.black : .evryNavy).opacity(palette.dark ? 0.3 : 0.08) : .clear,
                radius: elevated || isLifted ? 10 : 0, y: elevated || isLifted ? 4 : 0)
        .offset(y: yOff)
        .zIndex(elevated ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelf)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isLifted)
        // Only the stepped neighbour offset is animated — the finger-follow stays direct.
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: neighborShift)
        .popover(isPresented: Binding(
            get: { showRescheduleFor?.uid == task.uid },
            set: { if !$0 { showRescheduleFor = nil } }
        )) {
            rescheduleMenu(for: task)
        }
        // A 0.5s hold lifts the row: drag it to carry the task onto the
        // Schedule, or let go in place to multi-select. A UIKit long press on
        // the scroll view (`HoldDragCatcher`) rather than a SwiftUI sequenced
        // gesture, which stole vertical scrolls inside folders.
        .background(HoldDragCatcher(
            onLift: { p in holdBegan(task, at: p) },
            onMove: { p in holdMoved(task, to: p) },
            onEnd: { cancelled in holdEnded(task, cancelled: cancelled) }
        ))
        // Reorder is intentionally handle-only (multi-select mode) so a plain
        // tap-and-drag on a row never steals the ScrollView's vertical pan —
        // keeping scroll-over-tasks reliable.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3, maximumDistance: 10)
                .onEnded { _ in
                    guard !isSelecting, draggingID == nil, !taskSwiping,
                          !task.isNote, !task.completed else { return }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    suppressTapAction = true
                    showRescheduleFor = task
                }
        )
        // Rows soften into a blur — and shrink slightly — as they scroll past the
        // top/bottom edges of the day list, so tasks fade out rather than
        // hard-clipping at the container.
        .timelineScrollFade()
    }

    /// The hold completed: lift the row (declined mid-reorder, multi-select or
    /// a swipe).
    private func holdBegan(_ task: TaskItem, at point: CGPoint) -> Bool {
        guard draggingID == nil, !isSelecting, !taskSwiping, !scheduleDrag.isEngaged else { return false }
        showRescheduleFor = nil
        suppressTapAction = true
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scheduleDrag.lift(task, at: point, from: .tasks)
        }
        return true
    }

    /// The lifted row is moving: carry it towards the Schedule. Notes and
    /// finished tasks don't go on the schedule — they only multi-select.
    private func holdMoved(_ task: TaskItem, to point: CGPoint) {
        guard !task.isNote, !task.completed else { return }
        if scheduleDrag.move(task, to: point) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// The finger lifted: land a carried task on the Schedule, or — if the row
    /// was only held — start multi-select, as a plain hold always has.
    private func holdEnded(_ task: TaskItem, cancelled: Bool) {
        guard scheduleDrag.liftedID == task.uid else { return }
        if cancelled {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { scheduleDrag.reset() }
            return
        }
        if scheduleDrag.isActive {
            let placed = scheduleDrag.dropTime != nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { _ = scheduleDrag.finish() }
            if placed { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            return
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 0.7)
        withAnimation(.spring(response: 0.3)) {
            scheduleDrag.reset()
            isSelecting = true
            selectedIDs.insert(task.uid)
        }
    }

    private func rowTap(_ action: () -> Void) {
        if suppressTapAction { suppressTapAction = false; return }
        action()
    }

    /// Drag gesture for the multi-select reorder handle. Dragging a selected
    /// row moves the whole selection; dragging an unselected one moves just it.
    private func reorderHandleGesture(_ task: TaskItem, in items: [TaskItem]) -> some Gesture {
        // Measured in the list's fixed coordinate space. The handle rides on the
        // row it's dragging, so in its own (moving) space every offset change fed
        // back into the next translation — the row jittered under the finger.
        DragGesture(minimumDistance: 4, coordinateSpace: .named("dragSelect"))
            .onChanged { v in
                if draggingID == nil {
                    // Snapshot the true row step once, so the live preview and the
                    // drop use the same stable value (no per-frame recompute jitter).
                    dragStride = measuredStride()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { draggingID = task.uid }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                dragOffset = v.translation.height
            }
            .onEnded { v in
                finishReorder(draggedID: task.uid, in: items, finalOffset: v.translation.height)
            }
    }

    /// The smallest on-screen step between adjacent rows (from the drag-select
    /// frames). Using the minimum ignores the large gaps across folder/section
    /// headers, so it reflects a single row's true height + spacing.
    private func measuredStride() -> CGFloat {
        let ys = dragSel.frames.values.map(\.midY).sorted()
        guard ys.count >= 2 else { return 78 }
        let gaps = zip(ys.dropFirst(), ys).map { $0 - $1 }.filter { $0 > 8 }
        return gaps.min() ?? 78
    }

    /// The previewed ordering for the current drag: the dragged task — plus the
    /// rest of the selection if it's selected — treated as a contiguous block
    /// inserted at the hovered position. Non-group items keep their relative
    /// order. Used both for the live shift and the final drop.
    private func reorderPlan(draggedID: UUID, in items: [TaskItem], offset: CGFloat) -> (newItems: [TaskItem], group: [TaskItem]) {
        let rowH = dragStride
        guard let d = items.firstIndex(where: { $0.uid == draggedID }) else { return (items, []) }
        let step = Int((offset / rowH).rounded())
        let target = max(0, min(items.count - 1, d + step))
        let movesGroup = isSelecting && selectedIDs.contains(draggedID)
        let group = movesGroup ? items.filter { selectedIDs.contains($0.uid) } : [items[d]]
        let groupIDs = Set(group.map(\.uid))
        let rest = items.enumerated().filter { !groupIDs.contains($0.element.uid) }
        // Dragging down lands *after* the hovered row (so the last slot is
        // reachable); dragging up lands before it.
        let insertAt = rest.filter { target > d ? $0.offset <= target : $0.offset < target }.count
        var newItems = rest.map(\.element)
        newItems.insert(contentsOf: group, at: min(insertAt, newItems.count))
        return (newItems, group)
    }

    /// Commits the previewed order to `sortOrder` on drop.
    private func finishReorder(draggedID: UUID, in items: [TaskItem], finalOffset: CGFloat) {
        let (newItems, _) = reorderPlan(draggedID: draggedID, in: items, offset: finalOffset)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            for (i, t) in newItems.enumerated() { t.sortOrder = i }
            draggingID = nil
            dragOffset = 0
        }
    }

    private func rescheduleMenu(for task: TaskItem) -> some View {
        VStack(spacing: 0) {
            rescheduleRow(label: "Tomorrow", icon: "arrow.right", date: addDays(Date(), 1), task: task)
            Rectangle().fill(palette.border).frame(height: 1)
            rescheduleRow(label: "This weekend", icon: "beach.umbrella", date: TaskActions.nextWeekdayDate(6), task: task)
            Rectangle().fill(palette.border).frame(height: 1)
            rescheduleRow(label: "Next week", icon: "calendar", date: TaskActions.nextWeekdayDate(1), task: task)
        }
        .frame(width: 220)
        .padding(.vertical, 4)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(palette.card)
    }

    private func rescheduleRow(label: String, icon: String, date: Date, task: TaskItem) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                TaskActions.reschedule(task, to: date)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showRescheduleFor = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.nunito(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: EvrySpace.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared drag-select

/// Tap-and-drag multi-select shared by every inbox layout: extends `selected`
/// to cover the rows between the drag's anchor and the finger's row, with light
/// haptics on start and each change.
private func applyDragSelect(_ selector: inout DragSelector,
                             anchor: TaskItem, location: CGPoint,
                             ordered: [TaskItem], selected: inout Set<UUID>) {
    let began = !selector.isActive
    let newSel = selector.selection(anchor: anchor, location: location,
                                    ordered: ordered, current: selected)
    if began { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    if newSel != selected {
        selected = newSel
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - New task-group sheet

/// Names a new folder for the selected tasks. Its colour is automatic (the next
/// sky→navy shade), previewed here.
private struct NewTaskGroupSheet: View {
    let taskCount: Int
    let palette: Palette
    var onCreate: (String) -> Void
    var onAddToExisting: (TaskGroup) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Appearance.self) private var appearance

    @Query(sort: \TaskGroup.sortOrder) private var allGroups: [TaskGroup]
    /// Only folders that still hold tasks — an empty folder is never offered.
    private var groups: [TaskGroup] {
        allGroups.filter { !(($0.tasks ?? []).filter { !$0.isTrashed }).isEmpty }
    }

    @State private var name = ""

    /// The shade the new folder will be given.
    private var tint: Color { palette.folderColor(shade: FolderShade.peek(FolderShade.taskGroupsKey)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Existing folders — tap one to drop the selection straight in.
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add to a folder")
                                .font(.evrySmall)
                                .foregroundStyle(palette.textSec)
                            VStack(spacing: 8) {
                                ForEach(groups) { group in
                                    let gTint = group.tint(palette)
                                    let count = (group.tasks ?? []).filter { !$0.isTrashed }.count
                                    Button {
                                        onAddToExisting(group)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "folder.fill")
                                                .font(.nunito(size: 16))
                                                .foregroundStyle(gTint)
                                                .frame(width: 34, height: 34)
                                                .background(gTint.opacity(0.15), in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
                                                .accessibilityHidden(true)
                                            Text(group.name.isEmpty ? "Folder" : group.name)
                                                .font(.nunito(size: 16, weight: .semibold))
                                                .foregroundStyle(palette.text)
                                            Spacer()
                                            Text("\(count) task\(count == 1 ? "" : "s")")
                                                .font(.nunito(size: 13))
                                                .foregroundStyle(palette.textSec)
                                            Image(systemName: "plus")
                                                .font(.nunito(size: 12, weight: .bold))
                                                .foregroundStyle(palette.text)
                                                .accessibilityHidden(true)
                                        }
                                        .padding(.horizontal, EvrySpace.gutter)
                                        .padding(.vertical, 10)
                                        .frame(minHeight: EvrySpace.storeHeight)
                                        .evryField(palette, cornerRadius: EvryRadius.field)
                                    }
                                    .buttonStyle(PressScaleStyle())
                                    .accessibilityHint("Adds the selected tasks to this folder")
                                }
                            }
                        }

                        Text("Or create a new one")
                            .font(.evrySmall)
                            .foregroundStyle(palette.textSec)
                    }

                    // Preview
                    HStack(spacing: 14) {
                        Image(systemName: "folder.fill")
                            .font(.nunito(size: 22))
                            .foregroundStyle(tint)
                            .frame(width: 52, height: 52)
                            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: EvryRadius.tile, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name.isEmpty ? "New folder" : name)
                                .font(.evryTitle)
                                .foregroundStyle(palette.text)
                            Text("\(taskCount) task\(taskCount == 1 ? "" : "s")")
                                .font(.nunito(size: 13))
                                .foregroundStyle(palette.textSec)
                        }
                        Spacer()
                    }

                    TextField("Folder name", text: $name)
                        .evryTextField(palette)
                }
                .padding(20)
            }
            .background(palette.bg)
            .navigationTitle("Group tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .font(.evryLabel)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }
}

// MARK: - Timeline scroll fade

private extension View {
    /// Softens a timeline element into a blur + slight shrink + fade as it scrolls
    /// past the top/bottom edges of the day list — matching how task rows exit.
    func timelineScrollFade() -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .blur(radius: abs(phase.value) * 1.8)
                .opacity(1 - abs(phase.value) * 0.35)
                .scaleEffect(1 - pow(abs(phase.value), 2.5) * 0.2)
        }
    }
}

