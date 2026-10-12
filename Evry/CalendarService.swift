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
                calendarTitle: ek.calendar?.title ?? "",
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

    /// Robustly resolves the `EKEvent` for a tapped item. `event(withIdentifier:)`
    /// returns nil for some imported/subscribed calendar events, so fall back to
    /// scanning that day's events and matching the identifier.
    func editableEvent(id: String, title: String? = nil, near date: Date) -> EKEvent? {
        // 1. The usual path — resolves events keyed by their eventIdentifier.
        if let e = store.event(withIdentifier: id) { return e }
        // 2. Events whose eventIdentifier is nil are keyed by calendarItemIdentifier;
        //    resolve those with the API that actually accepts that identifier.
        if let item = store.calendarItem(withIdentifier: id) as? EKEvent { return item }
        guard isAuthorized else { return nil }
        // 3. Scan a few days around the tapped time — wide enough to catch all-day,
        //    multi-day, and timezone-boundary occurrences whose start was clamped to
        //    a different day.
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: date)) ?? date
        let end = cal.date(byAdding: .day, value: 4, to: cal.startOfDay(for: date)) ?? date
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let matches = store.events(matching: predicate)
        // 3a. Match on either identifier EventKit exposes.
        if let byID = matches.first(where: { $0.eventIdentifier == id || $0.calendarItemIdentifier == id }) {
            return byID
        }
        // 3b. Final fallback — identifiers can differ between the cached snapshot and
        //     a fresh query (e.g. synced calendars); match by title + start instead.
        if let title {
            return matches.first {
                $0.title == title && abs($0.startDate.timeIntervalSince(date)) < 60
            }
        }
        return nil
    }

    func importEvent(_ event: CalendarEvent, context: ModelContext) {
        guard !importedEventIDs.contains(event.id) else { return }
        let task = TaskItem(title: event.title, dueDate: event.startDate)
        context.insert(task)
        importedEventIDs.insert(event.id)
        UserDefaults.standard.set(Array(importedEventIDs), forKey: "evry_imported_event_ids")
    }

    /// Saves a timed event to the default calendar (used by press-and-drag
    /// creation on the day timeline). Returns false if not authorized or the save fails.
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

    /// Moves/resizes an existing event (just this occurrence of a repeating one).
    @discardableResult
    func reschedule(_ event: EKEvent, start: Date, end: Date) -> Bool {
        guard isAuthorized, event.calendar?.allowsContentModifications ?? false else { return false }
        event.startDate = start
        event.endDate = end
        do { try store.save(event, span: .thisEvent); return true } catch { return false }
    }

    /// Colour of the calendar new events go into (for the draft block preview).
    var defaultCalendarColor: CGColor? { store.defaultCalendarForNewEvents?.cgColor }

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
