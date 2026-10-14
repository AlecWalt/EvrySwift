//
//  InboxSchedule.swift
//  Evry
//
//  The Inbox's two modes. "Tasks" is the classic Inbox; "Schedule" (the
//  default) is a calm, single-column view of the day's calendar events and
//  timed tasks: cards in time order with a rail down the left. Tasks get there
//  by typing a time into their name, or by holding one on Tasks and dragging
//  it over (see `ScheduleDragState`). The rail fills as the day goes on —
//  it reaches an event's dot when the event starts, the dot lights up while the
//  event is on, then the line carries on towards the next event, stopping at
//  the last one of the day.
//

import SwiftUI
import EventKit
import SwiftData

// MARK: - Mode

enum InboxMode: String, CaseIterable, Identifiable {
    case tasks, schedule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .schedule: "Schedule"
        }
    }
}

// MARK: - Week strip

/// The week around the chosen day, opened by tapping the day's name. Tap a day
/// to jump to it; swipe sideways to move a week.
struct InboxWeekStrip: View {
    @Binding var dayOffset: Int
    let palette: Palette

    private let cal = Calendar.current

    private var selected: Date { cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())) ?? Date() }

    private var days: [Date] {
        let start = cal.dateInterval(of: .weekOfYear, for: selected)?.start ?? selected
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isSelected = cal.isDate(day, inSameDayAs: selected)
                let isToday = cal.isDateInToday(day)
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    let offset = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: day).day ?? 0
                    withAnimation(EvryMotion.settle) { dayOffset = offset }
                } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.nunito(size: 11, weight: .bold))
                            .foregroundStyle(palette.textMuted)
                        Text(day.formatted(.dateTime.day()))
                            .font(.nunito(size: 15, weight: isSelected || isToday ? .heavy : .semibold))
                            .foregroundStyle(isSelected ? palette.onPrimary : palette.text)
                            .frame(width: 32, height: 32)
                            .background {
                                if isSelected {
                                    Circle().fill(palette.primary)
                                } else if isToday {
                                    Circle().strokeBorder(palette.primary, lineWidth: 2)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, minHeight: EvrySpace.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    guard abs(v.translation.width) > 50, abs(v.translation.width) > abs(v.translation.height) else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(EvryMotion.settle) { dayOffset += v.translation.width < 0 ? 7 : -7 }
                }
        )
    }
}

// MARK: - Schedule drag (Tasks → Schedule)

/// A task being carried from the Tasks page onto the Schedule. Shared by the
/// task rows (the hold-and-drag gesture), the Inbox (the floating card and the
/// page switch at the screen's edge) and the Schedule (where it lands).
/// @Observable, so each piece re-renders only for what it reads — the finger's
/// position is read by the floating card and the drop marker, never by the
/// whole Inbox.
@Observable
final class ScheduleDragState {
    /// The row held long enough to lift (the finger is still down).
    var liftedID: UUID?
    /// The task being dragged, once the lifted row starts to move.
    var task: TaskItem?
    /// The finger, in global coordinates.
    var location: CGPoint = .zero
    /// The time the task would land at, while it's over the Schedule.
    var dropTime: Date?
    /// Which page the drag started on — only drags from Tasks turn the page.
    var origin: InboxMode = .tasks
    /// Where the hold landed, so a small wobble doesn't count as a drag.
    private var liftPoint: CGPoint = .zero

    var isActive: Bool { task != nil }
    var isEngaged: Bool { liftedID != nil || task != nil }

    /// The hold on `task` completed at `point` (the finger is still down).
    func lift(_ task: TaskItem, at point: CGPoint, from origin: InboxMode) {
        liftedID = task.uid
        liftPoint = point
        location = point
        self.origin = origin
    }

    /// The lifted finger moved. Returns true the moment it moves far enough to
    /// start carrying the task.
    func move(_ task: TaskItem, to point: CGPoint) -> Bool {
        guard liftedID == task.uid else { return false }
        location = point
        guard self.task == nil,
              hypot(point.x - liftPoint.x, point.y - liftPoint.y) > 12 else { return false }
        self.task = task
        return true
    }

    /// Lands the task at the hovered time (if any) and ends the drag. Returns
    /// whether it was scheduled.
    @discardableResult
    func finish() -> Bool {
        defer { reset() }
        guard let task, let dropTime else { return false }
        TaskActions.reschedule(task, to: dropTime)
        try? task.modelContext?.save()
        return true
    }

    func reset() {
        liftedID = nil
        task = nil
        dropTime = nil
    }
}

/// The floating card that follows the finger while a task is dragged, plus the
/// edge targets that switch between Tasks and Schedule when held over.
struct ScheduleDragOverlay: View {
    let drag: ScheduleDragState
    let palette: Palette
    let mode: InboxMode
    var onSwitch: (InboxMode) -> Void

    @State private var dwell: Task<Void, Never>?

    private let edgeZone: CGFloat = 44

    var body: some View {
        GeometryReader { g in
            let box = g.frame(in: .global)
            let target = edgeTarget(in: box)
            ZStack(alignment: .topLeading) {
                if drag.origin == .tasks {
                    if mode == .tasks {
                        edgeHint("Schedule", icon: "calendar", hot: target == .schedule)
                            .position(x: 22, y: box.height / 2)
                    } else {
                        edgeHint("Tasks", icon: "checkmark.square", hot: target == .tasks)
                            .position(x: box.width - 22, y: box.height / 2)
                    }
                }
                if let task = drag.task {
                    card(task)
                        // Lifted above the finger so it stays in view.
                        .position(x: drag.location.x - box.minX, y: drag.location.y - box.minY - 44)
                }
            }
            .frame(width: box.width, height: box.height)
            .onChange(of: target) { _, t in arm(t) }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .onDisappear { dwell?.cancel() }
    }

    private func edgeTarget(in box: CGRect) -> InboxMode? {
        // A card picked up on the Schedule just moves within it.
        guard drag.origin == .tasks else { return nil }
        let x = drag.location.x
        if mode == .tasks && x < box.minX + edgeZone { return .schedule }
        if mode == .schedule && x > box.maxX - edgeZone { return .tasks }
        return nil
    }

    /// Holding over an edge for a moment turns the page.
    private func arm(_ target: InboxMode?) {
        dwell?.cancel()
        guard let target else { return }
        dwell = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            onSwitch(target)
        }
    }

    private func edgeHint(_ title: String, icon: String, hot: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.nunito(size: 16, weight: .semibold))
            Text(title)
                .font(.nunito(size: 12, weight: .bold))
        }
        .foregroundStyle(Color.evryNavy)
        .padding(.vertical, 16)
        .frame(width: 60)
        .background(Color.evrySky.opacity(hot ? 1 : 0.55), in: Capsule())
        .scaleEffect(hot ? 1.08 : 1)
        .animation(EvryMotion.pop, value: hot)
        .accessibilityHidden(true)
    }

    private func card(_ task: TaskItem) -> some View {
        let subtitle: String = {
            if let time = drag.dropTime { return "at \(time.formatted(date: .omitted, time: .shortened))" }
            return mode == .tasks ? "Hold at the left edge for Schedule" : "Drop on your schedule"
        }()
        return HStack(spacing: 10) {
            Image(systemName: drag.dropTime == nil ? "calendar.badge.plus" : "clock")
                .font(.nunito(size: 16, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.nunito(size: 16, weight: .bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.nunito(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 250)
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
            .strokeBorder(palette.hairline, lineWidth: 1))
        .shadow(color: (palette.dark ? Color.black : Color.evryNavy).opacity(palette.dark ? 0.4 : 0.18),
                radius: 16, y: 8)
        .animation(EvryMotion.settle, value: drag.dropTime)
    }
}

// MARK: - Schedule

/// One thing on the schedule: a calendar event, or a task with a time.
private struct ScheduleEntry: Identifiable {
    enum Kind {
        case event(CalendarEvent)
        case task(TaskItem)
    }
    let kind: Kind
    let start: Date
    /// Events run to their end; a task is a moment (it ends as it starts).
    let end: Date

    var id: String {
        switch kind {
        case .event(let e): "event-\(e.id)"
        case .task(let t): "task-\(t.uid)"
        }
    }

    /// Where the next free slot after this begins — a task is given half an
    /// hour so a task dropped after it doesn't land at the very same minute.
    var slotEnd: Date {
        switch kind {
        case .event: end
        case .task: start.addingTimeInterval(30 * 60)
        }
    }
}

/// The day's events and timed tasks as cards along a progress rail.
struct ScheduleView: View {
    let dayOffset: Int
    let palette: Palette
    /// Every task — those due this day with a time are placed on the schedule.
    var tasks: [TaskItem] = []
    /// A task being dragged over from Tasks, if any.
    var drag: ScheduleDragState? = nil
    var onEditTask: (TaskItem) -> Void = { _ in }

    @Environment(CalendarService.self) private var calendar
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var events: [CalendarEvent] = []
    @State private var dotYs: [Int: CGFloat] = [:]
    /// Each card's global frame — measured only while a task is being dragged.
    @State private var entryFrames: [Int: CGRect] = [:]
    @State private var editing: EditableScheduleEvent?

    private let cal = Calendar.current
    private var day: Date { cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())) ?? Date() }

    /// Tasks due this day at a set time (midnight counts as "no time"). One
    /// being carried stays in place as a ghost — removing its card would end
    /// a drag that started on it — but is left out of the drop slots.
    private var timedTasks: [TaskItem] {
        tasks.filter { t in
            guard !t.isTrashed, !t.isNote,
                  let due = t.dueDate, cal.isDate(due, inSameDayAs: day) else { return false }
            let c = cal.dateComponents([.hour, .minute], from: due)
            return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
        }
    }

    /// Timed events and timed tasks, in time order. All-day items (holidays,
    /// birthdays…) stay off the schedule to keep it calm.
    private var entries: [ScheduleEntry] {
        let evs = events.filter { !$0.isAllDay }
            .map { ScheduleEntry(kind: .event($0), start: $0.startDate, end: $0.endDate) }
        let ts = timedTasks.compactMap { t in
            t.dueDate.map { ScheduleEntry(kind: .task(t), start: $0, end: $0) }
        }
        return (evs + ts).sorted { $0.start < $1.start }
    }

    /// Where the rail sits, and the dot centre's offset within a card.
    private static let railX: CGFloat = 14
    private static let dotYInCard: CGFloat = 22
    private static let space = "schedule"

    var body: some View {
        let items = entries
        let dragging = drag?.isActive ?? false
        Group {
            if items.isEmpty && !calendar.isAuthorized && !dragging {
                connectPrompt
            } else if items.isEmpty {
                ScrollView {
                    EmptyStateView(icon: "calendar",
                                   title: "Nothing scheduled",
                                   text: dayOffset == 0
                                       ? "Your day is wide open. Hold a task and drag it here, or add a time when you write it."
                                       : "A clear day — nothing on the calendar.",
                                   palette: palette)
                        .padding(.top, 28)
                }
            } else {
                list(items, measuring: dragging)
            }
        }
        .overlay {
            if let drag, dragging {
                // Every card but the one being carried marks out the gaps.
                let carried = drag.task.map { "task-\($0.uid)" }
                let others = items.indices.filter { items[$0].id != carried }
                ScheduleDropTracker(drag: drag,
                                    frames: others.compactMap { entryFrames[$0] },
                                    slotTimes: slotTimes(others.map { items[$0] }),
                                    palette: palette)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: dayOffset) { _, _ in reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        // EventKit posts these in bursts while it syncs (and once for our own
        // saves) — coalesce them into one reload.
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in reloadSoon() }
        .sheet(item: $editing) { wrapper in
            EventEditorView(palette: palette, store: calendar.eventStore, event: wrapper.event) { changed in
                editing = nil
                guard changed else { return }
                calendar.eventStore.reset()
                reload()
            }
        }
    }

    @State private var pendingReload: Task<Void, Never>?

    private func reloadSoon() {
        pendingReload?.cancel()
        pendingReload = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private func reload() {
        guard calendar.isAuthorized else { events = []; return }
        let end = cal.date(byAdding: .day, value: 1, to: day) ?? day
        withAnimation(EvryMotion.settle) {
            events = calendar.events(from: day, to: end)
        }
    }

    // MARK: Drop slots

    /// The time a dragged task lands at for each gap in the list: before the
    /// first card, between each pair, and after the last. A gap starts as the
    /// card above it ends (never later than the card below starts).
    private func slotTimes(_ items: [ScheduleEntry]) -> [Date] {
        let earliest = day.addingTimeInterval(5 * 60)   // midnight reads as "no time"
        let latest = cal.date(bySettingHour: 23, minute: 45, second: 0, of: day) ?? day
        func place(_ d: Date) -> Date {
            // Up to the next 5 minutes, kept within the day.
            let rounded = Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 300).rounded(.up) * 300)
            return min(max(rounded, earliest), latest)
        }
        guard let first = items.first else {
            // An empty day: the next quarter hour today, otherwise 9 AM.
            if dayOffset == 0 {
                let now = Date().timeIntervalSinceReferenceDate
                return [place(Date(timeIntervalSinceReferenceDate: (now / 900).rounded(.up) * 900))]
            }
            return [place(cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day)]
        }
        var out = [place(first.start.addingTimeInterval(-30 * 60))]
        for k in 1...items.count {
            var t = items[k - 1].slotEnd
            if k < items.count { t = min(t, items[k].start) }
            out.append(place(t))
        }
        return out
    }

    // MARK: List + rail

    private func list(_ items: [ScheduleEntry], measuring: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // One clock for the rail and every card (not one timer per
                // card): refreshes every 30s so the line keeps creeping forward.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                ZStack(alignment: .topLeading) {
                    rail(items, now: context.date)
                    VStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, entry in
                            Group {
                                switch entry.kind {
                                case .event(let e): card(e, now: context.date)
                                case .task(let t): taskCard(t)
                                }
                            }
                            .background(alignment: .topLeading) {
                                // Reports where this card's dot sits (and, mid-drag,
                                // the card's frame for the drop marker).
                                GeometryReader { g in
                                    Color.clear
                                        .preference(
                                            key: DotYKey.self,
                                            value: [i: g.frame(in: .named(Self.space)).minY + Self.dotYInCard])
                                        .preference(
                                            key: EntryFrameKey.self,
                                            value: measuring ? [i: g.frame(in: .global)] : [:])
                                }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                    .padding(.leading, 36)
                }
                }
                .coordinateSpace(.named(Self.space))
                .onPreferenceChange(DotYKey.self) { dotYs = $0 }
                .onPreferenceChange(EntryFrameKey.self) { entryFrames = $0 }

                if !calendar.isAuthorized {
                    Button("Connect calendar") {
                        Task {
                            await calendar.requestAccess()
                            reload()
                        }
                    }
                    .font(.nunito(size: 15, weight: .bold))
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, minHeight: EvrySpace.tap)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
            .animation(EvryMotion.settle, value: items.map(\.id))
        }
        .scrollIndicators(.hidden)
        // Hold still while a card is lifted or carried.
        .scrollDisabled(drag?.isEngaged ?? false)
    }

    /// The light track to the last card, the sky line filled to "now", and a
    /// dot per card — passed (filled), on now (glowing) or still to come.
    private func rail(_ items: [ScheduleEntry], now: Date) -> some View {
        let ys = items.indices.compactMap { dotYs[$0] }
        let last = ys.last ?? 0
        let fill = progressY(items, now: now)
        let active = activeIndex(items, now: now)
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(palette.border)
                .frame(width: 3, height: max(0, last))
                .offset(x: Self.railX - 1.5)
            Capsule()
                .fill(Color.evrySky)
                .frame(width: 4, height: max(0, min(fill, last)))
                .offset(x: Self.railX - 2)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: fill)
            ForEach(items.indices, id: \.self) { i in
                if let y = dotYs[i] {
                    RailDot(state: active == i ? .now : (isDone(items[i], now: now) ? .done : .ahead),
                            palette: palette)
                        .position(x: Self.railX, y: y)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isPastDay: Bool { dayOffset < 0 }

    private func isDone(_ entry: ScheduleEntry, now: Date) -> Bool {
        if case .task(let t) = entry.kind, t.completed { return true }
        return entry.end <= now || isPastDay
    }

    private func activeIndex(_ items: [ScheduleEntry], now: Date) -> Int? {
        guard dayOffset == 0 else { return nil }
        return items.lastIndex { $0.start <= now && now < $0.end }
    }

    /// How far down the rail the line has reached at `now`. It reaches each dot
    /// as its card's time comes, holds there while an event is on, then travels
    /// to the next dot over the gap — and never goes past the last card.
    private func progressY(_ items: [ScheduleEntry], now: Date) -> CGFloat {
        let ys = items.indices.map { dotYs[$0] ?? 0 }
        guard let lastY = ys.last else { return 0 }
        if dayOffset < 0 { return lastY }
        if dayOffset > 0 { return 0 }

        // The latest card whose time has come.
        guard let i = items.lastIndex(where: { $0.start <= now }) else {
            // Before the first card: from the top, starting at midnight.
            let first = items[0].start
            let span = first.timeIntervalSince(day)
            let f = span > 0 ? now.timeIntervalSince(day) / span : 1
            return ys[0] * CGFloat(min(max(f, 0), 1))
        }
        // Still on (or overlapping events): sit at its dot.
        if now < items[i].end || i == items.count - 1 { return ys[i] }
        let from = items[i].end, to = items[i + 1].start
        let span = to.timeIntervalSince(from)
        let f = span > 0 ? now.timeIntervalSince(from) / span : 1
        return ys[i] + (ys[i + 1] - ys[i]) * CGFloat(min(max(f, 0), 1))
    }

    // MARK: Cards

    private func card(_ e: CalendarEvent, now: Date) -> some View {
        let isNow = dayOffset == 0 && e.startDate <= now && now < e.endDate
        let isPast = isPastDay || (dayOffset == 0 && e.endDate <= now)
        let time = "\(e.startDate.formatted(date: .omitted, time: .shortened))–\(e.endDate.formatted(date: .omitted, time: .shortened))"
        // A tap gesture (not a Button): a sideways swipe across the card is never
        // mistaken for a tap, so swiping to Tasks or the menu can't open it.
        return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(time)
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .monospacedDigit()
                    if isNow {
                        Text("Now")
                            .font(.nunito(size: 12, weight: .heavy))
                            .foregroundStyle(Color.evryNavy)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.evrySky, in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(e.title)
                    .font(.nunito(size: 17, weight: .bold))
                    .foregroundStyle(isPast ? palette.textMuted : palette.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isNow ? palette.skySoft : palette.card,
                        in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
                .strokeBorder(isNow ? Color.evrySky : palette.hairline, lineWidth: isNow ? 1.5 : 1))
            .animation(EvryMotion.settle, value: isNow)
            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
            .onTapGesture { open(e) }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(e.title), \(time)\(isNow ? ", happening now" : "")")
            .accessibilityAction { open(e) }
    }

    /// A timed task: its checkbox, time and title. Tap to edit it; hold and
    /// drag it to another gap to move it to that time.
    private func taskCard(_ t: TaskItem) -> some View {
        let time = t.dueDate?.formatted(date: .omitted, time: .shortened) ?? ""
        let lifted = drag?.liftedID == t.uid
        let carried = lifted && drag?.task?.uid == t.uid
        return HStack(alignment: .center, spacing: 10) {
            TaskCheckbox(checked: t.completed, palette: palette, contentAlignment: .leading) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    TaskActions.toggle(t, context: context)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(time)
                        .font(.nunito(size: 13, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .monospacedDigit()
                }
                Text(t.title)
                    .font(.nunito(size: 17, weight: .bold))
                    .foregroundStyle(t.completed ? palette.textMuted : palette.text)
                    .strikethrough(t.completed, color: palette.textPh)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onEditTask(t) }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        // Tasks are told apart from events by a dashed hairline; a high-priority
        // task gets a solid sky outline, as it does on Tasks.
        .overlay {
            let shape = RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
            if t.priority == .high && !t.completed {
                shape.strokeBorder(Color.evrySky, lineWidth: 2)
            } else {
                shape.strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .background(HoldDragCatcher(
            onLift: { p in liftCard(t, at: p) },
            onMove: { p in moveCard(t, to: p) },
            onEnd: { cancelled in dropCard(cancelled: cancelled) }
        ))
        .scaleEffect(lifted && !carried ? 1.03 : 1)
        .shadow(color: lifted && !carried ? Color.evryNavy.opacity(palette.dark ? 0.3 : 0.1) : .clear,
                radius: 10, y: 4)
        .opacity(carried ? 0.35 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: lifted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Task, \(t.title), at \(time)\(t.completed ? ", done" : "")")
        .accessibilityAction(named: "Edit") { onEditTask(t) }
    }

    // MARK: Moving a task card

    private func liftCard(_ t: TaskItem, at point: CGPoint) -> Bool {
        guard let drag, !drag.isEngaged, !t.completed else { return false }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            drag.lift(t, at: point, from: .schedule)
        }
        return true
    }

    private func moveCard(_ t: TaskItem, to point: CGPoint) {
        guard let drag else { return }
        // Not animated: the floating card must track the finger exactly.
        if drag.move(t, to: point) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

    private func dropCard(cancelled: Bool) {
        guard let drag else { return }
        let placed = !cancelled && drag.isActive && drag.dropTime != nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if placed { _ = drag.finish() } else { drag.reset() }
        }
        if placed { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func open(_ e: CalendarEvent) {
        if let ek = e.ekEvent ?? calendar.ekEvent(withIdentifier: e.id) {
            editing = EditableScheduleEvent(event: ek)
        }
    }

    // MARK: Not connected

    private var connectPrompt: some View {
        ScrollView {
            VStack(spacing: 0) {
                EmptyStateView(icon: "calendar.badge.plus",
                               title: "Connect your calendar",
                               text: "See your day’s events here, in order, as the day unfolds.",
                               palette: palette)
                Button("Connect calendar") {
                    Task {
                        await calendar.requestAccess()
                        reload()
                    }
                }
                .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
            }
            .padding(.top, 28)
        }
    }
}

/// Watches a dragged task over the Schedule: works out which gap it's over,
/// draws a marker there with the time it would land at, and reports that time.
private struct ScheduleDropTracker: View {
    let drag: ScheduleDragState
    /// The cards' global frames, in order.
    let frames: [CGRect]
    /// One more than the cards: before the first, between each, after the last.
    let slotTimes: [Date]
    let palette: Palette

    var body: some View {
        GeometryReader { g in
            let box = g.frame(in: .global)
            let slot = slotIndex(in: box)
            let target = slot.flatMap { $0 < slotTimes.count ? slotTimes[$0] : nil }
            ZStack(alignment: .topLeading) {
                if let slot, let target {
                    marker(target)
                        .frame(width: max(0, box.width - 40))
                        .position(x: box.width / 2, y: markerY(slot, in: box) - box.minY)
                        .transition(.opacity)
                }
            }
            .frame(width: box.width, height: box.height)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: slot)
            .onChange(of: target, initial: true) { old, new in
                drag.dropTime = new
                if new != nil && old != new { UISelectionFeedbackGenerator().selectionChanged() }
            }
            .onDisappear { drag.dropTime = nil }
        }
        .allowsHitTesting(false)
    }

    private func slotIndex(in box: CGRect) -> Int? {
        let p = drag.location
        guard box.contains(p) else { return nil }
        return frames.filter { $0.midY < p.y }.count
    }

    private func markerY(_ slot: Int, in box: CGRect) -> CGFloat {
        let y: CGFloat
        if frames.isEmpty {
            y = box.minY + 40
        } else if slot == 0 {
            y = frames[0].minY - 5
        } else if slot >= frames.count {
            y = frames[frames.count - 1].maxY + 5
        } else {
            y = (frames[slot - 1].maxY + frames[slot].minY) / 2
        }
        return min(max(y, box.minY + 14), box.maxY - 14)
    }

    private func marker(_ time: Date) -> some View {
        HStack(spacing: 8) {
            Text(time.formatted(date: .omitted, time: .shortened))
                .font(.nunito(size: 13, weight: .heavy))
                .foregroundStyle(palette.onPrimary)
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(palette.primary, in: Capsule())
            Capsule()
                .fill(palette.primary)
                .frame(height: 3)
        }
        .accessibilityHidden(true)
    }
}

private struct EditableScheduleEvent: Identifiable {
    let id = UUID()
    let event: EKEvent
}

private struct DotYKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct EntryFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// A rail dot: still to come (hollow), done (filled), or on now (a larger
/// glowing dot with a soft pulse).
private struct RailDot: View {
    enum State { case ahead, done, now }
    let state: State
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var pulse = false

    var body: some View {
        ZStack {
            if state == .now {
                Circle()
                    .fill(Color.evrySky.opacity(0.45))
                    .frame(width: 30, height: 30)
                    .scaleEffect(pulse && !reduceMotion ? 1.25 : 0.85)
                    .opacity(pulse && !reduceMotion ? 0.35 : 0.9)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            }
            // Only an upcoming (white) dot gets the dark outline; once it's
            // blue — done or on now — it's a plain sky dot.
            Circle()
                .fill(state == .ahead ? palette.card : Color.evrySky)
                .frame(width: state == .now ? 18 : 14, height: state == .now ? 18 : 14)
                .overlay {
                    if state == .ahead {
                        Circle().strokeBorder(palette.dark ? Color.evryWhite : Color.evryNavy, lineWidth: 2)
                    }
                }
        }
        .animation(EvryMotion.pop, value: state)
        .onAppear { pulse = true }
    }
}
