//
//  CalendarService.swift
//  Evry
//

import EventKit
import SwiftUI
import UIKit

// MARK: - Value types

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarColor: Color
    /// The live EKEvent this was built from — carried through so a tap can edit
    /// the exact event directly, without fragile identifier re-resolution.
    var ekEvent: EKEvent? = nil
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
    var hiddenCalendarIDs: Set<String> = []

    private let store = EKEventStore()

    var isAuthorized: Bool { authStatus == .fullAccess }
    var accessDenied: Bool { authStatus == .denied || authStatus == .restricted }

    var authStatusLabel: String {
        switch authStatus {
        case .notDetermined:
            return "Connect your calendar to see Apple, Google, and Outlook events alongside your tasks."
        case .denied, .restricted:
            return "Calendar access is turned off. You can turn it on in Settings → Privacy & Security → Calendars."
        case .fullAccess:
            return "Connected"
        case .writeOnly:
            return "Evry needs full calendar access to show your events. Please turn it on in Settings → Privacy & Security → Calendars."
        @unknown default:
            return "We couldn’t check calendar access. Please try again in a moment."
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
            // No calendar colour → the brand sky rather than a stray grey.
            let cgColor = ek.calendar?.cgColor ?? UIColor(Color.evrySky).cgColor
            return CalendarEvent(
                // Prefer the event identifier, but fall back to the always-present
                // calendarItemIdentifier so events whose eventIdentifier is nil
                // (some imported/subscribed calendars) still resolve for editing —
                // rather than a throwaway UUID that could never be looked up.
                id: ek.eventIdentifier ?? ek.calendarItemIdentifier,
                title: ek.title ?? "Untitled",
                startDate: ek.startDate,
                endDate: ek.endDate,
                isAllDay: ek.isAllDay,
                calendarColor: Color(UIColor(cgColor: cgColor)),
                ekEvent: ek
            )
        }.sorted { $0.startDate < $1.startDate }
    }

    /// The underlying store — needed to host `EKEventEditViewController`.
    var eventStore: EKEventStore { store }

    /// Fetches the editable `EKEvent` behind a `CalendarEvent`, if it still exists.
    func ekEvent(withIdentifier id: String) -> EKEvent? {
        store.event(withIdentifier: id)
    }

    /// Saves a timed event to the default calendar. Returns false if not
    /// authorized or the save fails.
    @discardableResult
    func createEvent(title: String, start: Date, end: Date) -> Bool {
        guard isAuthorized else { return false }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = store.defaultCalendarForNewEvents
        do { try store.save(event, span: .thisEvent); return true } catch { return false }
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
