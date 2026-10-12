//
//  CalendarTabView.swift
//  Evry
//
//  The Calendar tab — Apple Calendar–style. Two modes:
//   • Month: a month grid with event/task dots. Tapping a day zooms into…
//   • Week:  a fixed weekday-letter header, a horizontally-paging strip of date
//     numbers, and a horizontally-paging day timeline below where events/tasks
//     render as blocks. Paging uses native paging scroll views so it's smooth.
//  In week mode the month title becomes a button that returns to the month grid.
//

import SwiftUI
import SwiftData
import EventKit
import UIKit

struct CalendarTabView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(CalendarService.self) private var calendarService

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var mode: CalMode = .month
    @State private var displayMonth = Calendar.current.startOfDay(for: .now)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var dayEvents: [CalendarEvent] = []
    /// Preloaded per-day dot colors (events + tasks) so scrolling the month list
    /// is an O(1) lookup — no EventKit query or filtering mid-scroll.
    @State private var dotCache: [Date: [Color]] = [:]
    /// Native paging scroll positions (day timeline / week number strip).
    @State private var dayScrollID: Int?
    @State private var weekScrollID: Int?
    /// Vertical scroll positions for the month list and the year list.
    @State private var monthScrollID: Int? = 0
    @State private var yearScrollID: Int? = Calendar.current.component(.year, from: .now)
    /// Live scroll phase of the month list — month-change haptics only fire while
    /// the user is actually scrolling, never on programmatic positioning.
    @State private var monthScrollPhase: ScrollPhase = .idle
    /// Bumped once per month crossed while scrolling (drives the haptic tick).
    @State private var monthHapticTick = 0
    /// The calendar event currently being edited (via the Evry event editor).
    @State private var editingEvent: EditableEvent?
    /// An event being created by press-and-drag on the day timeline, then named
    /// in place.
    @State private var draft: EventDraft?
    @State private var draftTitle = ""
    @FocusState private var draftFocused: Bool
    /// An existing event being dragged to a new time or resized from an edge.
    @State private var adjusting: EventAdjust?

    private struct EventAdjust: Equatable {
        enum Mode { case move, start, end }
        let mode: Mode
        let eventID: String
        let event: EKEvent
        let day: Date
        /// Move: how far the finger sat below the event's start when picked up.
        let grabOffset: TimeInterval
        var start: Date
        var end: Date
    }

    private struct EventDraft: Equatable {
        var day: Date
        /// Where the press landed (snapped) — the drag stretches from here.
        var anchor: Date
        var start: Date
        var end: Date
        /// Released: the block now shows a text field for the name.
        var naming = false
    }

    private struct EditableEvent: Identifiable {
        let id = UUID()
        let event: EKEvent
    }

    private enum CalMode { case year, month, week }

    private let cal = Calendar.current
    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]
    private let hourHeight: CGFloat = 52
    private let leftGutter: CGFloat = 54
    /// Fixed reference point for paging indices, resolved once at launch.
    private let refDay = Calendar.current.startOfDay(for: .now)
    private let dayIndexRange = -366...366
    private let weekIndexRange = -54...54

    private var dueTasks: [TaskItem] {
        allTasks.filter { !$0.isTrashed && !$0.isNote && $0.dueDate != nil }
    }

    private var needsConnect: Bool { !calendarService.isAuthorized && !calendarService.accessDenied }

    // MARK: Paging index math

    private func dayIndex(_ d: Date) -> Int {
        cal.dateComponents([.day], from: refDay, to: cal.startOfDay(for: d)).day ?? 0
    }
    private func date(dayIndex i: Int) -> Date {
        cal.date(byAdding: .day, value: i, to: refDay) ?? refDay
    }
    private var refWeekStart: Date {
        let idx = cal.component(.weekday, from: refDay) - 1
        return cal.date(byAdding: .day, value: -idx, to: refDay) ?? refDay
    }
    private func weekStart(_ d: Date) -> Date {
        let idx = cal.component(.weekday, from: d) - 1
        return cal.date(byAdding: .day, value: -idx, to: cal.startOfDay(for: d)) ?? d
    }
    private func weekIndex(_ d: Date) -> Int {
        (cal.dateComponents([.day], from: refWeekStart, to: weekStart(d)).day ?? 0) / 7
    }
    private func date(weekIndex wi: Int, weekday offset: Int) -> Date {
        let start = cal.date(byAdding: .day, value: wi * 7, to: refWeekStart) ?? refWeekStart
        return cal.date(byAdding: .day, value: offset, to: start) ?? start
    }

    /// The first of the current month — origin for the month list indices.
    private var refMonth: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: refDay)) ?? refDay
    }
    private func monthIndex(_ d: Date) -> Int {
        cal.dateComponents([.month], from: refMonth, to: firstOfMonth(d)).month ?? 0
    }
    private func monthDate(_ index: Int) -> Date {
        cal.date(byAdding: .month, value: index, to: refMonth) ?? refMonth
    }
    private func firstOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }
    private let monthIndexRange = -240...240
    private var yearRange: ClosedRange<Int> {
        let y = cal.component(.year, from: refDay)
        return (y - 20)...(y + 20)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)

            if mode != .year, needsConnect {
                connectBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            switch mode {
            case .year:  yearView
            case .month: monthView
            case .week:  weekView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
        .sheet(item: $editingEvent) { wrapper in
            EventEditorView(palette: palette, store: calendarService.eventStore, event: wrapper.event) { changed in
                editingEvent = nil
                guard changed else { return }
                // The editor saves synchronously, but the store caches event
                // objects — drop the cache so the re-query reads the new
                // time/length rather than a stale copy.
                calendarService.eventStore.reset()
                rebuildDotCache()
                rebuildDayEvents()
            }
        }
        .onAppear { rebuildDotCache(); rebuildDayEvents() }
        // If the event being edited disappears from the store (deleted elsewhere,
        // e.g. on another device), close the editor and refresh the day.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                guard let editing = editingEvent,
                      let id = editing.event.eventIdentifier,           // nil = a new, unsaved event
                      calendarService.eventStore.event(withIdentifier: id) == nil else { continue }
                editingEvent = nil
                try? await Task.sleep(for: .milliseconds(350))
                calendarService.eventStore.reset()
                rebuildDotCache()
                rebuildDayEvents()
            }
        }
        .onChange(of: monthScrollID) { _, id in
            // Keep the header year in sync with the visible month (no fetching).
            guard mode == .month, let id else { return }
            let m = monthDate(id)
            guard !cal.isDate(m, equalTo: displayMonth, toGranularity: .month) else { return }
            displayMonth = m
            // One light tick per month crossed — only while the user is driving
            // the scroll (finger down or flinging), so jumping to a month from the
            // year picker / week view or the initial positioning stays silent.
            if [.tracking, .interacting, .decelerating].contains(monthScrollPhase) {
                monthHapticTick &+= 1
            }
        }
        .onChange(of: selectedDay) { _, _ in
            if draft != nil { commitDraft() }
            rebuildDayEvents()
            let di = dayIndex(selectedDay); if dayScrollID != di { dayScrollID = di }
            let wi = weekIndex(selectedDay); if weekScrollID != wi { weekScrollID = wi }
        }
        .onChange(of: dayScrollID) { _, id in
            guard mode == .week, let id else { return }
            let d = date(dayIndex: id)
            if !cal.isDate(d, inSameDayAs: selectedDay) { selectedDay = d }
        }
        .onChange(of: weekScrollID) { _, id in
            guard mode == .week, let id, weekIndex(selectedDay) != id else { return }
            let offset = cal.component(.weekday, from: selectedDay) - 1
            selectedDay = date(weekIndex: id, weekday: offset)
        }
        .onChange(of: allTasks.count) { _, _ in rebuildDotCache() }
        .onChange(of: calendarService.authStatus) { _, _ in rebuildDotCache(); rebuildDayEvents() }
        .onChange(of: calendarService.selectedCalendarIDs) { _, _ in rebuildDotCache(); rebuildDayEvents() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            switch mode {
            case .week:
                // Selected day is the hero (with an ordinal date line + "Today" pill),
                // matching the Timeline. The chevron returns to the month list.
                Button { returnToMonth() } label: {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.nunito(size: 20, weight: .bold))
                            .foregroundStyle(palette.primary)
                            // Match the hero line's height so the chevron centers
                            // against the title rather than floating to a corner.
                            .frame(height: 41)
                        PageTitle(
                            title: selectedDay.formatted(.dateTime.weekday(.wide)),
                            subtitle: "\(selectedDay.formatted(.dateTime.month(.wide))) \(selectedDay.ordinalDayString)",
                            badge: cal.isDateInToday(selectedDay) ? "Today" : nil,
                            palette: palette
                        )
                    }
                }
                .buttonStyle(.plain)
            case .month:
                // The visible month is the hero, the year its supporting line.
                // Tap to open the year picker.
                Button { openYearView() } label: {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.nunito(size: 20, weight: .bold))
                            .foregroundStyle(palette.primary)
                            // Match the hero line's height so the chevron centers
                            // against the title rather than floating to a corner.
                            .frame(height: 41)
                        PageTitle(
                            title: displayMonth.formatted(.dateTime.month(.wide)),
                            subtitle: displayMonth.formatted(.dateTime.year()),
                            palette: palette
                        )
                    }
                }
                .buttonStyle(.plain)
            case .year:
                PageTitle(title: "Year", palette: palette)
            }

            Spacer()

            // Same header button as the Inbox tools and Notes header.
            HeaderIconButton(systemName: "plus", palette: palette) { addEvent() }
                .accessibilityLabel("Add event")
            // Center the add button against the hero title line.
            .frame(height: 41)
        }
    }

    /// Create a new calendar event on the selected day and open the event editor.
    private func addEvent() {
        if calendarService.isAuthorized {
            presentNewEvent()
        } else {
            Task { await calendarService.requestAccess(); presentNewEvent() }
        }
    }

    private func presentNewEvent() {
        guard calendarService.isAuthorized else { return }
        let store = calendarService.eventStore
        let event = EKEvent(eventStore: store)
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.calendar = store.defaultCalendarForNewEvents
        editingEvent = EditableEvent(event: event)
    }

    private var connectBanner: some View {
        Button {
            Task { await calendarService.requestAccess(); rebuildDotCache(); rebuildDayEvents() }
        } label: {
            HStack(spacing: 12) {
                ToolIcon(tool: .calendar, tile: 32, palette: palette)
                Text("Connect your calendar to see your events here")
                    .font(.nunito(size: 15, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.nunito(size: 14, weight: .bold))
                    .foregroundStyle(palette.primary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, EvrySpace.gutter)
            .frame(minHeight: EvrySpace.storeHeight)
            .evryCard(palette)
        }
        .buttonStyle(.plain)
    }

    // MARK: Year view

    /// A scroll-wheel style year picker: it snaps each year to the middle, the
    /// centered year is enlarged in the ink colour (the "selected" one), and the
    /// rest shrink and fade toward the edges.
    private var yearView: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(yearRange), id: \.self) { year in
                        Button {
                            // First tap scrolls the year to the center; tapping the
                            // already-centered year opens it.
                            if year == yearScrollID {
                                openMonths(year: year)
                            } else {
                                withAnimation(.easeInOut(duration: 0.25)) { yearScrollID = year }
                            }
                        } label: {
                            Text(String(year))
                                .font(.nunito(size: 34, weight: .heavy))
                                .foregroundStyle(year == yearScrollID ? palette.primary : palette.textSec)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .scrollTransition(axis: .vertical) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1.3 : 0.82)
                                .opacity(phase.isIdentity ? 1 : 0.4)
                        }
                        .id(year)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $yearScrollID)
            // Pad so the first/last years can reach the vertical center.
            .contentMargins(.vertical, max(0, geo.size.height / 2 - 34), for: .scrollContent)
            // A tactile "tick" as each year passes the center while scrolling.
            .sensoryFeedback(.selection, trigger: yearScrollID)
        }
    }

    // MARK: Month view (vertical scroll of months)

    private var monthView: some View {
        VStack(spacing: 0) {
            weekdayLetters
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(monthIndexRange, id: \.self) { mi in
                        monthSection(monthDate(mi), isCurrent: mi == monthScrollID)
                            .id(mi)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $monthScrollID)
            .onScrollPhaseChange { _, phase in monthScrollPhase = phase }
            .sensoryFeedback(.selection, trigger: monthHapticTick)
        }
        .onDisappear { monthScrollPhase = .idle }
    }

    /// `isCurrent` marks the month the scroll position treats as current (the
    /// one named in the header) — its title takes the full ink colour.
    private func monthSection(_ month: Date, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(month.formatted(.dateTime.month(.wide)))
                .font(.evryH3)
                .foregroundStyle(isCurrent ? palette.primary : palette.textSec)
                .animation(.easeInOut(duration: 0.2), value: isCurrent)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 2)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(Array(monthCells(month).enumerated()), id: \.offset) { _, day in
                    if let day {
                        monthCell(day)
                    } else {
                        Color.clear.frame(height: 70)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    /// A month's day cells with leading/trailing blanks so days align to weekdays.
    private func monthCells(_ month: Date) -> [Date?] {
        let first = firstOfMonth(month)
        let leading = cal.component(.weekday, from: first) - 1
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for d in 0..<count { cells.append(cal.date(byAdding: .day, value: d, to: first)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private var weekdayLetters: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.evryCaption)
                    .foregroundStyle(palette.textMuted)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 2)
    }

    private func monthCell(_ day: Date) -> some View {
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let indicators = dayIndicators(for: day)

        return Button {
            enterWeek(day)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if isSelected {
                        Circle().fill(palette.primary).frame(width: 30, height: 30)
                    } else if isToday {
                        // Today: a navy (sky in dark) ring — never red.
                        Circle().strokeBorder(palette.primary, lineWidth: 1.5).frame(width: 30, height: 30)
                    }
                    Text("\(cal.component(.day, from: day))")
                        .font(.nunito(size: 15, weight: isToday || isSelected ? .heavy : .regular))
                        .foregroundStyle(dayNumberColor(isToday: isToday, isSelected: isSelected))
                }
                .frame(height: 30)

                // Up to three tiny dots: an event keeps its calendar's colour
                // (the user's data, dot only); tasks are brand ink.
                HStack(spacing: 3) {
                    ForEach(Array(indicators.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dayNumberColor(isToday: Bool, isSelected: Bool) -> Color {
        if isSelected { return palette.onPrimary }
        if isToday { return palette.primary }
        return palette.text
    }

    /// O(1) lookup into the preloaded dot cache — cheap enough to run per cell
    /// during a fast scroll.
    private func dayIndicators(for day: Date) -> [Color] {
        dotCache[cal.startOfDay(for: day)] ?? []
    }

    // MARK: Week view

    private var weekView: some View {
        VStack(spacing: 0) {
            // Fixed weekday letters — stay put while the numbers page beneath.
            weekdayLetters
                .padding(.horizontal, 12)
                .padding(.top, 2)

            weekNumberPager
                .frame(height: 46)
                .padding(.bottom, 6)

            Rectangle().fill(palette.border).frame(height: 1)

            let taskCount = timelessTaskCount(for: selectedDay)
            let allDay = allDayEvents(for: selectedDay)
            let hasSummary = taskCount > 0 || !allDay.isEmpty
            if hasSummary {
                topSummaryBar(taskCount: taskCount, events: allDay)
                    // Slides down + fades in (and back up out) as you page onto
                    // or off a day that has due tasks / all-day events, with the
                    // timeline below easing to make room — instead of popping.
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            dayPager
        }
        .clipped()
        // Keyed only on the bar's presence, so paging between days never
        // animates anything else (e.g. the day pager's scroll position).
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: hasSummaryBar)
    }

    /// Whether the selected day shows the top summary row (animation key).
    private var hasSummaryBar: Bool {
        timelessTaskCount(for: selectedDay) > 0 || !allDayEvents(for: selectedDay).isEmpty
    }

    /// The top row: a "N tasks due" indicator on the left, then all-day events
    /// splitting the remaining width evenly.
    private func topSummaryBar(taskCount: Int, events: [CalendarEvent]) -> some View {
        HStack(spacing: 8) {
            if taskCount > 0 {
                HStack(spacing: 6) {
                    Image(EvryTool.tasks.glyph)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(palette.primary)
                        .accessibilityHidden(true)
                    Text("\(taskCount) task\(taskCount == 1 ? "" : "s") due")
                        .font(.nunito(size: 13, weight: .semibold))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            ForEach(events) { event in
                allDayEventChip(event)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, EvrySpace.gutter)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func allDayEventChip(_ event: CalendarEvent) -> some View {
        // Sky-soft pill with a sky ring; the calendar's colour survives only as
        // the tiny leading dot.
        HStack(spacing: 6) {
            Circle().fill(event.calendarColor).frame(width: 6, height: 6)
            Text(event.title)
                .font(.nunito(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(palette.skySoft, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.evrySky, lineWidth: 1))
        // Grow the hit area toward the tap minimum without changing the layout.
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .onTapGesture { openEventEditor(event.ekEvent, id: event.id, title: event.title, near: event.startDate) }
    }

    /// Horizontally-paging strip of date numbers — only the numbers move.
    private var weekNumberPager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(weekIndexRange, id: \.self) { wi in
                    weekNumbers(wi)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $weekScrollID)
    }

    private func weekNumbers(_ wi: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = date(weekIndex: wi, weekday: offset)
                let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
                let isToday = cal.isDateInToday(day)
                ZStack {
                    if isSelected {
                        Circle().fill(palette.primary).frame(width: 36, height: 36)
                    } else if isToday {
                        Circle().strokeBorder(palette.primary, lineWidth: 1.5).frame(width: 36, height: 36)
                    }
                    Text("\(cal.component(.day, from: day))")
                        .font(.nunito(size: 16, weight: isSelected || isToday ? .heavy : .semibold))
                        .foregroundStyle(isSelected ? palette.onPrimary : palette.text)
                }
                .frame(width: 36, height: 36)
                .frame(minHeight: EvrySpace.tap)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { selectDay(day) }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Horizontally-paging day timeline — each page is one day's hour grid + blocks.
    private var dayPager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(dayIndexRange, id: \.self) { di in
                    dayPage(date(dayIndex: di))
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $dayScrollID)
        // Don't page days while an event is being stretched or dragged.
        .scrollDisabled((draft.map { !$0.naming } ?? false) || adjusting != nil)
    }

    private func dayPage(_ day: Date) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        dayGrid(width: w)
                        ForEach(layout(timedBlocks(for: day))) { p in
                            timelineBlock(p, day: day, totalWidth: w)
                        }
                        // One touch layer over the blocks handles everything:
                        //  • tap an event → open it (the Buttons beneath remain for VoiceOver)
                        //  • press-drag an event's middle → move it; its top/bottom
                        //    edge → change the start/end time
                        //  • press-hold empty space → create an event, drag to size it
                        TimelinePressCatcher(
                            onBegan: { pt in beginPress(at: pt, on: day, width: w) },
                            onChanged: { pt in
                                if adjusting != nil { updateAdjust(to: pt.y) } else { updateDraft(to: pt.y) }
                            },
                            onEnded: { if adjusting != nil { endAdjust() } else { endDraftDrag() } },
                            onTap: { pt in tapTimeline(at: pt, on: day, width: w) }
                        )
                        .frame(width: w, height: hourHeight * 24)
                        if cal.isDateInToday(day) {
                            nowLine(width: w)
                        }
                        if let d = draft, cal.isDate(d.day, inSameDayAs: day) {
                            draftBlock(d, totalWidth: w)
                                .zIndex(5)
                        }
                    }
                    .frame(width: w, height: hourHeight * 24, alignment: .topLeading)
                    .padding(.bottom, 130)
                }
                // Same leading accent indicator as the Inbox list.
                .evryScrollIndicator(palette)
                // Hold still while stretching a new event or dragging one.
                .scrollDisabled((draft.map { !$0.naming } ?? false) || adjusting != nil)
                // Once released, bring the new event into view above the keyboard.
                .onChange(of: draft?.naming) { _, naming in
                    guard naming == true, let d = draft, cal.isDate(d.day, inSameDayAs: day) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(cal.component(.hour, from: d.start), anchor: .center)
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        proxy.scrollTo(morningHour(day), anchor: .top)
                    }
                }
            }
        }
    }

    private func dayGrid(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(hourLabel(hour))
                        .font(.nunito(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textMuted)
                        .frame(width: leftGutter - 10, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle()
                        .fill(palette.hairline)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func morningHour(_ day: Date) -> Int {
        let timed = timedBlocks(for: day)
        guard let earliest = timed.map(\.start).min() else { return 7 }
        return max(0, cal.component(.hour, from: earliest) - 1)
    }

    @ViewBuilder
    private func timelineBlock(_ p: PositionedBlock, day: Date, totalWidth: CGFloat) -> some View {
        let frame = blockFrame(p, day: day, totalWidth: totalWidth)
        let x = frame.minX, y = frame.minY, w = frame.width, h = frame.height
        let lifted = adjusting?.eventID == p.block.eventID && p.block.eventID != nil

        // Tile-radius corners (12), scaled down for short events so they never
        // collapse into pills; the bar's inset grows with the event so it isn't
        // cramped against the edges.
        let radius = min(EvryRadius.tile, max(8, h / 2 - 4))
        let barInset = min(16, max(5, h * 0.26))

        let label = blockLabel(p.block, compact: h < 40, cornerRadius: radius, barInset: barInset)
            .frame(width: w, height: h, alignment: .topLeading)

        // IMPORTANT: apply `.offset` to the whole tappable element, NOT inside the
        // Button's label. `.offset` is layout-neutral, so if it lives inside the
        // label the Button's hit region stays pinned at the ZStack origin — every
        // block's tap target then collapses to the same spot and only the top-most
        // one (z-order) is tappable. Offsetting the Button itself moves its hit
        // region with it, so each block is independently tappable.
        Group {
            if let task = p.block.task {
                Button { onEdit(task) } label: { label }
                    .buttonStyle(.plain)
            } else if let eventID = p.block.eventID {
                Button { openEventEditor(p.block.ekEvent, id: eventID, title: p.block.title, near: p.block.start) } label: { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        // Picked up: lift it above its neighbours while it's dragged.
        .shadow(color: (palette.dark ? Color.black : .evryNavy).opacity(lifted ? (palette.dark ? 0.45 : 0.2) : 0),
                radius: lifted ? 20 : 0, y: lifted ? 14 : 0)
        .scaleEffect(lifted ? 1.02 : 1)
        .zIndex(lifted ? 3 : 0)
        .offset(x: x, y: y)
    }

    /// Where a block sits in the day grid (shared by drawing and hit-testing).
    private func blockFrame(_ p: PositionedBlock, day: Date, totalWidth: CGFloat) -> CGRect {
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let s = max(p.block.start, dayStart)
        let e = min(max(p.block.end, s), dayEnd)
        // A small gap so back-to-back events (one ending, one starting at the
        // same time) don't visually touch.
        let gap: CGFloat = 3
        let y = CGFloat(s.timeIntervalSince(dayStart) / 3600) * hourHeight
        let h = max(22, CGFloat(e.timeIntervalSince(s) / 3600) * hourHeight - gap)

        let gutter = leftGutter + 2
        let avail = max(0, totalWidth - gutter - 6)
        let colW = avail / CGFloat(max(1, p.columnCount))
        let x = gutter + CGFloat(p.column) * colW
        let w = max(0, colW - 3)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The top-most block under a point on the given day, if any.
    private func block(at point: CGPoint, on day: Date, width: CGFloat) -> (PositionedBlock, CGRect)? {
        layout(timedBlocks(for: day))
            .map { ($0, blockFrame($0, day: day, totalWidth: width)) }
            .last { $0.1.contains(point) }
    }

    // MARK: Now line

    /// Today's current-time marker: a navy (sky in dark) line across the grid
    /// with a dot at the gutter and the time in place of the hour label — never
    /// red. Refreshes every 30s.
    private func nowLine(width: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            let y = CGFloat(now.timeIntervalSince(cal.startOfDay(for: now)) / 3600) * hourHeight
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(palette.primary)
                    .frame(width: max(0, width - leftGutter - 4), height: 1.5)
                    .offset(x: leftGutter, y: 3.25)
                Circle()
                    .fill(palette.primary)
                    .frame(width: 8, height: 8)
                    .offset(x: leftGutter - 4)
                Text(now.formatted(.dateTime.hour().minute()))
                    .font(.nunito(size: 11, weight: .heavy))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 2)
                    .background(palette.bg)
                    .frame(width: leftGutter - 8, alignment: .trailing)
                    .offset(y: -3)
            }
            .offset(y: y - 4)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The block body — side bar + title (+ time when there's room). Fills the
    /// whole block height (the duration) so a 2-hour event is twice as tall as a
    /// 1-hour one; the bar is short and inset so it stays clear of the corners.
    /// Events and tasks differ by surface, not hue: events sit on sky-soft with
    /// a sky ring (their calendar's colour survives only as the slim bar); tasks
    /// are white cards with a navy bar.
    private func blockLabel(_ block: DayBlock, compact: Bool, cornerRadius: CGFloat, barInset: CGFloat) -> some View {
        let isTask = block.task != nil
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 1) {
            Text(block.title)
                .font(.nunito(size: 13, weight: .bold))
                .foregroundStyle(palette.text)
                .lineLimit(compact ? 1 : 2)
            if !compact {
                Text(timeText(block))
                    .font(.nunito(size: 11))
                    .foregroundStyle(palette.textSec)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isTask ? palette.card : palette.skySoft, in: shape)
        // The bar spans the block height, inset from the edges/corners.
        .overlay(alignment: .leading) {
            Capsule()
                .fill(block.color)
                .frame(width: 3)
                .padding(.vertical, barInset)
                .padding(.leading, 12)
        }
        .overlay(shape.strokeBorder(isTask ? palette.border : Color.evrySky.opacity(palette.dark ? 0.45 : 1),
                                    lineWidth: 1))
    }

    private func timeText(_ block: DayBlock) -> String {
        if block.start == block.end {
            return block.start.formatted(.dateTime.hour().minute())
        }
        return "\(block.start.formatted(.dateTime.hour().minute()))–\(block.end.formatted(.dateTime.hour().minute()))"
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        return date.formatted(.dateTime.hour())
    }

    // MARK: Press-and-drag event creation

    /// The time at a y-offset in the day grid, snapped to 15 minutes.
    private func timelineTime(y: CGFloat, on day: Date, rounding: FloatingPointRoundingRule) -> Date {
        let minutes = min(24 * 60, max(0, Double(y / hourHeight) * 60))
        let snapped = (minutes / 15).rounded(rounding) * 15
        return cal.startOfDay(for: day).addingTimeInterval(snapped * 60)
    }

    /// Routes a press on the timeline: on an event → move it (middle) or resize
    /// it (top/bottom edge); on empty space → start a new event.
    private func beginPress(at point: CGPoint, on day: Date, width: CGFloat) {
        if let (p, frame) = block(at: point, on: day, width: width),
           let id = p.block.eventID, let event = p.block.ekEvent {
            if draft != nil { commitDraft() }
            // Read-only calendars (holidays, subscriptions) can't be changed.
            guard event.calendar?.allowsContentModifications ?? false else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            let edge = min(14, frame.height * 0.28)
            let mode: EventAdjust.Mode = point.y <= frame.minY + edge ? .start
                : (point.y >= frame.maxY - edge ? .end : .move)
            let fingerTime = timelineTime(y: point.y, on: day, rounding: .toNearestOrAwayFromZero)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                adjusting = EventAdjust(mode: mode, eventID: id, event: event, day: day,
                                        grabOffset: fingerTime.timeIntervalSince(p.block.start),
                                        start: p.block.start, end: p.block.end)
            }
            return
        }
        // Tasks on the timeline aren't dragged; empty space creates.
        guard block(at: point, on: day, width: width) == nil else { return }
        beginDraft(at: point.y, on: day)
    }

    /// Follows the finger in 15-minute steps, keeping the event within the day
    /// and at least 15 minutes long.
    private func updateAdjust(to y: CGFloat) {
        guard var a = adjusting else { return }
        let dayStart = cal.startOfDay(for: a.day)
        let dayEnd = dayStart.addingTimeInterval(86400)
        let t = timelineTime(y: y, on: a.day, rounding: .toNearestOrAwayFromZero)
        switch a.mode {
        case .move:
            let length = a.end.timeIntervalSince(a.start)
            var start = t.addingTimeInterval(-a.grabOffset)
            // Re-snap after the offset so the start lands on a 15-minute mark.
            let mins = (start.timeIntervalSince(dayStart) / 60 / 15).rounded() * 15
            start = dayStart.addingTimeInterval(mins * 60)
            start = min(max(start, dayStart), dayEnd.addingTimeInterval(-length))
            a.start = start
            a.end = start.addingTimeInterval(length)
        case .start:
            a.start = max(dayStart, min(t, a.end.addingTimeInterval(-900)))
        case .end:
            a.end = min(dayEnd, max(t, a.start.addingTimeInterval(900)))
        }
        guard a != adjusting else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.85)) { adjusting = a }
    }

    /// Released: save the new time (if it changed) and settle the block.
    private func endAdjust() {
        guard let a = adjusting else { return }
        let changed = a.start != a.event.startDate || a.end != a.event.endDate
        if changed, calendarService.reschedule(a.event, start: a.start, end: a.end) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            rebuildDayEvents()
            rebuildDotCache()
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { adjusting = nil }
    }

    /// A plain tap: open the event or task under the finger, or finish naming a draft.
    private func tapTimeline(at point: CGPoint, on day: Date, width: CGFloat) {
        if draft?.naming == true { commitDraft(); return }
        guard let (p, _) = block(at: point, on: day, width: width) else { return }
        if let task = p.block.task {
            onEdit(task)
        } else if let id = p.block.eventID {
            openEventEditor(p.block.ekEvent, id: id, title: p.block.title, near: p.block.start)
        }
    }

    /// Hold recognized: a 30-minute event appears where the finger landed.
    private func beginDraft(at y: CGFloat, on day: Date) {
        if draft != nil { commitDraft() }
        guard calendarService.isAuthorized else {
            Task { await calendarService.requestAccess(); rebuildDotCache(); rebuildDayEvents() }
            return
        }
        let dayEnd = cal.startOfDay(for: day).addingTimeInterval(86400)
        // Keep a full 30 minutes inside the day.
        let start = min(timelineTime(y: y, on: day, rounding: .down), dayEnd.addingTimeInterval(-1800))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        draftTitle = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            draft = EventDraft(day: day, anchor: start, start: start, end: start.addingTimeInterval(1800))
        }
    }

    /// Dragging stretches the event to the finger — downward from the anchor, or
    /// upward past it — never shorter than 15 minutes.
    private func updateDraft(to y: CGFloat) {
        guard var d = draft, !d.naming else { return }
        let dayStart = cal.startOfDay(for: d.day)
        let t = timelineTime(y: y, on: d.day, rounding: .toNearestOrAwayFromZero)
        let minEnd = d.anchor.addingTimeInterval(900)
        if t >= minEnd {
            d.start = d.anchor
            d.end = t
        } else if t < d.anchor {
            d.start = max(dayStart, t)
            d.end = d.anchor.addingTimeInterval(1800)
        } else {
            d.start = d.anchor
            d.end = d.anchor.addingTimeInterval(1800)
        }
        guard d != draft else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.85)) { draft = d }
    }

    /// Finger lifted: the block becomes an inline name field with the keyboard up.
    private func endDraftDrag() {
        guard var d = draft, !d.naming else { return }
        d.naming = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { draft = d }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { draftFocused = true }
    }

    /// Saves the named event (an unnamed draft is simply discarded).
    private func commitDraft() {
        guard let d = draft else { return }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        draftFocused = false
        withAnimation(.easeOut(duration: 0.2)) { draft = nil }
        draftTitle = ""
        guard d.naming, !title.isEmpty else { return }
        if calendarService.createEvent(title: title, start: d.start, end: d.end) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            rebuildDayEvents()
            rebuildDotCache()
        }
    }

    private func cancelDraft() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        draftFocused = false
        withAnimation(.easeOut(duration: 0.2)) { draft = nil }
        draftTitle = ""
    }

    private var draftColor: Color {
        calendarService.defaultCalendarColor.map { Color(cgColor: $0) } ?? palette.primary
    }

    /// The new event, drawn like a timeline block: live time range while
    /// stretching, then a name field in place once released.
    private func draftBlock(_ d: EventDraft, totalWidth: CGFloat) -> some View {
        let dayStart = cal.startOfDay(for: d.day)
        let y = CGFloat(d.start.timeIntervalSince(dayStart) / 3600) * hourHeight
        let h = max(24, CGFloat(d.end.timeIntervalSince(d.start) / 3600) * hourHeight - 3)
        let gutter = leftGutter + 2
        let w = max(0, totalWidth - gutter - 9)
        let radius = min(EvryRadius.tile, max(8, h / 2 - 4))
        let range = "\(d.start.formatted(.dateTime.hour().minute()))–\(d.end.formatted(.dateTime.hour().minute()))"
        let color = draftColor

        return VStack(alignment: .leading, spacing: 1) {
            if d.naming {
                TextField("New event", text: $draftTitle)
                    .font(.nunito(size: 14, weight: .bold))
                    .foregroundStyle(palette.text)
                    .tint(palette.primary)
                    .focused($draftFocused)
                    .submitLabel(.done)
                    .onSubmit(commitDraft)
                    .padding(.trailing, 26)
            } else {
                Text("New event")
                    .font(.nunito(size: 14, weight: .bold))
                    .foregroundStyle(palette.textSec)
            }
            if h >= 40 || !d.naming {
                Text(range)
                    .font(.nunito(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .frame(width: w, height: h, alignment: .topLeading)
        // The block being made: sky-soft with a full-ink outline (the "focused"
        // state); the target calendar's colour only as the slim bar.
        .background(palette.skySoft, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(palette.primary, lineWidth: 1.5))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, min(16, max(5, h * 0.26)))
                .padding(.leading, 12)
        }
        .overlay(alignment: .topTrailing) {
            if d.naming {
                Button(action: cancelDraft) {
                    Image(systemName: "xmark")
                        .font(.nunito(size: 11, weight: .bold))
                        .foregroundStyle(palette.text)
                        .frame(width: 22, height: 22)
                        .background(palette.card, in: Circle())
                        .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, max(1, min(6, (h - 22) / 2)))
                .padding(.trailing, 6)
                .accessibilityLabel("Cancel new event")
            }
        }
        .evryShadowLift(palette)
        .scaleEffect(d.naming ? 1 : 1.02)
        .offset(x: gutter, y: y)
    }

    // MARK: Blocks

    private struct DayBlock: Identifiable {
        let id: String
        let title: String
        let color: Color
        let start: Date
        let end: Date
        let task: TaskItem?
        var eventID: String? = nil
        var ekEvent: EKEvent? = nil
    }

    private struct PositionedBlock: Identifiable {
        let block: DayBlock
        let column: Int
        let columnCount: Int
        var id: String { block.id }
    }

    /// Calendar events plus tasks that have a specific time sit on the hourly
    /// timeline; timeless tasks are only summarised in the count indicator.
    private func timedBlocks(for day: Date) -> [DayBlock] {
        var blocks: [DayBlock] = []
        for e in dayEvents where !e.isAllDay && cal.isDate(e.startDate, inSameDayAs: day) {
            // While an event is being dragged, draw it at its new time.
            let live = adjusting?.eventID == e.id ? adjusting : nil
            blocks.append(DayBlock(id: "e-\(e.id)", title: e.title, color: e.calendarColor,
                                   start: live?.start ?? e.startDate, end: live?.end ?? e.endDate, task: nil,
                                   eventID: e.id, ekEvent: e.ekEvent))
        }
        for t in dueTasks where cal.isDate(t.dueDate!, inSameDayAs: day) && hasTime(t.dueDate) {
            let start = t.dueDate!
            blocks.append(DayBlock(id: "t-\(t.uid.uuidString)",
                                   title: t.title.isEmpty ? "Untitled task" : t.title,
                                   color: palette.primary,
                                   start: start, end: start.addingTimeInterval(3600), task: t))
        }
        return blocks
    }

    /// Tasks due that day that have no specific time — represented only by the
    /// small count indicator (not placed on the timeline).
    private func timelessTaskCount(for day: Date) -> Int {
        dueTasks.filter { cal.isDate($0.dueDate!, inSameDayAs: day) && !hasTime($0.dueDate) }.count
    }

    private func allDayEvents(for day: Date) -> [CalendarEvent] {
        dayEvents.filter { $0.isAllDay && cal.isDate($0.startDate, inSameDayAs: day) }
    }

    private func hasTime(_ date: Date?) -> Bool {
        guard let date else { return false }
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }

    /// Column layout for overlapping blocks: cluster transitively-overlapping
    /// items, then greedily assign each to the first free column in its cluster.
    private func layout(_ blocks: [DayBlock]) -> [PositionedBlock] {
        let sorted = blocks.sorted { $0.start < $1.start }
        var result: [PositionedBlock] = []
        var i = 0
        while i < sorted.count {
            var clusterEnd = sorted[i].end
            var j = i + 1
            while j < sorted.count && sorted[j].start < clusterEnd {
                clusterEnd = max(clusterEnd, sorted[j].end)
                j += 1
            }
            let cluster = Array(sorted[i..<j])
            var columns: [[DayBlock]] = []
            for b in cluster {
                var placed = false
                for k in columns.indices {
                    if let last = columns[k].last, last.end <= b.start {
                        columns[k].append(b); placed = true; break
                    }
                }
                if !placed { columns.append([b]) }
            }
            for (ci, col) in columns.enumerated() {
                for b in col {
                    result.append(PositionedBlock(block: b, column: ci, columnCount: columns.count))
                }
            }
            i = j
        }
        return result
    }


    // MARK: Navigation

    /// Month list → year picker. Switched without an animated cross-fade — that
    /// briefly overlapped the year rows as the list jumped to position.
    private func openYearView() {
        yearScrollID = cal.component(.year, from: displayMonth)
        mode = .year
    }

    /// Year picker → month list. The current year lands on the current month;
    /// other years start at January.
    private func openMonths(year: Int) {
        let target: Date
        if year == cal.component(.year, from: refDay) {
            target = refMonth
        } else {
            target = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? displayMonth
        }
        displayMonth = target
        monthScrollID = monthIndex(target)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { mode = .month }
    }

    /// Week → month list, scrolled back to the selected day's month.
    private func returnToMonth() {
        displayMonth = firstOfMonth(selectedDay)
        monthScrollID = monthIndex(selectedDay)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { mode = .month }
    }

    private func enterWeek(_ day: Date) {
        let d = cal.startOfDay(for: day)
        selectedDay = d
        if !cal.isDate(d, equalTo: displayMonth, toGranularity: .month) { displayMonth = d }
        dayScrollID = dayIndex(d)
        weekScrollID = weekIndex(d)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { mode = .week }
    }

    private func selectDay(_ day: Date) {
        selectedDay = cal.startOfDay(for: day)
    }

    /// Open the Evry event editor for a tapped calendar event.
    private func openEventEditor(_ ekEvent: EKEvent?, id: String, title: String, near date: Date) {
        // Prefer the live event carried from the query; fall back to re-resolving
        // by identifier/title only if it's somehow missing.
        let resolved = ekEvent ?? calendarService.editableEvent(id: id, title: title, near: date)
        guard let resolved else { return }
        editingEvent = EditableEvent(event: resolved)
    }

    // MARK: Events

    /// Preload event + task dots for a wide window once, so the month list never
    /// queries EventKit or filters while scrolling.
    private func rebuildDotCache() {
        var cache: [Date: [Color]] = [:]
        // Events: a single EventKit query spanning ±30 months.
        if calendarService.isAuthorized {
            let start = cal.date(byAdding: .month, value: -30, to: refMonth) ?? refMonth
            let end = cal.date(byAdding: .month, value: 30, to: refMonth) ?? refMonth
            for e in calendarService.events(from: start, to: end) {
                cache[cal.startOfDay(for: e.startDate), default: []].append(e.calendarColor)
            }
        }
        // Tasks (already in memory): one ink dot per task due that day.
        for t in dueTasks {
            guard let due = t.dueDate else { continue }
            cache[cal.startOfDay(for: due), default: []].append(palette.primary)
        }
        // Cap so each lookup stays tiny (events first, then tasks).
        dotCache = cache.mapValues { Array($0.prefix(3)) }
    }

    private func rebuildDayEvents() {
        guard calendarService.isAuthorized else { dayEvents = []; return }
        // A window around the selected day so the neighbouring pages that the
        // pager renders already have their events.
        let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: selectedDay)) ?? selectedDay
        let end = cal.date(byAdding: .day, value: 8, to: cal.startOfDay(for: selectedDay)) ?? selectedDay
        dayEvents = calendarService.events(from: start, to: end)
    }
}


// MARK: - Timeline press catcher

/// A transparent UIKit layer over the day timeline. A press held ~0.25s begins a
/// gesture that then tracks the finger (UILongPressGestureRecognizer is
/// continuous) — used to create, move and resize events. Moving before the hold
/// fires fails the press, leaving vertical scrolling and day paging untouched.
/// Plain taps are reported with their location (open an event, finish a draft).
private struct TimelinePressCatcher: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void
    var onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.press(_:)))
        // Short enough to feel like "tap and drag" on an event.
        press.minimumPressDuration = 0.25
        press.allowableMovement = 10
        view.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: TimelinePressCatcher
        init(_ parent: TimelinePressCatcher) { self.parent = parent }

        @objc func press(_ g: UILongPressGestureRecognizer) {
            let point = g.location(in: g.view)
            switch g.state {
            case .began: parent.onBegan(point)
            case .changed: parent.onChanged(point)
            case .ended, .cancelled, .failed: parent.onEnded()
            default: break
            }
        }

        @objc func tap(_ g: UITapGestureRecognizer) { parent.onTap(g.location(in: g.view)) }
    }
}
