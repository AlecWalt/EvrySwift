//
//  PomodoroModel.swift
//  Evry
//
//  Pomodoro state machine — the Swift port of the webapp's pomodoro store
//  (js/store.js): three presets, work/short-break/long-break phases, and
//  wall-clock-based timing so backgrounding doesn't drift the timer.
//

import AudioToolbox
import Foundation
import Observation
import UIKit

enum PomodoroPhase: String, Codable {
    case work, shortBreak, longBreak

    var label: String {
        switch self {
        case .work: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }

    /// Path-tab status label ("Focusing" while working).
    var statusLabel: String {
        switch self {
        case .work: "Focusing"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }
}

struct PomodoroPreset: Identifiable, Equatable {
    let key: String
    let label: String
    let workMin: Int
    let shortBreakMin: Int
    let longBreakMin: Int
    let sessionsUntilLongBreak: Int

    var id: String { key }

    static let all: [PomodoroPreset] = [
        PomodoroPreset(key: "classic", label: "Classic",     workMin: 25, shortBreakMin: 5,  longBreakMin: 15, sessionsUntilLongBreak: 4),
        PomodoroPreset(key: "short",   label: "Short Focus", workMin: 15, shortBreakMin: 5,  longBreakMin: 10, sessionsUntilLongBreak: 4),
        PomodoroPreset(key: "deep",    label: "Deep Work",   workMin: 45, shortBreakMin: 15, longBreakMin: 30, sessionsUntilLongBreak: 2),
    ]

    static func byKey(_ key: String) -> PomodoroPreset {
        all.first { $0.key == key } ?? all[0]
    }
}

/// Persisted snapshot (UserDefaults "pomodoro_state_v1", mirroring the webapp).
private struct PomodoroSnapshot: Codable {
    var presetKey: String
    var phase: PomodoroPhase
    var running: Bool
    var phaseEndAt: Date?
    var remainingAtPause: TimeInterval?
    var completedSessions: Int
    var targetSessions: Int?    // nil in legacy saves → treated as 0 (unlimited)
}

@Observable
final class PomodoroModel {
    private(set) var preset: PomodoroPreset = PomodoroPreset.all[0]
    private(set) var phase: PomodoroPhase = .work
    private(set) var running = false
    private(set) var completedSessions = 0
    /// 0 = run indefinitely; >0 = stop after this many work sessions complete.
    private(set) var targetSessions: Int = 0

    /// Fires once per phase change so the shell can raise a toast wherever
    /// the user is.
    @ObservationIgnored var onPhaseChange: ((PomodoroPhase) -> Void)?

    /// Ticked by the timer while running — observing views re-derive
    /// `remaining` from it every second.
    private var now = Date()

    private var phaseEndAt: Date?
    private var remainingAtPause: TimeInterval?
    @ObservationIgnored private var timer: Timer?

    private static let storageKey = "pomodoro_state_v1"

    init() {
        load()
        syncTimer()
    }

    // MARK: Derived

    func duration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .work: Double(preset.workMin) * 60
        case .shortBreak: Double(preset.shortBreakMin) * 60
        case .longBreak: Double(preset.longBreakMin) * 60
        }
    }

    var totalDuration: TimeInterval { duration(of: phase) }

    var remaining: TimeInterval {
        if running, let end = phaseEndAt {
            return max(0, end.timeIntervalSince(now))
        }
        return remainingAtPause ?? totalDuration
    }

    var timeLabel: String {
        let totalSec = Int(max(0, remaining.rounded(.up)))
        return "\(totalSec / 60):\(String(format: "%02d", totalSec % 60))"
    }

    // MARK: Controls

    func start() {
        phaseEndAt = Date().addingTimeInterval(remainingAtPause ?? totalDuration)
        remainingAtPause = nil
        running = true
        now = Date()
        save()
        syncTimer()
    }

    func pause() {
        guard running, let end = phaseEndAt else { return }
        remainingAtPause = max(0, end.timeIntervalSinceNow)
        phaseEndAt = nil
        running = false
        save()
        syncTimer()
    }

    func reset() {
        phase = .work
        running = false
        phaseEndAt = nil
        remainingAtPause = nil
        completedSessions = 0
        save()
        syncTimer()
    }

    func skip() {
        if advancePhase() {
            save()
            syncTimer()
            return
        }
        if running {
            phaseEndAt = Date().addingTimeInterval(totalDuration)
        } else {
            remainingAtPause = nil
        }
        save()
        playPhaseTransitionFeedback()
    }

    func selectPreset(_ preset: PomodoroPreset) {
        self.preset = preset
        reset()
    }

    func setTargetSessions(_ n: Int) {
        targetSessions = n
        save()
    }

    // MARK: Internals

    /// Returns `true` if the session target was just reached (caller should stop rather than continue).
    @discardableResult
    private func advancePhase() -> Bool {
        if phase == .work {
            completedSessions += 1
            if targetSessions > 0 && completedSessions >= targetSessions {
                running = false
                phaseEndAt = nil
                remainingAtPause = nil
                phase = .work
                return true
            }
            phase = completedSessions % preset.sessionsUntilLongBreak == 0 ? .longBreak : .shortBreak
        } else {
            phase = .work
        }
        return false
    }

    private func tick() {
        now = Date()
        if running, let end = phaseEndAt, now >= end {
            if advancePhase() {
                save()
                syncTimer()
                return
            }
            phaseEndAt = now.addingTimeInterval(totalDuration)
            save()
            playPhaseTransitionFeedback()
            onPhaseChange?(phase)
        }
    }

    private func playPhaseTransitionFeedback() {
        let style: UIImpactFeedbackGenerator.FeedbackStyle = phase == .work ? .medium : .heavy
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        AudioServicesPlaySystemSound(1057)
    }

    private func syncTimer() {
        if running, timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !running, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func save() {
        let snapshot = PomodoroSnapshot(
            presetKey: preset.key,
            phase: phase,
            running: running,
            phaseEndAt: phaseEndAt,
            remainingAtPause: remainingAtPause,
            completedSessions: completedSessions,
            targetSessions: targetSessions
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let snapshot = try? JSONDecoder().decode(PomodoroSnapshot.self, from: data) else { return }
        preset = PomodoroPreset.byKey(snapshot.presetKey)
        phase = snapshot.phase
        running = snapshot.running
        phaseEndAt = snapshot.phaseEndAt
        remainingAtPause = snapshot.remainingAtPause
        completedSessions = snapshot.completedSessions
        targetSessions = snapshot.targetSessions ?? 0
        now = Date()
        // A phase that expired while the app was closed advances on the
        // first tick after the timer restarts.
    }
}
