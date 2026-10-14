//
//  EvryTests.swift
//  EvryTests
//
//  Baseline tests for the app's riskiest pure logic — typed-input parsing,
//  Evry's date reading, place labelling and matching, chat bullet formatting,
//  habit streaks and recurring-task completion. They pin today's behaviour so
//  refactors can't change it silently.
//

import Foundation
import SwiftData
import Testing
@testable import Evry

private let cal = Calendar.current
private func hour(_ d: Date?) -> Int? { d.map { cal.component(.hour, from: $0) } }
private func minute(_ d: Date?) -> Int? { d.map { cal.component(.minute, from: $0) } }

/// An in-memory store with the app's full schema (a partial schema traps when a
/// model's relationships point at types outside it).
@MainActor
private func memoryContext() throws -> ModelContext {
    let schema = Schema([TaskItem.self, TaskGroup.self, Note.self, Folder.self, Habit.self, HabitEntry.self])
    let container = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    // Kept alive for the test's duration via the context's container reference.
    retained.append(container)
    return container.mainContext
}
@MainActor private var retained: [ModelContainer] = []

// MARK: - Quick-add parsing

@MainActor
struct TaskParsingTests {
    @Test func parsesTitleTagsPriorityAndTime() {
        let p = parseTaskInput("Gym 3pm #health !high")
        #expect(p.title == "Gym")
        #expect(p.tags == ["health"])
        #expect(p.priority == .high)
        #expect(hour(p.date) == 15)
    }

    @Test func parses24HourTime() {
        let p = parseTaskInput("Standup at 9:30")
        #expect(p.title == "Standup")
        #expect(hour(p.date) == 9)
        #expect(minute(p.date) == 30)
    }

    @Test func weekdayGivesAFutureDay() {
        let p = parseTaskInput("Call mom friday")
        #expect(p.title == "Call mom")
        let d = try? #require(p.date)
        #expect(d.map { cal.component(.weekday, from: $0) } == 6)
        #expect(d.map { $0 > Date() } == true)
    }

    @Test func plainTitleHasNoDate() {
        let p = parseTaskInput("Read a book")
        #expect(p.title == "Read a book")
        #expect(p.date == nil)
    }
}

// MARK: - Evry's dates

@MainActor
struct EvryWhenTests {
    @Test func todayAtShortTime() {
        let d = EvryWhen.parse("today at 8p")
        #expect(d.map { cal.isDateInToday($0) } == true)
        #expect(hour(d) == 20)
    }

    @Test func tomorrowIsADayWithoutTime() {
        let d = EvryWhen.parse("tomorrow")
        #expect(d.map { cal.isDateInTomorrow($0) } == true)
        #expect(EvryWhen.hasTime(d) == false)
    }

    @Test func tonightIsTheEvening() {
        #expect(hour(EvryWhen.parse("tonight")) == 20)
    }

    @Test func relativeHours() {
        let d = try? #require(EvryWhen.parse("in 2 hours"))
        let gap = d.map { $0.timeIntervalSinceNow } ?? 0
        #expect(abs(gap - 7200) < 120)
    }

    @Test func relativeMinutesWithoutSpace() {
        withKnownIssue("B14: 'in 20min' reads as 20 weeks") {
            let d = EvryWhen.parse("in 20min")
            let gap = d.map { $0.timeIntervalSinceNow } ?? 0
            #expect(abs(gap - 1200) < 120)
        }
    }

    @Test func emptyIsNil() {
        #expect(EvryWhen.parse("") == nil)
    }
}

// MARK: - Place labels

@MainActor
struct PlaceLabelTests {
    private func cand(_ name: String, _ category: MKPointOfInterestCategoryProxy = .none,
                      address: Bool = false) -> PlaceCandidate {
        PlaceCandidate(name: name, address: "1 Main St", category: category.value,
                       coordinate: .init(latitude: 0, longitude: 0), distance: nil, isAddress: address)
    }

    @Test func gymByName() {
        #expect(PlaceLabels.role(for: cand("North Mass Boulder"), stated: nil).label == "Gym")
    }

    @Test func groceryOnlyForChains() {
        #expect(PlaceLabels.role(for: cand("Kroger", .foodMarket), stated: nil).label == "Grocery store")
        let local = PlaceLabels.role(for: cand("Fresh Bites Market", .foodMarket), stated: nil)
        #expect(local.label == "Work")
        #expect(local.check == .work)
    }

    @Test func houseAsksHome() {
        let r = PlaceLabels.role(for: cand("4410 N Park Ave", address: true), stated: nil)
        #expect(r.label == "Home")
        #expect(r.check == .home)
    }

    @Test func savedWorkIsNotAskedAgain() {
        let r = PlaceLabels.role(for: cand("Salesforce Tower"), stated: nil, saved: ["Work"])
        #expect(r.label == "Location")
        #expect(r.check == .none)
    }

    @Test func statedKindIgnoresThePlaceName() {
        #expect(PlaceLabels.statedKind(in: "my gym, Planet Fitness", excluding: "Planet Fitness") == "Gym")
        #expect(PlaceLabels.statedKind(in: "Whole Foods Market", excluding: "Whole Foods Market") == nil)
    }

    @Test func repliesByRule() async {
        #expect(await PlaceResolver.interpretReply("yes") == .yes)
        #expect(await PlaceResolver.interpretReply("nope") == .no)
        #expect(await PlaceResolver.interpretReply("wrong one") == .wrongPlace)
        #expect(await PlaceResolver.interpretReply("no that's just a store I go to") == .kind("Store"))
    }

    @Test func negatedReplyIsANo() async {
        await withKnownIssue("B11: negation read as a kind") {
            #expect(await PlaceResolver.interpretReply("no, I don't work there") == .no)
        }
    }
}

/// Lets tests name a category (or none) without importing MapKit at each site.
import MapKit
struct MKPointOfInterestCategoryProxy {
    let value: MKPointOfInterestCategory?
    static let none = MKPointOfInterestCategoryProxy(value: nil)
    static let foodMarket = MKPointOfInterestCategoryProxy(value: .foodMarket)
}

// MARK: - Saved place matching

@MainActor
struct PlaceMatchTests {
    private let places = [
        FrequentPlace(label: "Gym", name: "North Mass Boulder", address: "1411 Roosevelt Ave", latitude: 0, longitude: 0),
        FrequentPlace(label: "Work", name: "Salesforce Tower", address: "111 Monument Cir", latitude: 0, longitude: 0),
        FrequentPlace(label: "Home", name: "4410 N Park Ave", address: "4410 N Park Ave", latitude: 0, longitude: 0),
    ]

    @Test(arguments: [
        ("Go to the gym", "Gym"), ("Leg day", "Gym"), ("North Mass with Sam", "Gym"),
        ("Meeting at the office", "Work"), ("Commute", "Work"), ("Head home", "Home"),
    ])
    func matches(title: String, label: String) {
        #expect(FrequentPlaces.match(for: title, in: places)?.label == label)
    }

    @Test(arguments: ["Work on API docs", "Pick up paint at Home Depot", "Write report"])
    func noMatch(title: String) {
        #expect(FrequentPlaces.match(for: title, in: places) == nil)
    }
}

// MARK: - Chat formatting

@MainActor
struct BulletFormattingTests {
    @Test func inlineBulletsBreakOntoLines() {
        #expect(EvryConversation.formatBullets("Today: • A • B") == "Today:\n• A\n• B")
    }

    @Test func dashBulletsBecomeDots() {
        #expect(EvryConversation.formatBullets("Notes:\n- A\n* B") == "Notes:\n• A\n• B")
    }

    @Test func plainTextUntouched() {
        #expect(EvryConversation.formatBullets("All set!") == "All set!")
    }
}

// MARK: - Habits

@MainActor
struct HabitStatsTests {
    @Test func streakCountsConsecutiveDays() throws {
        let ctx = try memoryContext()
        let habit = Habit(name: "Read")
        habit.createdAt = cal.date(byAdding: .day, value: -10, to: Date())!
        ctx.insert(habit)
        for back in 0..<3 {
            ctx.insert(HabitEntry(habit: habit, day: cal.date(byAdding: .day, value: -back, to: Date())!))
        }
        let stats = HabitStats(habit: habit)
        #expect(stats.currentStreak == 3)
        #expect(stats.todayDone)
        #expect(stats.completedDays == 3)
        // The cheap helpers agree with the full stats.
        #expect(habit.isDoneToday == stats.todayDone)
        #expect(habit.checkIns(on: Date()) == stats.today)
        #expect(habit.isDue(on: Date()))
    }
}

// MARK: - Recurring tasks

@MainActor
struct RecurrenceTests {
    private func context() throws -> ModelContext { try memoryContext() }

    @Test func completingSpawnsTheNextOccurrence() throws {
        let ctx = try context()
        let task = TaskItem(title: "Water plants", dueDate: startOfDay(Date()), autoLocation: false)
        task.recurrence = .daily
        ctx.insert(task)
        TaskActions.toggle(task, context: ctx)
        let all = try ctx.fetch(FetchDescriptor<TaskItem>())
        #expect(all.count == 2)
        #expect(all.contains { !$0.completed && $0.dueDate.map { cal.isDateInTomorrow($0) } == true })
    }

    @Test func uncompletingRemovesTheSpawnedCopy() throws {
        let ctx = try context()
        let task = TaskItem(title: "Water plants", dueDate: startOfDay(Date()), autoLocation: false)
        task.recurrence = .daily
        ctx.insert(task)
        TaskActions.toggle(task, context: ctx)
        TaskActions.toggle(task, context: ctx)
        let open = try ctx.fetch(FetchDescriptor<TaskItem>()).filter { !$0.isTrashed }
        withKnownIssue("B7: un-completing leaves the spawned copy") {
            #expect(open.count == 1)
        }
    }
}
