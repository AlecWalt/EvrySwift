//
//  TaskRowView.swift
//  Evry
//
//  The task card — port of the webapp's TaskItem row: a flat Evry card (white,
//  navy hairline, no resting shadow), circle checkbox, strikethrough title,
//  notes preview, sky/navy meta chips, embedded subtasks, trailing trash button.
//  Priority and urgency are carried by glyphs and words, never by hue.
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
    /// Drag-to-select: while multi-selecting, pressing the select circle and
    /// sliding reports the finger location (in the "dragSelect" coordinate
    /// space) so the container can select rows the finger passes over.
    var onDragSelect: ((CGPoint) -> Void)? = nil
    var onDragSelectEnd: (() -> Void)? = nil
    var compact: Bool = false
    /// Hides the due-date chip (used on the Timeline, where every task shown is
    /// already due that day) while keeping the row's height unchanged.
    var hideDueDate: Bool = false
    /// Vertically centers the checkbox and content (like the trailing trash icon)
    /// instead of top-aligning — used on the Timeline.
    var centered: Bool = false
    /// Card corner radius. Defaults to radius-card, the design system's row/card
    /// radius (matches `SwipeActionRow`'s revealed actions).
    var cornerRadius: CGFloat = EvryRadius.card
    /// Forwarded to the checkbox — incrementing it (on swipe-to-complete) plays the
    /// same completion animation + delayed commit as tapping the circle.
    var completeToken: Int = 0

    // Collapsed by default so the subtask container doesn't spring back open when
    // the row is rebuilt (e.g. swiping to another day on the Timeline).
    @State private var subtasksExpanded = false
    @State private var showDirectionsChooser = false
    // Measured card width so the subtask container can sit at ~90% of it.
    @State private var cardW: CGFloat = 0
    /// The title shows one line; tapping a cut-off title opens it out in full.
    @State private var titleExpanded = false
    /// The title's natural one-line width, and the width it's given.
    @State private var titleFullWidth: CGFloat = 0
    @State private var titleShownWidth: CGFloat = 0
    private var titleTruncated: Bool { titleFullWidth > titleShownWidth + 1 }

    private enum MapsProvider { case apple, google }

    private var hasMeta: Bool {
        guard !task.isNote else { return false }
        let hasDate = task.dueDate != nil && !hideDueDate
        // Priority isn't a chip anymore (it's a mark beside the title).
        return hasDate || !task.tags.isEmpty || task.recurrence != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            taskCard
                .zIndex(1)
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { cardW = g.size.width }
                            .onChange(of: g.size.width) { _, w in cardW = w }
                    }
                )

            // A separate container that slides out from under the card, revealing
            // the subtasks. It sits behind the card (zIndex 0) with its top tucked
            // under, so the card hides its top edge and the two read as merged.
            if !task.subtasks.isEmpty && subtasksExpanded {
                subtaskContainer
                    .zIndex(0)
                    // Symmetric transition drives both the slide-out (open) and the
                    // retract-under-the-card (close).
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Report this row's vertical bounds (in the list's "dragSelect" space) so
        // a drag-select can map the finger position to a row.
        .background {
            if isSelecting && onDragSelect != nil {
                GeometryReader { g in
                    Color.clear.preference(
                        key: SelectRowFrameKey.self,
                        value: [task.uid: g.frame(in: .named("dragSelect"))]
                    )
                }
            }
        }
        // Bringing a task back from the completed section clears its subtasks too,
        // so they don't stay ticked (they were auto-completed with the task).
        .onChange(of: task.completed) { _, done in
            guard !done, !task.subtasks.isEmpty else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                for i in task.subtasks.indices where task.subtasks[i].completed {
                    task.subtasks[i].completed = false
                }
            }
        }
    }

    private var taskCard: some View {
        HStack(alignment: centered ? .center : .top, spacing: 12) {
            if isSelecting {
                Button(action: onSelect) {
                    ZStack {
                        Circle().fill(isSelected ? palette.primary : .clear)
                        Circle().strokeBorder(isSelected ? palette.primary : palette.border, lineWidth: 2)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.nunito(size: 10, weight: .bold))
                                .foregroundStyle(palette.onPrimary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
                    // Match the checkbox's enlarged footprint so the row keeps its
                    // height in multi-select instead of collapsing (esp. on the
                    // Timeline, where rows are otherwise anchored by the trash icon).
                    .frame(width: 38, height: 38, alignment: centered ? .leading : .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Selected" : "Not selected")
                // Press the circle and slide to select rows the finger passes
                // over. A plain tap (no movement) still falls through to the
                // Button's single-toggle.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("dragSelect"))
                        .onChanged { onDragSelect?($0.location) }
                        .onEnded { _ in onDragSelectEnd?() },
                    including: onDragSelect == nil ? .subviews : .all
                )
                .padding(.top, centered ? 0 : 2)
            } else {
                TaskCheckbox(checked: task.completed, palette: palette,
                             contentAlignment: centered ? .leading : .topLeading,
                             externalCompleteToken: completeToken,
                             // The instant the task starts completing, mark its
                             // subtasks done. Visible subtask checkboxes animate via
                             // their own onChange (same pop + ring, in sync); a
                             // collapsed container stays consistent too.
                             onBeginComplete: {
                                 guard !task.subtasks.isEmpty else { return }
                                 withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                                     for i in task.subtasks.indices where !task.subtasks[i].completed {
                                         task.subtasks[i].completed = true
                                     }
                                 }
                             },
                             action: onToggle)
                    .padding(.top, centered ? 0 : 2)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // Pinned: a small navy bookmark (the same pin glyph Notes use).
                    if task.pinned {
                        Image(systemName: "bookmark.fill")
                            .font(.nunito(size: 12, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .accessibilityLabel("Pinned")
                    }
                    // Priority: a glyph leading the title, in line with it (rather
                    // than a chip underneath) — "!" medium, "↓" low. High priority
                    // is the card's sky outline instead (see `taskCard`).
                    if task.priority != .high, let mark = task.priority.symbol, !task.completed {
                        Image(systemName: mark)
                            .font(.nunito(size: 14, weight: .heavy))
                            .foregroundStyle(task.priority == .low ? palette.textSec : palette.text)
                            .accessibilityLabel("\(task.priority.label) priority")
                    }
                    // Same type as the Schedule's cards: a bold 17pt title. One
                    // line only; a title that's cut off opens out when tapped.
                    Text(task.title)
                        .font(.nunito(size: 17, weight: .bold))
                        .foregroundStyle(task.completed ? palette.textSec : palette.text)
                        .strikethrough(task.completed, color: palette.textPh)
                        .multilineTextAlignment(.leading)
                        .lineLimit(titleExpanded ? nil : 1)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleShownWidth = $0 }
                        .background(alignment: .leading) {
                            // Measures the whole title on one line, to tell
                            // whether the shown line is cut off.
                            Text(task.title)
                                .font(.nunito(size: 17, weight: .bold))
                                .fixedSize()
                                .hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleFullWidth = $0 }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                onSelect()
                            } else if titleTruncated {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { titleExpanded.toggle() }
                            } else {
                                onEdit()
                            }
                        }
                        .accessibilityAction(named: "Edit") { onEdit() }
                    // Assigned-time bubble ("at 3:00 PM") — a quiet sky-soft chip so
                    // the time reads as metadata, not an accent.
                    if let time = dueTimeLabel {
                        metaChip(time, foreground: palette.textSec, background: palette.hover)
                            .fixedSize()
                    }
                    // Subtask disclosure sits to the right of the title.
                    if !task.subtasks.isEmpty {
                        Spacer(minLength: 8)
                        subtaskToggle
                    }
                }

                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 4)
                }

                if !task.location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.nunito(size: 12))
                            .foregroundStyle(palette.textSec)
                        Text(task.location)
                            .font(.nunito(size: 13))
                            .foregroundStyle(palette.textSec)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                }

                if hasMeta {
                    metaChips
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // In multi-select the trailing buttons step aside but keep their
            // space (the reorder handle sits where the trash was), so the text
            // never shifts or rewraps.
            if !task.location.isEmpty {
                Button {
                    showDirectionsChooser = true
                } label: {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.nunito(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .evryButtonFace(palette, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Directions")
                .opacity(isSelecting ? 0 : 1)
                .allowsHitTesting(!isSelecting)
                .accessibilityHidden(isSelecting)
            }

            TrashBurstButton(palette: palette, action: onDelete)
                .opacity(isSelecting ? 0 : 1)
                .allowsHitTesting(!isSelecting)
                .accessibilityHidden(isSelecting)
        }
        .padding(.vertical, compact ? 8 : 12)
        .padding(.horizontal, EvrySpace.gutter)
        // Flat at rest: white fill + the card hairline, no shadow. (The Inbox
        // adds a light lift only while a row is being dragged.)
        .evryField(palette, cornerRadius: cornerRadius)
        // High priority: a sky outline around the whole card.
        .overlay {
            if task.priority == .high && !task.completed {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.evrySky, lineWidth: 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint(task.priority == .high && !task.completed ? "High priority" : "")
        .opacity(task.completed ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if isSelecting { onSelect() } else { onEdit() } }
        .confirmationDialog("Directions to \(task.location)", isPresented: $showDirectionsChooser, titleVisibility: .visible) {
            Button("Apple Maps") { openDirections(.apple) }
            Button("Google Maps") { openDirections(.google) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func openDirections(_ provider: MapsProvider) {
        let query = task.location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch provider {
        case .apple:
            if let url = URL(string: "https://maps.apple.com/?daddr=\(query)&dirflg=d") {
                UIApplication.shared.open(url)
            }
        case .google:
            // Try the Google Maps app; if it isn't installed the open fails and
            // the web version opens instead. (canOpenURL would need the scheme
            // listed in LSApplicationQueriesSchemes, so it always said no.)
            let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(query)")
            guard let app = URL(string: "comgooglemaps://?daddr=\(query)&directionsmode=driving") else {
                if let web { UIApplication.shared.open(web) }
                return
            }
            UIApplication.shared.open(app) { opened in
                if !opened, let web { UIApplication.shared.open(web) }
            }
        }
    }

    /// "at 3:00 PM" when the task's due date carries an explicit (non-midnight)
    /// time; nil for date-only or undated tasks. Midnight is treated as "no time"
    /// to match the app's date/time convention.
    private var dueTimeLabel: String? {
        guard let due = task.dueDate else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: due)
        guard (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0 else { return nil }
        return "at \(due.formatted(date: .omitted, time: .shortened))"
    }

    private var metaChips: some View {
        HStack(spacing: 4) {
            if let due = task.dueDate, !hideDueDate {
                DateChip(date: due, palette: palette)
            }
            if let recurrence = task.recurrence {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.nunito(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                    Text(recurrence.label)
                        .font(.nunito(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(palette.skySoft, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Repeats \(recurrence.label.lowercased())")
            }
            ForEach(task.tags, id: \.self) { tag in
                metaChip("#\(tag)", foreground: palette.textSec, background: palette.hover)
            }
        }
    }

    /// A metadata pill sized for the row's 17pt title (13pt medium, 2×8 padding)
    /// — the shared `ChipView` pill, one step up.
    private func metaChip(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            // Bold 13pt, like the Schedule cards' time line.
            .font(.nunito(size: 13, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var subtaskToggle: some View {
        // Explicit animation so both the slide-out (open) and retract (close) play,
        // along with the chevron rotation.
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                subtasksExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.nunito(size: 13, weight: .semibold))
                .foregroundStyle(palette.textSec)
                .rotationEffect(.degrees(subtasksExpanded ? 0 : -90))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtasksExpanded ? "Hide subtasks" : "Show subtasks")
    }

    /// The slide-out subtask container: ~90% of the card width, tucked under the
    /// card (top edge hidden so they merge), adapting to the subtasks' height.
    private var subtaskContainer: some View {
        subtaskList
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            // Top inset clears the slice tucked behind the card.
            .padding(.top, cornerRadius + 16)
            .padding(.bottom, 13)
            .evryField(palette, cornerRadius: cornerRadius)
            .frame(width: cardW > 0 ? cardW * 0.9 : nil)
            // Pull the top up under the card so its top edge/border is hidden.
            .padding(.top, -(cornerRadius + 10))
            .opacity(task.completed ? 0.62 : 1)
    }

    private var subtaskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(task.subtasks) { subtask in
                HStack(spacing: 8) {
                    if !task.isNote {
                        // Same checkbox as the main task — pop + radiating ring on
                        // complete. `subtaskCompleteToken` fires them all together
                        // when the parent task is completed.
                        TaskCheckbox(
                            checked: subtask.completed,
                            palette: palette,
                            size: 16,
                            contentAlignment: .center,
                            action: { onToggleSubtask(subtask) }
                        )
                    }
                    Text(subtask.title)
                        .font(.nunito(size: 14))
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
        case .nextWeekend: "Next weekend"
        }
    }

    var icon: String {
        switch self {
        case .today:       "arrow.up"
        case .tomorrow:    "arrow.right"
        case .nextWeekend: "arrow.left"
        }
    }

    /// Hint-badge fill. The three directions differ by strength of the brand
    /// tones (navy → sky → sky-soft) plus their arrow and label, never by hue.
    func color(_ palette: Palette) -> Color {
        switch self {
        case .today:       palette.primary
        case .tomorrow:    Palette.doneFill
        case .nextWeekend: palette.skySoft
        }
    }

    /// Label/icon ink on `color(_:)`.
    func ink(_ palette: Palette) -> Color {
        switch self {
        case .today:       palette.onPrimary
        case .tomorrow:    palette.onSky
        case .nextWeekend: palette.text
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
    /// When set, a downward drag flings the card off the bottom and calls this —
    /// used by the quick-add overlay so a swipe down closes it.
    var onDismiss: (() -> Void)? = nil
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
                guard !committing else { return }
                let t = value.translation
                // Downward drag dismisses (works even when scheduling is locked,
                // e.g. an empty quick-add field).
                if onDismiss != nil, t.height > 0, abs(t.height) > abs(t.width) {
                    offset = CGSize(width: 0, height: t.height)
                    return
                }
                guard !isLocked else { return }
                offset = visualOffset(for: t)
                updateHint(for: t)
            }
            .onEnded { value in
                guard !committing else { return }
                let t = value.translation
                if onDismiss != nil, t.height > 0, abs(t.height) > abs(t.width),
                   t.height > 110 || value.velocity.height > 700 {
                    // Close the keyboard right away so it animates down with the card.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                    committing = true
                    withAnimation(.easeIn(duration: 0.22)) {
                        offset = CGSize(width: 0, height: cardHeight + 500)
                        opacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onDismiss?() }
                    return
                }
                guard !isLocked else { reset(); return }
                if let dest = destination(t, value.velocity) {
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
        // Jump below the screen with animations explicitly off, then rise on
        // the next frame. In one update, the jump could be swept into other
        // in-flight animations and UIKit-backed content (the text field) would
        // glide over from the card's old spot off the top of the screen.
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            offset = CGSize(width: 0, height: reentryDistance)
            opacity = 1
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                offset = .zero
            }
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
                    .font(.nunito(size: 11, weight: .bold))
                Text(dest.label)
                    .font(.nunito(size: 12, weight: .bold))
            }
            .foregroundStyle(dest.ink(palette))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(dest.color(palette), in: Capsule())
            .overlay(Capsule().strokeBorder(dest == .nextWeekend ? Color.evrySky : .clear, lineWidth: 1))
            .evryShadowLift(palette)
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

// MARK: - Drag-to-select support

/// Collects each visible row's frame (keyed by task id) in the list's
/// "dragSelect" coordinate space, so a drag can map the finger's Y to a row.
struct SelectRowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Range-selection state for tap-and-drag multi-select. Holds the anchor row
/// (where the drag began) and the selection that existed before the drag, then
/// on each move selects everything between the anchor and the finger's row.
struct DragSelector {
    var anchor: UUID?
    private var baseline: Set<UUID> = []
    var frames: [UUID: CGRect] = [:]

    var isActive: Bool { anchor != nil }

    /// Returns the selection for the finger at `location`, given the ordered rows
    /// and the current selection (captured as the baseline on the first call).
    mutating func selection(anchor a: TaskItem, location: CGPoint,
                            ordered: [TaskItem], current: Set<UUID>) -> Set<UUID> {
        if anchor == nil {
            anchor = a.uid
            baseline = current
        }
        guard let ai = ordered.firstIndex(where: { $0.uid == a.uid }) else { return current }
        let ci = closestIndex(to: location.y, ordered: ordered) ?? ai
        let lo = min(ai, ci), hi = max(ai, ci)
        var result = baseline
        for i in lo...hi { result.insert(ordered[i].uid) }
        return result
    }

    mutating func end() {
        anchor = nil
        baseline = []
    }

    /// The row whose center is nearest the given Y (handles gaps and past-the-ends).
    private func closestIndex(to y: CGFloat, ordered: [TaskItem]) -> Int? {
        var best: Int?
        var bestDist = CGFloat.infinity
        for (i, task) in ordered.enumerated() {
            guard let f = frames[task.uid] else { continue }
            let d = abs(f.midY - y)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}
