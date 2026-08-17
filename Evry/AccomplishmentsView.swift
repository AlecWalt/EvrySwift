//
//  AccomplishmentsView.swift
//  Evry
//
//  Uses on-device AI (FoundationModels) to summarise completed tasks for the day,
//  stores results in UserDefaults, and optionally saves to the calendar.
//

import FoundationModels
import SwiftUI
import SwiftData

// MARK: - Generable summary type

@Generable(description: "A motivating daily accomplishments summary")
private struct AccomplishmentResult {
    @Guide(description: "A short, upbeat one-sentence summary of what the person accomplished today — at most 14 words. Be specific but concise. Start with 'Today you'. No trailing period is required.")
    var summary: String

    @Guide(description: "A short theme for the day — 1-4 words (e.g. 'Deep Work Day', 'Creative Sprint', 'Family First')")
    var theme: String
}

// MARK: - UserDefaults storage

enum AccomplishmentsStore {
    private static let key = "evry_accomplishments_v1"

    static func load() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    static func save(summary: String, for date: Date) {
        var all = load()
        all[dateKey(date)] = summary
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: date) ?? date
        let cutoffKey = dateKey(cutoff)
        all = all.filter { $0.key > cutoffKey }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func summary(for date: Date) -> String? { load()[dateKey(date)] }

    static func dateKey(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day())
    }
}

// MARK: - View

struct AccomplishmentsView: View {
    let completedTasks: [TaskItem]
    let date: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(CalendarService.self) private var calendarService

    @State private var phase: Phase = .idle
    @State private var summary = ""
    @State private var theme = ""
    @State private var savedToCalendar = false

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var aiAvailable: Bool { SystemLanguageModel.default.isAvailable }

    private enum Phase { case idle, generating, done, error }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Completed task list
                    VStack(alignment: .leading, spacing: 10) {
                        Text("COMPLETED TODAY")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(palette.textSec)

                        if completedTasks.isEmpty {
                            Text("No completed tasks yet today.")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.textSec)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(completedTasks) { task in
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Palette.success)
                                    Text(task.title)
                                        .font(.system(size: 14))
                                        .foregroundStyle(palette.text)
                                        .strikethrough(true, color: palette.textPh)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .evryCard(palette)

                    // AI summary card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(palette.primary)
                            Text("AI Summary")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.text)
                            Spacer()
                        }

                        switch phase {
                        case .idle:
                            if let stored = AccomplishmentsStore.summary(for: date) {
                                Text(stored)
                                    .font(.system(size: 15))
                                    .foregroundStyle(palette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .onAppear { summary = stored; phase = .done }
                            } else if !aiAvailable {
                                Text("On-device AI is not available on this device.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.textSec)
                            } else if completedTasks.isEmpty {
                                Text("Complete some tasks first to generate your summary.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.textSec)
                            } else {
                                Button { Task { await generate() } } label: {
                                    Label("Generate Summary", systemImage: "sparkles")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(palette.onPrimary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 13)
                                        .background(palette.primary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                }
                                .buttonStyle(PressScaleStyle(scale: 0.97))
                            }

                        case .generating:
                            HStack(spacing: 10) {
                                ProgressView().tint(palette.primary)
                                Text("Generating…")
                                    .font(.system(size: 14))
                                    .foregroundStyle(palette.textSec)
                            }

                        case .done:
                            if !theme.isEmpty {
                                Text(theme.uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(palette.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(palette.primaryLight, in: Capsule())
                            }
                            Text(summary)
                                .font(.system(size: 15))
                                .foregroundStyle(palette.text)
                                .fixedSize(horizontal: false, vertical: true)

                            if calendarService.isAuthorized {
                                Button {
                                    let title = "✓ \(theme.isEmpty ? "Daily Summary" : theme)"
                                    if calendarService.saveAccomplishment(date: date, title: title, notes: summary) {
                                        withAnimation { savedToCalendar = true }
                                    }
                                } label: {
                                    Label(
                                        savedToCalendar ? "Saved to Calendar" : "Save to Calendar",
                                        systemImage: savedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus"
                                    )
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(savedToCalendar ? Palette.success : palette.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        savedToCalendar ? palette.successLight : palette.primaryLight,
                                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(savedToCalendar)
                            }

                            Button { Task { await generate() } } label: {
                                Text("Regenerate")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textSec)
                            }
                            .buttonStyle(.plain)

                        case .error:
                            Text("Could not generate summary. Try again.")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.textSec)
                            Button("Retry") { Task { await generate() } }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.primary)
                                .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .evryCard(palette)
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(palette.bg)
            .navigationTitle("Today's Accomplishments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(palette.primary)
    }

    private func generate() async {
        guard aiAvailable, !completedTasks.isEmpty else { return }
        withAnimation { phase = .generating }
        do {
            let list = completedTasks.map { "• \($0.title)" }.joined(separator: "\n")
            let session = LanguageModelSession(instructions: """
                You are a warm, encouraging productivity coach who celebrates what someone accomplished today.
                Today's date: \(date.formatted(.dateTime.weekday().day().month().year()))
                """)
            let response = try await session.respond(
                to: "Here are the tasks I completed today:\n\n\(list)\n\nWrite my accomplishments summary.",
                generating: AccomplishmentResult.self
            )
            let result = response.content
            await MainActor.run {
                summary = result.summary
                theme = result.theme
                AccomplishmentsStore.save(summary: result.summary, for: date)
                withAnimation { phase = .done }
            }
        } catch {
            await MainActor.run { withAnimation { phase = .error } }
        }
    }
}
