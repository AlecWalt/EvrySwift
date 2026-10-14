//
//  PathView.swift
//  Evry
//
//  The Focus Mode backdrop — one next-action card at a time with skip
//  rotation, ported from the webapp's pathTab.js. "Not this one" pushes the
//  task to the back of its urgency tier rather than excluding it.
//

import SwiftUI
import SwiftData
import UIKit

struct PathView: View {
    let palette: Palette
    var onEdit: (TaskItem) -> Void
    var onDelete: (TaskItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    /// Skip order survives re-renders, resets with the view — same scope as
    /// the webapp's component state.
    @State private var skippedOrder: [UUID] = []
    @State private var celebrating = false
    // Drives the Focus Mode entrance — the task screen fades + slides up once
    // as we drop into Focus Mode after Start is pressed.
    @State private var contentAppeared = false
    // Completion animation — matches TaskCheckbox (springy pop + radiating ring).
    @State private var popScale: CGFloat = 1
    @State private var burstScale: CGFloat = 0.7
    @State private var burstOpacity: Double = 0

    private var tasks: [TaskItem] { allTasks.filter { !$0.isTrashed } }
    private var candidate: TaskItem? { nextAction(tasks: tasks, skippedOrder: skippedOrder) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
            if let candidate {
                VStack(spacing: 16) {
                    Spacer()
                    card(candidate)
                    Button {
                        guard !celebrating else { return }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            skippedOrder.removeAll { $0 == candidate.uid }
                            skippedOrder.append(candidate.uid)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Not this one")
                            Image(systemName: "chevron.right")
                                .font(.nunito(size: 12, weight: .bold))
                                .accessibilityHidden(true)
                        }
                        .font(.evrySmall)
                        .foregroundStyle(palette.textSec)
                        .padding(.horizontal, 16)
                        .frame(minHeight: EvrySpace.tap)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Shows the next task instead")
                    .disabled(celebrating)
                    Spacer()
                }
                .padding(.horizontal, EvrySpace.grid)
                // Room for Focus Mode's exit button above, no tab bar below.
                .padding(.top, 60)
                .padding(.bottom, 80)
            } else {
                VStack {
                    Spacer()
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "That’s everything for now",
                        text: "Take a breath and enjoy the rest of your day.",
                        palette: palette
                    )
                    Spacer()
                }
                .padding(.top, 60)
                .padding(.bottom, 80)
            }
            }
            // Focus Mode entrance: fade + slide up.
            .opacity(contentAppeared ? 1 : 0)
            .offset(y: contentAppeared ? 0 : 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
        .onAppear {
            // Let the Pomodoro cover finish dismissing before sliding in.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(0.15)) {
                contentAppeared = true
            }
        }
    }

    private func card(_ task: TaskItem) -> some View {
        VStack(spacing: 10) {
            // Eyebrow: date chip
            if let due = task.dueDate {
                HStack(spacing: 8) {
                    DateChip(date: due, palette: palette)
                }
                .padding(.top, 6)
            }

            Button {
                onEdit(task)
            } label: {
                Text(task.title)
                    .font(.evryH3)
                    .foregroundStyle(celebrating ? palette.textSec : palette.text)
                    .strikethrough(celebrating, color: palette.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if !task.notes.isEmpty {
                Text(task.notes)
                    .font(.evryBody)
                    .lineSpacing(4)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
            }

            if !task.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(task.subtasks) { subtask in
                        HStack(spacing: 8) {
                            Button {
                                if let idx = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
                                    task.subtasks[idx].completed.toggle()
                                }
                            } label: {
                                // Done = the sky check disc with a navy tick.
                                ZStack {
                                    Circle().fill(subtask.completed ? Palette.doneFill : .clear)
                                    Circle().strokeBorder(subtask.completed ? Color.clear : palette.border, lineWidth: 1.5)
                                    if subtask.completed {
                                        Image(systemName: "checkmark")
                                            .font(.nunito(size: 10, weight: .heavy))
                                            .foregroundStyle(palette.onSky)
                                    }
                                }
                                .frame(width: 20, height: 20)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(subtask.title)
                            .accessibilityValue(subtask.completed ? "Done" : "Not done")
                            Text(subtask.title)
                                .font(.nunito(size: 15))
                                .foregroundStyle(subtask.completed ? palette.textSec : palette.text)
                                .strikethrough(subtask.completed, color: palette.textMuted)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }

            if !task.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(task.tags, id: \.self) { tag in
                        ChipView(text: "#\(tag)", foreground: palette.textSec, background: palette.hover)
                    }
                }
            }

            // Big complete button — 68pt circle; while celebrating it becomes the
            // sky check disc with a navy tick (the done fill).
            Button {
                complete(task)
            } label: {
                ZStack {
                    // Radiating ring that bursts outward on completion.
                    Circle()
                        .stroke(palette.primary, lineWidth: 2.5)
                        .scaleEffect(burstScale)
                        .opacity(burstOpacity)
                    Circle()
                        .fill(celebrating ? Palette.doneFill : palette.card)
                    Circle()
                        .strokeBorder(celebrating ? Color.clear : palette.border, lineWidth: 2.5)
                    Image(systemName: "checkmark")
                        .font(.nunito(size: 26, weight: .heavy))
                        .foregroundStyle(celebrating ? palette.onSky : palette.textPh)
                }
                .frame(width: 68, height: 68)
                .scaleEffect(popScale)
            }
            .buttonStyle(PressScaleStyle(scale: 0.94))
            .accessibilityLabel("Complete \(task.title)")
            .disabled(celebrating)
            .padding(.top, 10)
        }
        .frame(maxWidth: 420)
        .padding(.top, 28)
        .padding(.horizontal, 24)
        .padding(.bottom, 26)
        .evryCard(palette, cornerRadius: EvryRadius.panel)
        .overlay(alignment: .topTrailing) {
            Button {
                onDelete(task)
            } label: {
                Image(systemName: "trash")
                    .font(.nunito(size: 15, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
                    .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete task")
            .padding(8)
        }
        .scaleEffect(celebrating ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: celebrating)
    }

    private func complete(_ task: TaskItem) {
        guard !celebrating else { return }
        celebrating = true
        playCompletion()
        // Let the checkmark/burst beat play before the card swaps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                TaskActions.toggle(task, context: context)
            }
            celebrating = false
        }
    }

    /// Springy pop + radiating ring — the same completion beat as TaskCheckbox.
    private func playCompletion() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { popScale = 1.35 }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.55).delay(0.12)) { popScale = 1 }
        burstScale = 0.85
        burstOpacity = 0.75
        withAnimation(.easeOut(duration: 0.45)) {
            burstScale = 2.2
            burstOpacity = 0
        }
    }
}

#Preview {
    PathView(
        palette: Palette(dark: false, accent: .evry),
        onEdit: { _ in },
        onDelete: { _ in }
    )
    .environment(Appearance())
    .environment(PomodoroModel())
    .modelContainer(for: [TaskItem.self], inMemory: true)
}
