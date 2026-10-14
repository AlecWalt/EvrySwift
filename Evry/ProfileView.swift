//
//  ProfileView.swift
//  Evry
//
//  Profile tab — search and settings, the person's name and level title, their
//  photo ringed by level progress, today's goals as progress bars, membership,
//  stats tiles, the week chart and settings sheet. Pull down to search.
//

import SwiftUI
import EventKit
import SwiftData
import StoreKit
import PhotosUI
import UIKit
import MessageUI

private let profileISO8601 = ISO8601DateFormatter()

private let narrowDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEEEE"
    return f
}()

/// Avatar fills: sky strength steps only (no new hues). Initials sit on them in
/// navy, which reads at ≥ 8:1 on every step.
private let avatarColors: [Color] = [
    Color.evrySky,
    Color.evrySky.mix(with: .evryWhite, by: 0.35),
    Color.evrySky.mix(with: .evryNavy, by: 0.12),
    Color.evrySkySoft,
    Color.evrySky.mix(with: .evryWhite, by: 0.6),
    Color.evrySky.mix(with: .evryNavy, by: 0.2),
]

/// A 1pt divider in the palette's border tone.
private func paletteDivider(_ palette: Palette) -> some View {
    Rectangle().fill(palette.border).frame(height: 1)
}

private func avatarColor(for name: String) -> Color {
    var hash = 0
    for scalar in name.unicodeScalars {
        hash = Int(scalar.value) &+ ((hash << 5) &- hash)
    }
    return avatarColors[abs(hash) % avatarColors.count]
}

struct ProfileView: View {
    let palette: Palette
    var onEnterFocusMode: () -> Void

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @Query private var habits: [Habit]

    @Environment(\.requestReview) private var requestReview
    @Environment(CalendarService.self) private var calendarService
    @Environment(TourCoordinator.self) private var tourCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("user_name") private var userName = ""
    @AppStorage("app_first_used") private var firstUsed = ""
    @AppStorage("membership_plan") private var membershipPlan = ""
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var profileImageData: Data? = nil
    @State private var cropItem: CropImage? = nil
    @State private var showSettings = false
    @State private var showSetupFlow = false
    @State private var showMembershipPromo = false
    @State private var showGlobalSearch = false
    @State private var showCrests = false
    @AppStorage(EvryXP.totalKey) private var xpTotal = 0
    /// The level the crest currently shows (animates on level-up).
    @State private var shownLevel = 1
    /// The level ring's fill (0…1). Driven by hand rather than straight from
    /// `level.fraction`, so a level-up can fill the ring all the way, celebrate,
    /// and only then start the next level from empty.
    @State private var ringFraction: Double = 0
    /// Bumped to play the level-up burst.
    @State private var levelUpBurst = 0
    /// The level just reached, shown briefly under the photo.
    @State private var levelUpBanner: Int? = nil
    /// Guards against an older ring animation finishing after a newer one.
    @State private var ringGeneration = 0
    /// The XP the ring last showed, so a level-up earned elsewhere still plays
    /// here the next time the profile opens.
    @AppStorage("profile_seen_xp") private var seenXP = -1
    @AppStorage("daily_pomo_goal") private var dailyFocusGoal = 60
    /// The frequent places from setup (JSON) — shown in the developer area.
    @AppStorage(FrequentPlaces.key) private var frequentPlacesData = Data()
    /// How far the page is pulled down past its top (pull far enough to search).
    @State private var pullDistance: CGFloat = 0
    @State private var pullArmed = false
    @State private var scrollInteracting = false
    private static let pullToSearch: CGFloat = 80

    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed } }
    private var stats: TaskStats { computeStats(tasks) }

    private var initials: String {
        let words = userName.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard !words.isEmpty else { return "?" }
        return words.prefix(2).compactMap { $0.first.map(String.init)?.uppercased() }.joined()
    }

    private var joinedLabel: String {
        let date = profileISO8601.date(from: firstUsed) ?? Date()
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    /// The page background: white (navy in dark mode).
    private var pageBackground: Color {
        palette.bg
    }

    private var level: EvryXP.Progress { EvryXP.progress(for: xpTotal) }
    private var tier: CrestTier { .forLevel(level.level) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, EvrySpace.gutter)
                avatar
                    .padding(.top, 10)
                container
                    .padding(.top, -53)    // the photo sits over the container's top edge
                    .padding(.horizontal, 8)
            }
            .padding(.top, 8)
        }
        // Pull down from the top to open search.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            max(0, -(geo.contentOffset.y + geo.contentInsets.top))
        } action: { _, pull in
            pullDistance = pull
            guard scrollInteracting else { return }
            if pull >= Self.pullToSearch && !pullArmed {
                pullArmed = true
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            } else if pull < Self.pullToSearch * 0.8 && pullArmed {
                pullArmed = false
            }
        }
        .onScrollPhaseChange { _, phase in
            scrollInteracting = phase == .interacting
            // Opens as the finger lets go, if it was pulled far enough.
            if phase != .interacting && pullArmed {
                pullArmed = false
                showGlobalSearch = true
            }
        }
        .overlay(alignment: .top) { pullHint }
        .background(pageBackground.ignoresSafeArea())
        .onAppear {
            profileImageData = UserDefaults.standard.data(forKey: "profile_image_data")
            if firstUsed.isEmpty {
                firstUsed = profileISO8601.string(from: Date())
            }
            syncRingOnAppear()
        }
        .onChange(of: xpTotal) { old, new in playProgress(from: old, to: new) }
        .onChange(of: selectedPhoto) { _, item in
            // Load the full image, then let the user crop/zoom before saving.
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { cropItem = CropImage(image: img); selectedPhoto = nil }
                }
            }
        }
        .fullScreenCover(item: $cropItem) { c in
            ProfilePhotoCropper(image: c.image, palette: palette) { jpeg in
                profileImageData = jpeg
                UserDefaults.standard.set(jpeg, forKey: "profile_image_data")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .fullScreenCover(isPresented: $showSetupFlow) { SetupFlowView() }
        .sheet(isPresented: $showMembershipPromo) { MembershipPromoView() }
        .sheet(isPresented: $showGlobalSearch) { GlobalSearchSheet() }
        .sheet(isPresented: $showCrests) {
            CrestGallerySheet(level: level.level, palette: palette)
                .presentationDetents([.medium, .large])
        }
    }

    /// A magnifying glass that fades in above the header as the page is pulled
    /// down, filling in once it's pulled far enough to open search.
    private var pullHint: some View {
        let progress = min(1, pullDistance / Self.pullToSearch)
        return Image(systemName: "magnifyingglass")
            .font(.nunito(size: 17, weight: .bold))
            .foregroundStyle(pullArmed ? palette.onPrimary : palette.text)
            .frame(width: 40, height: 40)
            .background(pullArmed ? palette.primary : palette.hover, in: Circle())
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(Double(progress))
            .offset(y: max(0, pullDistance / 2 - 20))
            .animation(EvryMotion.pop, value: pullArmed)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Level ring

    private func syncRingOnAppear() {
        // First visit, or XP was reset: just show where things stand.
        guard seenXP >= 0, seenXP <= xpTotal, seenXP != xpTotal else {
            seenXP = xpTotal
            shownLevel = level.level
            ringFraction = level.fraction
            return
        }
        // Progress made since the profile was last seen: start from there and
        // play it in, once the page has settled.
        let from = seenXP
        let start = EvryXP.progress(for: from)
        shownLevel = start.level
        ringFraction = start.fraction
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { playProgress(from: from, to: xpTotal) }
    }

    /// Moves the ring from one XP total to another. Within a level it simply
    /// glides. Across a level it fills the rest of the ring, bursts, shows the
    /// new level, then empties out of sight and fills to the new progress.
    private func playProgress(from oldXP: Int, to newXP: Int) {
        let old = EvryXP.progress(for: oldXP)
        let new = EvryXP.progress(for: newXP)
        seenXP = newXP
        ringGeneration += 1
        let generation = ringGeneration

        guard new.level > old.level else {
            withAnimation(EvryMotion.settle) {
                shownLevel = new.level
                ringFraction = new.fraction
            }
            return
        }
        if reduceMotion {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.easeOut(duration: 0.2)) {
                shownLevel = new.level
                ringFraction = new.fraction
            }
            return
        }

        // 1. Close the circle.
        withAnimation(.easeInOut(duration: 0.6)) { ringFraction = 1 } completion: {
            guard generation == ringGeneration else { return }
            // 2. Celebrate.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            levelUpBurst += 1
            withAnimation(EvryMotion.pop) {
                shownLevel = new.level
                levelUpBanner = new.level
            }
            Task { @MainActor in
                // 3. Empty the ring under the burst (no backwards sweep), then
                //    fill to the new level's progress.
                try? await Task.sleep(for: .milliseconds(550))
                guard generation == ringGeneration else { return }
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { ringFraction = 0 }
                try? await Task.sleep(for: .milliseconds(40))
                guard generation == ringGeneration else { return }
                withAnimation(.easeOut(duration: 0.8)) { ringFraction = new.fraction }
                try? await Task.sleep(for: .milliseconds(1600))
                guard generation == ringGeneration else { return }
                withAnimation(.easeOut(duration: 0.3)) { levelUpBanner = nil }
            }
        }
    }

    // MARK: Header

    /// Search on the left, settings on the right, the name, level title and
    /// level centred between them. Tap the title for the crests.
    private var header: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(userName.isEmpty ? "Your name" : userName)
                    .font(.nunito(size: 26, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(Color.evryNavy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Button { showCrests = true } label: {
                    Text("\(tier.title) · Lv. \(shownLevel)")
                        .font(.nunito(size: 15, weight: .semibold))
                        .foregroundStyle(Color.evryNavy.opacity(0.8))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(EvryMotion.settle, value: shownLevel)
                }
                .buttonStyle(PressScaleStyle(scale: 0.97))
                .accessibilityLabel("\(tier.title), level \(level.level), \(Int((level.fraction * 100).rounded())) percent to the next level")
                .accessibilityHint("Shows your crests")
            }
            .padding(.horizontal, 60)

            HStack {
                circleButton("magnifyingglass", label: "Search tasks, notes and projects") { showGlobalSearch = true }
                Spacer()
                circleButton("gearshape.fill", label: "Open settings") { showSettings = true }
            }
        }
        .foregroundStyle(palette.dark ? Color.evryWhite : .evryNavy)
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.nunito(size: 17, weight: .bold))
                .foregroundStyle(palette.text)
                .frame(width: EvrySpace.tap + 4, height: EvrySpace.tap + 4)
                .background(palette.card, in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    // MARK: Avatar

    /// The person's photo (or initials), large and centred, ringed by their
    /// progress to the next level. Tap to change the photo.
    private var avatar: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
            ZStack {
                ZStack {
                    Circle()
                        .fill(profileImageData != nil ? Color.clear : (userName.isEmpty ? palette.skySoft : avatarColor(for: userName)))
                    if let data = profileImageData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    } else if userName.isEmpty {
                        Image(systemName: "camera.fill")
                            .font(.nunito(size: 34, weight: .semibold))
                            .foregroundStyle(Color.evryNavy.opacity(0.6))
                    } else {
                        Text(initials)
                            .font(.nunito(size: 52, weight: .heavy))
                            .foregroundStyle(Color.evryNavy)
                    }
                }
                .frame(width: 148, height: 148)
                .overlay(Circle().strokeBorder(Color.evryWhite, lineWidth: 6))

                // The level ring: a white track hugging the photo (with a soft
                // shadow so it reads on the white page), filling with sky
                // clockwise from the top.
                Circle()
                    .stroke(Color.evryWhite, lineWidth: 12)
                    .frame(width: 162, height: 162)
                    .shadow(color: Color.evryNavy.opacity(palette.dark ? 0.35 : 0.14), radius: 5, y: 2)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, ringFraction)))
                    .stroke(Color.evrySky, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 162, height: 162)
            }
            .frame(width: 174, height: 174)
            .background { LevelUpBurst(trigger: levelUpBurst) }
            // Levelling up: the whole ring pops.
            .keyframeAnimator(initialValue: 1.0, trigger: levelUpBurst) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.12, duration: 0.22, spring: .snappy)
                SpringKeyframe(0.97, duration: 0.18, spring: .snappy)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
            }
            .overlay(alignment: .bottom) {
                if let reached = levelUpBanner {
                    Text("Level \(reached) reached")
                        .font(.nunito(size: 14, weight: .heavy))
                        .foregroundStyle(Color.evryNavy)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.evrySky, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.evryWhite, lineWidth: 2))
                        .offset(y: 10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change profile photo")
        .accessibilityValue("Level \(level.level), \(Int((level.fraction * 100).rounded())) percent to the next level")
        .zIndex(1)
    }

    // MARK: Container

    /// Everything below the photo, in one white container. It runs past the
    /// bottom of the page, so the sky only shows at the top and as slim slivers
    /// down the sides.
    private var container: some View {
        VStack(alignment: .leading, spacing: 18) {
            todayTiles
            if membershipPlan != "pro" {
                upgradeRow
            }
            statsTiles
            activitySection
            developerSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 64)        // room for the photo, which overlaps the top edge
        .padding(.bottom, 100)    // clear of the tab bar
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: EvryRadius.panel, topTrailingRadius: EvryRadius.panel,
                                   style: .continuous)
                .fill(palette.card)
                // Extends well below the content, so overscrolling never shows sky.
                .padding(.bottom, -1200)
        }
    }

    /// A panel inside the white container: white, with the same light outline
    /// as the app's other cards and buttons marking its edge.
    private func inset<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.evrySmall)
            .foregroundStyle(palette.textSec)
            .padding(.leading, 4)
            .padding(.bottom, -8)
    }

    // MARK: Today

    /// Today's tasks, habits and focus — three progress bars, one per line, in
    /// a single inset.
    private var todayTiles: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let dueTasks = tasks.filter { t in
            !t.isNote && (t.dueDate.map { Calendar.current.isDate($0, inSameDayAs: today) } ?? false)
        }
        let tasksDone = dueTasks.filter(\.completed).count
        // Habits due today (built habits are records, so they don't count).
        let dueHabits = habits.filter { !$0.isFormed && $0.isScheduled(on: today) }
        let habitsDone = dueHabits.filter { HabitStats(habit: $0).todayDone }.count
        let focus = FocusLog.minutes(on: Date())
        let focusGoal = max(1, dailyFocusGoal)

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Today")
            inset {
                VStack(spacing: 14) {
                    goalBar(icon: "checkmark.square.fill", label: "Tasks",
                            value: dueTasks.isEmpty ? "–" : "\(tasksDone)/\(dueTasks.count)",
                            fraction: dueTasks.isEmpty ? 0 : Double(tasksDone) / Double(dueTasks.count),
                            reached: !dueTasks.isEmpty && tasksDone == dueTasks.count)
                    goalBar(icon: "arrow.triangle.2.circlepath", label: "Habits",
                            value: dueHabits.isEmpty ? "–" : "\(habitsDone)/\(dueHabits.count)",
                            fraction: dueHabits.isEmpty ? 0 : Double(habitsDone) / Double(dueHabits.count),
                            reached: !dueHabits.isEmpty && habitsDone == dueHabits.count)
                    goalBar(icon: "timer", label: "Focus",
                            value: "\(minutesLabel(focus)) / \(minutesLabel(focusGoal))",
                            fraction: Double(focus) / Double(focusGoal),
                            reached: focus >= focusGoal)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func minutesLabel(_ m: Int) -> String {
        m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") : "\(m)m"
    }

    /// One line of the Today panel: icon and name, the bar, and the count.
    private func goalBar(icon: String, label: String, value: String, fraction: Double, reached: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: reached ? "checkmark.circle.fill" : icon)
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(palette.primary)
                .frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: reduceMotion ? false : reached)
                .accessibilityHidden(true)
            Text(label)
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(palette.text)
                .frame(width: 58, alignment: .leading)
            ProgressBarView(fraction: max(0, min(1, fraction)), palette: palette)
                .frame(height: 8)
            Text(value)
                .font(.nunito(size: 14, weight: .heavy))
                .foregroundStyle(palette.text)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
                .frame(minWidth: 44, alignment: .trailing)
                .fixedSize()
        }
        .animation(EvryMotion.settle, value: reached)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) today")
        .accessibilityValue(reached ? "\(value), done" : value)
    }

    // MARK: Membership

    /// Trial-aware subtitle for the membership row.
    private var trialSubtitle: String {
        let days = MembershipAccess.daysRemaining()
        if days > 0 {
            return "\(days) day\(days == 1 ? "" : "s") left in your free trial"
        }
        return "Your free trial has ended. Keep everything with a membership."
    }

    private var upgradeRow: some View {
        inset {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.nunito(size: 17, weight: .semibold))
                    .foregroundStyle(Color.evryNavy)
                    .frame(width: 40, height: 40)
                    .background(Color.evrySky, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep everything, always")
                        .font(.nunito(size: 15, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text(trialSubtitle)
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.textSec)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Join") { showMembershipPromo = true }
                    .font(.nunito(size: 15, weight: .bold))
                    .foregroundStyle(palette.onPrimary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 40)
                    .background(palette.primary, in: Capsule())
                    .frame(minHeight: EvrySpace.tap)
                    .contentShape(Capsule())
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Start your membership")
            }
            .padding(12)
        }
    }

    // MARK: Stats

    private var statsTiles: some View {
        let overdueCount = tasks.filter { !$0.completed && isOverdueDate($0.dueDate) }.count
        let activeTasks = tasks.filter { !$0.completed && !$0.isNote }.count
        let cells: [(value: String, label: String, alert: Bool)] = [
            ("\(stats.weekDone)", "This week", false),
            ("\(stats.monthDone)", "This month", false),
            ("\(stats.totalDone)", "All-time", false),
            ("\(activeTasks)", "Active", false),
            ("\(overdueCount)", "Overdue", overdueCount > 0),
            (joinedLabel, "Member since", false),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Your stats")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    inset {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if cell.alert {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.nunito(size: 12, weight: .bold))
                                        .foregroundStyle(palette.text)
                                        .accessibilityHidden(true)
                                }
                                Text(cell.value)
                                    .font(.nunito(size: 17, weight: .heavy))
                                    .foregroundStyle(palette.text)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            Text(cell.label)
                                .font(.nunito(size: 12, weight: cell.alert ? .bold : .regular))
                                .foregroundStyle(palette.textSec)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Activity (week chart)

    private var activitySection: some View {
        let maxCount = max(1, stats.weekData.map(\.count).max() ?? 1)

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Last 7 days")
            inset {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(stats.weekData) { day in
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            // Today is the strong ink; other days are sky fill
                            // (dimmed in dark mode, where the ink is sky too).
                            UnevenRoundedRectangle(topLeadingRadius: EvryRadius.tail, topTrailingRadius: EvryRadius.tail,
                                                   style: .continuous)
                                .fill(day.isToday ? palette.primary : Color.evrySky.opacity(palette.dark ? 0.35 : 1))
                                .frame(height: max(3, CGFloat(day.count) / CGFloat(maxCount) * 44 + (day.count > 0 ? 4 : 0)))
                            Text(narrowDateFormatter.string(from: day.date))
                                .font(.nunito(size: 12, weight: day.isToday ? .bold : .semibold))
                                .foregroundStyle(day.isToday ? palette.text : palette.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))): \(day.count) done")
                    }
                }
                .frame(height: 72)
                .padding(14)
            }
        }
    }

    // MARK: Developer section

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Developer")
            inset {
                VStack(spacing: 0) {
                    devButton("Add \(EvryXP.perGoal) XP") {
                        EvryXP.add(EvryXP.perGoal)
                    }
                    paletteDivider(palette).padding(.leading, 16)
                    devButton("Reset XP and level") {
                        EvryXP.reset()
                    }
                    paletteDivider(palette).padding(.leading, 16)
                    devButton("Add sample events today") {
                        addSampleEvents()
                    }
                    paletteDivider(palette).padding(.leading, 16)
                    devButton("Preview setup flow") {
                        showSetupFlow = true
                    }
                    paletteDivider(palette).padding(.leading, 16)
                    devButton("Preview review popup") {
                        requestReview()
                    }
                    paletteDivider(palette).padding(.leading, 16)
                    devButton("Trial: reset to \(MembershipAccess.trialDays) days") {
                        membershipPlan = ""
                        firstUsed = ISO8601DateFormatter().string(from: Date())
                    }
                    paletteDivider(palette).padding(.leading, 16)
                    devButton("Trial: 3 days left") {
                        membershipPlan = ""
                        let d = Calendar.current.date(byAdding: .day, value: -(MembershipAccess.trialDays - 3), to: Date()) ?? Date()
                        firstUsed = ISO8601DateFormatter().string(from: d)
                    }
                    paletteDivider(palette).padding(.leading, 16)
                    devButton("Trial: expire now (show wall)") {
                        membershipPlan = ""
                        let d = Calendar.current.date(byAdding: .day, value: -40, to: Date()) ?? Date()
                        firstUsed = ISO8601DateFormatter().string(from: d)
                    }
                }
            }
            savedPlacesPanel
        }
    }

    /// Dev: the frequent places collected in setup, as stored.
    private var savedPlacesPanel: some View {
        let places = (try? JSONDecoder().decode([FrequentPlace].self, from: frequentPlacesData)) ?? []
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Saved places")
                .padding(.top, 10)
            inset {
                VStack(spacing: 0) {
                    if places.isEmpty {
                        Text("No places saved yet.")
                            .font(.evryBody)
                            .foregroundStyle(palette.textSec)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    ForEach(places) { place in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.label)
                                .font(.nunito(size: 15, weight: .bold))
                                .foregroundStyle(palette.text)
                            Text(place.name)
                                .font(.nunito(size: 14))
                                .foregroundStyle(palette.text)
                            if !place.address.isEmpty && place.address != place.name {
                                Text(place.address)
                                    .font(.nunito(size: 13))
                                    .foregroundStyle(palette.textSec)
                            }
                            Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                                .font(.nunito(size: 12))
                                .foregroundStyle(palette.textMuted)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        paletteDivider(palette).padding(.leading, 16)
                    }
                    if !places.isEmpty {
                        devButton("Clear saved places") {
                            frequentPlacesData = Data()
                        }
                    }
                }
            }
        }
    }

    /// Dev: a spread of events around now, to try the Schedule rail — one done,
    /// one on now, two still to come, plus an all-day one.
    private func addSampleEvents() {
        Task { @MainActor in
            if !calendarService.isAuthorized { await calendarService.requestAccess() }
            guard calendarService.isAuthorized else { return }
            let now = Date()
            func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
            _ = calendarService.createEvent(title: "Morning stand-up", start: at(-150), end: at(-120))
            _ = calendarService.createEvent(title: "Design review", start: at(-20), end: at(40))
            _ = calendarService.createEvent(title: "Lunch with Sam", start: at(90), end: at(150))
            _ = calendarService.createEvent(title: "Dentist", start: at(240), end: at(300))
            let store = calendarService.eventStore
            let allDay = EKEvent(eventStore: store)
            allDay.title = "Mum’s birthday"
            allDay.isAllDay = true
            allDay.startDate = Calendar.current.startOfDay(for: now)
            allDay.endDate = allDay.startDate
            allDay.calendar = store.defaultCalendarForNewEvents
            try? store.save(allDay, span: .thisEvent)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func devButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: EvrySpace.buttonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Settings sheet

struct SettingsSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(CalendarService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    @AppStorage("user_name") private var userName = ""
    @AppStorage("user_email") private var userEmail = ""
    @AppStorage("membership_plan") private var membershipPlan = ""
    @AppStorage("pro_welcomed") private var proWelcomed = false
    @AppStorage("tab_inbox_visible") private var tabInbox = true
    @AppStorage("tab_habits_visible") private var tabHabits = true
    @AppStorage("tab_calendar_visible") private var tabCalendar = false
    @AppStorage("tab_notes_visible") private var tabNotes = true
    @State private var showMembershipPlans = false
    @State private var showProfile = false
    @State private var showAppearance = false
    @State private var showCalendars = false
    @State private var showLayout = false
    @State private var showNotifications = false
    @State private var showLogoutConfirm = false
    @State private var showTrash = false
    @State private var showClearCompletedConfirm = false
    @State private var showClearCompletedFinalConfirm = false
    @State private var showReportIssue = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Evry \(v) (\(b))"
    }

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private var currentPlanLabel: String {
        if membershipPlan == "pro" { return "Member" }
        let days = MembershipAccess.daysRemaining()
        return days > 0 ? "Trial · \(days)d left" : "Trial ended"
    }

    private var calendarValueLabel: String {
        guard calendarService.isAuthorized else { return "Not connected" }
        let n = calendarService.allCalendarInfos.count
        return n == 1 ? "1 calendar" : "\(n) calendars"
    }

    private var clearCompletedCount: Int {
        allTasks.filter { $0.completed && !$0.isTrashed }.count
    }

    private var layoutValueLabel: String {
        // Profile is always shown; count it alongside the toggleable tabs.
        let count = [tabInbox, tabHabits, tabCalendar, tabNotes].filter { $0 }.count + 1
        return "\(count) tabs"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    sectionLabel("Account")

                    settingsNavRow(
                        icon: "person",
                        label: "Profile", value: userName.isEmpty ? nil : userName
                    ) { showProfile = true }

                    sectionLabel("Settings")

                    settingsNavRow(
                        icon: "paintbrush.pointed",
                        label: "Appearance", value: appearance.themeMode.label
                    ) { showAppearance = true }

                    settingsNavRow(
                        icon: "star",
                        label: "Membership", value: currentPlanLabel
                    ) { showMembershipPlans = true }

                    settingsNavRow(
                        icon: "bell",
                        label: "Notifications", value: nil
                    ) { showNotifications = true }

                    settingsNavRow(
                        icon: "calendar",
                        label: "Calendars", value: calendarValueLabel
                    ) { showCalendars = true }

                    settingsNavRow(
                        icon: "square.grid.2x2",
                        label: "Layout", value: layoutValueLabel
                    ) { showLayout = true }

                    settingsNavRow(
                        icon: "exclamationmark.bubble",
                        label: "Report an issue", value: nil
                    ) { showReportIssue = true }

                    sectionLabel("Data")

                    settingsNavRow(
                        icon: "trash",
                        label: "Recently deleted", value: nil
                    ) { showTrash = true }

                    VStack(spacing: 8) {
                        Button {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            withAnimation(EvryMotion.settle) {
                                showClearCompletedConfirm.toggle()
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "checkmark.circle")
                                    .font(.nunito(size: 18, weight: .semibold))
                                    .foregroundStyle(Palette.danger)
                                    .frame(width: 30, height: 30)
                                    .accessibilityHidden(true)
                                Text("Clear all completed")
                                    .font(.evryBody)
                                    .foregroundStyle(Palette.danger)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.nunito(size: 12, weight: .bold))
                                    .foregroundStyle(palette.textMuted)
                                    .rotationEffect(.degrees(showClearCompletedConfirm ? 180 : 0))
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(minHeight: EvrySpace.storeHeight)
                            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .evryField(palette)

                        // Inline confirmation, right below the button.
                        if showClearCompletedConfirm {
                            let count = allTasks.filter { $0.completed && !$0.isTrashed }.count
                            HStack(spacing: 10) {
                                Button("Cancel") {
                                    withAnimation(EvryMotion.settle) { showClearCompletedConfirm = false }
                                }
                                .buttonStyle(EvrySecondaryButtonStyle(palette: palette, fullWidth: true))

                                Button {
                                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                                    // Second, deliberate confirmation — this can't be undone.
                                    showClearCompletedFinalConfirm = true
                                } label: {
                                    Label(count > 0 ? "Delete \(count)" : "Delete", systemImage: "trash")
                                        .font(.evryLabel)
                                        .foregroundStyle(Palette.onSignal)
                                        .frame(maxWidth: .infinity, minHeight: EvrySpace.buttonHeight)
                                        .background(Palette.danger, in: Capsule())
                                        .evryShadowButton(palette)
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(PressScaleStyle(scale: 0.98))
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    // Log out
                    VStack(spacing: 8) {
                        Button { showLogoutConfirm = true } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.nunito(size: 18, weight: .semibold))
                                    .foregroundStyle(palette.primary)
                                    .frame(width: 30, height: 30)
                                    .accessibilityHidden(true)
                                Text("Log out")
                                    .font(.evryBody)
                                    .foregroundStyle(palette.text)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(minHeight: EvrySpace.storeHeight)
                            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .evryField(palette)

                        if !userEmail.isEmpty {
                            Text(userEmail)
                                .font(.nunito(size: 14))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                    .padding(.top, 12)

                    Text(appVersion)
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.textMuted)
                        .padding(.top, 8)
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
                .padding(.bottom, 20)
            }
            .background(palette.bg)
            .navigationTitle("Settings")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        // Themed confirmations (same card as the Focus Mode exit prompt), over
        // the whole sheet.
        .evryConfirm(
            isPresented: $showClearCompletedFinalConfirm,
            title: "Delete \(clearCompletedCount) completed task\(clearCompletedCount == 1 ? "" : "s")?",
            message: "This permanently removes them and can’t be undone.",
            confirmTitle: "Delete \(clearCompletedCount)"
        ) {
            for task in allTasks where task.completed && !task.isTrashed {
                TaskActions.delete(task)
            }
            withAnimation(EvryMotion.settle) { showClearCompletedConfirm = false }
        }
        .evryConfirm(
            isPresented: $showLogoutConfirm,
            title: "Log out?",
            message: "You’ll be signed out of your account on this device.",
            confirmTitle: "Log out"
        ) {
            userName = ""
            userEmail = ""
            dismiss()
        }
        .sheet(isPresented: $showProfile)         { ProfileAccountSheet() }
        .sheet(isPresented: $showAppearance)      { AppearanceSettingsView() }
        .fullScreenCover(isPresented: $showMembershipPlans, onDismiss: {
            // If the user just upgraded here, close Settings too so the root can
            // present the Pro welcome — a fullScreenCover can't layer over this
            // still-open sheet, which is why the celebration didn't play.
            if membershipPlan == "pro" && !proWelcomed { dismiss() }
        }) { MembershipPlansView() }
        .sheet(isPresented: $showCalendars)       { CalendarsSettingsView() }
        .sheet(isPresented: $showNotifications)   { NotificationsSettingsView() }
        .sheet(isPresented: $showLayout)          { LayoutSettingsView() }
        .sheet(isPresented: $showTrash)           { TrashView() }
        .sheet(isPresented: $showReportIssue) {
            ReportIssueSheet(userName: userName, userEmail: userEmail, appVersion: appVersion)
        }
    }

    // MARK: Row helpers

    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text, palette: palette)
            .padding(.horizontal, 4)
    }

    private func settingsNavRow(
        icon: String,
        label: String,
        value: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.nunito(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                Spacer()
                if let value {
                    Text(value)
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: EvrySpace.storeHeight)
            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .evryField(palette)
    }
}

// MARK: - Form styling (shared by the account sub-screens)

private extension View {
    /// Puts a system `Form` on the Evry page tone with Nunito text.
    func evryFormStyle(_ palette: Palette) -> some View {
        self
            .font(.evryBody)
            .scrollContentBackground(.hidden)
            .background(palette.bg)
    }
}

// MARK: - Mail compose wrapper

private struct MailComposeView: UIViewControllerRepresentable {
    let subject: String
    let body: String
    var onFinished: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients(["feedback@evry.app"])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinished: (MFMailComposeResult) -> Void
        init(onFinished: @escaping (MFMailComposeResult) -> Void) { self.onFinished = onFinished }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            DispatchQueue.main.async { self.onFinished(result) }
        }
    }
}

// MARK: - Report an issue sheet

private struct ReportIssueSheet: View {
    var userName: String
    var userEmail: String
    var appVersion: String

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @State private var messageText = ""
    @State private var showMailCompose = false
    @State private var showNoMailAlert = false
    @State private var submitted = false
    @FocusState private var editorFocused: Bool

    @AppStorage("feedback_send_log") private var sendLog = ""

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private var timestamps: [Date] {
        sendLog.split(separator: ",")
            .compactMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0) }
    }

    private var now: Date { Date() }
    private var last24hCount: Int { timestamps.filter { now.timeIntervalSince($0) < 86400 }.count }
    private var last30dCount: Int { timestamps.filter { now.timeIntervalSince($0) < 30 * 86400 }.count }

    private var canSend: Bool {
        last24hCount < 3 && last30dCount < 10 && !messageText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var emailBody: String {
        let name = userName.isEmpty ? "Not set" : userName
        let email = userEmail.isEmpty ? "Not set" : userEmail
        let trimmed = messageText.trimmingCharacters(in: .whitespaces)
        let device = UIDevice.current
        return "\(trimmed)\n\n---\nName: \(name)\nEmail: \(email)\nApp: \(appVersion)\niOS: \(device.systemVersion)\nDevice: \(device.model)"
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    if submitted {
                        VStack(spacing: 12) {
                            EvryMascot(size: 96, float: true)
                                .padding(.bottom, 4)
                            Text("Report sent")
                                .font(.evryH3)
                                .foregroundStyle(palette.text)
                            Text("Thanks for telling us. We’ll look into it.")
                                .font(.evryBody)
                                .foregroundStyle(palette.textSec)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Describe the issue")
                                .font(.evryLabel)
                                .foregroundStyle(palette.text)
                                .padding(.horizontal, 4)

                            ZStack(alignment: .topLeading) {
                                if messageText.isEmpty {
                                    Text("For example, what went wrong, or what you’d like to see improved…")
                                        .font(.evryBody)
                                        .foregroundStyle(palette.textPh)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                                TextEditor(text: $messageText)
                                    .font(.evryBody)
                                    .foregroundStyle(palette.text)
                                    .frame(minHeight: 140)
                                    .scrollContentBackground(.hidden)
                                    .focused($editorFocused)
                                    .accessibilityLabel("Describe the issue")
                            }
                            .evryTextField(palette, focused: editorFocused)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.nunito(size: 13, weight: .semibold))
                                .accessibilityHidden(true)
                            let remaining = max(0, 3 - last24hCount)
                            Text("\(remaining) report\(remaining == 1 ? "" : "s") left today")
                                .font(.nunito(size: 14))
                        }
                        .foregroundStyle(palette.textSec)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sent with your report")
                                .font(.evryCaption)
                                .foregroundStyle(palette.textMuted)
                            HStack(spacing: 6) {
                                Text(userName.isEmpty ? "Anonymous" : userName)
                                Text("·")
                                Text(appVersion)
                            }
                            .font(.nunito(size: 14))
                            .foregroundStyle(palette.textSec)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(palette.skyMist, in: RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))

                        if last24hCount >= 3 {
                            FieldError(message: "You’ve sent 3 reports today. Please try again tomorrow.", palette: palette)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if last30dCount >= 10 {
                            FieldError(message: "You’ve sent 10 reports this month. Please try again later.", palette: palette)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button("Send report") { sendReport() }
                            .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                            .disabled(!canSend)
                    }
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
            }
            .background(palette.bg)
            .navigationTitle("Report an issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(submitted ? "Close" : "Cancel") { dismiss() }
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .sheet(isPresented: $showMailCompose) {
            MailComposeView(subject: "Evry app feedback", body: emailBody) { result in
                showMailCompose = false
                if result == .sent {
                    recordSend()
                    withAnimation(EvryMotion.settle) { submitted = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                }
            }
            .ignoresSafeArea()
        }
        .alert("Mail isn’t set up", isPresented: $showNoMailAlert) {
            Button("OK") {}
        } message: {
            Text("Please add a Mail account in Settings, or email us at feedback@evry.app.")
        }
    }

    private func sendReport() {
        guard canSend else { return }
        if MFMailComposeViewController.canSendMail() {
            showMailCompose = true
        } else {
            showNoMailAlert = true
        }
    }

    private func recordSend() {
        var ts = timestamps.filter { now.timeIntervalSince($0) < 30 * 86400 }
        ts.append(now)
        sendLog = ts.map { String($0.timeIntervalSince1970) }.joined(separator: ",")
    }
}

// MARK: - Account navigation enum

private enum AccountScreen: Hashable {
    case changeEmail, changePassword, forgotPassword, twoFactor
}

// MARK: - Profile Account Sheet

struct ProfileAccountSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @AppStorage("user_name") private var userName = ""
    @AppStorage("user_email") private var userEmail = ""
    @AppStorage("two_factor_enabled") private var twoFactorEnabled = false

    @State private var profileImageData: Data? = nil
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var cropItem: CropImage? = nil
    @State private var confirmingDelete = false
    @State private var path: [AccountScreen] = []

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private var initials: String {
        let words = userName.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard !words.isEmpty else { return "?" }
        return words.prefix(2).compactMap { $0.first.map(String.init)?.uppercased() }.joined()
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    // Centered profile picture
                    PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                        ZStack(alignment: .bottomTrailing) {
                            Circle()
                                .fill(profileImageData != nil ? Color.clear
                                      : userName.isEmpty ? palette.skySoft
                                      : avatarColor(for: userName))
                                .frame(width: 96, height: 96)
                                .overlay {
                                    if let data = profileImageData, let img = UIImage(data: data) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .clipShape(Circle())
                                    } else {
                                        Text(initials)
                                            .font(.nunito(size: 32, weight: .heavy))
                                            .foregroundStyle(userName.isEmpty ? palette.text : Color.evryNavy)
                                    }
                                }
                            Circle()
                                .fill(palette.card)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(palette.hairline, lineWidth: 1))
                                        .overlay(
                                    Image(systemName: "camera.fill")
                                        .font(.nunito(size: 13, weight: .semibold))
                                        .foregroundStyle(palette.primary)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change profile photo")
                    .padding(.top, 12)

                    // Name field
                    accountRow(icon: "person.fill", iconBg: palette.primaryLight) {
                        TextField("Full name", text: $userName)
                            .font(.evryBody)
                            .foregroundStyle(palette.text)
                    }
                    .frame(minHeight: EvrySpace.storeHeight)
                    .evryField(palette)

                    // Email
                    Button { path.append(.changeEmail) } label: {
                        accountNavRow(
                            icon: "envelope.fill",
                            label: "Email",
                            value: userEmail.isEmpty ? "Not set" : userEmail,
                            action: "Change"
                        )
                    }
                    .buttonStyle(.plain)
                    .evryField(palette)

                    // Password
                    Button { path.append(.changePassword) } label: {
                        accountNavRow(
                            icon: "lock.fill",
                            label: "Password",
                            value: "••••••••",
                            action: "Change"
                        )
                    }
                    .buttonStyle(.plain)
                    .evryField(palette)

                    // Two-factor authentication
                    Button { path.append(.twoFactor) } label: {
                        HStack(spacing: 14) {
                            iconBadge("shield.lefthalf.filled", bg: palette.primaryLight)
                            Text("Two-factor authentication")
                                .font(.evryBody)
                                .foregroundStyle(palette.text)
                            Spacer()
                            Text(twoFactorEnabled ? "On" : "Off")
                                .font(.nunito(size: 14, weight: twoFactorEnabled ? .bold : .regular))
                                .foregroundStyle(twoFactorEnabled ? palette.text : palette.textSec)
                            Image(systemName: "chevron.right")
                                .font(.nunito(size: 12, weight: .bold))
                                .foregroundStyle(palette.textMuted)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: EvrySpace.storeHeight)
                        .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .evryField(palette)

                    // Delete account
                    Button { confirmingDelete = true } label: {
                        HStack(spacing: 14) {
                            iconBadge("trash.fill", bg: palette.skySoft, fg: Palette.danger)
                            Text("Delete account")
                                .font(.evryBody)
                                .foregroundStyle(Palette.danger)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.nunito(size: 12, weight: .bold))
                                .foregroundStyle(palette.textMuted)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(minHeight: EvrySpace.storeHeight)
                        .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .evryField(palette)
                    .padding(.top, 12)
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
            }
            .background(palette.bg)
            .navigationTitle("Profile")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .navigationDestination(for: AccountScreen.self) { screen in
                switch screen {
                case .changeEmail:    ChangeEmailView(path: $path)
                case .changePassword: ChangePasswordView(path: $path)
                case .forgotPassword: ForgotPasswordView()
                case .twoFactor:      TwoFactorView(isEnabled: $twoFactorEnabled)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .onAppear {
            profileImageData = UserDefaults.standard.data(forKey: "profile_image_data")
        }
        .onChange(of: selectedPhoto) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { cropItem = CropImage(image: img); selectedPhoto = nil }
                }
            }
        }
        .fullScreenCover(item: $cropItem) { c in
            ProfilePhotoCropper(image: c.image, palette: palette) { jpeg in
                profileImageData = jpeg
                UserDefaults.standard.set(jpeg, forKey: "profile_image_data")
            }
        }
        .evryConfirm(
            isPresented: $confirmingDelete,
            title: "Delete your account?",
            message: "This can’t be undone.",
            confirmTitle: "Delete"
        ) {
            userName = ""
            userEmail = ""
            dismiss()
        }
    }

    // MARK: Row helpers

    private func accountRow<Content: View>(
        icon: String,
        iconBg: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon, bg: iconBg)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func accountNavRow(icon: String, label: String, value: String, action: String) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon, bg: palette.primaryLight)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.nunito(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                Text(value)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
            }
            Spacer()
            Text(action)
                .font(.evrySmall)
                .foregroundStyle(palette.primary)
            Image(systemName: "chevron.right")
                .font(.nunito(size: 12, weight: .bold))
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: EvrySpace.storeHeight)
        .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
    }

    private func iconBadge(_ name: String, bg: Color, fg: Color? = nil) -> some View {
        Image(systemName: name)
            .font(.nunito(size: 18, weight: .semibold))
            .foregroundStyle(fg ?? palette.primary)
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
    }
}

// MARK: - Change Email

private struct ChangeEmailView: View {
    @Binding var path: [AccountScreen]

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @AppStorage("user_email") private var userEmail = ""

    @State private var newEmail = ""
    @State private var confirmEmail = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var success = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var canSave: Bool { !newEmail.isEmpty && !confirmEmail.isEmpty && !password.isEmpty }

    var body: some View {
        ZStack {
            Form {
                Section("New email address") {
                    TextField("New email", text: $newEmail)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Confirm new email", text: $confirmEmail)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .listRowBackground(palette.card)

                Section("Confirm it’s you") {
                    SecureField("Current password", text: $password)
                }
                .listRowBackground(palette.card)

                if !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.evrySmall)
                            .foregroundStyle(palette.text)
                    }
                    .listRowBackground(palette.card)
                }

                Section {
                    Button("Forgot password?") { path.append(.forgotPassword) }
                        .font(.evryLabel)
                        .foregroundStyle(palette.primary)
                }
                .listRowBackground(palette.card)
            }
            .evryFormStyle(palette)
            .navigationTitle("Change email")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }

            if success {
                successOverlay("Email updated", palette: palette)
            }
        }
        .animation(EvryMotion.settle, value: success)
    }

    private func save() {
        errorMessage = ""
        guard newEmail.lowercased() == confirmEmail.lowercased() else {
            errorMessage = "Those email addresses don’t match. Please enter them again."
            return
        }
        guard newEmail.contains("@"), newEmail.contains(".") else {
            errorMessage = "That email doesn’t look quite right. Please check it and try again."
            return
        }
        userEmail = newEmail.lowercased().trimmingCharacters(in: .whitespaces)
        success = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if path.last == .changeEmail { path.removeLast() }
        }
    }
}

// MARK: - Change Password

private struct ChangePasswordView: View {
    @Binding var path: [AccountScreen]

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage = ""
    @State private var success = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var canUpdate: Bool { !currentPassword.isEmpty && !newPassword.isEmpty && !confirmPassword.isEmpty }

    var body: some View {
        ZStack {
            Form {
                Section("Current password") {
                    SecureField("Current password", text: $currentPassword)
                }
                .listRowBackground(palette.card)

                Section("New password") {
                    SecureField("New password", text: $newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                }
                .listRowBackground(palette.card)

                if !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.evrySmall)
                            .foregroundStyle(palette.text)
                    }
                    .listRowBackground(palette.card)
                }

                Section {
                    Button("Forgot password?") { path.append(.forgotPassword) }
                        .font(.evryLabel)
                        .foregroundStyle(palette.primary)
                }
                .listRowBackground(palette.card)
            }
            .evryFormStyle(palette)
            .navigationTitle("Change password")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canUpdate)
                }
            }

            if success {
                successOverlay("Password updated", palette: palette)
            }
        }
        .animation(EvryMotion.settle, value: success)
    }

    private func save() {
        errorMessage = ""
        guard newPassword == confirmPassword else {
            errorMessage = "Those new passwords don’t match. Please enter them again."
            return
        }
        guard newPassword.count >= 8 else {
            errorMessage = "Please use at least 8 characters for your new password."
            return
        }
        success = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if path.last == .changePassword { path.removeLast() }
        }
    }
}

// MARK: - Forgot Password

private struct ForgotPasswordView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @AppStorage("user_email") private var userEmail = ""

    @State private var email = ""
    @State private var sent = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        Group {
            if sent {
                VStack(spacing: 20) {
                    Spacer()
                    EvryMascot(size: 96, float: true)
                    VStack(spacing: 8) {
                        Text("Check your inbox")
                            .font(.evryH3)
                            .foregroundStyle(palette.text)
                        Text("We sent a link to reset your password to:\n\(email)")
                            .font(.evryBody)
                            .foregroundStyle(palette.textSec)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .background(palette.bg.ignoresSafeArea())
            } else {
                Form {
                    Section {
                        Text("Enter the email address on your account and we’ll send you a link to reset your password.")
                            .font(.evryBody)
                            .foregroundStyle(palette.textSec)
                    }
                    .listRowBackground(palette.card)
                    Section("Email address") {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .listRowBackground(palette.card)
                }
                .evryFormStyle(palette)
                .onAppear { if email.isEmpty { email = userEmail } }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send link") { sent = true }
                            .fontWeight(.semibold)
                            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .navigationTitle("Forgot password")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Two-Factor Authentication

private struct TwoFactorView: View {
    @Binding var isEnabled: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: isEnabled ? "shield.lefthalf.filled.badge.checkmark" : "shield.lefthalf.filled")
                        .font(.nunito(size: 32))
                        .foregroundStyle(isEnabled ? Palette.success : palette.textSec)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isEnabled ? "Two-factor is on" : "Two-factor is off")
                            .font(.evryLabel)
                            .foregroundStyle(palette.text)
                        Text(isEnabled
                             ? "Your account has an extra layer of protection."
                             : "Turn it on to ask for a verification code when you sign in.")
                            .font(.nunito(size: 14))
                            .foregroundStyle(palette.textSec)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(palette.card)

            Section {
                Toggle("Use two-factor authentication", isOn: $isEnabled)
                    .tint(palette.primary)
            }
            .listRowBackground(palette.card)

            if isEnabled {
                Section("Recovery") {
                    Label(
                        "Keep your recovery codes somewhere safe, in case you lose access to your authenticator app.",
                        systemImage: "key.fill"
                    )
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textSec)
                }
                .listRowBackground(palette.card)
            }
        }
        .evryFormStyle(palette)
        .navigationTitle("Two-factor authentication")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .tint(palette.primary)
    }
}

// MARK: - Shared success overlay

private func successOverlay(_ message: String, palette: Palette) -> some View {
    ZStack {
        palette.bg.ignoresSafeArea()
        VStack(spacing: 16) {
            EvryMascot(size: 96, float: true)
            HStack(spacing: 8) {
                EvryCheck(size: 24)
                Text(message)
                    .font(.evryH3)
                    .foregroundStyle(palette.text)
            }
        }
    }
    .transition(.opacity)
}

// MARK: - Layout Settings

private struct LayoutSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @AppStorage("tab_inbox_visible") private var tabInbox = true
    @AppStorage("tab_habits_visible") private var tabHabits = true
    @AppStorage("tab_calendar_visible") private var tabCalendar = false
    @AppStorage("tab_notes_visible") private var tabNotes = true
    @AppStorage("inbox_hide_completed") private var hideCompleted = false
    @AppStorage("inbox_hide_notes") private var hideNotes = false
    @AppStorage("inbox_hide_reschedule") private var hideReschedule = false
    @AppStorage("inbox_swipe_layout") private var swipeLayout = true

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    // Profile is always present, so only the toggleable tabs count toward the
    // "at least one must stay enabled" rule.
    private var enabledCount: Int {
        [tabInbox, tabHabits, tabCalendar, tabNotes].filter { $0 }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    sectionLabel("Tabs")
                    tabRow("Inbox",    tool: .tasks,    isOn: $tabInbox)
                    tabRow("Habits",   tool: .habits,   isOn: $tabHabits)
                    tabRow("Calendar", tool: .calendar, isOn: $tabCalendar)
                    tabRow("Notes",    tool: .notes,    isOn: $tabNotes)
                    Text("Keep at least one tab on. Profile is always here.")
                        .font(.nunito(size: 14))
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)

                    sectionLabel("Inbox")
                        .padding(.top, 8)
                    inboxRow("Hide completed tasks", icon: "eye.slash", isOn: $hideCompleted)
                    inboxRow("Hide notes", icon: "note.text.badge.plus", isOn: $hideNotes)
                    inboxRow("Hide reschedule button", icon: "calendar.badge.minus", isOn: $hideReschedule)
                    // Swipe between Schedule and Tasks (and right for the menu),
                    // instead of the Tasks / Schedule selector.
                    inboxRow("Swipe navigation", icon: "hand.draw", isOn: $swipeLayout)
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
            }
            .background(palette.bg)
            .navigationTitle("Layout")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }

    private func tabRow(_ name: String, tool: EvryTool, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            ToolIcon(tool: tool, tile: 32, palette: palette)
            Text(name)
                .font(.evryBody)
                .foregroundStyle(palette.text)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                set: { newVal in
                    if !newVal && enabledCount <= 1 { return }
                    isOn.wrappedValue = newVal
                }
            ))
            .labelsHidden()
            .tint(palette.primary)
            .accessibilityLabel(name)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: EvrySpace.storeHeight)
        .evryField(palette)
    }

    private func inboxRow(_ name: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.nunito(size: 18, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? palette.primary : palette.textSec)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text(name)
                .font(.evryBody)
                .foregroundStyle(palette.text)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(palette.primary)
                .accessibilityLabel(name)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: EvrySpace.storeHeight)
        .evryField(palette)
    }

    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text, palette: palette)
            .padding(.horizontal, 4)
    }
}

// MARK: - Notifications Settings

private struct NotificationsSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @AppStorage("notif_task_reminders")    private var taskReminders = true
    @AppStorage("notif_daily_digest")      private var dailyDigest   = false
    @AppStorage("notif_weekly_summary")    private var weeklySummary = false
    @AppStorage("notif_default_reminder_hour") private var defaultReminderHour = 9
    @AppStorage("notif_digest_hour")       private var digestHour    = 8
    @AppStorage("notif_digest_minute")     private var digestMinute  = 0

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private var defaultReminderDate: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: defaultReminderHour, minute: 0, second: 0, of: Date()) ?? Date()
            },
            set: {
                defaultReminderHour = Calendar.current.component(.hour, from: $0)
            }
        )
    }

    private var digestDate: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: digestHour, minute: digestMinute, second: 0, of: Date()) ?? Date()
            },
            set: {
                digestHour   = Calendar.current.component(.hour, from: $0)
                digestMinute = Calendar.current.component(.minute, from: $0)
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    sectionLabel("Reminders")

                    notifRow("Task reminders", icon: "bell.fill",
                             subtitle: "A kind nudge before tasks are due", isOn: $taskReminders)

                    if taskReminders {
                        timePickerRow(
                            icon: "clock.fill",
                            label: "Default reminder time",
                            subtitle: "Used when a task has no specific time",
                            selection: defaultReminderDate
                        )
                    }

                    notifRow("Daily digest", icon: "sun.max.fill",
                             subtitle: "A morning look at your day’s tasks", isOn: $dailyDigest)

                    if dailyDigest {
                        timePickerRow(
                            icon: "clock.fill",
                            label: "Digest time",
                            subtitle: "When to receive your daily summary",
                            selection: digestDate
                        )
                    }

                    notifRow("Weekly summary", icon: "chart.bar.fill",
                             subtitle: "A look back at your week", isOn: $weeklySummary)
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
                .animation(EvryMotion.settle, value: taskReminders)
                .animation(EvryMotion.settle, value: dailyDigest)
            }
            .background(palette.bg)
            .navigationTitle("Notifications")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }

    private func notifRow(_ name: String, icon: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.nunito(size: 18, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? palette.primary : palette.textSec)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                Text(subtitle)
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textSec)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(palette.primary)
                .accessibilityLabel(name)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: EvrySpace.storeHeight)
        .evryField(palette)
    }

    private func timePickerRow(icon: String, label: String, subtitle: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.nunito(size: 18, weight: .semibold))
                .foregroundStyle(palette.primary)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.evryBody)
                    .foregroundStyle(palette.text)
                Text(subtitle)
                    .font(.nunito(size: 14))
                    .foregroundStyle(palette.textSec)
            }
            Spacer()
            DatePicker(label, selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .tint(palette.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: EvrySpace.storeHeight)
        .background(palette.skyMist, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
            .strokeBorder(palette.hairline, lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text, palette: palette)
            .padding(.horizontal, 4)
    }
}

// MARK: - Appearance Settings

private struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        @Bindable var appearance = appearance
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    sectionLabel("Theme")

                    Picker("Theme", selection: $appearance.themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .evryCard(palette, shadow: false)
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
            }
            .background(palette.bg)
            .navigationTitle("Appearance")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
    }

    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text, palette: palette)
            .padding(.horizontal, 4)
    }
}

// MARK: - Calendars Settings

private struct CalendarsSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(CalendarService.self) private var calendarService
    @Environment(\.dismiss) private var dismiss

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !calendarService.isAuthorized {
                        VStack(spacing: 20) {
                            ToolIcon(tool: .calendar, tile: 48, palette: palette)
                                .padding(.top, 40)
                            Text(calendarService.authStatusLabel)
                                .font(.evryBody)
                                .foregroundStyle(palette.textSec)
                                .multilineTextAlignment(.center)
                            if calendarService.accessDenied {
                                Button("Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
                            } else {
                                Button("Connect your calendar") {
                                    Task { await calendarService.requestAccess() }
                                }
                                .buttonStyle(EvryPrimaryButtonStyle(palette: palette))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else if calendarService.allCalendarInfos.isEmpty {
                        EmptyStateView(
                            icon: "calendar",
                            title: "No calendars yet",
                            text: "Add a calendar on your iPhone and it’ll show up here.",
                            palette: palette
                        )
                        .padding(.top, 28)
                    } else {
                        sectionLabel("Calendars")

                        VStack(spacing: 0) {
                            ForEach(Array(calendarService.allCalendarInfos.enumerated()), id: \.element.id) { i, info in
                                if i > 0 {
                                    paletteDivider(palette).padding(.leading, 56)
                                }
                                Toggle(isOn: Binding(
                                    get: { calendarService.selectedCalendarIDs.contains(info.id) },
                                    set: { _ in calendarService.toggleCalendar(info.id) }
                                )) {
                                    HStack(spacing: 12) {
                                        // The calendar's own colour, kept only as a
                                        // tiny dot — it's the user's data.
                                        Circle()
                                            .fill(info.color)
                                            .frame(width: 10, height: 10)
                                            .frame(width: 28, height: 28)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(info.title)
                                                .font(.evryBody)
                                                .foregroundStyle(palette.text)
                                            Text(info.sourceTitle)
                                                .font(.nunito(size: 14))
                                                .foregroundStyle(palette.textSec)
                                        }
                                    }
                                }
                                .tint(palette.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(minHeight: EvrySpace.storeHeight)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        calendarService.hideCalendar(info.id)
                                    } label: {
                                        Label("Remove from list", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
                        .evryCard(palette, shadow: false)
                    }
                }
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.vertical, 20)
            }
            .background(palette.bg)
            .navigationTitle("Calendars")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
    }

    private func sectionLabel(_ text: String) -> some View {
        SectionLabel(text: text, palette: palette)
            .padding(.horizontal, 4)
    }
}

// MARK: - Global Search Sheet

struct GlobalSearchSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectNavigationState.self) private var projectNavState

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    @State private var searchText = ""
    @FocusState private var focused: Bool

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed } }

    private var results: [TaskItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return tasks.filter {
            $0.title.lowercased().contains(q) ||
            $0.notes.lowercased().contains(q) ||
            $0.tags.contains(where: { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.nunito(size: 15, weight: .semibold))
                        .foregroundStyle(palette.textSec)
                        .accessibilityHidden(true)
                    TextField("Tasks, notes, projects, tags…", text: $searchText)
                        .font(.evryBody)
                        .foregroundStyle(palette.text)
                        .autocorrectionDisabled()
                        .focused($focused)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.textMuted)
                                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                        .padding(.vertical, -12)
                        .padding(.trailing, -12)
                    }
                }
                .evryTextField(palette, focused: focused)
                .padding(.horizontal, EvrySpace.gutter)
                .padding(.top, 16)
                .padding(.bottom, 12)

                paletteDivider(palette)

                ScrollView {
                    VStack(spacing: 0) {
                        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: "Search everything",
                                text: "Find tasks, notes, projects and tags in one place.",
                                palette: palette
                            )
                            .padding(.top, 28)
                        } else if results.isEmpty {
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: "Nothing matches “\(searchText.trimmingCharacters(in: .whitespaces))”",
                                text: "Try a different word, or check the spelling.",
                                palette: palette
                            )
                            .padding(.top, 28)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                if !results.isEmpty {
                                    SectionLabel(text: "Tasks and notes", palette: palette)
                                        .padding(.horizontal, 20)

                                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                                        .font(.nunito(size: 13))
                                        .foregroundStyle(palette.textMuted)
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 8)

                                    ForEach(results) { task in
                                        SearchResultRow(task: task, palette: palette, query: searchText) {
                                            // Go to the Inbox, on the task's own day, and
                                            // spotlight the task itself.
                                            projectNavState.focusTaskID = task.uid
                                            projectNavState.requestedTab = .inbox
                                            dismiss()
                                        }
                                        .padding(.horizontal, EvrySpace.gutter)
                                        .padding(.bottom, 8)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .background(palette.bg)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
            }
        }
        .tint(palette.primary)
    }
}

private struct SearchResultRow: View {
    let task: TaskItem
    let palette: Palette
    let query: String
    var onTap: (() -> Void)? = nil

    /// Builds an AttributedString with every occurrence of `query` bolded and tinted.
    private func highlighted(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return attr }
        let lower = text.lowercased()
        var searchFrom = lower.startIndex
        while let range = lower.range(of: q, range: searchFrom..<lower.endIndex) {
            let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let end   = lower.distance(from: lower.startIndex, to: range.upperBound)
            let attrStart = attr.characters.index(attr.startIndex, offsetBy: start)
            let attrEnd   = attr.characters.index(attr.startIndex, offsetBy: end)
            attr[attrStart..<attrEnd].foregroundColor = palette.primary
            attr[attrStart..<attrEnd].font = Font.nunito(size: 15, weight: .heavy)
            searchFrom = range.upperBound
        }
        return attr
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if task.completed {
                        EvryCheck(size: 22)
                    } else {
                        Circle()
                            .strokeBorder(palette.dark ? Color.evryWhite35 : .evryNavy28, lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                    }
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(task.title))
                        .font(.nunito(size: 15, weight: .semibold))
                        .foregroundStyle(task.completed ? palette.textSec : palette.text)
                        .strikethrough(task.completed, color: palette.textMuted)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let due = task.dueDate {
                            let overdue = isOverdueDate(due) && !task.completed
                            HStack(spacing: 3) {
                                if overdue {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .accessibilityHidden(true)
                                }
                                Text(due.formatted(.dateTime.month(.abbreviated).day()))
                            }
                            .font(.nunito(size: 13, weight: overdue ? .bold : .regular))
                            .foregroundStyle(overdue ? palette.text : palette.textSec)
                        }
                        if !task.tags.isEmpty {
                            Text(task.tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
                                .font(.nunito(size: 13))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: EvrySpace.storeHeight)
            .evryField(palette)
            .contentShape(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityValue(task.completed ? "Done" : "")
    }
}

// MARK: - Trash View

struct TrashView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \TaskItem.deletedAt, order: .reverse) private var allTasks: [TaskItem]

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var trashedTasks: [TaskItem] { allTasks.filter { $0.deletedAt != nil } }
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Group {
                if trashedTasks.isEmpty {
                    VStack {
                        Spacer()
                        EmptyStateView(
                            icon: "trash",
                            title: "Nothing here",
                            text: "Deleted tasks stay here for 30 days, in case you change your mind.",
                            palette: palette
                        )
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(trashedTasks) { task in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.title)
                                            .font(.nunito(size: 16, weight: .semibold))
                                            .foregroundStyle(palette.text)
                                            .lineLimit(1)
                                        if let deleted = task.deletedAt {
                                            let days = Calendar.current.dateComponents([.day], from: deleted, to: Date()).day ?? 0
                                            let remaining = max(0, 30 - days)
                                            Text("Deleted \(deleted.formatted(.relative(presentation: .named))) · \(remaining)d left")
                                                .font(.nunito(size: 13))
                                                .foregroundStyle(palette.textSec)
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        withAnimation(EvryMotion.settle) { TaskActions.restore(task) }
                                    } label: {
                                        Text("Restore")
                                            .font(.evrySmall)
                                            .padding(.horizontal, 14)
                                            .frame(minHeight: 36)
                                            .evryButtonFace(palette, in: Capsule())
                                            .frame(minHeight: EvrySpace.tap)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PressScaleStyle())
                                    .accessibilityLabel("Restore \(task.title)")
                                }
                                .listRowBackground(palette.card)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        context.delete(task)
                                    } label: {
                                        Label("Delete forever", systemImage: "trash.fill")
                                    }
                                }
                            }
                        } footer: {
                            Text("Tasks are permanently deleted after 30 days.")
                                .font(.nunito(size: 13))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Delete all") { confirmDeleteAll = true }
                            .font(.evrySmall)
                            .foregroundStyle(Palette.danger)
                        }
                    }
                }
            }
            .background(palette.bg)
            .navigationTitle("Recently deleted")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
        .evryConfirm(
            isPresented: $confirmDeleteAll,
            title: "Delete all \(trashedTasks.count) task\(trashedTasks.count == 1 ? "" : "s")?",
            message: "They’ll be permanently removed. This can’t be undone.",
            confirmTitle: "Delete all"
        ) {
            withAnimation { for task in trashedTasks { context.delete(task) } }
        }
    }
}

// MARK: - Profile photo cropper

/// Identifiable wrapper so a picked image can drive a `.fullScreenCover(item:)`.
struct CropImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// A circular crop/zoom editor: pan and pinch the image within a round window,
/// then confirm to save it as the profile picture.
struct ProfilePhotoCropper: View {
    let image: UIImage
    let palette: Palette
    /// Called with the cropped, downscaled JPEG when the user confirms.
    var onDone: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The screen's scale, from the environment (UIScreen.main is deprecated).
    @Environment(\.displayScale) private var displayScale

    // Committed transform, plus live gesture deltas.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    /// On-screen diameter of the crop window.
    private let side: CGFloat = 300

    private var effectiveScale: CGFloat { scale * pinch }
    private var effectiveOffset: CGSize {
        CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
    }

    var body: some View {
        ZStack {
            Color.evryNavy.ignoresSafeArea()

            VStack(spacing: 28) {
                Text("Move and zoom")
                    .font(.evryTitle)
                    .foregroundStyle(Color.evryWhite)

                // The crop window: the image fills a square, pannable/zoomable,
                // with a circular mask cut out of a dimming overlay to show the
                // area that becomes the avatar.
                cropContent(scale: effectiveScale, offset: effectiveOffset)
                    .frame(width: side, height: side)
                    .clipped()
                    .overlay(
                        Rectangle()
                            .fill(Color.evryNavy.opacity(0.6))
                            .frame(width: side, height: side)
                            .reverseMask { Circle().frame(width: side, height: side) }
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        Circle().strokeBorder(Color.evrySky, lineWidth: 2)
                            .frame(width: side, height: side)
                            .allowsHitTesting(false)
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .updating($drag) { v, state, _ in state = v.translation }
                            .onEnded { v in
                                offset.width += v.translation.width
                                offset.height += v.translation.height
                            }
                            .simultaneously(with:
                                MagnificationGesture()
                                    .updating($pinch) { v, state, _ in state = v }
                                    .onEnded { v in scale = min(4, max(1, scale * v)) }
                            )
                    )

                // On navy: ghost-light for the alternative, sky for the main action.
                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(EvryGhostLightButtonStyle(fullWidth: true))

                    Button("Use photo") {
                        if let jpeg = renderCrop() { onDone(jpeg) }
                        dismiss()
                    }
                    .buttonStyle(EvrySkyButtonStyle(fullWidth: true))
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
            }
        }
    }

    /// The zoom/pan image layer, sized to fill the square crop window.
    private func cropContent(scale: CGFloat, offset: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: side, height: side)
    }

    /// Snapshots the crop window (square, so the avatar's circular clip shows the
    /// centered region) and downscales it to a profile-sized JPEG.
    @MainActor private func renderCrop() -> Data? {
        let content = cropContent(scale: scale, offset: offset)
            .frame(width: side, height: side)
            .clipped()
        let renderer = ImageRenderer(content: content)
        renderer.scale = displayScale
        guard let rendered = renderer.uiImage else { return nil }
        let thumb = rendered.preparingThumbnail(of: CGSize(width: 300, height: 300)) ?? rendered
        return thumb.jpegData(compressionQuality: 0.8)
    }
}

private extension View {
    /// Punches the given shape out of the view (used for the crop dimming overlay).
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}

// MARK: - Level-up burst

/// The level-up flourish behind the profile ring: two sky shockwaves and a
/// ring of sparkles flung outward, all fading as they go.
private struct LevelUpBurst: View {
    let trigger: Int

    @State private var progress: Double = 0
    @State private var visible = false

    private let sparkles = 10

    var body: some View {
        ZStack {
            if visible {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .stroke(Color.evrySky, lineWidth: i == 0 ? 6 : 3)
                        .frame(width: 162, height: 162)
                        .scaleEffect(1 + progress * (i == 0 ? 0.45 : 0.75))
                        .opacity(1 - progress)
                }
                ForEach(0..<sparkles, id: \.self) { i in
                    let angle = Double(i) / Double(sparkles) * 2 * .pi
                    let radius = 86 + progress * 58
                    Image(systemName: i.isMultiple(of: 2) ? "sparkle" : "star.fill")
                        .font(.system(size: i.isMultiple(of: 2) ? 18 : 10, weight: .bold))
                        .foregroundStyle(i.isMultiple(of: 3) ? Color.evryNavy : Color.evrySky)
                        .scaleEffect(0.4 + progress * 0.8)
                        .rotationEffect(.degrees(progress * 90))
                        .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                        .opacity(1 - progress)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                progress = 0
                visible = true
            }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.95)) { progress = 1 } completion: {
                    visible = false
                    progress = 0
                }
            }
        }
    }
}
