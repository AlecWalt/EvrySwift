//
//  CalendarService.swift
//  Evry
//

import EventKit
import SwiftUI
import SwiftData
import UIKit

// MARK: - Value types

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let calendarColor: Color
}

struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let sourceTitle: String
    let color: Color
}

// MARK: - Service

@Observable
final class CalendarService {
    var authStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    var allCalendars: [EKCalendar] = []
    var selectedCalendarIDs: Set<String> = []
    var importedEventIDs: Set<String> = []
    var hiddenCalendarIDs: Set<String> = []

    private let store = EKEventStore()

    var isAuthorized: Bool { authStatus == .fullAccess }
    var accessDenied: Bool { authStatus == .denied || authStatus == .restricted }

    var authStatusLabel: String {
        switch authStatus {
        case .notDetermined:
            return "Connect your calendar to see Apple, Google, and Outlook events alongside your tasks."
        case .denied, .restricted:
            return "Calendar access was denied. Enable it in Settings → Privacy & Security → Calendars."
        case .fullAccess:
            return "Connected"
        case .writeOnly:
            return "Full access is required. Enable it in Settings → Privacy & Security → Calendars."
        @unknown default:
            return "Unable to determine calendar access."
        }
    }

    var allCalendarInfos: [CalendarInfo] {
        allCalendars
            .filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
            .map { cal in
                CalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    sourceTitle: cal.source.title,
                    color: Color(UIColor(cgColor: cal.cgColor))
                )
            }
    }

    init() {
        if let ids = UserDefaults.standard.array(forKey: "evry_selected_calendar_ids") as? [String] {
            selectedCalendarIDs = Set(ids)
        }
        if let ids = UserDefaults.standard.array(forKey: "evry_imported_event_ids") as? [String] {
            importedEventIDs = Set(ids)
        }
        if let ids = UserDefaults.standard.array(forKey: "evry_hidden_calendar_ids") as? [String] {
            hiddenCalendarIDs = Set(ids)
        }
        if isAuthorized { refreshCalendars() }
    }

    func requestAccess() async {
        do { _ = try await store.requestFullAccessToEvents() } catch {}
        authStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized { refreshCalendars() }
    }

    func refreshStatus() {
        authStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized { refreshCalendars() }
    }

    func refreshCalendars() {
        allCalendars = store.calendars(for: .event)
        if selectedCalendarIDs.isEmpty {
            selectedCalendarIDs = Set(allCalendars.map(\.calendarIdentifier))
            UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: "evry_selected_calendar_ids")
        }
    }

    func hideCalendar(_ id: String) {
        hiddenCalendarIDs.insert(id)
        selectedCalendarIDs.remove(id)
        UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: "evry_hidden_calendar_ids")
        UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: "evry_selected_calendar_ids")
    }

    func toggleCalendar(_ id: String) {
        if selectedCalendarIDs.contains(id) {
            selectedCalendarIDs.remove(id)
        } else {
            selectedCalendarIDs.insert(id)
        }
        UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: "evry_selected_calendar_ids")
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        let active = allCalendars.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        guard !active.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: active)
        return store.events(matching: predicate).map { ek in
            let cgColor = ek.calendar?.cgColor ?? CGColor(gray: 0.5, alpha: 1)
            return CalendarEvent(
                id: ek.eventIdentifier ?? UUID().uuidString,
                title: ek.title ?? "Untitled",
                startDate: ek.startDate,
                endDate: ek.endDate,
                isAllDay: ek.isAllDay,
                calendarTitle: ek.calendar?.title ?? "",
                calendarColor: Color(UIColor(cgColor: cgColor))
            )
        }.sorted { $0.startDate < $1.startDate }
    }

    func importEvent(_ event: CalendarEvent, context: ModelContext) {
        guard !importedEventIDs.contains(event.id) else { return }
        let task = TaskItem(title: event.title, dueDate: event.startDate)
        context.insert(task)
        importedEventIDs.insert(event.id)
        UserDefaults.standard.set(Array(importedEventIDs), forKey: "evry_imported_event_ids")
    }

    @discardableResult
    func saveAccomplishment(date: Date, title: String, notes: String) -> Bool {
        guard isAuthorized else { return false }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.isAllDay = true
        event.startDate = Calendar.current.startOfDay(for: date)
        event.endDate = Calendar.current.startOfDay(for: date)
        event.calendar = store.defaultCalendarForNewEvents
        do { try store.save(event, span: .thisEvent); return true } catch { return false }
    }
}
