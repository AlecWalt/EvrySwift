//
//  XPTests.swift
//  EvryTests
//
//  Queued XP: earned XP waits for the Profile visit, bonuses are whole
//  crystals and capped per day, and queued amounts split into 5-XP crystals.
//

import Foundation
import Testing
@testable import Evry

@MainActor
@Suite(.serialized)
struct XPQueueTests {
    /// Each test gets its own empty store.
    private func fresh() -> UserDefaults {
        let suite = "EvryXP.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        EvryXP.defaults = defaults
        return defaults
    }

    @Test func goalsAreQueuedNotApplied() {
        _ = fresh()
        #expect(EvryXP.award(.habits))
        #expect(EvryXP.total == 0)
        #expect(EvryXP.pending == EvryXP.perGoal)
        // Once a day.
        #expect(!EvryXP.award(.habits))
        #expect(EvryXP.pending == EvryXP.perGoal)
    }

    @Test func takingPendingEmptiesTheQueue() {
        _ = fresh()
        EvryXP.queue(35)
        EvryXP.queue(15)
        #expect(EvryXP.takePending() == 50)
        #expect(EvryXP.pending == 0)
        #expect(EvryXP.total == 0)   // applied only as crystals land
    }

    @Test func crystalsCarryFiveEach() {
        #expect(EvryXP.crystals(for: 50) == Array(repeating: 5, count: 10))
        #expect(EvryXP.crystals(for: 12) == [5, 5, 2])
        #expect(EvryXP.crystals(for: 0).isEmpty)
    }

    @Test func bonusesAreChancyWholeCrystalsAndCapped() {
        _ = fresh()
        // A miss pays nothing.
        #expect(EvryXP.rollBonus(.taskCompleted, roll: 0.99) == 0)
        // A hit pays a multiple of 5.
        let paid = EvryXP.rollBonus(.taskCompleted, roll: 0, pick: 0.99)
        #expect(paid == 10)
        #expect(paid % EvryXP.perCrystal == 0)
        // Toggling a task over and over stops paying at the day's cap.
        for _ in 0..<20 { EvryXP.rollBonus(.taskCompleted, roll: 0, pick: 0.99) }
        #expect(EvryXP.pending == EvryXP.Bonus.taskCompleted.dailyCap)
        // A new day, a new allowance.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        #expect(EvryXP.rollBonus(.taskCompleted, on: tomorrow, roll: 0, pick: 0) == 5)
    }

    @Test func resetClearsTheQueueToo() {
        _ = fresh()
        EvryXP.queue(40)
        EvryXP.add(100)
        EvryXP.rollBonus(.noteCreated, roll: 0, pick: 0)
        EvryXP.reset()
        #expect(EvryXP.total == 0 && EvryXP.pending == 0)
        #expect(EvryXP.rollBonus(.noteCreated, roll: 0, pick: 0.99) == 15)
    }

    @Test func streamPutsUnlandedXPBack() {
        _ = fresh()
        EvryXP.queue(30)
        let stream = XPStream()
        stream.play(reduceMotion: false)
        #expect(EvryXP.pending == 0)
        stream.stop()   // closed before anything landed
        #expect(EvryXP.pending == 30)
        #expect(EvryXP.total == 0)
    }

    @Test func reduceMotionAppliesAtOnce() {
        _ = fresh()
        EvryXP.queue(25)
        XPStream().play(reduceMotion: true)
        #expect(EvryXP.total == 25 && EvryXP.pending == 0)
    }
}
