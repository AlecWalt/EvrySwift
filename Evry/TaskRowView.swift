//
//  TaskRowView.swift
//  Evry
//
//  The task card — port of the webapp's TaskItem row: rounded card, circle
//  checkbox, strikethrough title, notes preview, colored meta chips,
//  embedded subtasks, trailing trash button.
//

import SwiftUI
import UIKit

struct TaskRowView: View {
    let task: TaskItem
    let palette: Palette
    var onToggle: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onToggleSubtask: (SubtaskData) -> Void
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    var compact: Bool = false

    @State private var subtasksExpanded = true

    private var hasMeta: Bool {
        !task.isNote && (task.dueDate != nil || !task.tags.isEmpty || task.priority != .normal || task.recurrence != nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isSelecting {
                Button(action: onSelect) {
                    ZStack {
                        Circle().fill(isSelected ? palette.primary : .clear)
                        Circle().strokeBorder(isSelected ? palette.primary : palette.border, lineWidth: 2)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else if task.isNote {
                // A note has nothing to "complete" — same footprint so notes
                // and tasks still line up in a mixed list.
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textPh)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
            } else {
                TaskCheckbox(checked: task.completed, palette: palette, action: onToggle)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if task.pinned {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.primary)
                    }
                    Text(task.title)
                        .font(.system(size: 16.5))
                        .foregroundStyle(task.completed ? palette.textSec : palette.text)
                        .strikethrough(task.completed, color: palette.textPh)
                        .multilineTextAlignment(.leading)
                }

                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.system(size: task.isNote ? 13.5 : 12))
                        .foregroundStyle(task.isNote ? palette.text : palette.textSec)
                        .lineLimit(task.isNote ? 8 : 2)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 3)
                }

                if hasMeta {
                    metaChips
                        .padding(.top, 5)
                }

                if !task.subtasks.isEmpty {
                    subtaskToggle
                        .padding(.top, 6)
                    if subtasksExpanded {
                        subtaskList
                            .padding(.top, 4)
                            .padding(.leading, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isSelecting {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSec)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.3)
            }
        }
        .padding(.vertical, compact ? 7 : 11)
        .padding(.horizontal, 14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(task.completed ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if isSelecting { onSelect() } else { onEdit() } }
    }

    private var metaChips: some View {
        HStack(spacing: 4) {
            if let due = task.dueDate {
                DateChip(date: due, palette: palette)
            }
            if let recurrence = task.recurrence {
                ChipView(text: "🔁 \(recurrence.label)", foreground: palette.primary, background: palette.primaryLight)
            }
            if let priorityLabel = task.priority.chipLabel {
                ChipView(
                    text: priorityLabel,
                    foreground: priorityColor,
                    background: priorityBackground
                )
            }
            ForEach(task.tags, id: \.self) { tag in
                ChipView(text: "#\(tag)", foreground: palette.textSec, background: palette.hover)
            }
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: Palette.danger
        case .medium: Palette.warning
        case .low: Palette.success
        case .normal: palette.textSec
        }
    }

    private var priorityBackground: Color {
        switch task.priority {
        case .high: palette.dangerLight
        case .medium: palette.warningLight
        case .low: palette.successLight
        case .normal: palette.hover
        }
    }

    private var subtaskToggle: some View {
        let done = task.subtasks.filter(\.completed).count
        let total = task.subtasks.count
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                subtasksExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.textPh)
                    .rotationEffect(.degrees(subtasksExpanded ? 0 : -90))
                Text("\(done)/\(total) subtasks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textSec)
            }
        }
        .buttonStyle(.plain)
    }

    private var subtaskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(task.subtasks) { subtask in
                HStack(spacing: 8) {
                    if !task.isNote {
                        Button {
                            onToggleSubtask(subtask)
                        } label: {
                            ZStack {
                                Circle().fill(subtask.completed ? Palette.success : .clear)
                                Circle().strokeBorder(subtask.completed ? Palette.success : palette.border, lineWidth: 1.5)
                                if subtask.completed {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(subtask.title)
                        .font(.system(size: 13))
                        .foregroundStyle(subtask.completed ? palette.textSec : palette.text)
                        .strikethrough(subtask.completed, color: palette.textPh)
                }
            }
        }
    }
}

// MARK: - Swipe-to-schedule

/// Where a schedule swipe sends a task. `keyword` feeds the shared
/// `resolveDateKeyword` so the resolved date matches typed keywords exactly.
enum ScheduleDestination {
    case today, tomorrow, nextWeekend

    /// The keyword handed to `resolveDateKeyword` — one source of truth.
    var keyword: String {
        switch self {
        case .today:       "today"
        case .tomorrow:    "tomorrow"
        case .nextWeekend: "next weekend"
        }
    }

    var label: String {
        switch self {
        case .today:       "Today"
        case .tomorrow:    "Tomorrow"
        case .nextWeekend: "Next Weekend"
        }
    }

    var icon: String {
        switch self {
        case .today:       "arrow.up"
        case .tomorrow:    "arrow.right"
        case .nextWeekend: "arrow.left"
        }
    }

    func color(_ palette: Palette) -> Color {
        switch self {
        case .today:       palette.primary
        case .tomorrow:    Palette.success
        case .nextWeekend: Color(hex: 0x8B5CF6)
        }
    }
}

/// Wraps a task card with gesture-based scheduling:
/// swipe **up** → Today (drops into the list), **right** → Tomorrow (flies off
/// right), **left** → Next Weekend (slingshot: recoils right, then launches
/// left). Partial drags spring back. Direction is decided from both translation
/// distance and release velocity. The resolved date always comes from
/// `resolveDateKeyword`, so it stays in sync with the typed-keyword system.
struct ScheduleSwipeCard<Content: View>: View {
    let palette: Palette
    /// Committed schedule change — resolved `date` plus which direction fired.
    var onSchedule: (Date, ScheduleDestination) -> Void
    /// True while a higher-priority gesture (reorder / multi-select) owns the
    /// row — swiping is suppressed so the gestures don't fight.
    var isLocked: Bool = false
    /// When true the whole card is flung fully off-screen in its direction on
    /// commit, then a fresh, empty card slides back up from the bottom — used by
    /// the quick-add sheet so it feels like the sheet itself is sent to the day.
    var sendsAway: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var offset: CGSize = .zero
    @State private var opacity: Double = 1
    @State private var pending: ScheduleDestination? = nil
    @State private var armed = false
    @State private var committing = false
    @State private var cardWidth: CGFloat = 400
    @State private var cardHeight: CGFloat = 240

    // Commit needs either enough distance OR enough release velocity.
    private let distanceThreshold: CGFloat = 78
    private let velocityThreshold: CGFloat = 320
    // Below this the hint doesn't show yet — avoids flicker on tiny nudges.
    private let hintThreshold: CGFloat = 26

    private var exitDistance: CGFloat { cardWidth + 220 }
    private var exitUpDistance: CGFloat { cardHeight + 520 }
    private var reentryDistance: CGFloat { cardHeight + 120 }

    var body: some View {
        content()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { cardWidth = geo.size.width; cardHeight = geo.size.height }
                        .onChange(of: geo.size.width) { _, w in cardWidth = w }
                        .onChange(of: geo.size.height) { _, h in cardHeight = h }
                }
            )
            .offset(offset)
            .opacity(opacity)
            // Tilt tracks horizontal pull for a physical feel; kept subtle and
            // capped so it never looks broken. Vertical (Today) swipes stay upright.
            .rotationEffect(.degrees(Double(max(-8, min(8, offset.width / 26)))),
                            anchor: .bottom)
            .overlay(alignment: hintAlignment) { hintBadge }
            .contentShape(Rectangle())
            .simultaneousGesture(scheduleDrag)
    }

    // MARK: Gesture

    private var scheduleDrag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !committing, !isLocked else { return }
                offset = visualOffset(for: value.translation)
                updateHint(for: value.translation)
            }
            .onEnded { value in
                guard !committing, !isLocked else { return }
                if let dest = destination(value.translation, value.velocity) {
                    commit(dest)
                } else {
                    reset()
                }
            }
    }

    /// Live visual position: leftward gets slingshot resistance (rubber-banding),
    /// downward is heavily resisted (Today is an *up* gesture), up/right track 1:1.
    private func visualOffset(for t: CGSize) -> CGSize {
        var w = t.width
        if w < 0 { w = -rubberBand(-w) }
        // Allow free upward travel; clamp/resist downward drift.
        let h = t.height < 0 ? t.height : rubberBand(t.height, limit: 60)
        return CGSize(width: w, height: h)
    }

    /// Diminishing-returns curve — the farther you pull, the more it resists,
    /// like drawing back a slingshot.
    private func rubberBand(_ x: CGFloat, limit: CGFloat = 140) -> CGFloat {
        let c: CGFloat = 0.55
        return (1 - 1 / (x / limit * c + 1)) * limit
    }

    private func updateHint(for t: CGSize) {
        let dest = liveDestination(t)
        if dest != pending {
            pending = dest
            if dest != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
        let magnitude = abs(t.width) > abs(t.height) ? abs(t.width) : abs(t.height)
        let nowArmed = dest != nil && magnitude >= distanceThreshold
        if nowArmed != armed {
            armed = nowArmed
            if nowArmed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }

    /// Direction shown live while dragging (past the small hint threshold).
    private func liveDestination(_ t: CGSize) -> ScheduleDestination? {
        if abs(t.width) > abs(t.height) {
            if t.width > hintThreshold { return .tomorrow }
            if t.width < -hintThreshold { return .nextWeekend }
        } else {
            if t.height < -hintThreshold { return .today }
        }
        return nil
    }

    /// Final direction on release — distance OR velocity crosses the threshold.
    private func destination(_ t: CGSize, _ v: CGSize) -> ScheduleDestination? {
        if abs(t.width) > abs(t.height) {
            if t.width > distanceThreshold || v.width > velocityThreshold { return .tomorrow }
            if t.width < -distanceThreshold || v.width < -velocityThreshold { return .nextWeekend }
        } else {
            if t.height < -distanceThreshold || v.height < -velocityThreshold { return .today }
        }
        return nil
    }

    // MARK: Commit animations

    private func commit(_ dest: ScheduleDestination) {
        committing = true
        pending = dest
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        guard let date = resolveDateKeyword(dest.keyword) else { reset(); return }

        switch dest {
        case .today:
            if sendsAway {
                // Send the whole card up and off the top, fading as it goes.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    offset = CGSize(width: 0, height: -exitUpDistance)
                    opacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    onSchedule(date, dest)
                    reenter()
                }
            } else {
                // Pop upward, then settle back into place — the due-date change
                // re-sorts the row toward the top of Today's list.
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.7)) {
                    offset = CGSize(width: 0, height: -130)
                }
                onSchedule(date, dest)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                        offset = .zero
                    }
                    finishCommit()
                }
            }

        case .tomorrow:
            // Carry the drag's momentum straight off the right edge.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                offset = CGSize(width: exitDistance, height: offset.height * 0.15)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                onSchedule(date, dest)
                if sendsAway { reenter() } else { offset = .zero; finishCommit() }
            }

        case .nextWeekend:
            // Slingshot — phase 1: recoil further left (drawing the band back).
            withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) {
                offset = CGSize(width: -110, height: offset.height * 0.1)
            }
            // Phase 2: launch right, faster than a direct exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                    offset = CGSize(width: exitDistance, height: 0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    onSchedule(date, dest)
                    if sendsAway { reenter() } else { offset = .zero; finishCommit() }
                }
            }
        }
    }

    /// Drops a fresh, empty card in from below and springs it up — the "next
    /// sheet pops up" beat after the previous one is sent away.
    private func reenter() {
        offset = CGSize(width: 0, height: reentryDistance)
        opacity = 1
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            offset = .zero
        }
        finishCommit()
    }

    private func finishCommit() {
        committing = false
        pending = nil
        armed = false
    }

    private func reset() {
        withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.68)) {
            offset = .zero
        }
        pending = nil
        armed = false
    }

    // MARK: Hint badge

    private var hintAlignment: Alignment {
        switch pending {
        case .today:       .top
        case .tomorrow:    .trailing
        case .nextWeekend: .leading
        case .none:        .center
        }
    }

    @ViewBuilder private var hintBadge: some View {
        if let dest = pending {
            let progress = min(1, hintProgress)
            HStack(spacing: 5) {
                Image(systemName: dest.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(dest.label)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(dest.color(palette), in: Capsule())
            .scaleEffect(armed ? 1.0 : 0.9)
            .opacity(0.35 + progress * 0.65)
            .padding(8)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: armed)
            .allowsHitTesting(false)
        }
    }

    /// 0→1 as the drag approaches the commit threshold, for the hint's fade/scale.
    private var hintProgress: CGFloat {
        let magnitude = abs(offset.width) > abs(offset.height) ? abs(offset.width) : abs(offset.height)
        return max(0, min(1, magnitude / distanceThreshold))
    }
}
