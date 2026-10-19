//
//  EventEditorView.swift
//  Evry
//
//  The Evry event editor — replaces Apple's EKEventEditViewController for both
//  creating and editing calendar events, styled like the task editor: compact
//  outlined cards for title/notes and the details (all-day, start, end, repeat,
//  place, travel time, alert). Saves straight to EventKit.
//
//  Travel time: EventKit has no public travel-time API (Apple Calendar's own
//  travel time isn't exposed). Evry stores it two ways:
//   • an extra EKAlarm at `start - travelTime`, so the device reminds you to
//     leave (this is what actually happens in the calendar), and
//   • the chosen duration in UserDefaults, keyed by the event's
//     calendarItemIdentifier, so the editor can tell that alarm apart from the
//     regular alert when the event is reopened (a 30-min travel alarm and a
//     30-min alert are otherwise identical EKAlarms).
//  Other apps will see the travel alarm as a plain alert; it does not block
//  time on the calendar.
//

import SwiftUI
import EventKit
import UIKit

struct EventEditorView: View {
    let palette: Palette
    let store: EKEventStore
    let event: EKEvent
    /// Called when the editor closes. `true` when the store was changed (saved
    /// or deleted), so the caller can refresh.
    var onDone: (_ changed: Bool) -> Void

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var repeatRule: EventRepeat
    @State private var location: String
    /// The location filled in from a saved place the title mentions ("Work",
    /// "Gym"), so it can follow the title until the person sets their own.
    @State private var autoLocation: String? = nil
    @State private var travel: EventTravel
    @State private var alert: EventAlert
    @State private var notes: String

    @State private var expanded: DateField?
    @State private var showDeleteConfirm = false
    @State private var spanChoice: SpanChoice?
    @State private var errorMessage: String?
    @FocusState private var focus: TextFieldID?

    /// Snapshot of what was loaded, to detect edits.
    private let original: Snapshot
    /// Alarms the editor doesn't manage (a second alert, absolute-date alarms) —
    /// preserved untouched when the alert or travel time changes.
    private let otherAlarms: [EKAlarm]
    private let isNew: Bool
    private let readOnly: Bool

    private enum DateField: Hashable { case startDate, startTime, endDate, endTime }
    private enum TextFieldID: Hashable { case title, location, notes }
    private enum SpanChoice: Identifiable {
        case save(allowThisEvent: Bool), delete
        var id: String {
            switch self {
            case .save: return "save"
            case .delete: return "delete"
            }
        }
    }

    private struct Snapshot: Equatable {
        var title: String, isAllDay: Bool, start: Date, end: Date
        var repeatRule: EventRepeat, location: String, travel: EventTravel
        var alert: EventAlert, notes: String
    }

    private let cal = Calendar.current

    init(palette: Palette, store: EKEventStore, event: EKEvent, onDone: @escaping (_ changed: Bool) -> Void) {
        self.palette = palette
        self.store = store
        self.event = event
        self.onDone = onDone
        isNew = event.eventIdentifier == nil
        readOnly = !(event.calendar?.allowsContentModifications ?? true)

        let travel = EventTravel.stored(for: event)
        // Split the alarms: one relative alarm matching the travel offset is the
        // travel alarm; the first remaining relative alarm is "the" alert; the
        // rest are kept as-is.
        var alarms = event.alarms ?? []
        if travel != .none,
           let i = alarms.firstIndex(where: { $0.absoluteDate == nil && $0.relativeOffset == -travel.seconds }) {
            alarms.remove(at: i)
        }
        var alert = EventAlert.none
        if let i = alarms.firstIndex(where: { $0.absoluteDate == nil }) {
            alert = EventAlert(offset: alarms[i].relativeOffset)
            alarms.remove(at: i)
        }
        otherAlarms = alarms

        let start = event.startDate ?? .now
        let end = event.endDate ?? start.addingTimeInterval(3600)
        let snap = Snapshot(
            title: event.title ?? "",
            isAllDay: event.isAllDay,
            start: start,
            end: end,
            repeatRule: EventRepeat(rule: event.recurrenceRules?.first),
            location: event.location ?? "",
            travel: travel,
            alert: alert,
            notes: event.notes ?? ""
        )
        original = snap
        _title = State(initialValue: snap.title)
        _isAllDay = State(initialValue: snap.isAllDay)
        _start = State(initialValue: snap.start)
        _end = State(initialValue: snap.end)
        _repeatRule = State(initialValue: snap.repeatRule)
        _location = State(initialValue: snap.location)
        _travel = State(initialValue: snap.travel)
        _alert = State(initialValue: snap.alert)
        _notes = State(initialValue: snap.notes)
    }

    private var current: Snapshot {
        Snapshot(title: title, isAllDay: isAllDay, start: start, end: end, repeatRule: repeatRule,
                 location: location, travel: travel, alert: alert, notes: notes)
    }
    private var hasChanges: Bool { current != original }

    // MARK: Body

    // Laid out like the task editor: a header with the actions, then compact
    // outlined cards — title and notes, the details, and delete.
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    if readOnly {
                        Text("This calendar is read-only, so this event can't be changed.")
                            .font(.evrySmall)
                            .foregroundStyle(palette.textSec)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    mainCard
                    detailsCard
                    if travel != .none {
                        Text("You'll get a reminder to leave \(travel.label.lowercased()) before it starts.")
                            .font(.nunito(size: 13, weight: .semibold))
                            .foregroundStyle(palette.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    if let errorMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                            Text(errorMessage)
                        }
                        .font(.evrySmall)
                        .foregroundStyle(palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !isNew && !readOnly {
                        Button {
                            focus = nil
                            showDeleteConfirm = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                    .font(.nunito(size: 15, weight: .semibold))
                                Text("Delete event")
                                    .font(.nunito(size: 15, weight: .bold))
                            }
                            .foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .editCard(palette)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .disabled(readOnly)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(palette.bg.ignoresSafeArea())
        .tint(palette.primary)
        .presentationBackground(palette.bg)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasChanges)
        .evryConfirm(
            isPresented: $showDeleteConfirm,
            title: "Delete this event?",
            message: "It will be removed from your calendar.",
            confirmTitle: "Delete"
        ) {
            if event.hasRecurrenceRules {
                spanChoice = .delete
            } else {
                delete(span: .thisEvent)
            }
        }
        .overlay {
            if let choice = spanChoice {
                spanChoiceCard(choice)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(EvryMotion.card, value: spanChoice?.id)
        .onChange(of: start) { old, new in
            // Moving the start keeps the event's length.
            end = new.addingTimeInterval(max(0, end.timeIntervalSince(old)))
        }
        .onChange(of: end) { _, new in
            if new < start { end = start }
        }
        .onAppear {
            if isNew { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focus = .title } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Text(isNew ? "New event" : "Edit event")
                .font(.evryH3)
                .foregroundStyle(palette.text)
            Spacer()
            Button("Cancel") { close(changed: false) }
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(palette.textSec)
                .padding(.horizontal, 10)
                .frame(minHeight: EvrySpace.tap)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
            Button("Save", action: attemptSave)
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(palette.onPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 34)
                .background(palette.primary, in: Capsule())
                .frame(minHeight: EvrySpace.tap)
                .buttonStyle(PressScaleStyle())
                .disabled(readOnly || (!isNew && !hasChanges))
                .opacity(readOnly || (!isNew && !hasChanges) ? 0.4 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    // MARK: Cards

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("New event", text: $title, axis: .vertical)
                .font(.nunito(size: 19, weight: .bold))
                .foregroundStyle(palette.text)
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .onChange(of: title) { _, newTitle in
                    // Only fills an empty location (or one it filled itself).
                    guard !readOnly, location.isEmpty || location == autoLocation else { return }
                    let match = FrequentPlaces.match(for: newTitle)?.locationString
                    withAnimation(EvryMotion.settle) {
                        location = match ?? ""
                        autoLocation = match
                    }
                }
            hairline
            TextField("Add notes…", text: $notes, axis: .vertical)
                .font(.evryBody)
                .foregroundStyle(palette.textSec)
                .lineLimit(1...8)
                .focused($focus, equals: .notes)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .editCard(palette)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            row(icon: "sun.max", label: "All-day") {
                Toggle("All-day", isOn: $isAllDay.animation(EvryMotion.card))
                    .labelsHidden()
                    .tint(palette.primary)
            }
            hairline
            dateRow("Starts", icon: "calendar", date: $start, dateField: .startDate, timeField: .startTime)
            hairline
            dateRow("Ends", icon: "calendar.badge.checkmark", date: $end, dateField: .endDate,
                    timeField: .endTime, minimum: start)
            hairline
            row(icon: "arrow.triangle.2.circlepath", label: "Repeat") {
                inlineMenu(selection: $repeatRule,
                           options: EventRepeat.choices(including: original.repeatRule),
                           label: \.label)
            }
            hairline
            row(icon: "mappin.and.ellipse", label: "Place") {
                TextField("Add a place", text: $location)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .location)
                    .submitLabel(.done)
            }
            hairline
            row(icon: "car", label: "Travel time") {
                inlineMenu(selection: $travel, options: EventTravel.allCases, label: \.label)
            }
            hairline
            row(icon: "bell", label: "Alert") {
                inlineMenu(selection: $alert,
                           options: EventAlert.choices(including: original.alert),
                           label: { $0.label(allDay: isAllDay) })
            }
        }
        .font(.evryBody)
        .foregroundStyle(palette.text)
        .editCard(palette)
    }

    // MARK: Building blocks

    private var hairline: some View {
        Rectangle().fill(palette.hairline).frame(height: 1).padding(.leading, 14)
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.nunito(size: 15, weight: .semibold))
            .foregroundStyle(palette.primary)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    /// A compact details row: icon, label, and its control on the right.
    private func row<Control: View>(icon: String, label: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            rowIcon(icon)
            Text(label)
                .font(.nunito(size: 15, weight: .semibold))
                .foregroundStyle(palette.text)
                .fixedSize()
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }

    /// "Starts  [Mon, Oct 12]  [9:00 AM]" — chips that open an inline picker
    /// beneath the row.
    @ViewBuilder
    private func dateRow(_ label: String, icon: String, date: Binding<Date>, dateField: DateField,
                         timeField: DateField, minimum: Date? = nil) -> some View {
        row(icon: icon, label: label) {
            HStack(spacing: 6) {
                chip(date.wrappedValue.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                     field: dateField)
                if !isAllDay {
                    chip(date.wrappedValue.formatted(.dateTime.hour().minute()), field: timeField)
                }
            }
        }

        if expanded == dateField {
            pickerContainer {
                DatePicker("", selection: date, in: (minimum ?? .distantPast)..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
        } else if expanded == timeField && !isAllDay {
            pickerContainer {
                DatePicker("", selection: date, in: (minimum ?? .distantPast)...,
                           displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func pickerContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .tint(palette.primary)
            .padding(.horizontal, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// A white outlined chip (filled sky while its picker is open).
    private func chip(_ text: String, field: DateField) -> some View {
        let on = expanded == field
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            focus = nil
            withAnimation(EvryMotion.card) { expanded = on ? nil : field }
        } label: {
            Text(text)
                .font(.nunito(size: 14, weight: .bold))
                .foregroundStyle(on ? Color.evryNavy : palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(on ? Color.evrySky : palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : palette.border, lineWidth: 1))
                .frame(minHeight: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The current choice with an up/down chevron, opening a menu of options.
    private func inlineMenu<T: Hashable>(selection: Binding<T>, options: [T],
                                         label: @escaping (T) -> String) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    selection.wrappedValue = option
                } label: {
                    if option == selection.wrappedValue {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label(selection.wrappedValue))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.nunito(size: 11, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.nunito(size: 15, weight: .semibold))
            .foregroundStyle(palette.text)
            .frame(minHeight: EvrySpace.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Span choice (repeating events)

    private func spanChoiceCard(_ choice: SpanChoice) -> some View {
        let isDelete: Bool
        let allowThisEvent: Bool
        switch choice {
        case .save(let allow): isDelete = false; allowThisEvent = allow
        case .delete: isDelete = true; allowThisEvent = true
        }
        return ZStack {
            Color.evryNavy.opacity(palette.dark ? 0.5 : 0.28)
                .ignoresSafeArea()
                .onTapGesture { spanChoice = nil }
            VStack(spacing: 14) {
                Text(isDelete ? "Delete a repeating event" : "Save a repeating event")
                    .font(.evryTitle)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.center)
                Text(isDelete ? "Delete just this one, or this and every one after it?"
                              : (allowThisEvent ? "Change just this one, or this and every one after it?"
                                                : "Changing how it repeats applies to this and every one after it."))
                    .font(.evryBody)
                    .foregroundStyle(palette.textSec)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    if allowThisEvent {
                        Button {
                            spanChoice = nil
                            if isDelete { delete(span: .thisEvent) } else { save(span: .thisEvent) }
                        } label: { Text("This event only").frame(maxWidth: .infinity) }
                        .buttonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true))
                    }
                    Button(role: isDelete ? .destructive : nil) {
                        spanChoice = nil
                        if isDelete { delete(span: .futureEvents) } else { save(span: .futureEvents) }
                    } label: { Text("All future events").frame(maxWidth: .infinity) }
                    .buttonStyle(allowThisEvent
                                 ? AnyButtonStyle(EvrySecondaryButtonStyle(palette: palette, fullWidth: true))
                                 : AnyButtonStyle(EvryPrimaryButtonStyle(palette: palette, fullWidth: true)))
                    Button("Cancel") { spanChoice = nil }
                        .font(.evryLabel)
                        .foregroundStyle(palette.primary)
                        .frame(maxWidth: .infinity, minHeight: EvrySpace.tap)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(EvrySpace.card)
            .frame(maxWidth: 360)
            .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 1))
            .evryShadowLift(palette)
            .padding(.horizontal, 32)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    // MARK: Actions

    private func close(changed: Bool) {
        focus = nil
        onDone(changed)
    }

    private func attemptSave() {
        focus = nil
        errorMessage = nil
        if !isNew && event.hasRecurrenceRules {
            // Changing the repeat rule itself only makes sense for the series.
            spanChoice = .save(allowThisEvent: repeatRule == original.repeatRule)
        } else {
            save(span: .thisEvent)
        }
    }

    private func save(span: EKSpan) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.title = trimmed.isEmpty ? "New event" : trimmed
        event.isAllDay = isAllDay
        if isAllDay {
            let first = cal.startOfDay(for: start)
            let last = cal.startOfDay(for: max(end, start))
            event.startDate = first
            // EventKit reports all-day events as ending at the last second of
            // their final day; write it the same way so it round-trips.
            event.endDate = last.addingTimeInterval(86_399)
        } else {
            event.startDate = start
            event.endDate = max(end, start)
        }
        event.location = location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if isNew || repeatRule != original.repeatRule {
            event.recurrenceRules = repeatRule.rule.map { [$0] }
        }
        if isNew || alert != original.alert || travel != original.travel {
            var alarms = otherAlarms
            if let offset = alert.offset { alarms.append(EKAlarm(relativeOffset: offset)) }
            if travel != .none { alarms.append(EKAlarm(relativeOffset: -travel.seconds)) }
            event.alarms = alarms.isEmpty ? nil : alarms
        }
        if event.calendar == nil { event.calendar = store.defaultCalendarForNewEvents }

        do {
            try store.save(event, span: span, commit: true)
            EventTravel.store(travel, for: event)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            close(changed: true)
        } catch {
            store.reset()
            errorMessage = "We couldn't save this event. Please try again."
        }
    }

    private func delete(span: EKSpan) {
        do {
            try store.remove(event, span: span, commit: true)
            if span == .futureEvents || !event.hasRecurrenceRules { EventTravel.store(.none, for: event) }
            close(changed: true)
        } catch {
            // Drop any half-applied change, as a failed save does, so a retry
            // (or the calendar on screen) starts from what's really stored.
            store.reset()
            errorMessage = "We couldn't delete this event. Please try again."
        }
    }
}

// MARK: - Options

/// The repeat choices. `.custom` keeps a rule Evry can't express (e.g. "every
/// weekday") untouched unless the user picks something else.
enum EventRepeat: Hashable {
    case none, daily, weekly, biweekly, monthly, yearly, custom

    static let standard: [EventRepeat] = [.none, .daily, .weekly, .biweekly, .monthly, .yearly]

    static func choices(including original: EventRepeat) -> [EventRepeat] {
        original == .custom ? standard + [.custom] : standard
    }

    init(rule: EKRecurrenceRule?) {
        guard let rule else { self = .none; return }
        // Rules with extra constraints (specific weekdays, set positions…) are
        // more than the simple choices describe.
        let simple = (rule.daysOfTheWeek ?? []).isEmpty && (rule.daysOfTheMonth ?? []).isEmpty
            && (rule.monthsOfTheYear ?? []).isEmpty && (rule.setPositions ?? []).isEmpty
        switch (rule.frequency, rule.interval, simple) {
        case (.daily, 1, true):   self = .daily
        case (.weekly, 1, true):  self = .weekly
        case (.weekly, 2, true):  self = .biweekly
        case (.monthly, 1, true): self = .monthly
        case (.yearly, 1, true):  self = .yearly
        default:                  self = .custom
        }
    }

    var label: String {
        switch self {
        case .none: return "None"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Every month"
        case .yearly: return "Every year"
        case .custom: return "Custom"
        }
    }

    /// The rule to write, or nil for no repeat. (`.custom` is only ever saved
    /// when unchanged, so it never reaches here.)
    var rule: EKRecurrenceRule? {
        let parts: (EKRecurrenceFrequency, Int)
        switch self {
        case .none, .custom: return nil
        case .daily: parts = (.daily, 1)
        case .weekly: parts = (.weekly, 1)
        case .biweekly: parts = (.weekly, 2)
        case .monthly: parts = (.monthly, 1)
        case .yearly: parts = (.yearly, 1)
        }
        return EKRecurrenceRule(recurrenceWith: parts.0, interval: parts.1, end: nil)
    }
}

/// The alert choices, as offsets from the event's start. `.other` preserves an
/// existing alert that isn't one of the presets.
enum EventAlert: Hashable {
    case none
    case before(TimeInterval)
    case other(TimeInterval)

    static let presets: [EventAlert] = [.none, .before(0), .before(300), .before(600), .before(900),
                                        .before(1800), .before(3600), .before(86_400)]

    static func choices(including original: EventAlert) -> [EventAlert] {
        if case .other = original { return presets + [original] }
        return presets
    }

    init(offset: TimeInterval) {
        let seconds = -offset
        self = Self.presets.contains(.before(seconds)) ? .before(seconds) : .other(offset)
    }

    var offset: TimeInterval? {
        switch self {
        case .none: return nil
        case .before(let s): return -s
        case .other(let o): return o
        }
    }

    func label(allDay: Bool) -> String {
        switch self {
        case .none: return "None"
        case .before(0): return allDay ? "On the day" : "At time of event"
        case .before(let s): return "\(Self.duration(s)) before"
        case .other(let o): return o <= 0 ? "\(Self.duration(-o)) before" : "\(Self.duration(o)) after"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes % 1440 == 0 { let d = minutes / 1440; return d == 1 ? "1 day" : "\(d) days" }
        if minutes % 60 == 0 { let h = minutes / 60; return h == 1 ? "1 hour" : "\(h) hours" }
        return "\(minutes) min"
    }
}

/// Travel time — stored as an extra "time to leave" alarm plus a local record
/// (see the file header for why).
enum EventTravel: Int, CaseIterable, Hashable {
    case none = 0, five = 5, fifteen = 15, thirty = 30, hour = 60, ninety = 90, twoHours = 120

    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    var label: String {
        switch self {
        case .none: return "None"
        case .ninety: return "1.5 hours"
        default: return EventAlert.duration(seconds)
        }
    }

    private static func key(_ event: EKEvent) -> String {
        "evry_event_travel_\(event.calendarItemIdentifier)"
    }

    static func stored(for event: EKEvent) -> EventTravel {
        guard event.eventIdentifier != nil else { return .none }
        return EventTravel(rawValue: UserDefaults.standard.integer(forKey: key(event))) ?? .none
    }

    static func store(_ travel: EventTravel, for event: EKEvent) {
        if travel == .none {
            UserDefaults.standard.removeObject(forKey: key(event))
        } else {
            UserDefaults.standard.set(travel.rawValue, forKey: key(event))
        }
    }
}

// MARK: - Helpers

/// Type-erases a button style so one button can switch between primary and
/// secondary looks.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
