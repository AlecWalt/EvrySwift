//
//  TourTests.swift
//  EvryTests
//
//  Section tours: they wait for a clear screen in the right section, waiting
//  steps only move on when the person does the thing, and each plays once.
//

import Foundation
import Testing
@testable import Evry

@MainActor
struct TourCenterTests {
    private func steps(_ log: Ref) -> [TourStep] {
        [
            TourStep(target: .inboxContent, text: "One", onEnter: { log.entered.append(0) }),
            TourStep(target: .inboxDay, text: "Two", advance: .event(.weekOpened), onEnter: { log.entered.append(1) }),
            TourStep(target: .inboxEvry, text: "Three", onTargetTap: { log.targetTapped = true }),
        ]
    }

    final class Ref {
        var entered: [Int] = []
        var targetTapped = false
    }

    private func freshID() -> String {
        let id = "test-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: TourCenter.doneKey(id))
        return id
    }

    @Test func waitsForAClearScreenInItsSection() {
        let tour = TourCenter(), log = Ref(), id = freshID()
        tour.update(.init(blocked: true, section: "inbox"))
        tour.request(id, section: "inbox", steps: steps(log))
        #expect(!tour.isActive)                       // something covers the page
        tour.update(.init(blocked: false, section: "habits"))
        #expect(!tour.isActive)                       // wrong section
        tour.update(.init(blocked: false, section: "inbox"))
        #expect(tour.isActive && tour.index == 0)
        #expect(log.entered == [0])
        tour.finish()
    }

    @Test func waitingStepsNeedTheirEvent() {
        let tour = TourCenter(), log = Ref(), id = freshID()
        tour.update(.init(blocked: false, section: "inbox"))
        tour.request(id, section: "inbox", steps: steps(log))
        tour.tapped(onTarget: false)
        #expect(tour.index == 1 && log.entered == [0, 1])
        // Taps elsewhere only nudge; the wrong event does nothing.
        tour.tapped(onTarget: false)
        tour.notify(.weekClosed)
        #expect(tour.index == 1 && tour.nudges == 1)
        tour.notify(.weekOpened)
        #expect(tour.index == 2)
        tour.finish()
    }

    @Test func tappingTheLastTargetRunsItsActionAndFinishes() {
        let tour = TourCenter(), log = Ref(), id = freshID()
        tour.update(.init(blocked: false, section: "inbox"))
        tour.request(id, section: "inbox", steps: steps(log))
        tour.tapped(onTarget: false)
        tour.notify(.weekOpened)
        tour.tapped(onTarget: true)
        #expect(log.targetTapped)
        #expect(!tour.isActive)
        #expect(TourCenter.hasSeen(id))
        // Seen tours don't come back.
        tour.request(id, section: "inbox", steps: steps(log))
        #expect(!tour.isActive)
    }

    @Test func openingTheChatEndsTheTour() {
        let tour = TourCenter(), log = Ref(), id = freshID()
        tour.update(.init(blocked: false, section: "inbox"))
        tour.request(id, section: "inbox", steps: steps(log))
        tour.notify(.chatOpened)
        #expect(!tour.isActive && TourCenter.hasSeen(id))
    }
}
