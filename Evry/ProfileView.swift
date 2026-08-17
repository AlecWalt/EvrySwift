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

    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    @Environment(\.requestReview) private var requestReview
    @Environment(TourCoordinator.self) private var tourCoordinator

    @AppStorage("user_name") private var userName = ""
    @AppStorage("app_first_used") private var firstUsed = ""
    @AppStorage("membership_plan") private var membershipPlan = ""
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var profileImageData: Data? = nil
    @State private var analyticsOpen = false
    @State private var showSettings = false
    @State private var showSetupFlow = false
    @State private var showMembershipPromo = false
    @State private var showGlobalSearch = false
    @State private var showAccomplishments = false

    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed } }
    private var stats: TaskStats { computeStats(tasks) }

    private var todayCompletedTasks: [TaskItem] {
        let cal = Calendar.current
        return tasks.filter { t in
            t.completed && !t.isNote &&
            (t.completedAt.map { cal.isDateInToday($0) } ?? false)
        }
    }

    private var todaySummary: String? { AccomplishmentsStore.summary(for: Date()) }

    private var initials: String {
        let words = userName.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard !words.isEmpty else { return "?" }
        return words.prefix(2).compactMap { $0.first.map(String.init)?.uppercased() }.joined()
    }

    private var joinedLabel: String {
        let date = profileISO8601.date(from: firstUsed) ?? Date()
        return date.formatted(.dateTime.month(.abbreviated).year())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("TextLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 40)

                // Global search bar
                Button { showGlobalSearch = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.textSec)
                        Text("Search all tasks, notes, projects…")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.textPh)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .evryField(palette)
                }
                .buttonStyle(.plain)

                profileCard
                if membershipPlan != "pro" {
                    upgradeCard
                }
                analyticsSection
                activitySection
                developerSection
            }
            .padding(20)
            .padding(.bottom, 110)
        }
        .background(palette.bg)
        .onAppear {
            profileImageData = UserDefaults.standard.data(forKey: "profile_image_data")
            if firstUsed.isEmpty {
                firstUsed = profileISO8601.string(from: Date())
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let thumb = img.preparingThumbnail(of: CGSize(width: 300, height: 300)),
                   let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                    profileImageData = jpeg
                    UserDefaults.standard.set(jpeg, forKey: "profile_image_data")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .fullScreenCover(isPresented: $showSetupFlow) { SetupFlowView() }
        .sheet(isPresented: $showMembershipPromo) { MembershipPromoView() }
        .sheet(isPresented: $showGlobalSearch) { GlobalSearchSheet() }
        .sheet(isPresented: $showAccomplishments) {
            AccomplishmentsView(completedTasks: todayCompletedTasks, date: Date())
        }
    }

    // MARK: Upgrade card

    private var upgradeCard: some View {
        Button { showMembershipPromo = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(palette.primaryLight)
                        .frame(width: 46, height: 46)
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(palette.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade to Pro")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text("Timeline, Calendar, Cloud Sync & more")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primary)
            }
            .padding(16)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(palette.primary.opacity(0.35), lineWidth: 1.5)
            )
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: Profile card

    private var profileCard: some View {
        profileCardBody
            // The accomplishments bubble hangs off the bottom edge, attached to
            // the card. Reserve room below so it doesn't crowd the next card.
            .overlay(alignment: .bottom) {
                accomplishmentsBubble
                    .offset(y: 16)
            }
            .padding(.bottom, 22)
            .zIndex(1)
    }

    private var profileCardBody: some View {
        HStack(spacing: 16) {
            PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                ZStack {
                    Circle()
                        .fill(profileImageData != nil ? Color.clear : (userName.isEmpty ? palette.border : avatarColor(for: userName)))
                    if let data = profileImageData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    } else {
                        Text(initials)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Circle()
                        .fill(palette.primary)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(palette.onPrimary)
                        )
                        .offset(x: 20, y: 20)
                }
                .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)

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
        .evryCard(palette, cornerRadius: 28)
    }

    // MARK: Analytics

    private var analyticsSection: some View {
        let overdueCount = tasks.filter { !$0.completed && isOverdueDate($0.dueDate) }.count
        let today = startOfDay(Date())
        let weekEnd = addDays(Date(), 7)
        let dueThisWeek = tasks.filter { t in
            guard !t.completed, let d = t.dueDate else { return false }
            let day = startOfDay(d)
            return day >= today && day <= weekEnd
        }.count
        let activeTasks = tasks.filter { !$0.completed && !$0.isNote }.count

        return VStack(alignment: .leading, spacing: 8) {
            Text("ANALYTICS")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(palette.textSec)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        analyticsOpen.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.primary)
                            .frame(width: 32, height: 32)
                            .background(palette.primaryLight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(stats.totalDone) tasks completed")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.text)
                            Text(stats.streak > 0 ? "\(stats.streak)-day streak 🔥" : "Tap to see your stats")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSec)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(palette.textSec)
                            .rotationEffect(.degrees(analyticsOpen ? 180 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if analyticsOpen {
                    Divider()
                        .background(palette.border)
                    statsGrid(
                        overdueCount: overdueCount,
                        dueThisWeek: dueThisWeek,
                        activeTasks: activeTasks
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .evryCard(palette, cornerRadius: 28)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private func statsGrid(overdueCount: Int, dueThisWeek: Int, activeTasks: Int) -> some View {
        let cells: [(String, String, String, Bool)] = [
            ("\(stats.todayDone)", "/\(stats.todayTotal)", "Today's tasks", false),
            ("\(stats.weekDone)", "", "This week", false),
            ("\(stats.monthDone)", "", "This month", false),
            ("\(stats.totalDone)", "", "All-time done", false),
            ("\(stats.streak)", "", "Day streak 🔥", false),
            ("\(stats.longestStreak)", "", "Best streak", false),
            ("\(overdueCount)", "", "Overdue", overdueCount > 0),
            ("\(dueThisWeek)", "", "Due this week", false),
            ("\(activeTasks)", "", "Active tasks", false),
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
    }

    // MARK: Activity (week chart)

    private var activitySection: some View {
        let maxCount = max(1, stats.weekData.map(\.count).max() ?? 1)

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
                            Text(narrowDateFormatter.string(from: day.date))
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
            .evryCard(palette, cornerRadius: 28)
        }
    }

    // MARK: Accomplishments

    /// Very short line shown in the bubble — the AI one-liner if present,
    /// otherwise a simple completed-count.
    private var accomplishmentsBubbleText: String {
        if let summary = todaySummary, !summary.isEmpty { return summary }
        let n = todayCompletedTasks.count
        return "\(n) task\(n == 1 ? "" : "s") done today"
    }

    /// Small pill hanging off the bottom of the profile card.
    private var accomplishmentsBubble: some View {
        Button { showAccomplishments = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.primary)
                Text(accomplishmentsBubbleText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.textSec)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        }
        .buttonStyle(PressScaleStyle())
        .padding(.horizontal, 20)
    }

    // MARK: Developer section

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEVELOPER")
                .font(.system(size: 12, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(palette.textSec)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                devButton("Report an Issue") {
                    if let url = URL(string: "mailto:EvryToDo@gmail.com?subject=Evry%20Issue%20Report") {
                        UIApplication.shared.open(url)
                    }
                }
                Divider().background(palette.border)
                devButton("Preview setup flow") {
                    showSetupFlow = true
                }
                Divider().background(palette.border)
                devButton("Test notification (fires in 5 s)") {
                    NotificationService.scheduleTest()
                }
                Divider().background(palette.border)
                devButton("Preview membership promo") {
                    showMembershipPromo = true
                }
                Divider().background(palette.border)
                devButton("Preview review popup") {
                    requestReview()
                }
            }
            .evryCard(palette, cornerRadius: 24)
        }
    }

    private func devButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textPh)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
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
    @AppStorage("tab_inbox_visible") private var tabInbox = true
    @AppStorage("tab_calendar_visible") private var tabCalendar = true
    @AppStorage("tab_notes_visible") private var tabNotes = true
    @AppStorage("tab_profile_visible") private var tabProfile = true
    @State private var showMembershipPlans = false
    @State private var showProfile = false
    @State private var showAppearance = false
    @State private var showCalendars = false
    @State private var showLayout = false
    @State private var showNotifications = false
    @State private var showLogoutConfirm = false
    @State private var showTrash = false
    @State private var showClearCompletedConfirm = false
    @State private var showReportIssue = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Evry \(v) (\(b))"
    }

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    private var currentPlanLabel: String {
        switch membershipPlan {
        case "lite": return "Lite"
        case "pro":  return "Pro"
        default:     return "Free"
        }
    }

    private var calendarValueLabel: String {
        guard calendarService.isAuthorized else { return "Not connected" }
        let n = calendarService.allCalendarInfos.count
        return n == 1 ? "1 calendar" : "\(n) calendars"
    }

    private var layoutValueLabel: String {
        let count = [tabInbox, tabCalendar, tabNotes, tabProfile].filter { $0 }.count
        return "\(count) tabs"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    sectionLabel("ACCOUNT")

                    settingsNavRow(
                        icon: "person.fill",
                        label: "Profile", value: userName.isEmpty ? nil : userName
                    ) { showProfile = true }

                    sectionLabel("SETTINGS")

                    settingsNavRow(
                        icon: "paintbrush.pointed.fill",
                        label: "Appearance", value: appearance.themeMode.label
                    ) { showAppearance = true }

                    settingsNavRow(
                        icon: "star.fill",
                        label: "Membership", value: currentPlanLabel
                    ) { showMembershipPlans = true }

                    settingsNavRow(
                        icon: "bell.fill",
                        label: "Notifications", value: nil
                    ) { showNotifications = true }

                    settingsNavRow(
                        icon: "calendar",
                        label: "Calendars", value: calendarValueLabel
                    ) { showCalendars = true }

                    settingsNavRow(
                        icon: "square.grid.2x2.fill",
                        label: "Layout", value: layoutValueLabel
                    ) { showLayout = true }

                    settingsNavRow(
                        icon: "exclamationmark.bubble.fill",
                        label: "Report an Issue", value: nil
                    ) { showReportIssue = true }

                    sectionLabel("DATA")

                    settingsNavRow(
                        icon: "trash.fill",
                        label: "Recently Deleted", value: nil
                    ) { showTrash = true }

                    VStack(spacing: 8) {
                        Button {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                showClearCompletedConfirm.toggle()
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Palette.danger)
                                    .frame(width: 30, height: 30)
                                Text("Clear All Completed")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Palette.danger)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Palette.danger.opacity(0.6))
                                    .rotationEffect(.degrees(showClearCompletedConfirm ? 180 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .evryField(palette)
                        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Palette.danger.opacity(0.25), lineWidth: 1))

                        // Inline confirmation, right below the button.
                        if showClearCompletedConfirm {
                            let count = allTasks.filter { $0.completed && !$0.isTrashed }.count
                            HStack(spacing: 10) {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showClearCompletedConfirm = false }
                                } label: {
                                    Text("Cancel")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(palette.text)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .evryField(palette)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    for task in allTasks where task.completed && !task.isTrashed {
                                        TaskActions.delete(task)
                                    }
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showClearCompletedConfirm = false }
                                } label: {
                                    Text(count > 0 ? "Delete \(count)" : "Delete")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Palette.danger, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    // Log Out
                    VStack(spacing: 8) {
                        Button { showLogoutConfirm = true } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(palette.primary)
                                    .frame(width: 30, height: 30)
                                Text("Log Out")
                                    .font(.system(size: 15))
                                    .foregroundStyle(palette.text)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .evryField(palette)

                        if !userEmail.isEmpty {
                            Text(userEmail)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                    .padding(.top, 4)

                    Text(appVersion)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textPh)
                        .padding(.top, 8)
                }
                .padding(20)
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
            .confirmationDialog(
                "Log out of your account?",
                isPresented: $showLogoutConfirm,
                titleVisibility: .visible
            ) {
                Button("Log Out", role: .destructive) {
                    userName = ""
                    userEmail = ""
                    dismiss()
                }
            }
        }
        .tint(palette.primary)
        .preferredColorScheme(appearance.preferredColorScheme)
        .sheet(isPresented: $showProfile)         { ProfileAccountSheet() }
        .sheet(isPresented: $showAppearance)      { AppearanceSettingsView() }
        .fullScreenCover(isPresented: $showMembershipPlans) { MembershipPlansView() }
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
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(palette.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .frame(width: 30, height: 30)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.text)
                Spacer()
                if let value {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSec)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.textPh)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .evryField(palette)
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
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(Palette.success)
                            Text("Report Sent")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(palette.text)
                            Text("Thanks for the feedback. We'll look into it.")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.textSec)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DESCRIBE THE ISSUE")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(palette.textSec)
                                .padding(.horizontal, 4)

                            ZStack(alignment: .topLeading) {
                                if messageText.isEmpty {
                                    Text("Tell us what went wrong or what you'd like to see improved…")
                                        .font(.system(size: 15))
                                        .foregroundStyle(palette.textPh)
                                        .padding(.top, 14)
                                        .padding(.horizontal, 14)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $messageText)
                                    .font(.system(size: 15))
                                    .foregroundStyle(palette.text)
                                    .frame(minHeight: 140)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .scrollContentBackground(.hidden)
                            }
                            .evryField(palette)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSec)
                            let remaining = max(0, 3 - last24hCount)
                            Text("\(remaining) report\(remaining == 1 ? "" : "s") remaining today")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSec)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("INCLUDED WITH REPORT")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(palette.textPh)
                            HStack(spacing: 6) {
                                Text(userName.isEmpty ? "Anonymous" : userName)
                                Text("·")
                                Text(appVersion)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSec)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .evryField(palette)

                        if last24hCount >= 3 {
                            Text("Daily limit reached (3/day). Try again tomorrow.")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.danger)
                                .multilineTextAlignment(.center)
                        } else if last30dCount >= 10 {
                            Text("Monthly limit reached (10/month).")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.danger)
                                .multilineTextAlignment(.center)
                        }

                        Button { sendReport() } label: {
                            Text("Send Report")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(canSend ? palette.primary : palette.border,
                                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(!canSend)
                    }
                }
                .padding(20)
            }
            .background(palette.bg)
            .navigationTitle("Report an Issue")
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
            MailComposeView(subject: "Evry App Feedback", body: emailBody) { result in
                showMailCompose = false
                if result == .sent {
                    recordSend()
                    withAnimation { submitted = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                }
            }
            .ignoresSafeArea()
        }
        .alert("Mail Not Available", isPresented: $showNoMailAlert) {
            Button("OK") {}
        } message: {
            Text("Please set up a Mail account in Settings, or contact us at feedback@evry.app")
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
                                      : userName.isEmpty ? palette.border
                                      : avatarColor(for: userName))
                                .frame(width: 90, height: 90)
                                .overlay {
                                    if let data = profileImageData, let img = UIImage(data: data) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .clipShape(Circle())
                                    } else {
                                        Text(initials)
                                            .font(.system(size: 32, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            Circle()
                                .fill(palette.primary)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(palette.onPrimary)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)

                    // Name field
                    accountRow(icon: "person.fill", iconBg: palette.primaryLight) {
                        TextField("Full name", text: $userName)
                            .font(.system(size: 15))
                            .foregroundStyle(palette.text)
                    }
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

                    // Two-Factor Authentication
                    Button { path.append(.twoFactor) } label: {
                        HStack(spacing: 14) {
                            iconBadge("shield.lefthalf.filled", bg: palette.primaryLight)
                            Text("Two-Factor Authentication")
                                .font(.system(size: 15))
                                .foregroundStyle(palette.text)
                            Spacer()
                            Text(twoFactorEnabled ? "On" : "Off")
                                .font(.system(size: 13))
                                .foregroundStyle(twoFactorEnabled ? Palette.success : palette.textSec)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.textPh)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .evryField(palette)

                    // Delete account
                    Button { confirmingDelete = true } label: {
                        HStack(spacing: 14) {
                            iconBadge("trash.fill", bg: Palette.danger.opacity(0.15), fg: Palette.danger)
                            Text("Delete Account")
                                .font(.system(size: 15))
                                .foregroundStyle(Palette.danger)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.textPh)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .evryField(palette)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(Palette.danger.opacity(0.25), lineWidth: 1)
                    )
                }
                .padding(20)
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
                   let img = UIImage(data: data),
                   let thumb = img.preparingThumbnail(of: CGSize(width: 300, height: 300)),
                   let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                    profileImageData = jpeg
                    UserDefaults.standard.set(jpeg, forKey: "profile_image_data")
                }
            }
        }
        .confirmationDialog(
            "Delete your account? This cannot be undone.",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                userName = ""
                userEmail = ""
                dismiss()
            }
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
        .padding(.vertical, 13)
    }

    private func accountNavRow(icon: String, label: String, value: String, action: String) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon, bg: palette.primaryLight)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
            }
            Spacer()
            Text(action)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.primary)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textPh)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func iconBadge(_ name: String, bg: Color, fg: Color? = nil) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(fg ?? palette.primary)
            .frame(width: 30, height: 30)
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
                Section("New Email Address") {
                    TextField("New email", text: $newEmail)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Confirm new email", text: $confirmEmail)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Verify Identity") {
                    SecureField("Current password", text: $password)
                }

                if !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.danger)
                    }
                }

                Section {
                    Button("Forgot password?") { path.append(.forgotPassword) }
                        .foregroundStyle(palette.primary)
                }
            }
            .navigationTitle("Change Email")
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
                successOverlay("Email updated!", palette: palette)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: success)
    }

    private func save() {
        errorMessage = ""
        guard newEmail.lowercased() == confirmEmail.lowercased() else {
            errorMessage = "Email addresses don't match. Please re-enter them."
            return
        }
        guard newEmail.contains("@"), newEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
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
                Section("Current Password") {
                    SecureField("Current password", text: $currentPassword)
                }

                Section("New Password") {
                    SecureField("New password", text: $newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                }

                if !errorMessage.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.danger)
                    }
                }

                Section {
                    Button("Forgot password?") { path.append(.forgotPassword) }
                        .foregroundStyle(palette.primary)
                }
            }
            .navigationTitle("Change Password")
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
                successOverlay("Password updated!", palette: palette)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: success)
    }

    private func save() {
        errorMessage = ""
        guard newPassword == confirmPassword else {
            errorMessage = "New passwords don't match."
            return
        }
        guard newPassword.count >= 8 else {
            errorMessage = "Password must be at least 8 characters."
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
                    Image(systemName: "envelope.badge.fill")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(palette.primary)
                    VStack(spacing: 8) {
                        Text("Check your inbox")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(palette.text)
                        Text("We sent a password reset link to:\n\(email)")
                            .font(.system(size: 15))
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
                        Text("Enter the email address associated with your account and we'll send you a link to reset your password.")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSec)
                    }
                    Section("Email Address") {
                        TextField("Email", text: $email)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .onAppear { if email.isEmpty { email = userEmail } }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send Link") { sent = true }
                            .fontWeight(.semibold)
                            .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .navigationTitle("Forgot Password")
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
                        .font(.system(size: 32))
                        .foregroundStyle(isEnabled ? Palette.success : palette.textSec)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isEnabled ? "Enabled" : "Disabled")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isEnabled ? Palette.success : palette.text)
                        Text(isEnabled
                             ? "Your account has an extra layer of protection."
                             : "Enable to require a verification code at sign-in.")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSec)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                Toggle("Enable Two-Factor Auth", isOn: $isEnabled)
                    .tint(palette.primary)
            }

            if isEnabled {
                Section("Recovery") {
                    Label(
                        "Save your recovery codes in a secure location in case you lose access to your authenticator app.",
                        systemImage: "key.fill"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSec)
                }
            }
        }
        .navigationTitle("Two-Factor Auth")
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62))
                .foregroundStyle(Palette.success)
            Text(message)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.text)
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
    @AppStorage("tab_calendar_visible") private var tabCalendar = true
    @AppStorage("tab_notes_visible") private var tabNotes = true
    @AppStorage("tab_profile_visible") private var tabProfile = true
    @AppStorage("inbox_hide_notes") private var hideNotes = false
    @AppStorage("inbox_hide_reschedule") private var hideReschedule = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var enabledCount: Int {
        [tabInbox, tabCalendar, tabNotes, tabProfile].filter { $0 }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    sectionLabel("TABS")
                    tabRow("Inbox",    icon: "tray",              isOn: $tabInbox)
                    tabRow("Calendar", icon: "calendar",          isOn: $tabCalendar)
                    tabRow("Notes",    icon: "note.text",         isOn: $tabNotes)
                    tabRow("Profile",  icon: "person",            isOn: $tabProfile)
                    Text("At least one tab must always be enabled.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)

                    sectionLabel("INBOX")
                        .padding(.top, 8)
                    inboxRow("Hide Notes", icon: "note.text.badge.plus", isOn: $hideNotes)
                    inboxRow("Hide Reschedule Button", icon: "calendar.badge.minus", isOn: $hideReschedule)
                }
                .padding(20)
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

    private func tabRow(_ name: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? palette.primary : palette.textSec)
                .frame(width: 30, height: 30)
            Text(name)
                .font(.system(size: 15))
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .evryField(palette)
    }

    private func inboxRow(_ name: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? palette.primary : palette.textSec)
                .frame(width: 30, height: 30)
            Text(name)
                .font(.system(size: 15))
                .foregroundStyle(palette.text)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(palette.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .evryField(palette)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(palette.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                VStack(spacing: 16) {
                    sectionLabel("NOTIFICATIONS")

                    notifRow("Task Reminders", icon: "bell.fill",
                             subtitle: "Get notified before tasks are due", isOn: $taskReminders)

                    if taskReminders {
                        timePickerRow(
                            icon: "clock.fill",
                            label: "Default reminder time",
                            subtitle: "Used when a task has no specific time",
                            selection: defaultReminderDate
                        )
                    }

                    notifRow("Daily Digest", icon: "sun.max.fill",
                             subtitle: "Morning summary of your day's tasks", isOn: $dailyDigest)

                    if dailyDigest {
                        timePickerRow(
                            icon: "clock.fill",
                            label: "Digest time",
                            subtitle: "When to receive your daily summary",
                            selection: digestDate
                        )
                    }

                    notifRow("Weekly Summary", icon: "chart.bar.fill",
                             subtitle: "Weekly overview of your progress", isOn: $weeklySummary)
                }
                .padding(20)
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isOn.wrappedValue ? palette.primary : palette.textSec)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(palette.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .evryField(palette)
    }

    private func timePickerRow(icon: String, label: String, subtitle: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.primary)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSec)
            }
            Spacer()
            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .tint(palette.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .evryCard(palette, cornerRadius: 22)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(palette.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// MARK: - Appearance Settings

private struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @AppStorage("membership_plan") private var membershipPlan = ""
    @State private var showAccentUpgrade = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }

    var body: some View {
        @Bindable var appearance = appearance
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    sectionLabel("THEME")

                    Picker("Theme", selection: $appearance.themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .evryCard(palette, cornerRadius: 24)

                    sectionLabel("ACCENT COLOR")

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(AccentColorTheme.all) { accent in
                            let isFree = accent.key == "default" || accent.key == "ink"
                            let isLocked = !isFree && membershipPlan != "lite" && membershipPlan != "pro"
                            Button {
                                if isLocked { showAccentUpgrade = true }
                                else { appearance.accentKey = accent.key }
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack {
                                        Circle()
                                            .fill(accent.primary.opacity(isLocked ? 0.38 : 1))
                                            .frame(width: 34, height: 34)
                                        if appearance.accentKey == accent.key {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(accent.onPrimary)
                                        } else if isLocked {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.9))
                                        }
                                    }
                                    Text(accent.label)
                                        .font(.system(size: 10))
                                        .foregroundStyle(isLocked ? palette.textPh : palette.textSec)
                                }
                            }
                            .buttonStyle(PressScaleStyle())
                        }
                    }
                    .padding(16)
                    .evryCard(palette, cornerRadius: 24)
                }
                .padding(20)
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
        .sheet(isPresented: $showAccentUpgrade) { MembershipPromoView() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(palette.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                            Image(systemName: "calendar.badge.exclamationmark")
                                .font(.system(size: 52, weight: .light))
                                .foregroundStyle(palette.textSec)
                                .padding(.top, 40)
                            Text(calendarService.authStatusLabel)
                                .font(.system(size: 15))
                                .foregroundStyle(palette.textSec)
                                .multilineTextAlignment(.center)
                            if calendarService.accessDenied {
                                Button("Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 12)
                                .background(palette.primary, in: Capsule())
                            } else {
                                Button("Connect Calendar") {
                                    Task { await calendarService.requestAccess() }
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 12)
                                .background(palette.primary, in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else if calendarService.allCalendarInfos.isEmpty {
                        Text("No calendars found")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.textSec)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    } else {
                        sectionLabel("CALENDARS")

                        VStack(spacing: 0) {
                            ForEach(Array(calendarService.allCalendarInfos.enumerated()), id: \.element.id) { i, info in
                                if i > 0 {
                                    Divider().background(palette.border).padding(.leading, 58)
                                }
                                Toggle(isOn: Binding(
                                    get: { calendarService.selectedCalendarIDs.contains(info.id) },
                                    set: { _ in calendarService.toggleCalendar(info.id) }
                                )) {
                                    HStack(spacing: 12) {
                                        Circle()
                                            .fill(info.color)
                                            .frame(width: 10, height: 10)
                                            .frame(width: 28, height: 28)
                                            .background(info.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(info.title)
                                                .font(.system(size: 15))
                                                .foregroundStyle(palette.text)
                                            Text(info.sourceTitle)
                                                .font(.system(size: 12))
                                                .foregroundStyle(palette.textSec)
                                        }
                                    }
                                }
                                .tint(info.color)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        calendarService.hideCalendar(info.id)
                                    } label: {
                                        Label("Remove from list", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .evryCard(palette, cornerRadius: 24)
                    }
                }
                .padding(20)
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
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(palette.textSec)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textSec)
                    TextField("Tasks, notes, projects, tags…", text: $searchText)
                        .font(.system(size: 16))
                        .foregroundStyle(palette.text)
                        .autocorrectionDisabled()
                        .focused($focused)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.textPh)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .evryField(palette)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundStyle(palette.textPh)
                                Text("Search everything")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(palette.textSec)
                                Text("Tasks, notes, projects and tags\nacross your entire workspace.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.textPh)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 60)
                        } else if results.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 36, weight: .light))
                                    .foregroundStyle(palette.textPh)
                                Text("No results for \"\(searchText)\"")
                                    .font(.system(size: 15))
                                    .foregroundStyle(palette.textSec)
                            }
                            .padding(.top, 60)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                if !results.isEmpty {
                                    Text("TASKS & NOTES")
                                        .font(.system(size: 11, weight: .bold))
                                        .tracking(0.8)
                                        .foregroundStyle(palette.textSec)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 16)
                                        .padding(.bottom, 6)

                                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                                        .font(.system(size: 12))
                                        .foregroundStyle(palette.textSec)
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 4)

                                    ForEach(results) { task in
                                        SearchResultRow(task: task, palette: palette, query: searchText) {
                                            projectNavState.requestedTab = .inbox
                                            dismiss()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.bottom, 6)
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
            attr[attrStart..<attrEnd].font = .systemFont(ofSize: 14, weight: .bold)
            searchFrom = range.upperBound
        }
        return attr
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.completed ? Palette.success : palette.border)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(highlighted(task.title))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(task.completed ? palette.textSec : palette.text)
                        .strikethrough(task.completed, color: palette.textPh)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let due = task.dueDate {
                            Text(due.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 11))
                                .foregroundStyle(isOverdueDate(due) ? Palette.danger : palette.textSec)
                        }
                        if !task.tags.isEmpty {
                            Text(task.tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
                                .font(.system(size: 11))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textPh)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .evryField(palette)
        }
        .buttonStyle(.plain)
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

    var body: some View {
        NavigationStack {
            Group {
                if trashedTasks.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "trash")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(palette.textPh)
                        Text("Recently Deleted is empty")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.textSec)
                        Text("Deleted tasks appear here for 30 days.")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textPh)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .padding(.horizontal, 32)
                } else {
                    List {
                        Section {
                            ForEach(trashedTasks) { task in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(palette.text)
                                            .lineLimit(1)
                                        if let deleted = task.deletedAt {
                                            let days = Calendar.current.dateComponents([.day], from: deleted, to: Date()).day ?? 0
                                            let remaining = max(0, 30 - days)
                                            Text("Deleted \(deleted.formatted(.relative(presentation: .named))) · \(remaining)d left")
                                                .font(.system(size: 12))
                                                .foregroundStyle(palette.textSec)
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        withAnimation { TaskActions.restore(task) }
                                    } label: {
                                        Text("Restore")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(palette.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(palette.primaryLight, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        context.delete(task)
                                    } label: {
                                        Label("Delete Forever", systemImage: "trash.fill")
                                    }
                                }
                            }
                        } footer: {
                            Text("Tasks are permanently deleted after 30 days.")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textSec)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Delete All") {
                                for task in trashedTasks { context.delete(task) }
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.danger)
                        }
                    }
                }
            }
            .background(palette.bg)
            .navigationTitle("Recently Deleted")
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
    }
}
