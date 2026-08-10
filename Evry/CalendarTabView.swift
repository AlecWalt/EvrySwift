//
//  CalendarTabView.swift
//  Evry
//
//  Calendar tab — month grid with task dots (circles) and event dots (squares),
//  selected-day panel showing external calendar events with one-tap import,
//  and the Evry task list for that day.
//

import SwiftUI
import SwiftData
import UIKit

struct CalendarTabView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(CalendarService.self) private var calendarService
    @Query(sort: \TaskItem.dueDate) private var allTasks: [TaskItem]
    @State private var displayMonth: Date = .now
    @State private var selectedDay: Date = .now
    @AppStorage("inbox_hide_completed") private var hideCompleted = false
    @State private var showCompleted = false
    @State private var calendarExpanded = false
    @State private var dragProgress: CGFloat = 0

    private let cal = Calendar.current
    private let weekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    private var tasks: [TaskItem] {
        allTasks.filter { !$0.isTrashed && !$0.isNote }
    }

    private var firstOfMonth: Date {
        let c = cal.dateComponents([.year, .month], from: displayMonth)
        return cal.date(from: c) ?? displayMonth
    }

    private var lastOfMonth: Date {
        cal.date(byAdding: DateComponents(month: 1, second: -1), to: firstOfMonth) ?? firstOfMonth
    }

    private var monthLabel: String {
        firstOfMonth.formatted(.dateTime.month(.wide).year())
    }

    private var gridDays: [Date?] {
        let leadingPad = cal.component(.weekday, from: firstOfMonth) - 1
        let count = cal.range(of: .day, in: .month, for: firstOfMonth)!.count
        var days: [Date?] = Array(repeating: nil, count: leadingPad)
        for d in 0..<count {
            days.append(cal.date(byAdding: .day, value: d, to: firstOfMonth))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }

    private var weekRows: [[Date?]] {
        stride(from: 0, to: gridDays.count, by: 7).map { i in
            Array(gridDays[i..<min(i+7, gridDays.count)])
        }
    }

    private var currentWeekIndex: Int {
        weekRows.firstIndex { week in
            week.compactMap { $0 }.contains { cal.isDate($0, inSameDayAs: selectedDay) }
        } ?? 0
    }

    // Each row = 50pt cell + 2pt spacing (except last row has no trailing spacing)
    private var cellRowHeight: CGFloat { 52 }
    private var collapsedGridHeight: CGFloat { 50 }
    private var expandedGridHeight: CGFloat { CGFloat(weekRows.count) * cellRowHeight - 2 }
    private var currentGridHeight: CGFloat {
        collapsedGridHeight + (expandedGridHeight - collapsedGridHeight) * dragProgress
    }
    // Offset the grid upward so the current week is visible when collapsed
    private var gridYOffset: CGFloat {
        -CGFloat(currentWeekIndex) * cellRowHeight * (1 - dragProgress)
    }

    // Direct 7-day week from selectedDay — used for collapsed row (no month dependency)
    private var currentWeekDays: [Date] {
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: selectedDay)
        guard let weekStart = cal.date(from: comps) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var monthEvents: [CalendarEvent] {
        calendarService.events(from: firstOfMonth, to: lastOfMonth)
    }

    private func tasks(on day: Date) -> [TaskItem] {
        tasks.filter { task in
            guard let due = task.dueDate else { return false }
            return cal.isDate(due, inSameDayAs: day)
        }
    }

    private func calendarEvents(on day: Date) -> [CalendarEvent] {
        monthEvents.filter { cal.isDate($0.startDate, inSameDayAs: day) }
    }

    private func taskDotColors(for day: Date) -> [Color] {
        let dotPalette: [Color] = [
            palette.primary,
            Color(hex: 0x22C55E),
            Color(hex: 0xEC4899),
            Color(hex: 0xF97316),
            Color(hex: 0x8B5CF6),
        ]
        return tasks(on: day).prefix(4).map { task in
            var h = 0
            for s in task.uid.uuidString.unicodeScalars {
                h = Int(s.value) &+ ((h << 5) &- h)
            }
            return dotPalette[abs(h) % dotPalette.count]
        }
    }

    private func eventDotColors(for day: Date) -> [Color] {
        calendarEvents(on: day).prefix(3).map(\.calendarColor)
    }

    private var selectedDayTasks: [TaskItem] { tasks(on: selectedDay) }
    private var selectedDayEvents: [CalendarEvent] { calendarEvents(on: selectedDay) }
    private var activeDayTasks: [TaskItem] { selectedDayTasks.filter { !$0.completed } }
    private var completedCalendarTasks: [TaskItem] { selectedDayTasks.filter { $0.completed } }

    private var selectedDayLabel: String {
        selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                monthHeader
                weekdayHeader
                dayGrid
                    .padding(.horizontal, 8)
                Divider()
                    .background(palette.border)
                    .padding(.top, 8)
                selectedDayPanel
            }
        }
        .background(palette.bg)
        .onAppear {
            dragProgress = calendarExpanded ? 1 : 0
            calendarService.refreshStatus()
        }
    }

    // MARK: Month header

    private var monthHeader: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if calendarExpanded {
                        displayMonth = cal.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
                    } else {
                        selectedDay = cal.date(byAdding: .day, value: -7, to: selectedDay) ?? selectedDay
                        displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: selectedDay)) ?? displayMonth
                    }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 36, height: 36)
                    .background(palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(monthLabel)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(palette.text)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if calendarExpanded {
                        displayMonth = cal.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
                    } else {
                        selectedDay = cal.date(byAdding: .day, value: 7, to: selectedDay) ?? selectedDay
                        displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: selectedDay)) ?? displayMonth
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(width: 36, height: 36)
                    .background(palette.card, in: Circle())
                    .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: Weekday header row

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(weekdayLabels[i])
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textSec)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    // MARK: Day grid

    private var dayGrid: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Collapsed view: direct 7-day row derived from selectedDay.
                // No month dependency — never jumps when crossing months.
                HStack(spacing: 0) {
                    ForEach(Array(currentWeekDays.enumerated()), id: \.offset) { _, day in
                        DayCell(
                            day: day,
                            isToday: cal.isDateInToday(day),
                            isSelected: cal.isDate(day, inSameDayAs: selectedDay),
                            taskDots: taskDotColors(for: day),
                            eventDots: eventDotColors(for: day),
                            palette: palette
                        ) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                selectedDay = day
                            }
                        }
                    }
                }
                .frame(height: 50, alignment: .top)
                .opacity(Double(1 - dragProgress))

                // Expanded view: full month grid, fades in as calendar opens
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                    spacing: 2
                ) {
                    ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                        if let day {
                            DayCell(
                                day: day,
                                isToday: cal.isDateInToday(day),
                                isSelected: cal.isDate(day, inSameDayAs: selectedDay),
                                taskDots: taskDotColors(for: day),
                                eventDots: eventDotColors(for: day),
                                palette: palette
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    selectedDay = day
                                }
                            }
                        } else {
                            Color.clear.frame(height: 50)
                        }
                    }
                }
                .offset(y: gridYOffset)
                .opacity(Double(dragProgress))
            }
            .frame(height: currentGridHeight, alignment: .top)
            .clipped()

            // Drag handle — drag smoothly to expand/collapse
            Capsule()
                .fill(palette.border)
                .frame(width: 32, height: 3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let range = expandedGridHeight - collapsedGridHeight
                            guard range > 0 else { return }
                            let startProgress = calendarExpanded ? 1.0 : 0.0
                            dragProgress = max(0, min(1, startProgress + v.translation.height / range))
                        }
                        .onEnded { v in
                            let isTap = abs(v.translation.height) < 8 && abs(v.translation.width) < 8
                            let shouldExpand: Bool
                            if isTap {
                                shouldExpand = !calendarExpanded
                            } else {
                                let velocity = v.predictedEndTranslation.height - v.translation.height
                                shouldExpand = dragProgress > 0.45 || velocity > 150
                            }
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                calendarExpanded = shouldExpand
                                dragProgress = shouldExpand ? 1 : 0
                                if shouldExpand {
                                    // Sync displayMonth to selectedDay when opening the full grid
                                    displayMonth = cal.date(from: cal.dateComponents([.year, .month], from: selectedDay)) ?? displayMonth
                                }
                            }
                        }
                )
        }
    }

    // MARK: Selected day panel

    private var selectedDayPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedDayLabel.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(palette.textSec)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            if !calendarService.isAuthorized {
                calendarConnectBanner
                    .padding(.bottom, 12)
            }

            if !selectedDayEvents.isEmpty {
                VStack(spacing: 8) {
                    ForEach(selectedDayEvents) { event in
                        EventRow(
                            event: event,
                            palette: palette,
                            isImported: calendarService.importedEventIDs.contains(event.id)
                        ) {
                            calendarService.importEvent(event, context: modelContext)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            if activeDayTasks.isEmpty && completedCalendarTasks.isEmpty && selectedDayEvents.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 30))
                            .foregroundStyle(palette.border)
                        Text("No tasks or events this day")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSec)
                    }
                    .padding(.vertical, 28)
                    Spacer()
                }
            } else {
                if !activeDayTasks.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(activeDayTasks) { task in
                            TaskRowView(
                                task: task,
                                palette: palette,
                                onToggle: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        TaskActions.toggle(task, context: modelContext)
                                    }
                                },
                                onEdit: { onEdit(task) },
                                onDelete: { onDelete(task) },
                                onToggleSubtask: { subtask in
                                    withAnimation {
                                        if let i = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                                            task.subtasks[i].completed.toggle()
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if !completedCalendarTasks.isEmpty && !hideCompleted {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { showCompleted.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            SectionLabel(text: "Completed (\(completedCalendarTasks.count))", palette: palette)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(palette.textSec)
                                .rotationEffect(.degrees(showCompleted ? 180 : 0))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    if showCompleted {
                        VStack(spacing: 8) {
                            ForEach(completedCalendarTasks) { task in
                                TaskRowView(
                                    task: task,
                                    palette: palette,
                                    onToggle: {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                            TaskActions.toggle(task, context: modelContext)
                                        }
                                    },
                                    onEdit: { onEdit(task) },
                                    onDelete: { onDelete(task) },
                                    onToggleSubtask: { subtask in
                                        withAnimation {
                                            if let i = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                                                task.subtasks[i].completed.toggle()
                                            }
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .padding(.bottom, 120)
    }

    private var calendarConnectBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 18))
                .foregroundStyle(palette.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect your calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text(calendarService.accessDenied
                     ? "Enable access in Settings → Privacy → Calendars"
                     : "See Apple, Google & Outlook events here")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
                    .lineLimit(2)
            }
            Spacer()
            if calendarService.accessDenied {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primary)
                .buttonStyle(.plain)
            } else {
                Button("Connect") {
                    Task { await calendarService.requestAccess() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.primaryLight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Event row

struct EventRow: View {
    let event: CalendarEvent
    let palette: Palette
    let isImported: Bool
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                if event.isAllDay {
                    Text("All day · \(event.calendarTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                } else {
                    Text("\(event.startDate.formatted(.dateTime.hour().minute())) – \(event.endDate.formatted(.dateTime.hour().minute())) · \(event.calendarTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                }
            }

            Spacer()

            Button(action: onImport) {
                Image(systemName: isImported ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 22))
                    .foregroundStyle(isImported ? Palette.success : palette.primary)
            }
            .buttonStyle(.plain)
            .disabled(isImported)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .evryCard(palette)
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let day: Date
    let isToday: Bool
    let isSelected: Bool
    let taskDots: [Color]
    let eventDots: [Color]
    let palette: Palette
    let action: () -> Void

    private var dayNumber: Int { Calendar.current.component(.day, from: day) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    if isSelected {
                        Circle().fill(palette.primary).frame(width: 26, height: 26)
                    } else if isToday {
                        Circle().fill(palette.primaryLight).frame(width: 26, height: 26)
                    }
                    Text("\(dayNumber)")
                        .font(.system(size: 13, weight: isToday || isSelected ? .bold : .regular))
                        .foregroundStyle(
                            isSelected ? palette.onPrimary
                            : isToday  ? palette.primary
                            : palette.text
                        )
                }
                .frame(width: 30, height: 30)

                // Task dots — circles
                HStack(spacing: 2) {
                    ForEach(Array(taskDots.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(isSelected ? palette.onPrimary.opacity(0.6) : color)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 6)

                // Event dots — rounded squares, visually distinct from task dots
                HStack(spacing: 2) {
                    ForEach(Array(eventDots.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isSelected ? palette.onPrimary.opacity(0.5) : color)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 6)
            }
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
