//
//  HabitsView.swift
//  Evry
//
//  Habits tab — laid out like the Inbox: the shared page header, then a
//  horizontally-paging carousel with one card per habit (a large circular
//  progress ring, the title, and a checkmark button that logs one check-in).
//  Below the carousel, the focused habit's week and streak stats. New habits
//  come from the shared swipe-up handle (`AddHabitSheet`), like tasks do.
//

import SwiftUI
import SwiftData
import UIKit

struct HabitsView: View {
    let palette: Palette

    @Environment(\.modelContext) private var context
    @Environment(Appearance.self) private var appearance
    // Animated so neighbouring cards slide into a deleted card's place.
    @Query(sort: \Habit.sortOrder, animation: .spring(response: 0.45, dampingFraction: 0.85))
    private var habits: [Habit]

    /// The carousel page currently in view.
    @State private var focusedID: UUID?
    /// Each habit's stats, reused until its history or schedule changes.
    @State private var statsCache = HabitStatsCache()
    /// Cards playing their delete animation (shrink + fade) before removal.
    @State private var removingIDs: Set<UUID> = []
    @State private var detailHabit: Habit?
    @State private var editingHabit: Habit?
    /// The habit the delete prompt is asking about. Deliberately separate from
    /// `confirmingDelete`: the prompt clears its `isPresented` binding *before*
    /// running `onConfirm`, so the target must outlive the presentation flag.
    @State private var deletingHabit: Habit?
    @State private var deletingName = ""
    @State private var confirmingDelete = false
    /// Delete requested from the detail sheet — run once that sheet has fully
    /// dismissed, so it never renders a deleted model.
    @State private var deleteAfterDetail: Habit?
    @State private var headerPop: CGFloat = 1
    /// Habit whose goal was just reached — drives the full-screen celebration.
    @State private var celebrating: Habit?

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let stats = Dictionary(habits.map { ($0.uid, statsCache.stats(for: $0, today: today)) },
                               uniquingKeysWith: { a, _ in a })
        // Built habits are records now, so they no longer count toward today.
        let due = habits.filter { $0.isDue(on: today) }
        let doneToday = due.filter { stats[$0.uid]?.todayDone == true }.count
        let allDone = !due.isEmpty && doneToday == due.count
        let focused = habits.first { $0.uid == focusedID } ?? habits.first

        return VStack(spacing: 0) {
            header(done: doneToday, total: due.count, allDone: allDone)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 8)

            if habits.isEmpty {
                // Evry (the mascot) welcomes an empty page.
                EmptyStateView(
                    icon: "arrow.triangle.2.circlepath",
                    title: "No habits yet",
                    text: "Swipe up on the handle below to add your first one.",
                    palette: palette
                )
                .padding(.top, 28)
                Spacer()
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 14) {
                        carousel(stats: stats, today: today)
                        pageDots(focused: focused)
                        if let focused, let s = stats[focused.uid] {
                            focusedDetails(focused, stats: s)
                                .padding(.horizontal, 20)
                                .id(focused.uid)
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, 4)
                    // Just enough to clear the swipe-up handle; the page fits
                    // without scrolling on standard phones, and only scrolls
                    // (bounce-free otherwise) on smaller screens.
                    .padding(.bottom, 44)
                    .animation(EvryMotion.settle, value: focused?.uid)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
        .onChange(of: habits.count) { old, new in
            // A newly created habit is appended last — page to it so it's visible.
            // Deferred a beat so the new card is laid out in the lazy stack first —
            // setting the position in the same update moves the dots but not the scroll.
            if new > old, let newest = habits.last?.uid {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { focusedID = newest }
                }
            }
        }
        .onChange(of: allDone) { old, new in
            if new && !old { celebrate() }
        }
        // Full-screen (over the tab bar and swipe handle) with a clear
        // background; the view runs its own entrance, so the slide is suppressed.
        .fullScreenCover(item: $celebrating) { habit in
            HabitFormedCelebration(
                habitName: habit.name, icon: habit.icon, color: habit.color,
                days: habit.goalDays
            ) {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { celebrating = nil }
            }
            .environment(appearance)
            .presentationBackground(.clear)
        }
        .sheet(item: $editingHabit) { habit in
            HabitEditorSheet(habit: habit).environment(appearance)
        }
        .sheet(item: $detailHabit, onDismiss: {
            // The detail sheet confirmed a delete — run it now that the sheet is gone.
            if let habit = deleteAfterDetail {
                deleteAfterDetail = nil
                delete(habit)
            }
        }) { habit in
            HabitDetailSheet(habit: habit) { target in
                deleteAfterDetail = target
                detailHabit = nil
            }
            .environment(appearance)
        }
        .evryConfirm(
            isPresented: $confirmingDelete,
            title: "Delete “\(deletingName)”?",
            message: "Its streak and check-in history will be removed.",
            confirmTitle: "Delete habit"
        ) {
            if let habit = deletingHabit { delete(habit) }
        }
    }

    /// Opens the delete prompt for `habit`. The name is copied so the title
    /// doesn't blank out while the prompt animates away.
    private func requestDelete(_ habit: Habit) {
        deletingHabit = habit
        deletingName = habit.name
        confirmingDelete = true
    }

    // MARK: Header

    private func header(done: Int, total: Int, allDone: Bool) -> some View {
        // Top-aligned like the Inbox and Notes headers so the title sits at
        // the same height on every tab.
        HStack(alignment: .top, spacing: 12) {
            PageTitle(title: "Habits", subtitle: "Small routines, steady streaks", palette: palette)

            Spacer()

            if total > 0 {
                // The day's overall progress: completed / due today.
                ZStack {
                    HabitRing(fraction: Double(done) / Double(total),
                              color: allDone ? Palette.success : palette.primary,
                              track: palette.primaryLight, lineWidth: 5)
                    Text("\(done)/\(total)")
                        .font(.nunito(size: 14, weight: .heavy))
                        .foregroundStyle(allDone ? Palette.success : palette.text)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(done)))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
                .frame(width: 52, height: 52)
                .scaleEffect(headerPop)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: done)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(done) of \(total) habits done today")
            }
        }
        // Holds its height when the ring hides (nothing due) so content doesn't jump.
        .frame(minHeight: 52, alignment: .top)
    }

    // MARK: Carousel

    private func carousel(stats: [UUID: HabitStats], today: Date) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(habits) { habit in
                    if let s = stats[habit.uid] {
                        HabitPage(
                            habit: habit,
                            stats: s,
                            restDay: !habit.isScheduled(on: today),
                            isFocused: habit.uid == (focusedID ?? habits.first?.uid),
                            palette: palette,
                            onCheckIn: { HabitActions.checkIn(habit, context: context) },
                            onUndo: { HabitActions.undoCheckIn(habit, context: context) },
                            onOpen: { detailHabit = habit },
                            onFormed: { presentCelebration(for: habit) }
                        )
                        .containerRelativeFrame(.horizontal)
                        .scaleEffect(removingIDs.contains(habit.uid) ? 0.75 : 1)
                        .opacity(removingIDs.contains(habit.uid) ? 0 : 1)
                        .blur(radius: removingIDs.contains(habit.uid) ? 8 : 0)
                        .contextMenu {
                            if s.today > 0 {
                                Button {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    HabitActions.undoCheckIn(habit, context: context)
                                } label: {
                                    Label("Undo check-in", systemImage: "arrow.uturn.backward")
                                }
                            }
                            Button { editingHabit = habit } label: {
                                Label("Edit habit", systemImage: "pencil")
                            }
                            Button(role: .destructive) { requestDelete(habit) } label: {
                                Label("Delete habit", systemImage: "trash")
                            }
                        }
                        .id(habit.uid)
                    }
                }
            }
            .scrollTargetLayout()
        }
        // Neighbouring cards peek in from the edges, hinting there's more to swipe.
        // Same 20pt page margin as the title and the tiles below.
        .contentMargins(.horizontal, 20, for: .scrollContent)
        // Room for the cards' soft shadow inside the clipped scroll view.
        .contentMargins(.vertical, 8, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $focusedID)
        .scrollIndicators(.hidden)
        .onChange(of: focusedID) { old, new in
            if old != nil, new != nil, old != new { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    @ViewBuilder
    private func pageDots(focused: Habit?) -> some View {
        if habits.count > 1 {
            HStack(spacing: 5) {
                ForEach(habits) { habit in
                    let on = habit.uid == focused?.uid
                    Capsule()
                        .fill(on ? palette.primary : palette.border)
                        .frame(width: on ? 18 : 6, height: 6)
                }
            }
            .animation(EvryMotion.settle, value: focused?.uid)
            .accessibilityHidden(true)
        }
    }

    // MARK: Focused habit details

    private func focusedDetails(_ habit: Habit, stats: HabitStats) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                statTile("Streak", value: stats.currentStreak, icon: "flame.fill")
                statTile("Best", value: stats.bestStreak, icon: "trophy.fill")
                statTile("30 days", value: Int((stats.rate30 * 100).rounded()), suffix: "%",
                         icon: "chart.bar.fill")
            }
            weekStrip(habit, stats: stats)
        }
    }

    private func statTile(_ title: String, value: Int, suffix: String = "", icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.nunito(size: 14, weight: .semibold))
                .foregroundStyle(palette.primary)
                .accessibilityHidden(true)
            Text("\(value)\(suffix)")
                .font(.nunito(size: 20, weight: .heavy))
                .foregroundStyle(palette.text)
                .contentTransition(.numericText())
            Text(title)
                .font(.evryCaption)
                .foregroundStyle(palette.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .evryField(palette, cornerRadius: EvryRadius.field)
    }

    /// The focused habit's current week, Sunday → Saturday — each a small ring
    /// of that day's progress. Days still ahead are dimmed.
    private func weekStrip(_ habit: Habit, stats: HabitStats) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Always Sunday-first (weekday 1), regardless of the locale's first day.
        let sunday = cal.date(byAdding: .day, value: 1 - cal.component(.weekday, from: today), to: today) ?? today
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: sunday) }

        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let fraction = min(1, Double(stats.count(on: day)) / Double(stats.target))
                let scheduled = habit.isScheduled(on: day)
                let isToday = day == today
                VStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.evryCaption)
                        .foregroundStyle(isToday ? palette.text : palette.textMuted)
                    ZStack {
                        HabitRing(fraction: fraction, color: habit.color, track: palette.hover, lineWidth: 4)
                        if fraction >= 1 {
                            Image(systemName: "checkmark")
                                .font(.nunito(size: 12, weight: .heavy))
                                .foregroundStyle(palette.text)
                        } else {
                            Text("\(cal.component(.day, from: day))")
                                .font(.nunito(size: 12, weight: isToday ? .heavy : .semibold))
                                .foregroundStyle(isToday ? palette.text : palette.textSec)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .opacity(day > today ? 0.35 : (scheduled || fraction > 0 ? 1 : 0.4))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .evryField(palette, cornerRadius: EvryRadius.field)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: completed \(days.filter { stats.count(on: $0) >= stats.target }.count) of 7 days")
    }

    // MARK: Actions

    /// Shrinks + fades the card away, then deletes it and pages to a neighbour
    /// (the @Query animation slides the remaining cards into place).
    private func delete(_ habit: Habit) {
        deletingHabit = nil
        // Already removed (e.g. a double confirm) — nothing to do.
        guard !habit.isDeleted, habit.modelContext != nil else { return }
        let id = habit.uid
        let neighbour: UUID? = habits.firstIndex { $0.uid == id }.flatMap { i in
            i + 1 < habits.count ? habits[i + 1].uid : (i > 0 ? habits[i - 1].uid : nil)
        }
        withAnimation(.easeIn(duration: 0.3)) { _ = removingIDs.insert(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            if !habit.isDeleted { HabitActions.delete(habit, context: context) }
            removingIDs.remove(id)
            if focusedID == id || focusedID == nil { focusedID = neighbour }
        }
    }

    private func presentCelebration(for habit: Habit) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { celebrating = habit }
    }

    /// Every habit due today is done — a double haptic tap and a header-ring pop,
    /// timed to land just after the card's own completion burst.
    private func celebrate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let heavy = UIImpactFeedbackGenerator(style: .heavy)
            heavy.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { heavy.impactOccurred(intensity: 0.7) }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.45)) { headerPop = 1.25 }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.15)) { headerPop = 1 }
        }
    }
}

// MARK: - Habit page (carousel card)

private struct HabitPage: View {
    let habit: Habit
    let stats: HabitStats
    let restDay: Bool
    /// The card in the middle of the carousel — only it runs the liquid drift.
    let isFocused: Bool
    let palette: Palette
    let onCheckIn: () -> Void
    let onUndo: () -> Void
    let onOpen: () -> Void
    /// Fired once the goal fill finishes on the day the habit is built — the
    /// page runs the full-screen celebration.
    let onFormed: () -> Void

    #if DEBUG
    @Environment(\.modelContext) private var context
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var ringPop: CGFloat = 1
    // Once the day's target is met the card turns into its goal view — a
    // vertical bar filling the card toward the long-term goal — and stays that
    // way until the check-in is undone from the corner arrow.
    @State private var showingGoal = false
    @State private var goalFill: Double = 0
    @State private var goalDaysShown = 0
    @State private var goalTask: Task<Void, Never>?
    /// Extra wave height, spiked whenever the level rises so the surface sloshes.
    @State private var slosh: CGFloat = 0
    /// The habit has been built — the card is its permanent trophy record.
    @State private var showFormed = false
    @State private var formedTask: Task<Void, Never>?

    private var subtitle: String {
        restDay ? "Rest day" : habit.scheduleLabel
    }

    private var coveringMain: Bool { showingGoal || showFormed }

    var body: some View {
        mainContent
            .opacity(coveringMain ? 0 : 1)
            .scaleEffect(coveringMain ? 0.94 : 1)
            .allowsHitTesting(!coveringMain)
            .accessibilityHidden(coveringMain)
            .overlay {
                if showFormed {
                    formedView.transition(.scale(scale: 0.92).combined(with: .opacity))
                } else if showingGoal {
                    goalView.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .evryCard(palette)
            .onAppear(perform: syncGoal)
            .onDisappear {
                goalTask?.cancel(); goalTask = nil
                formedTask?.cancel(); formedTask = nil
            }
            // History changed while the goal view is up (another completed day,
            // e.g. the dev button) — pour the liquid up to the new level.
            .onChange(of: stats.completedDays) { old, new in
                guard stats.todayDone, new != old else { return }
                // A reveal still in flight would land on a stale count — cut it
                // short and go straight to the latest level.
                if goalTask != nil {
                    goalTask?.cancel(); goalTask = nil
                    showingGoal = true
                }
                guard showingGoal else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                    goalFill = stats.goalFraction
                    goalDaysShown = new
                }
                if new > old { splash() }
            }
            .onChange(of: habit.formedAt) { old, new in
                if old == nil, new != nil {
                    // Let the fill finish rising before the big moment.
                    formedTask?.cancel()
                    formedTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(goalTask == nil ? 1.0 : 2.1))
                        guard !Task.isCancelled else { return }
                        onFormed()
                        try? await Task.sleep(for: .seconds(0.4))
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { showFormed = true }
                        formedTask = nil
                    }
                } else if new == nil {
                    formedTask?.cancel(); formedTask = nil
                    withAnimation(.easeInOut(duration: 0.35)) { showFormed = false }
                }
            }
            .onChange(of: stats.today) { old, new in
                guard new > old else { return }
                withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { ringPop = 1.05 }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6).delay(0.1)) { ringPop = 1 }
            }
            .onChange(of: stats.todayDone) { old, new in
                if new && !old {
                    playGoalReveal()
                } else if !new {
                    goalTask?.cancel()
                    goalTask = nil
                    withAnimation(.easeInOut(duration: 0.35)) { showingGoal = false }
                }
            }
            // Goal length edited while showing — glide the bar to the new level.
            .onChange(of: stats.goal) { _, _ in
                guard showingGoal else { return }
                withAnimation(.spring(response: 0.8, dampingFraction: 0.9)) { goalFill = stats.goalFraction }
            }
    }

    // MARK: Goal view

    /// The card filled from the bottom up to the long-term goal progress, with
    /// the day count on top and an undo arrow in the corner.
    private var goalView: some View {
        ZStack {
            // During the reveal, the staged values animate from yesterday to
            // today; otherwise always read the live stats so the level and
            // count can never drift from the real history.
            liquid(level: goalTask != nil ? goalFill : stats.goalFraction)
                .animation(.spring(response: 0.7, dampingFraction: 0.85), value: stats.completedDays)

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: habit.icon)
                            .foregroundStyle(palette.primary)
                        Text(habit.name)
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                    }
                    .font(.evryLabel)
                    .padding(.horizontal, 56)
                    .padding(.bottom, 14)

                    Text("Goal")
                        .font(.evrySmall)
                        .foregroundStyle(palette.textSec)
                    let shownDays = goalTask != nil ? goalDaysShown : stats.completedDays
                    Text("\(shownDays)")
                        .font(.nunito(size: 72, weight: .heavy))
                        .foregroundStyle(palette.text)
                        .contentTransition(.numericText(value: Double(shownDays)))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: shownDays)
                    Text("of \(stats.goal) days")
                        .font(.nunito(size: 17, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text(stats.goalReached
                         ? "Habit formed. Nicely done."
                         : "\(Int((stats.goalFraction * 100).rounded()))% of the way to making it stick")
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .padding(.horizontal, 20)
                    Label("Done today", systemImage: "checkmark.circle.fill")
                        .font(.evrySmall)
                        .foregroundStyle(palette.text)
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens habit details")
        .overlay(alignment: .topTrailing) { undoButton }
        #if DEBUG
        .overlay(alignment: .topLeading) { devCompleteButton }
        #endif
    }

    #if DEBUG
    // MARK: Developer tools (temporary — DEBUG builds only)

    /// TEMP dev buttons: backfill completed days (the most recent incomplete
    /// scheduled days before today) and the liquid rises in place. "+1" for a
    /// single day, "+10" to jump ahead quickly (stops at the goal).
    private var devCompleteButton: some View {
        HStack(spacing: 6) {
            devButton("+1", days: 1)
            devButton("+10", days: 10)
        }
        .padding(.leading, 12)
        .padding(.top, 10)
    }

    private func devButton(_ title: String, days: Int) -> some View {
        Button {
            devAddDays(days)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "hammer.fill")
                Text(title)
            }
            .font(.evryCaption)
            .foregroundStyle(Palette.onSignal)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Palette.warning, in: Capsule())
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Developer: complete \(days) more day\(days == 1 ? "" : "s")")
    }

    private func devAddDays(_ count: Int) {
        var added = 0
        while added < count, !habit.isFormed,
              HabitActions.devBackfillCompletedDay(habit, context: context) {
            added += 1
        }
        if added > 0 { UIImpactFeedbackGenerator(style: count > 1 ? .medium : .light).impactOccurred() }
    }
    #endif

    // MARK: Liquid

    /// Two offset wave layers rising from the bottom of the card to `level`,
    /// drifting continuously like liquid.
    private func liquid(level: Double) -> some View {
        // The drift is decorative: 30fps is plenty, and it holds still under
        // Reduce Motion and on the neighbouring (off-centre) cards.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isFocused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                LiquidFill(level: level, amplitude: 6 + slosh, phase: t * 1.7 + 1.2, cycles: 1.3)
                    .fill(habit.color.opacity(0.2))
                // Two strength steps of the habit's shade (opacity, not a new hue).
                LiquidFill(level: level, amplitude: 4.5 + slosh * 0.7, phase: -t * 2.2, cycles: 0.9)
                    .fill(habit.color.opacity(0.4))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Sloshes the surface — a quick swell that settles back down.
    private func splash() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.15, dampingFraction: 0.7)) { slosh = 7 }
        withAnimation(.easeOut(duration: 1.4).delay(0.15)) { slosh = 0 }
    }

    // MARK: Formed (habit built) record

    /// The permanent record once a habit is built: the plain card with the
    /// medal and when it was formed (no progress fill — it's complete).
    private var formedView: some View {
        ZStack {
            VStack(spacing: 8) {
                HabitMedal(icon: habit.icon, size: 92)
                    .padding(.bottom, 6)
                EyebrowPill(text: "Habit built", palette: palette, size: 12)
                Text(habit.name)
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                if let formed = habit.formedAt {
                    Text("\(stats.goal) days · built \(formed.formatted(.dateTime.month(.abbreviated).day().year()))")
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textSec)
                }
                HStack(spacing: 18) {
                    Label("\(stats.bestStreak) best streak", systemImage: "flame.fill")
                    Label("\(stats.completedDays) days", systemImage: "checkmark.seal.fill")
                }
                .font(.evryCaption)
                .foregroundStyle(palette.textSec)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens habit details")
        .overlay(alignment: .topTrailing) {
            // Undo only for the check-in that built it (i.e. formed today).
            if let formed = habit.formedAt, Calendar.current.isDateInToday(formed), stats.todayDone {
                undoButton
            }
        }
    }

    /// Looped arrow that undoes today's completing check-in, returning the card
    /// to its normal ring view.
    private var undoButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onUndo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.nunito(size: 14, weight: .bold))
                .foregroundStyle(palette.textSec)
                .frame(width: 34, height: 34)
                .background(palette.card.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .padding(10)
        .accessibilityLabel("Undo completion")
    }

    /// Matches the card to the current state without animating (first appear,
    /// or scrolling back to a card that's already done).
    private func syncGoal() {
        guard goalTask == nil else { return }
        showingGoal = stats.todayDone
        goalFill = stats.goalFraction
        goalDaysShown = stats.completedDays
        if formedTask == nil { showFormed = habit.isFormed }
    }

    /// Waits for the ring to finish filling, crossfades to the goal view, then
    /// fills the card from yesterday's progress to today's.
    private func playGoalReveal(to completedDays: Int? = nil) {
        goalTask?.cancel()
        let days = completedDays ?? stats.completedDays
        let goal = stats.goal
        let previous = max(0, days - 1)
        goalFill = min(1, Double(previous) / Double(goal))
        goalDaysShown = previous

        goalTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showingGoal = true }

            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 1.1, dampingFraction: 0.9)) {
                goalFill = min(1, Double(days) / Double(goal))
                goalDaysShown = days
            }
            splash()
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            goalTask = nil
        }
    }

    // MARK: Habit content

    private var mainContent: some View {
        VStack(spacing: 14) {
            // Tap the ring for the full history.
            Button(action: onOpen) {
                ZStack {
                    HabitRing(fraction: stats.todayFraction, color: habit.color,
                              track: palette.hover, lineWidth: 15)
                    VStack(spacing: 2) {
                        Image(systemName: habit.icon)
                            .font(.nunito(size: 24, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .padding(.bottom, 2)
                        Text("\(stats.today)/\(stats.target)")
                            .font(.evryH2)
                            .tracking(EvryTracking.h2)
                            .foregroundStyle(palette.text)
                            .contentTransition(.numericText())
                        Text(stats.todayDone ? "Done today" : "today")
                            .font(.nunito(size: 14, weight: stats.todayDone ? .bold : .regular))
                            .foregroundStyle(stats.todayDone ? palette.text : palette.textSec)
                    }
                }
                .frame(width: 172, height: 172)
                .scaleEffect(ringPop)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.97))
            .accessibilityLabel("\(habit.name), \(stats.today) of \(stats.target) today")
            .accessibilityHint("Opens habit details")

            VStack(spacing: 4) {
                Text(habit.name)
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if stats.currentStreak > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "flame.fill")
                            Text("\(stats.currentStreak)")
                        }
                        .font(.evrySmall)
                        .foregroundStyle(palette.text)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(stats.currentStreak) day streak")
                        Text("·").foregroundStyle(palette.textMuted)
                    }
                    Text(subtitle)
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textSec)
                    Text("·").foregroundStyle(palette.textMuted)
                    // Long-term goal progress.
                    HStack(spacing: 3) {
                        Image(systemName: stats.goalReached ? "checkmark.seal.fill" : "flag.checkered")
                        Text("\(min(stats.completedDays, stats.goal))/\(stats.goal)")
                            .contentTransition(.numericText())
                    }
                    .font(.evrySmall)
                    .foregroundStyle(palette.text)
                }
                .font(.nunito(size: 14))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }

            HabitCheckButton(done: stats.todayDone, color: habit.color, palette: palette,
                             willComplete: stats.today + 1 >= stats.target, action: onCheckIn)
        }
        .padding(.top, EvrySpace.grid)
        .padding(.bottom, 20)
        .padding(.horizontal, EvrySpace.gutter)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Liquid fill shape

/// A body of liquid filling its rect from the bottom up to `level` (0…1), with
/// a sine-wave surface. `phase` is advanced by a TimelineView to make the
/// surface drift; `level` and `amplitude` animate smoothly.
struct LiquidFill: Shape {
    var level: Double
    var amplitude: CGFloat
    var phase: Double
    /// Wave crests across the width.
    var cycles: Double = 1

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(level, amplitude) }
        set { level = newValue.first; amplitude = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(level, 0), 1)
        guard clamped > 0 else { return Path() }
        let surface = rect.maxY - rect.height * clamped
        // Calm the surface as the card brims so it meets the top edge cleanly.
        let amp = amplitude * CGFloat(min(1, (1 - clamped) * 12))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for x in stride(from: rect.minX, through: rect.maxX, by: 3) {
            let angle = phase + Double((x - rect.minX) / rect.width) * cycles * 2 * .pi
            path.addLine(to: CGPoint(x: x, y: surface + CGFloat(sin(angle)) * amp))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: surface + CGFloat(sin(phase + cycles * 2 * .pi)) * amp))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Medal

/// The medallion for built habits — the habit's icon on a sky check disc with a
/// white inner ring (the brand's "done" treatment, scaled up). No gold: the
/// Evry palette is white, sky and navy only.
struct HabitMedal: View {
    let icon: String
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.doneFill)
                .shadow(color: Color.evryNavy.opacity(0.18), radius: size * 0.14, y: size * 0.08)
            Circle()
                .strokeBorder(Color.evryWhite.opacity(0.8), lineWidth: size * 0.035)
                .padding(size * 0.08)
            Image(systemName: icon)
                .font(.nunito(size: size * 0.4, weight: .bold))
                .foregroundStyle(Color.evryNavy)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "checkmark.seal.fill")
                .font(.nunito(size: size * 0.26, weight: .bold))
                .foregroundStyle(Color.evryWhite, Color.evryNavy)
                .offset(x: size * 0.04, y: size * 0.04)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Habit built celebration

/// Full-screen moment for reaching a habit's long-term goal: a haptic drumroll,
/// the medal slamming in over spinning rays, confetti raining down, and a note
/// that the habit has become part of who they are.
struct HabitFormedCelebration: View {
    let habitName: String
    let icon: String
    let color: Color
    let days: Int
    let onDone: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var backdrop = false
    @State private var medalIn = false
    @State private var raysSpin = false
    @State private var textIn = false
    @State private var buttonIn = false
    @State private var confettiStart: Date?

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(palette.bg.opacity(0.55))
                .ignoresSafeArea()
                .opacity(backdrop ? 1 : 0)

            // Confetti is decorative — skipped under Reduce Motion. Pieces are
            // brand tones only: sky, its soft tints, white and navy.
            if let confettiStart, !reduceMotion {
                ConfettiRain(start: confettiStart,
                             colors: [color, Color.evrySky, Color.evrySkySoft, Color.evryWhite,
                                      Color.evryNavy, Color.evrySky.mix(with: .evryNavy, by: 0.5)])
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 22) {
                ZStack {
                    // Soft sky glow and rays behind the medal.
                    EvryGlow(onNavy: palette.dark)
                        .opacity(medalIn ? 1 : 0)
                    ForEach(0..<14, id: \.self) { i in
                        Capsule()
                            .fill(Color.evrySky.opacity(0.5))
                            .frame(width: 10, height: 70)
                            .offset(y: -118)
                            .rotationEffect(.degrees(Double(i) / 14 * 360))
                    }
                    .rotationEffect(.degrees(raysSpin ? 360 : 0))
                    .scaleEffect(medalIn ? 1 : 0.3)
                    .opacity(medalIn ? 1 : 0)

                    HabitMedal(icon: icon, size: 150)
                        .scaleEffect(medalIn ? 1 : 0.1)
                        .rotationEffect(.degrees(medalIn ? 0 : -40))
                        .opacity(medalIn ? 1 : 0)

                    // Evry joins in on the moment.
                    EvryMascot(size: 64, float: true, disc: true)
                        .offset(x: 92, y: 86)
                        .scaleEffect(medalIn ? 1 : 0.3)
                        .opacity(medalIn ? 1 : 0)
                }
                .frame(width: 300, height: 300)

                VStack(spacing: 10) {
                    EyebrowPill(text: "Habit built", palette: palette)
                    Text(habitName)
                        .font(.evryH2)
                        .tracking(EvryTracking.h2)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text("\(days) days of showing up. It’s part of your days now.")
                        .font(.evryLead)
                        .lineSpacing(4)
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .opacity(textIn ? 1 : 0)
                .offset(y: textIn ? 0 : 24)

                Button("Keep it going", action: finish)
                    .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
                    .frame(maxWidth: 260)
                    .opacity(buttonIn ? 1 : 0)
                    .scaleEffect(buttonIn ? 1 : 0.9)
                    .padding(.top, 8)
            }
        }
        .task { await play() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func play() async {
        withAnimation(.easeOut(duration: 0.35)) { backdrop = true }
        // Drumroll — rising taps.
        let rigid = UIImpactFeedbackGenerator(style: .rigid)
        rigid.prepare()
        for i in 0..<8 {
            rigid.impactOccurred(intensity: 0.25 + CGFloat(i) * 0.1)
            try? await Task.sleep(for: .milliseconds(max(40, 110 - i * 10)))
        }
        // The medal slams in.
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { medalIn = true }
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { medalIn = true }
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { raysSpin = true }
        }
        confettiStart = Date()
        try? await Task.sleep(for: .milliseconds(180))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { textIn = true }
        try? await Task.sleep(for: .milliseconds(500))
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { buttonIn = true }
        // A second pop of haptics as the confetti peaks.
        try? await Task.sleep(for: .milliseconds(300))
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func finish() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeIn(duration: 0.3)) {
            backdrop = false
            medalIn = false
            textIn = false
            buttonIn = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: onDone)
    }
}

/// Confetti pieces falling from above the screen with sway and spin, drawn in
/// a Canvas driven by a TimelineView.
private struct ConfettiRain: View {
    let start: Date
    let colors: [Color]

    private struct Piece {
        let x: Double, delay: Double, speed: Double, size: CGFloat
        let sway: Double, swaySpeed: Double, spin: Double, colorIndex: Int, round: Bool
        /// Burst pieces fire outward from the medal instead of raining from the top.
        var burst = false
        var vx: Double = 0, vy: Double = 0
    }

    /// Generated once, up front (State keeps the first set across re-renders).
    @State private var pieces: [Piece]
    /// Every piece has fallen off screen by ~7s; stop redrawing then.
    @State private var finished = false

    init(start: Date, colors: [Color]) {
        self.start = start
        self.colors = colors
        _pieces = State(initialValue: Self.makePieces(colorCount: max(1, colors.count)))
    }

    var body: some View {
        TimelineView(.animation(paused: finished)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start)
                for p in pieces {
                    let life = t - p.delay
                    guard life > 0 else { continue }
                    let x: Double, y: Double
                    if p.burst {
                        // Fired from the medal (upper-middle of the screen), then gravity.
                        x = size.width / 2 + p.vx * life + sin(life * p.swaySpeed) * p.sway * min(1, life)
                        y = size.height * 0.36 + p.vy * life + 520 * life * life
                    } else {
                        y = -30 + p.speed * life + 30 * life * life
                        x = p.x * size.width + sin(life * p.swaySpeed) * p.sway
                    }
                    guard y < size.height + 30 else { continue }
                    var piece = ctx
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(life * p.spin))
                    // Squash horizontally over time to fake a 3D flutter.
                    piece.scaleBy(x: CGFloat(abs(cos(life * p.spin * 0.7))) * 0.8 + 0.2, y: 1)
                    let rect = CGRect(x: -p.size / 2, y: -p.size * 0.35, width: p.size, height: p.size * 0.7)
                    let shape = p.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
                    piece.fill(shape, with: .color(colors[p.colorIndex % colors.count]))
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(8))
            finished = true
        }
    }

    private static func makePieces(colorCount: Int) -> [Piece] {
            // A burst out of the medal the instant it lands…
            let burst = (0..<90).map { _ in
                Piece(x: 0.5, delay: .random(in: 0...0.12), speed: 0,
                      size: .random(in: 7...13), sway: .random(in: 6...18), swaySpeed: .random(in: 2...5),
                      spin: .random(in: -10...10), colorIndex: .random(in: 0..<colorCount),
                      round: Bool.random() && Bool.random(),
                      burst: true, vx: .random(in: -380...380), vy: .random(in: -720...(-260)))
            }
            // …then rain staggered over ~3s so it keeps going while the text lands.
            let rain = (0..<150).map { _ in
                Piece(x: .random(in: 0...1), delay: .random(in: 0.2...3), speed: .random(in: 130...300),
                      size: .random(in: 7...13), sway: .random(in: 8...30), swaySpeed: .random(in: 2...5),
                      spin: .random(in: -8...8), colorIndex: .random(in: 0..<colorCount),
                      round: Bool.random() && Bool.random())
            }
            return burst + rain
    }
}

// MARK: - Checkmark button

/// Large round checkmark — each press logs one check-in. A medium haptic per
/// check-in; the one that reaches the daily target plays a success haptic and
/// a pop + ring burst. Once done for the day it settles into a muted "done"
/// state and further presses just give a soft bump.
struct HabitCheckButton: View {
    let done: Bool
    let color: Color
    let palette: Palette
    /// Whether the next press completes the day's target.
    let willComplete: Bool
    var size: CGFloat = 64
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var popScale: CGFloat = 1
    @State private var burstScale: CGFloat = 1
    @State private var burstOpacity: Double = 0
    @State private var shake: CGFloat = 0

    // To check in: the strong ink (navy / sky in dark) — the card's one main
    // action. Done: the sky check disc with a navy tick. `color` (the habit's
    // shade) tints only the completion burst.
    var body: some View {
        Button(action: tap) {
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 2.5)
                    .frame(width: size, height: size)
                    .scaleEffect(burstScale)
                    .opacity(burstOpacity)

                Circle()
                    .fill(done ? Palette.doneFill : palette.primary)
                    .frame(width: size, height: size)
                    // shadow-btn while it's the action; resting flat once done.
                    .shadow(color: (palette.dark ? Color.black : Color.evryNavy)
                                .opacity(done ? 0 : (palette.dark ? 0.4 : 0.35)),
                            radius: 8, y: 6)

                Image(systemName: "checkmark")
                    .font(.nunito(size: size * 0.4, weight: .heavy))
                    .foregroundStyle(done ? Color.evryNavy : palette.onPrimary)
            }
            .frame(width: size + 12, height: size + 12)
            .scaleEffect(popScale)
            .offset(x: shake)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
        .accessibilityLabel(done ? "Done for today" : "Check in")
    }

    private func tap() {
        guard !done else {
            // Already complete — a gentle nudge instead of logging more.
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation(.spring(response: 0.12, dampingFraction: 0.3)) { shake = 5 }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.4).delay(0.08)) { shake = 0 }
            return
        }
        action()
        if willComplete {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { popScale = 1.2 }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.55).delay(0.12)) { popScale = 1 }
            burstScale = 1
            burstOpacity = 0.8
            withAnimation(.easeOut(duration: 0.5)) {
                burstScale = 1.8
                burstOpacity = 0
            }
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.14, dampingFraction: 0.5)) { popScale = 0.9 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55).delay(0.08)) { popScale = 1 }
        }
    }
}

// MARK: - Progress ring

struct HabitRing: View {
    let fraction: Double
    let color: Color
    let track: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: fraction)
    }
}

// MARK: - Goal stepper

/// −/+ stepper matching the Profile tab's daily-goal stepper.
struct HabitGoalStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...20
    let palette: Palette

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            step("minus") { value = max(range.lowerBound, value - 1) }
            Text("\(value)")
                .font(.evryLabel)
                .monospacedDigit()
                .foregroundStyle(palette.text)
                .frame(minWidth: 34)
                .contentTransition(.numericText())
            step("plus") { value = min(range.upperBound, value + 1) }
        }
        .background(palette.skyMist, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
    }

    /// A tap steps once; holding keeps stepping (handy for the 66-day goal).
    private func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.nunito(size: 13, weight: .bold))
            .foregroundStyle(palette.primary)
            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 60, perform: {}, onPressingChanged: { pressing in
                repeatTask?.cancel()
                guard pressing else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
                repeatTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.4))
                    while !Task.isCancelled {
                        UISelectionFeedbackGenerator().selectionChanged()
                        action()
                        try? await Task.sleep(for: .seconds(0.07))
                    }
                }
            })
            .accessibilityElement()
            .accessibilityLabel(icon == "plus" ? "Increase" : "Decrease")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

// MARK: - Draft + shared form fields

/// Editable copy of a habit's settings, shared by the add card and edit sheet.
struct HabitDraft {
    var name = ""
    var icon = HabitStyle.icons[0]
    var colorHex: UInt32 = HabitStyle.defaultColor
    var dailyTarget = 1
    var goalDays = Habit.defaultGoalDays
    /// Specific days picked; empty means every day.
    var weekdays: Set<Int> = []

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedName.isEmpty }
    /// Persisted form: every day is stored as an empty list.
    var storedWeekdays: [Int] { weekdays.isEmpty || weekdays.count == 7 ? [] : weekdays.sorted() }

    init() {}

    init(_ habit: Habit) {
        name = habit.name
        icon = habit.icon
        colorHex = UInt32(truncatingIfNeeded: habit.colorHex)
        dailyTarget = habit.dailyTarget
        goalDays = habit.goalDays
        weekdays = Set(habit.weekdays)
    }

    func apply(to habit: Habit) {
        habit.name = trimmedName
        habit.icon = icon
        habit.colorHex = Int(colorHex)
        habit.dailyTarget = dailyTarget
        habit.goalDays = goalDays
        habit.weekdays = storedWeekdays
    }
}

/// Name, times-per-day, repeat days, icon and color — the habit form body.
private struct HabitFormFields: View {
    @Binding var draft: HabitDraft
    let palette: Palette
    var nameFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    private var tint: Color { HabitStyle.color(for: draft.colorHex) }
    private var tintInk: Color { HabitStyle.ink(for: draft.colorHex) }

    // Laid out like `NewFolderSheet` (the QuickAddCard reference): the name
    // field, then labelled sections. Kept compact so the add card fits above
    // the keyboard — the two steppers share a row, and the shade swatch sits
    // on the icon section's label row.
    var body: some View {
        // Spacing matches QuickAddCard's own content stack, so the card and
        // the edit sheet lay out identically.
        VStack(spacing: 16) {
            TextField("Name your habit, e.g. Read 10 pages", text: $draft.name)
                .focused(nameFocused)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .evryTextField(palette, focused: nameFocused.wrappedValue)
                .accessibilityLabel("Habit name")

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    QuickAddLabel(text: "Times per day", icon: "repeat", palette: palette)
                    HabitGoalStepper(value: $draft.dailyTarget, palette: palette)
                }
                VStack(alignment: .leading, spacing: 8) {
                    QuickAddLabel(text: "Goal (days)", icon: "flag.checkered", palette: palette)
                    HabitGoalStepper(value: $draft.goalDays, range: 1...365, palette: palette)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    QuickAddLabel(text: "Repeat", icon: "calendar", palette: palette)
                    Text(scheduleSummary)
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textSec)
                        .contentTransition(.opacity)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 4)
                }
                weekdayPicker
            }

            VStack(alignment: .leading, spacing: 6) {
                // Press and hold the swatch at the end of this row for the shade.
                HabitColorPicker(selection: $draft.colorHex, palette: palette) {
                    QuickAddLabel(text: "Icon & shade", icon: "square.grid.2x2", palette: palette)
                }
                QuickAddIconRow(icons: HabitStyle.icons, selection: $draft.icon,
                                tint: tint, ink: tintInk, palette: palette)
            }
        }
    }

    /// "Every day" when no specific days are picked, otherwise e.g. "Mon, Wed, Fri".
    private var scheduleSummary: String {
        let days = draft.storedWeekdays
        guard !days.isEmpty else { return "Every day" }
        if Set(days) == [2, 3, 4, 5, 6] { return "Weekdays" }
        if Set(days) == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return HabitStyle.orderedWeekdays.filter(days.contains).map { symbols[$0 - 1] }.joined(separator: ", ")
    }

    private var weekdayPicker: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return HStack(spacing: 6) {
            ForEach(HabitStyle.orderedWeekdays, id: \.self) { day in
                let on = draft.weekdays.contains(day)
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    // Nothing picked (the default) means every day, so days only
                    // light up once the user narrows the schedule.
                    if on { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.evrySmall)
                        .foregroundStyle(on ? palette.onPrimary : palette.textSec)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(on ? palette.primary : palette.hover, in: Circle())
                        .frame(minHeight: EvrySpace.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Color picker (press and hold)

/// A single swatch showing the current color. Press and hold it and the full
/// row of colors fans out from the swatch across the row; drag onto a color and
/// release to pick it (release without moving onto one to cancel). A plain tap
/// opens the row so a color can then be tapped. Keeps just one color on screen
/// the rest of the time.
struct HabitColorPicker<Label: View>: View {
    @Binding var selection: UInt32
    let palette: Palette
    @ViewBuilder var label: () -> Label

    @State private var open = false
    @State private var hovered: UInt32?
    // Per-gesture bookkeeping.
    @State private var gestureActive = false
    @State private var startedOnSwatch = false
    @State private var openLocation: CGPoint?
    @State private var armWork: DispatchWorkItem?

    /// The swatches offered (habits by default; Notes folders pass their own).
    var colors: [UInt32] = HabitStyle.colors
    private let swatchSize: CGFloat = 32
    private let rowHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let slot = width / CGFloat(colors.count)
            let swatchCenterX = width - swatchSize / 2

            ZStack {
                HStack {
                    label()
                    Spacer()
                }
                .opacity(open ? 0 : 1)

                // Every color sits stacked under the swatch when closed and
                // springs out to its own slot when open (staggered from the swatch).
                ForEach(Array(colors.enumerated()), id: \.element) { index, hex in
                    let centerX = slot * (CGFloat(index) + 0.5)
                    let isHovered = hovered == hex
                    Circle()
                        .fill(HabitStyle.color(for: hex))
                        .frame(width: 28, height: 28)
                        .overlay {
                            if selection == hex && (hovered == nil || isHovered) {
                                Image(systemName: "checkmark")
                                    .font(.nunito(size: 12, weight: .bold))
                                    .foregroundStyle(HabitStyle.ink(for: hex))
                            }
                        }
                        .scaleEffect(open ? (isHovered ? 1.35 : 1) : 0.4)
                        .opacity(open ? 1 : 0)
                        .position(x: open ? centerX : swatchCenterX, y: rowHeight / 2)
                        .animation(
                            .spring(response: 0.34, dampingFraction: 0.72)
                                .delay(open ? Double(colors.count - 1 - index) * 0.018 : 0),
                            value: open
                        )
                        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isHovered)
                }

                // The collapsed swatch — the only color visible until held.
                Circle()
                    .fill(HabitStyle.color(for: selection))
                    .frame(width: swatchSize, height: swatchSize)
                    .overlay(Circle().strokeBorder(Color.evryWhite.opacity(0.6), lineWidth: 2))
                    .evryShadowSoft(palette)
                    .scaleEffect(open ? 0.4 : 1)
                    .opacity(open ? 0 : 1)
                    .position(x: swatchCenterX, y: rowHeight / 2)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: open)
            }
            .contentShape(Rectangle())
            .gesture(pickGesture(width: width, slot: slot))
        }
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shade")
        .accessibilityValue("\((colors.firstIndex(of: selection) ?? 0) + 1) of \(colors.count), lightest to deepest")
        .accessibilityAdjustableAction { direction in
            let i = colors.firstIndex(of: selection) ?? 0
            switch direction {
            case .increment: selection = colors[min(colors.count - 1, i + 1)]
            case .decrement: selection = colors[max(0, i - 1)]
            @unknown default: break
            }
        }
    }

    private func pickGesture(width: CGFloat, slot: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !gestureActive {
                    gestureActive = true
                    startedOnSwatch = v.startLocation.x >= width - swatchSize - 16
                    if !open && startedOnSwatch {
                        // Arm the hold that fans the colors out.
                        let work = DispatchWorkItem { openRow(at: v.startLocation) }
                        armWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11, execute: work)
                    }
                }
                if open {
                    updateHover(v.location, slot: slot)
                }
            }
            .onEnded { _ in
                armWork?.cancel(); armWork = nil
                gestureActive = false
                if open {
                    if let pick = hovered {
                        selection = pick
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    // Released on a color picks it; anywhere else cancels.
                    closeRow()
                } else if startedOnSwatch {
                    // A quick tap: open the row and leave it open for a tap-to-pick.
                    openRow(at: nil)
                }
            }
    }

    private func openRow(at location: CGPoint?) {
        armWork = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        openLocation = location
        hovered = nil
        open = true
    }

    private func closeRow() {
        open = false
        hovered = nil
        openLocation = nil
    }

    private func updateHover(_ location: CGPoint, slot: CGFloat) {
        // Ignore the finger until it moves off the point where the hold began,
        // so releasing in place cancels instead of picking the color under it.
        if let origin = openLocation, hypot(location.x - origin.x, location.y - origin.y) < 10 {
            return
        }
        openLocation = nil
        let inRow = location.y > -40 && location.y < rowHeight + 40
        let index = Int(location.x / slot)
        let next: UInt32? = inRow && index >= 0 && index < colors.count ? colors[index] : nil
        guard next != hovered else { return }
        hovered = next
        if next != nil { UISelectionFeedbackGenerator().selectionChanged() }
    }
}

// MARK: - Add habit card (swipe-up)

/// Habit quick-add, opened from the shared swipe-up handle on the Habits
/// screen. Built on `QuickAddCard` (mirrors `NewFolderSheet`, the reference):
/// the card owns the chrome — grabber, panel, drag-to-close, entrance.
struct AddHabitSheet: View {
    @Binding var isPresented: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @State private var draft = HabitDraft()
    @FocusState private var nameFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        QuickAddCard(palette: palette, actionTitle: "Add habit", actionEnabled: draft.isValid,
                     onAction: create, onClose: close) {
            HabitFormFields(draft: $draft, palette: palette, nameFocused: $nameFocused, onSubmit: create)
        }
        .task {
            // Focus once the overlay is in the window (an early request is dropped).
            try? await Task.sleep(for: .milliseconds(120))
            nameFocused = true
            try? await Task.sleep(for: .milliseconds(300))
            if !nameFocused { nameFocused = true }
        }
    }

    private func create() {
        guard draft.isValid else { return }
        let nextOrder = ((try? context.fetch(FetchDescriptor<Habit>())) ?? []).map(\.sortOrder).max().map { $0 + 1 } ?? 0
        let habit = Habit(name: draft.trimmedName, icon: draft.icon, colorHex: Int(draft.colorHex),
                          dailyTarget: draft.dailyTarget, weekdays: draft.storedWeekdays,
                          goalDays: draft.goalDays)
        habit.sortOrder = nextOrder
        context.insert(habit)
        try? context.save()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        close()
    }

    private func close() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isPresented = false
    }
}

// MARK: - Edit sheet

private struct HabitEditorSheet: View {
    let habit: Habit

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @State private var draft = HabitDraft()
    @FocusState private var nameFocused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            ScrollView {
                HabitFormFields(draft: $draft, palette: palette, nameFocused: $nameFocused, onSubmit: save)
                    .padding(EvrySpace.grid)
                    .evryCard(palette, cornerRadius: EvryRadius.panel)
                    .padding(20)
            }
            .background(palette.bg)
            .navigationTitle("Edit habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!draft.isValid)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear { draft = HabitDraft(habit) }
    }

    private func save() {
        guard draft.isValid else { return }
        draft.apply(to: habit)
        try? context.save()
        // A new goal length can build (or un-build) the habit.
        HabitActions.refreshFormed(habit, context: context)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - Detail sheet

private struct HabitDetailSheet: View {
    let habit: Habit
    /// Hands the delete to the page, which dismisses this sheet and runs its
    /// animated delete from the sheet's `onDismiss` (no timers to race).
    let onDelete: (Habit) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @State private var showEdit = false
    @State private var confirmDelete = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        let stats = HabitStats(habit: habit)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    todayControls(stats)
                    statsGrid(stats)
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Last 16 weeks", palette: palette)
                        HabitHeatmap(habit: habit, stats: stats, palette: palette)
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete habit", systemImage: "trash")
                    }
                    .buttonStyle(EvrySecondaryButtonStyle(palette: palette, fullWidth: true))
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .background(palette.bg)
            .navigationTitle(habit.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Edit") { showEdit = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showEdit) {
                HabitEditorSheet(habit: habit).environment(appearance)
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .evryConfirm(
            isPresented: $confirmDelete,
            title: "Delete “\(habit.name)”?",
            message: "Its streak and check-in history will be removed.",
            confirmTitle: "Delete habit"
        ) {
            onDelete(habit)
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            // The habit's own shade on the Habits tile shape (a circle).
            Image(systemName: habit.icon)
                .font(.nunito(size: 30, weight: .semibold))
                .foregroundStyle(habit.ink)
                .frame(width: 72, height: 72)
                .background(habit.color, in: Circle())
                .accessibilityHidden(true)
            Text(habit.name)
                .font(.evryH3)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
            Text(habit.dailyTarget > 1 ? "\(habit.dailyTarget)× a day · \(habit.scheduleLabel)" : habit.scheduleLabel)
                .font(.nunito(size: 14))
                .foregroundStyle(palette.textSec)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// Today's check-ins: progress with a goal-style −/+ adjuster.
    private func todayControls(_ stats: HabitStats) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(stats.todayDone ? "Done for today" : "\(stats.today) of \(stats.target) today")
                    .font(.evryLabel)
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText())
                ProgressBarView(fraction: stats.todayFraction, palette: palette)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                todayStep("minus", enabled: stats.today > 0) {
                    HabitActions.undoCheckIn(habit, context: context)
                }
                Text("\(stats.today)")
                    .font(.evryLabel)
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
                    .frame(minWidth: 34)
                    .contentTransition(.numericText())
                todayStep("plus", enabled: !stats.todayDone) {
                    HabitActions.checkIn(habit, context: context)
                    if stats.today + 1 >= stats.target {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
            .background(palette.skyMist, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
        }
        .padding(EvrySpace.gutter)
        .evryCard(palette)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: stats.today)
    }

    private func todayStep(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.nunito(size: 13, weight: .bold))
                .foregroundStyle(enabled ? palette.primary : palette.textPh)
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "Add a check-in" : "Remove a check-in")
    }

    private func statsGrid(_ stats: HabitStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            statTile("Current streak", value: "\(stats.currentStreak)", unit: stats.currentStreak == 1 ? "day" : "days",
                     icon: "flame.fill")
            statTile("Best streak", value: "\(stats.bestStreak)", unit: stats.bestStreak == 1 ? "day" : "days",
                     icon: "trophy.fill")
            statTile("Last 30 days", value: "\(Int((stats.rate30 * 100).rounded()))", unit: "%",
                     icon: "chart.bar.fill")
            statTile("Goal", value: "\(stats.completedDays)", unit: "of \(stats.goal) days",
                     icon: stats.goalReached ? "checkmark.seal.fill" : "flag.checkered")
        }
    }

    private func statTile(_ title: String, value: String, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.evryCaption)
                .foregroundStyle(palette.textSec)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.nunito(size: 26, weight: .heavy))
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textSec)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EvrySpace.gutter)
        .evryField(palette, cornerRadius: EvryRadius.field)
    }
}

// MARK: - Heatmap

/// GitHub-style grid: one column per week, one row per weekday, shaded by how
/// much of the daily target was met.
private struct HabitHeatmap: View {
    let habit: Habit
    let stats: HabitStats
    let palette: Palette
    var weeks = 16

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let gridStart = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek

        HStack(alignment: .top, spacing: 4) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let day = cal.date(byAdding: .day, value: week * 7 + weekday, to: gridStart) ?? gridStart
                        cell(day: day, today: today)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(EvrySpace.gutter)
        .evryField(palette, cornerRadius: EvryRadius.field)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Completed on \(stats.completedDays) days")
    }

    @ViewBuilder
    private func cell(day: Date, today: Date) -> some View {
        let fraction = min(1, Double(stats.count(on: day)) / Double(max(1, habit.dailyTarget)))
        // Strength steps of the habit's shade: deeper = more of the target met.
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(day > today ? .clear : (fraction > 0 ? habit.color.opacity(0.3 + 0.7 * fraction) : palette.hover))
            .overlay {
                if day == today {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(palette.text, lineWidth: 1.5)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 16)
    }
}
