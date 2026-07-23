//
//  ProfileView.swift
//  Evry
//
//  Profile tab — brand logo, profile card (avatar/name/streak), collapsible
//  3x3 analytics grid, week chart and settings sheet, ported from
//  profileTab.js.
//

import SwiftUI
import SwiftData

private let avatarColors: [Color] = [
    Color(hex: 0x6366F1), Color(hex: 0x8B5CF6), Color(hex: 0xEC4899),
    Color(hex: 0xF97316), Color(hex: 0x22C55E), Color(hex: 0x0EA5E9),
]

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

    @Environment(PomodoroModel.self) private var pomodoro
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @Query private var projects: [Project]

    @AppStorage("user_name") private var userName = ""
    @AppStorage("app_first_used") private var firstUsed = ""
    @State private var analyticsOpen = false
    @State private var showSettings = false
    @State private var showPomodoro = false

    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed } }
    private var stats: TaskStats { computeStats(tasks) }

    private var initials: String {
        let words = userName.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard !words.isEmpty else { return "?" }
        return words.prefix(2).compactMap { $0.first.map(String.init)?.uppercased() }.joined()
    }

    private var joinedLabel: String {
        if firstUsed.isEmpty {
            firstUsed = ISO8601DateFormatter().string(from: Date())
        }
        let date = ISO8601DateFormatter().date(from: firstUsed) ?? Date()
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("TextLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 40)

                profileCard
                analyticsSection
                activitySection
                focusTrigger
                pomodoroTrigger
            }
            .padding(20)
            .padding(.bottom, 110)
        }
        .background(palette.bg)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $showPomodoro) {
            PomodoroView(onStart: onEnterFocusMode)
        }
    }

    // MARK: Profile card

    private var profileCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(userName.isEmpty ? palette.border : avatarColor(for: userName))
                Text(initials)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(userName.isEmpty ? "Your name" : userName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(stats.streak > 0 ? "🔥 \(stats.streak)-day streak" : "Complete a task to start a streak!")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
                Text("Member since \(joinedLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textPh)
            }

            Spacer()

            RoundIconButton(systemName: "gearshape", palette: palette) {
                showSettings = true
            }
        }
        .padding(18)
        .evryCard(palette, cornerRadius: 20)
    }

    // MARK: Analytics

    private var analyticsSection: some View {
        let completionRate = stats.total > 0 ? Int((Double(stats.totalDone) / Double(stats.total) * 100).rounded()) : 0
        let overdueCount = tasks.filter { !$0.completed && isOverdueDate($0.dueDate) }.count
        let today = startOfDay(Date())
        let weekEnd = addDays(Date(), 7)
        let dueThisWeek = tasks.filter { t in
            guard !t.completed, let d = t.dueDate else { return false }
            let day = startOfDay(d)
            return day >= today && day <= weekEnd
        }.count
        let activeProjects = projects.filter { p in
            let projTasks = (p.tasks ?? []).filter { !$0.isTrashed && !$0.isNote }
            return projTasks.isEmpty || projTasks.contains { !$0.completed }
        }.count

        return VStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    analyticsOpen.toggle()
                }
            } label: {
                HStack {
                    Label("Analytics", systemImage: "chart.bar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.textSec)
                        .rotationEffect(.degrees(analyticsOpen ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1.5))
            }
            .buttonStyle(.plain)

            if analyticsOpen {
                statsGrid(
                    completionRate: completionRate,
                    overdueCount: overdueCount,
                    dueThisWeek: dueThisWeek,
                    activeProjects: activeProjects
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func statsGrid(completionRate: Int, overdueCount: Int, dueThisWeek: Int, activeProjects: Int) -> some View {
        let cells: [(String, String, String, Bool)] = [
            ("\(stats.todayDone)", "/\(stats.todayTotal)", "Today's tasks", false),
            ("\(stats.totalDone)", "", "All-time done", false),
            ("\(stats.streak)", "", "Day streak 🔥", false),
            ("\(stats.longestStreak)", "", "Best streak", false),
            ("\(completionRate)", "%", "Completion rate", false),
            ("\(stats.total)", "", "Total tasks", false),
            ("\(overdueCount)", "", "Overdue", overdueCount > 0),
            ("\(dueThisWeek)", "", "Due this week", false),
            ("\(activeProjects)", "", "Active projects", false),
        ]

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(cell.0)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(cell.3 ? Palette.danger : palette.text)
                        if !cell.1.isEmpty {
                            Text(cell.1)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                    Text(cell.2)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.textSec)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .overlay(Rectangle().strokeBorder(palette.border.opacity(0.6), lineWidth: 0.5))
            }
        }
        .evryCard(palette, cornerRadius: 20)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Activity (week chart)

    private var activitySection: some View {
        let maxCount = max(1, stats.weekData.map(\.count).max() ?? 1)
        let narrowFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "EEEEE"
            return f
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(palette.textSec)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                Text("LAST 7 DAYS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.textSec)

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(stats.weekData) { day in
                        VStack(spacing: 5) {
                            Spacer(minLength: 0)
                            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                                .fill(day.isToday ? palette.primary : palette.border)
                                .frame(height: max(2, CGFloat(day.count) / CGFloat(maxCount) * 52 + (day.count > 0 ? 4 : 0)))
                            Text(narrowFmt.string(from: day.date))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.textSec)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 80)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .evryCard(palette, cornerRadius: 20)
        }
    }

    // MARK: Focus + Pomodoro triggers

    private var focusTrigger: some View {
        Button(action: onEnterFocusMode) {
            HStack(spacing: 12) {
                Image(systemName: "safari")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .frame(width: 40, height: 40)
                    .background(palette.primaryLight, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus Mode")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text("Just the next task — nothing else")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.textSec)
                }
                Spacer()
            }
            .padding(14)
            .evryCard(palette)
        }
        .buttonStyle(.plain)
    }

    private var pomodoroTrigger: some View {
        Button {
            showPomodoro = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .frame(width: 40, height: 40)
                    .background(palette.primaryLight, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pomodoro")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.text)
                    Text(pomodoro.running
                         ? "\(pomodoro.phase.statusLabel) — \(pomodoro.timeLabel)"
                         : "Timed focus sessions with breaks")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.textSec)
                }
                Spacer()
            }
            .padding(14)
            .evryCard(palette)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings sheet

struct SettingsSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @AppStorage("user_name") private var userName = ""
    @State private var confirmingErase = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        @Bindable var appearance = appearance
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Your name", text: $userName)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance.themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accent color")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSec)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(AccentColorTheme.all) { accent in
                                Button {
                                    appearance.accentKey = accent.key
                                } label: {
                                    VStack(spacing: 4) {
                                        Circle()
                                            .fill(accent.primary)
                                            .frame(width: 34, height: 34)
                                            .overlay {
                                                if appearance.accentKey == accent.key {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 13, weight: .bold))
                                                        .foregroundStyle(accent.onPrimary)
                                                }
                                            }
                                        Text(accent.label)
                                            .font(.system(size: 10))
                                            .foregroundStyle(palette.textSec)
                                    }
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Data") {
                    Button("Erase all data", role: .destructive) {
                        confirmingErase = true
                    }
                }
            }
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
            .confirmationDialog(
                "Erase all tasks and projects? This can't be undone.",
                isPresented: $confirmingErase,
                titleVisibility: .visible
            ) {
                Button("Erase everything", role: .destructive) {
                    try? context.delete(model: TaskItem.self)
                    try? context.delete(model: Project.self)
                }
            }
        }
        .tint(palette.primary)
    }
}
