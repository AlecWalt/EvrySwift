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
import EventKitUI

struct CalendarTabView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(CalendarService.self) private var calendarService

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    @AppStorage("membership_plan") private var membershipPlan = ""

    @State private var mode: CalMode = .month
    @State private var showProPromo = false
    @State private var displayMonth = Calendar.current.startOfDay(for: .now)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var dayEvents: [CalendarEvent] = []
    /// Preloaded per-day dot colors (events + tasks) so scrolling the month list
    /// is an O(1) lookup — no EventKit query or filtering mid-scroll.
    @State private var dotCache: [Date: [Color]] = [:]
    @State private var showAdd = false
    @State private var addSession = 0
    /// Native paging scroll positions (day timeline / week number strip).
    @State private var dayScrollID: Int?
    @State private var weekScrollID: Int?
    /// Vertical scroll positions for the month list and the year list.
    @State private var monthScrollID: Int? = 0
    @State private var yearScrollID: Int? = Calendar.current.component(.year, from: .now)
    /// The calendar event currently being edited (via the system event editor).
    @State private var editingEvent: EditableEvent?

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

    private var isPro: Bool { membershipPlan == "pro" }
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

    // MARK: Derived dates

    private var addDefaultDate: Date {
        cal.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDay) ?? selectedDay
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)

            if mode != .year {
                if !isPro {
                    proBanner
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                } else if needsConnect {
                    connectBanner
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }

            switch mode {
            case .year:  yearView
            case .month: monthView
            case .week:  weekView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
        .overlay(alignment: .bottom) {
            if showAdd {
                AddTaskSheet(isPresented: $showAdd, defaultDate: addDefaultDate)
                    .id(addSession)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $editingEvent) { wrapper in
            EventEditView(store: calendarService.eventStore, event: wrapper.event, tint: palette.primary) {
                // Clear the binding so SwiftUI actually dismisses the sheet — the
                // system editor's own dismiss left it presented, so the confirm
                // button appeared to do nothing.
                editingEvent = nil
                rebuildDotCache()
                rebuildDayEvents()
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showProPromo) { MembershipPromoView() }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: showAdd)
        .onChange(of: showAdd) { _, open in
            if open { addSession += 1 } else { rebuildDayEvents(); rebuildDotCache() }
        }
        .onAppear { rebuildDotCache(); rebuildDayEvents() }
        .onChange(of: monthScrollID) { _, id in
            // Keep the header year in sync with the visible month (no fetching).
            guard mode == .month, let id else { return }
            let m = monthDate(id)
            if !cal.isDate(m, equalTo: displayMonth, toGranularity: .month) { displayMonth = m }
        }
        .onChange(of: selectedDay) { _, _ in
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
        HStack(alignment: .center, spacing: 10) {
            switch mode {
            case .week:
                // Back to the month list, scrolled to the selected day's month.
                Button { returnToMonth() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .bold))
                        Text(selectedDay.formatted(.dateTime.month(.wide)))
                            .font(.system(size: 30, weight: .heavy))
                    }
                    .foregroundStyle(palette.primary)
                }
                .buttonStyle(.plain)
            case .month:
                // The year — tap to open the year picker.
                Button { openYearView() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .bold))
                        Text(displayMonth.formatted(.dateTime.year()))
                            .font(.system(size: 30, weight: .heavy))
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(palette.primary)
                }
                .buttonStyle(.plain)
            case .year:
                Text("Year")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(palette.text)
            }

            Spacer()

            Menu {
                Button { showAdd = true } label: {
                    Label("New Task", systemImage: "checkmark.circle")
                }
                Button { addEvent() } label: {
                    Label("New Event", systemImage: "calendar.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.onPrimary)
                    .frame(width: 34, height: 34)
                    .background(palette.primary, in: Circle())
            }
        }
    }

    /// Create a new calendar event on the selected day and open the system editor.
    private func addEvent() {
        guard isPro else { showProPromo = true; return }
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

    /// Calendar integration (connecting external calendars) is Pro-only.
    private var proBanner: some View {
        Button { showProPromo = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.primary)
                Text("Calendar sync is a Pro feature — upgrade to see your events here")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSec)
            }
            .padding(12)
            .evryCard(palette)
        }
        .buttonStyle(.plain)
    }

    private var connectBanner: some View {
        Button {
            Task { await calendarService.requestAccess(); rebuildDotCache(); rebuildDayEvents() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 16))
                    .foregroundStyle(palette.primary)
                Text("Connect your calendar to see events here")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSec)
            }
            .padding(12)
            .evryCard(palette)
        }
        .buttonStyle(.plain)
    }

    // MARK: Year view

    /// A scroll-wheel style year picker: it snaps each year to the middle, the
    /// centered year is enlarged + accent-tinted (the "selected" one), and the
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
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(year == yearScrollID ? palette.primary : palette.text)
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
                        monthSection(monthDate(mi))
                            .id(mi)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $monthScrollID)
        }
    }

    private func monthSection(_ month: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(month.formatted(.dateTime.month(.wide)))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(palette.text)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSec)
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
                        Circle().fill(palette.primary).frame(width: 28, height: 28)
                    }
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 15, weight: isToday || isSelected ? .bold : .regular))
                        .foregroundStyle(dayNumberColor(isToday: isToday, isSelected: isSelected))
                }
                .frame(height: 28)

                // Up to three simple event/task dots (lighter than dot + line).
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
        if isSelected { return .white }
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

            Divider()

            let taskCount = timelessTaskCount(for: selectedDay)
            let allDay = allDayEvents(for: selectedDay)
            if taskCount > 0 || !allDay.isEmpty {
                topSummaryBar(taskCount: taskCount, events: allDay)
            }

            dayPager
        }
    }

    /// The top row: a "N tasks due" indicator on the left, then all-day events
    /// splitting the remaining width evenly.
    private func topSummaryBar(taskCount: Int, events: [CalendarEvent]) -> some View {
        HStack(spacing: 8) {
            if taskCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.primary)
                    Text("\(taskCount) task\(taskCount == 1 ? "" : "s") due")
                        .font(.system(size: 12, weight: .medium))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func allDayEventChip(_ event: CalendarEvent) -> some View {
        HStack(spacing: 5) {
            Circle().fill(event.calendarColor).frame(width: 6, height: 6)
            Text(event.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(event.calendarColor.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(event.calendarColor.opacity(0.4), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { openEventEditor(event.id, near: event.startDate) }
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
                        Circle().fill(palette.primary).frame(width: 34, height: 34)
                    }
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : (isToday ? palette.primary : palette.text))
                }
                .frame(width: 34, height: 34)
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
                    }
                    .frame(width: w, height: hourHeight * 24, alignment: .topLeading)
                    .padding(.bottom, 130)
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
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textSec)
                        .frame(width: leftGutter - 10, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle()
                        .fill(palette.border.opacity(0.6))
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

        // Rounded corners like the timeline task items, scaled down for short
        // events so they never collapse into pills; the accent bar's inset grows
        // with the event so it isn't cramped against the edges.
        let radius = min(14, max(8, h / 2 - 4))
        let barInset = min(16, max(5, h * 0.26))

        let content = blockLabel(p.block, compact: h < 40, cornerRadius: radius, barInset: barInset)
            .frame(width: w, height: h, alignment: .topLeading)
            .offset(x: x, y: y)

        if let task = p.block.task {
            Button { onEdit(task) } label: { content }
                .buttonStyle(.plain)
        } else if let eventID = p.block.eventID {
            Button { openEventEditor(eventID, near: p.block.start) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    /// The colored block body — accent bar + title (+ time when there's room).
    /// Fills the whole block height (the duration) so a 2-hour event is twice as
    /// tall as a 1-hour one; the accent bar is short and inset so it stays clear
    /// of the rounded corners.
    private func blockLabel(_ block: DayBlock, compact: Bool, cornerRadius: CGFloat, barInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(block.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(compact ? 1 : 2)
            if !compact {
                Text(timeText(block))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textSec)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(block.color.opacity(0.16), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Accent bar spans the block height, inset from the edges/corners.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(block.color)
                .frame(width: 3)
                .padding(.vertical, barInset)
                .padding(.leading, 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(block.color.opacity(0.4), lineWidth: 1)
        )
    }

    private func timeText(_ block: DayBlock) -> String {
        if block.start == block.end {
            return block.start.formatted(.dateTime.hour().minute())
        }
        return "\(block.start.formatted(.dateTime.hour().minute())) – \(block.end.formatted(.dateTime.hour().minute()))"
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        return date.formatted(.dateTime.hour())
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
            blocks.append(DayBlock(id: "e-\(e.id)", title: e.title, color: e.calendarColor,
                                   start: e.startDate, end: e.endDate, task: nil, eventID: e.id))
        }
        for t in dueTasks where cal.isDate(t.dueDate!, inSameDayAs: day) && hasTime(t.dueDate) {
            let start = t.dueDate!
            blocks.append(DayBlock(id: "t-\(t.uid.uuidString)",
                                   title: t.title.isEmpty ? "Untitled Task" : t.title,
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

    /// Open the system event editor for a tapped calendar event (title, time,
    /// location, notes, and calendar/color are all editable there).
    private func openEventEditor(_ eventID: String, near date: Date) {
        guard let ek = calendarService.editableEvent(id: eventID, near: date) else { return }
        editingEvent = EditableEvent(event: ek)
    }

    // MARK: Events

    /// Preload event + task dots for a wide window once, so the month list never
    /// queries EventKit or filters while scrolling.
    private func rebuildDotCache() {
        var cache: [Date: [Color]] = [:]
        // Events: a single EventKit query spanning ±30 months (Pro only).
        if isPro && calendarService.isAuthorized {
            let start = cal.date(byAdding: .month, value: -30, to: refMonth) ?? refMonth
            let end = cal.date(byAdding: .month, value: 30, to: refMonth) ?? refMonth
            for e in calendarService.events(from: start, to: end) {
                cache[cal.startOfDay(for: e.startDate), default: []].append(e.calendarColor)
            }
        }
        // Tasks (already in memory): one accent dot per task due that day.
        for t in dueTasks {
            guard let due = t.dueDate else { continue }
            cache[cal.startOfDay(for: due), default: []].append(palette.primary)
        }
        // Cap so each lookup stays tiny (events first, then tasks).
        dotCache = cache.mapValues { Array($0.prefix(3)) }
    }

    private func rebuildDayEvents() {
        guard isPro, calendarService.isAuthorized else { dayEvents = []; return }
        // A window around the selected day so the neighbouring pages that the
        // pager renders already have their events.
        let start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: selectedDay)) ?? selectedDay
        let end = cal.date(byAdding: .day, value: 8, to: cal.startOfDay(for: selectedDay)) ?? selectedDay
        dayEvents = calendarService.events(from: start, to: end)
    }
}

// MARK: - System event editor

/// Wraps `EKEventEditViewController` so a tapped calendar event can be edited
/// (title, time, location, notes, and calendar/color) and saved back to EventKit.
private struct EventEditView: UIViewControllerRepresentable {
    let store: EKEventStore
    let event: EKEvent
    var tint: Color
    var onDone: () -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = event
        vc.editViewDelegate = context.coordinator
        // Theme the editor's bar buttons (Cancel / Add / Done) with the app accent.
        // Setting the VC's view tintColor is what actually recolors them — SwiftUI's
        // `.tint` doesn't reliably reach a hosted UIKit controller's nav bar.
        vc.view.tintColor = UIColor(tint)
        return vc
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
        controller.view.tintColor = UIColor(tint)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func eventEditViewController(_ controller: EKEventEditViewController,
                                     didCompleteWith action: EKEventEditViewAction) {
            // Dismiss via SwiftUI by clearing the presentation binding (onDone),
            // rather than dismissing this controller directly — the latter left the
            // SwiftUI sheet host presented, making the confirm button seem broken.
            onDone()
        }
    }
}
