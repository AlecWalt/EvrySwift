//
//  TaskSheets.swift
//  Evry
//
//  AddTaskSheet — the quick-add bottom card: natural-language title field
//  with live keyword highlighting, optional notes / checklist and location,
//  swipe-to-schedule. Styled with the Evry tokens (white panel, navy ink,
//  sky highlights) — meaning is carried by icons and words, never hue.
//  EditTaskSheet — the task editor in Evry's own style (not a system form):
//  compact outlined cards for title/notes, details (due, time, repeat, place,
//  tags, high priority, pinned), subtasks, and duplicate/tomorrow/delete actions.
//

import CoreLocation
import MapKit
import SwiftUI
import SwiftData
import UIKit

// MARK: - Add sheet

/// One editable row of the quick-add checklist (a draft subtask before save).
private struct ChecklistDraftItem: Identifiable, Equatable {
    let id = UUID()
    var text: String = ""
    var completed: Bool = false
}

struct AddTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance

    /// Presented as a bottom overlay (not a system sheet) so there's no dimming
    /// layer; this drives its visibility.
    @Binding var isPresented: Bool

    @State private var text = ""
    @State private var notes = ""
    @State private var location = ""
    /// The location filled in from a saved place the title mentions (so it
    /// can follow the title as it changes), and whether it was dismissed.
    @State private var autoLocation: String? = nil
    @State private var autoLocationDismissed = false
    @State private var showNotes = false
    @State private var showLocation = false
    @State private var locationQuery = ""
    @State private var locationResults: [MKMapItem] = []
    @State private var locationSearchTask: Task<Void, Never>? = nil
    @State private var locationProvider = CurrentLocationProvider()
    @State private var titleFocused: Bool = false
    // Drives a visible upward glide as the card (and keyboard) come in.
    @State private var appeared = false
    @State private var grabberLit = true
    /// Brief dip-and-spring when a task is added with Return (the swipes move
    /// the whole card; the keyboard button gets this subtle bounce instead).
    @State private var returnBounce: CGFloat = 0
    // Tap-and-hold the card to flag the new task high priority (a gesture-based
    // alternative to typing "!high").
    @State private var isHighPriority = false
    // Checklist mode: the description turns from a free-text notes box into an
    // editable checkbox list (saved as the task's subtasks) — good for e.g. a
    // grocery list. Type an item, hit return to drop to the next checkbox.
    @State private var listMode = false
    @State private var listItems: [ChecklistDraftItem] = []
    @FocusState private var notesFocused: Bool
    @FocusState private var locationFocused: Bool
    @FocusState private var focusedListItem: UUID?

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private var parsed: ParsedTask? { text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : parseTaskInput(text) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Transparent tap-catcher — the live app stays visible behind the card.
            Color.evryNavy.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeSheet() }

        // The whole card is the swipeable surface: type into it, then fling it
        // to a day. On commit it's sent off-screen and a fresh card slides up.
        ScheduleSwipeCard(
            palette: palette,
            onSchedule: { date, _ in submit(overrideDate: date) },
            // Locked with nothing to schedule, or while picking a location so
            // scrolling the results doesn't accidentally fling the card.
            isLocked: parsed == nil || showLocation,
            sendsAway: true,
            onDismiss: { closeSheet() }
        ) {
        VStack(spacing: 0) {
            // Arrives lit in the accent as the swipe-up pill "lands" as this
            // card's grabber, then settles to the neutral grabber color.
            Capsule()
                .fill(grabberLit ? palette.primary : palette.border)
                .frame(width: grabberLit ? 56 : 36, height: 4)
                .shadow(color: palette.primary.opacity(grabberLit ? 0.45 : 0), radius: 5)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if isHighPriority {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.nunito(size: 12, weight: .bold))
                        .accessibilityHidden(true)
                    Text("High priority")
                        .font(.evryCaption)
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(palette.skySoft, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.evrySky, lineWidth: 1))
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            HStack(spacing: 8) {
                HighlightedTaskTextField(
                    // Return files the task under today; typed dates like "fri"
                    // or "next week" (or a swipe of the card) pick another day.
                    placeholder: "Add task…",
                    text: $text,
                    palette: palette,
                    // Sized so the single-line field matches the 44pt notes and
                    // location buttons beside it.
                    fontSize: 16,
                    minFontSize: 14,
                    autoFocus: true,
                    onSubmit: { submit() },
                    focused: $titleFocused
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: EvrySpace.tap)
                // High priority thickens the ring (the badge above says why) —
                // no red, the words and weight carry it.
                .modifier(QuickAddFieldChrome(palette: palette, focused: titleFocused,
                                              emphasised: isHighPriority))

                if !showNotes {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showNotes = true
                        }
                    } label: {
                        Image(systemName: "note.text")
                            .font(.nunito(size: 16, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                            .evryButtonFace(palette, in: Circle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel("Add notes")
                }

                if !showLocation {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showLocation = true
                        }
                        locationQuery = location
                    } label: {
                        Image(systemName: location.isEmpty ? "mappin" : "mappin.circle.fill")
                            .font(.nunito(size: 16, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                            .evryButtonFace(palette, in: Circle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityLabel(location.isEmpty ? "Add a location" : "Change location")
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: parsed == nil)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            // Closing padding only when the title row is the last thing in the
            // card, so every field-to-field gap is the same 8pt.
            .padding(.bottom, parsed != nil || showNotes || showLocation || !location.isEmpty ? 0 : 16)

            if parsed != nil && !showNotes {
                swipeHint
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }

            if showNotes {
                HStack(alignment: .top, spacing: 8) {
                    // Content: free-text notes, or an editable checkbox list.
                    if listMode {
                        VStack(spacing: 8) {
                            // Iterate values (not `$listItems`) and bind each field
                            // by id — a binding-based ForEach can index-crash when the
                            // array is cleared mid-fling on swipe-to-schedule.
                            ForEach(listItems) { item in
                                HStack(spacing: 10) {
                                    Button {
                                        toggleListItem(item.id)
                                        UISelectionFeedbackGenerator().selectionChanged()
                                    } label: {
                                        doneGlyph(item.completed, palette: palette, size: 18)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.completed ? "Done" : "Not done")
                                    // Multiline (axis) so Return inserts a newline
                                    // and keeps the keyboard up; we intercept that
                                    // newline to advance to the next checkbox.
                                    TextField("List item…", text: listItemBinding(item.id), axis: .vertical)
                                        .font(.nunito(size: 15))
                                        .foregroundStyle(palette.text)
                                        .focused($focusedListItem, equals: item.id)
                                        .onChange(of: item.text) { _, newValue in
                                            listReturn(id: item.id, text: newValue)
                                        }
                                }
                                // New rows slide/fade in from the top as they're added.
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Add notes…", text: $notes, axis: .vertical)
                            .font(.nunito(size: 15))
                            .foregroundStyle(palette.text)
                            .lineLimit(3...6)
                            .focused($notesFocused)
                    }

                    // Trailing controls: turn into a checklist, and collapse.
                    VStack(spacing: 6) {
                        Button { toggleListMode() } label: {
                            Image(systemName: listMode ? "text.alignleft" : "checklist")
                                .font(.nunito(size: 12, weight: .bold))
                                .foregroundStyle(palette.text)
                                .frame(width: 28, height: 28)
                                .background(listMode ? Palette.doneFill : palette.skySoft, in: Circle())
                                .contentShape(Circle().inset(by: -8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(listMode ? "Switch to notes" : "Switch to a checklist")

                        // Collapse arrow, matching the location picker.
                        Button {
                            // Move focus back to the title so the keyboard stays up
                            // instead of dismissing when the field is removed.
                            titleFocused = true
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showNotes = false }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.nunito(size: 12, weight: .bold))
                                .foregroundStyle(palette.text)
                                .frame(width: 28, height: 28)
                                .background(palette.skySoft, in: Circle())
                                .contentShape(Circle().inset(by: -8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide notes")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .modifier(QuickAddFieldChrome(palette: palette,
                                              focused: notesFocused || focusedListItem != nil))
                .padding(.horizontal, 14)
                .padding(.top, 8)
                // Closing padding only when nothing follows — with the location
                // field/chip below, the 8pt gap matches Title → Description.
                .padding(.bottom, location.isEmpty && !showLocation ? 16 : 0)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if showLocation {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.nunito(size: 15))
                            .foregroundStyle(palette.text)
                            .accessibilityHidden(true)
                        TextField("Search for a place…", text: $locationQuery)
                            .font(.evryBody)
                            .foregroundStyle(palette.text)
                            .focused($locationFocused)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                        if !locationQuery.isEmpty {
                            Button {
                                locationQuery = ""
                                locationResults = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.nunito(size: 15))
                                    .foregroundStyle(palette.textMuted)
                                    .contentShape(Circle().inset(by: -10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                        Button {
                            // Move focus back to the title so the keyboard stays up
                            // instead of dismissing when the location field is removed.
                            titleFocused = true
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showLocation = false }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.nunito(size: 12, weight: .bold))
                                .foregroundStyle(palette.text)
                                .frame(width: 28, height: 28)
                                .background(palette.skySoft, in: Circle())
                                .contentShape(Circle().inset(by: -8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide location search")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .modifier(QuickAddFieldChrome(palette: palette, focused: locationFocused))

                    if !locationResults.isEmpty {
                        VStack(spacing: 0) {
                            let shown = Array(locationResults.prefix(5).enumerated())
                            ForEach(shown, id: \.offset) { i, item in
                                Button {
                                    selectLocation(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(palette.skySoft).frame(width: 32, height: 32)
                                            Image(systemName: "mappin")
                                                .font(.nunito(size: 14, weight: .bold))
                                                .foregroundStyle(palette.text)
                                        }
                                        .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name ?? "Unnamed place")
                                                .font(.nunito(size: 15, weight: .semibold))
                                                .foregroundStyle(palette.text)
                                                .lineLimit(1)
                                            let subtitle = mapItemSubtitle(item)
                                            if !subtitle.isEmpty {
                                                Text(subtitle)
                                                    .font(.nunito(size: 12))
                                                    .foregroundStyle(palette.textSec)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .frame(minHeight: EvrySpace.tap)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if i < shown.count - 1 {
                                    Rectangle().fill(palette.border).frame(height: 1).padding(.leading, 56)
                                }
                            }
                        }
                        .evryField(palette, cornerRadius: EvryRadius.field)
                        .clipShape(RoundedRectangle(cornerRadius: EvryRadius.field, style: .continuous))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !location.isEmpty && !showLocation {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.nunito(size: 13))
                        .foregroundStyle(palette.text)
                        .accessibilityHidden(true)
                    Text(location)
                        .font(.nunito(size: 14, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        if location == autoLocation { autoLocationDismissed = true }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { location = "" }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.nunito(size: 10, weight: .bold))
                            .foregroundStyle(palette.text)
                            .frame(width: 22, height: 22)
                            .background(palette.card, in: Circle())
                            .contentShape(Circle().inset(by: -11))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove location")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(palette.skySoft, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.evrySky, lineWidth: 1))
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Color.clear.frame(height: location.isEmpty && !showNotes ? 0 : 0)
        }
        // Card background lives inside the swipe surface so the whole card
        // (not just its contents) travels when flung.
        .background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous)
            .strokeBorder(palette.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: EvryRadius.panel, style: .continuous))
        // Tap-and-hold anywhere on the card to toggle high priority.
        .onLongPressGesture(minimumDuration: 0.35) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isHighPriority.toggle()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .evryShadowLift(palette)
        } // ScheduleSwipeCard
        // Resolve the card at its ideal (compact) height so the text view sizes to
        // its content instead of filling the whole overlay.
        .fixedSize(horizontal: false, vertical: true)
        // Grows up out of the swipe-up pill: rises and scales from the bottom
        // edge with a touch of overshoot, timed with the keyboard rising.
        .scaleEffect(x: appeared ? 1 : 0.82, y: appeared ? 1 : 0.6, anchor: .bottom)
        .offset(y: appeared ? 0 : 70)
        .opacity(appeared ? 1 : 0)
        // Return-to-add bounce.
        .scaleEffect(1 - returnBounce * 0.004, anchor: .bottom)
        .offset(y: returnBounce)
        } // ZStack
        .onAppear {
            // Explicitly claim first responder on every presentation. `autoFocus`
            // (via didMoveToWindow) can miss when the view is reused across a
            // quick close/reopen; this guarantees the keyboard comes back up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                titleFocused = true
            }
            // Spring the card up as it appears (and the keyboard rises with it).
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 0.45).delay(0.35)) { grabberLit = false }
        }
        .onChange(of: showNotes) { _, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    notesFocused = true
                }
            }
        }
        // Leaving the checklist (e.g. tapping into the title or location field)
        // drops the blank row(s) left at the end of the list.
        .onChange(of: focusedListItem) { _, focused in
            if focused == nil && listMode { trimTrailingEmptyListItems() }
        }
        // A title about a saved place ("go to the gym") fills its location in;
        // it follows the title until the person picks or clears one themselves.
        .onChange(of: text) { _, newText in
            guard !autoLocationDismissed, location.isEmpty || location == autoLocation else { return }
            let title = parseTaskInput(newText).title
            let match = FrequentPlaces.match(for: title)?.locationString
            guard match != autoLocation else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                location = match ?? ""
                autoLocation = match
            }
        }
        .onChange(of: showLocation) { _, newValue in
            if newValue {
                locationProvider.locate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    locationFocused = true
                }
                if !locationQuery.isEmpty { scheduleLocationSearch(locationQuery) }
            } else {
                locationSearchTask?.cancel()
            }
        }
        .onChange(of: locationQuery) { _, q in scheduleLocationSearch(q) }
    }

    private func selectLocation(_ item: MKMapItem) {
        location = mapItemLabel(item, fallback: item.name ?? "")
        locationResults = []
        locationQuery = ""
        UISelectionFeedbackGenerator().selectionChanged()
        // Collapse the dropdown/bubble but keep the keyboard up by moving focus
        // back to the title field rather than resigning first responder.
        titleFocused = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showLocation = false }
    }

    /// Debounced MapKit search, biased to the device's region and re-sorted so
    /// the nearest matches surface first.
    private func scheduleLocationSearch(_ q: String) {
        locationSearchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { locationResults = []; return }
        locationSearchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            let coord = locationProvider.coordinate
            if let coord {
                request.region = MKCoordinateRegion(center: coord, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
            }
            guard let response = try? await MKLocalSearch(request: request).start() else { return }
            let sorted = sortByDistance(response.mapItems, near: coord)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                locationResults = sorted
            }
        }
    }

    // Compact legend teaching the swipe-to-schedule directions.
    private var swipeHint: some View {
        // Directions are told apart by their arrows and words, not colour.
        HStack(spacing: 10) {
            Text("Swipe to schedule")
                .font(.nunito(size: 12, weight: .semibold))
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            swipeHintItem(icon: "arrow.up", label: "Today")
            swipeHintItem(icon: "arrow.right", label: "Tomorrow")
            swipeHintItem(icon: "arrow.left", label: "Weekend")
        }
        .minimumScaleFactor(0.85)
    }

    private func swipeHintItem(icon: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.nunito(size: 10, weight: .bold))
                .accessibilityHidden(true)
            Text(label)
                .font(.evryCaption)
                .lineLimit(1)
        }
        .foregroundStyle(palette.text)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Swipe \(icon == "arrow.up" ? "up" : icon == "arrow.right" ? "right" : "left") for \(label.lowercased())")
    }

    /// Closes the overlay, dismissing the keyboard immediately so it animates
    /// down in step with the card rather than lagging behind.
    private func closeSheet() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isPresented = false
    }

    /// Toggles the description between free-text notes and a checkbox list,
    /// carrying the content across so switching never loses what was typed.
    private func toggleListMode() {
        if !listMode {
            // Seed the list from any existing notes lines, plus a trailing empty
            // row ready for the next item.
            let lines = notes
                .split(whereSeparator: { $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            listItems = lines.map { ChecklistDraftItem(text: $0) } + [ChecklistDraftItem()]
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { listMode = true }
            let target = listItems.last?.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusedListItem = target }
        } else {
            // Fold the list back into notes (one item per line).
            notes = listItems
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { listMode = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { notesFocused = true }
        }
    }

    /// Removes empty rows from the end of the checklist, keeping one row if the
    /// list would otherwise be left with none.
    private func trimTrailingEmptyListItems() {
        var trimmed = listItems
        while trimmed.count > 1,
              let last = trimmed.last,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            trimmed.removeLast()
        }
        guard trimmed.count != listItems.count else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { listItems = trimmed }
    }

    /// Safe id-based binding to a list item's text (returns "" if the row was
    /// removed), so the field never reads a stale index during teardown.
    private func listItemBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { listItems.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                if let i = listItems.firstIndex(where: { $0.id == id }) {
                    listItems[i].text = newValue
                }
            }
        )
    }

    private func toggleListItem(_ id: UUID) {
        if let i = listItems.firstIndex(where: { $0.id == id }) {
            listItems[i].completed.toggle()
        }
    }

    /// A newline typed in a list row means "next checkbox". Because the field is
    /// multiline, the keyboard never resigns — we just split off the new row and
    /// move focus to it (any text after the caret carries into the new item).
    private func listReturn(id: UUID, text: String) {
        guard text.contains("\n"), let idx = listItems.firstIndex(where: { $0.id == id }) else { return }
        let comps = text.components(separatedBy: "\n")
        let head = comps[0]
        let tail = comps.dropFirst().joined(separator: "\n")
        // Return on an already-empty row: just strip the newline, don't add a row.
        if head.trimmingCharacters(in: .whitespaces).isEmpty && tail.isEmpty {
            listItems[idx].text = ""
            return
        }
        let newItem = ChecklistDraftItem(text: tail)
        // Animate the row sliding in and the container growing to fit it. Focus
        // moves in the same update so the keyboard stays put.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            listItems[idx].text = head
            listItems.insert(newItem, at: idx + 1)
        }
        focusedListItem = newItem.id
    }

    /// `overrideDate` is supplied by the swipe-to-schedule gesture and wins over
    /// any date parsed from the typed keywords.
    private func submit(overrideDate: Date? = nil) {
        guard let parsed, !parsed.title.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let task = TaskItem(
            title: parsed.title,
            // Return with no typed date lands on today.
            dueDate: overrideDate ?? parsed.date ?? startOfDay(Date()),
            tags: parsed.tags,
            // A long-press high-priority flag wins over the parsed priority.
            priority: isHighPriority ? .high : parsed.priority,
            // In list mode the description lives in subtasks, not the notes field.
            notes: listMode ? "" : notes.trimmingCharacters(in: .whitespacesAndNewlines),
            location: location,
            // The card already filled (or the person cleared) the location.
            autoLocation: false
        )
        if listMode {
            task.subtasks = listItems.compactMap {
                let t = $0.text.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : SubtaskData(title: t, completed: $0.completed)
            }
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            context.insert(task)
        }
        NotificationService.schedule(task)
        // Move first responder straight to the title field FIRST so the keyboard
        // never drops — otherwise, in list mode, collapsing the checklist section
        // resigns its field and the keyboard closes while the card stays up.
        text = ""
        notes = ""
        location = ""
        autoLocation = nil
        autoLocationDismissed = false
        titleFocused = true
        let resetForm = {
            showNotes = false
            listMode = false
            isHighPriority = false
        }
        if overrideDate != nil {
            // Swiped away — the card is off-screen, so reset instantly. An
            // animated reset here would drag the fields across the screen as the
            // fresh card rises from the bottom.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant, resetForm)
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85), resetForm)
            // Added with Return: the card stays put, so give it a subtle
            // dip-and-spring to confirm the add.
            withAnimation(.spring(response: 0.12, dampingFraction: 0.7)) { returnBounce = 6 }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.45).delay(0.1)) { returnBounce = 0 }
        }
        listItems = []
    }
}

// MARK: - Edit sheet

struct EditTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var scheme
    @Environment(Appearance.self) private var appearance
    @Environment(\.dismiss) private var dismiss

    @Bindable var task: TaskItem
    var onDelete: (TaskItem) -> Void

    @State private var newSubtask = ""
    @State private var tagsText = ""
    @FocusState private var focus: Field?
    private enum Field: Hashable { case title, notes, location, tags, subtask }

    private var palette: Palette { Palette(dark: scheme == .dark, accent: appearance.accent) }
    private let cal = Calendar.current

    // The Evry editor: white cards with the light outline used across the app,
    // compact rows inside them, and nothing borrowed from the system form.
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    mainCard
                    if !task.isNote {
                        detailsCard
                        subtasksCard
                        actions
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(palette.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .tint(palette.primary)
        .onAppear {
            if task.dueDate == nil { task.dueDate = startOfDay(Date()) }
            tagsText = task.tags.joined(separator: ", ")
        }
        .onChange(of: task.dueDate) {
            NotificationService.schedule(task)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(task.isNote ? "Edit note" : "Edit task")
                .font(.evryH3)
                .foregroundStyle(palette.text)
            Spacer()
            Button("Done") { dismiss() }
                .font(.nunito(size: 15, weight: .bold))
                .foregroundStyle(palette.onPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 34)
                .background(palette.primary, in: Capsule())
                .frame(minHeight: EvrySpace.tap)
                .buttonStyle(PressScaleStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    // MARK: Title + notes

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $task.title, axis: .vertical)
                .font(.nunito(size: 19, weight: .bold))
                .foregroundStyle(palette.text)
                .focused($focus, equals: .title)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            divider

            TextField("Add notes…", text: $task.notes, axis: .vertical)
                .font(.evryBody)
                .foregroundStyle(palette.textSec)
                .lineLimit(1...8)
                .focused($focus, equals: .notes)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .editCard(palette)
    }

    // MARK: Details

    private var detailsCard: some View {
        VStack(spacing: 0) {
            row(icon: "calendar", label: "Due") {
                DatePicker("Due", selection: dateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            divider
            row(icon: "clock", label: "Time") {
                if hasTime {
                    HStack(spacing: 4) {
                        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                        clearButton("Remove time") {
                            withAnimation(EvryMotion.settle) { task.dueDate = startOfDay(due) }
                        }
                    }
                } else {
                    chipButton("Add time", action: addTime)
                }
            }
            divider
            row(icon: "arrow.triangle.2.circlepath", label: "Repeat") {
                Menu {
                    Picker("Repeat", selection: Binding(
                        get: { task.recurrence },
                        set: { task.recurrence = $0 }
                    )) {
                        Text("Never").tag(RecurrenceFreq?.none)
                        ForEach(RecurrenceFreq.allCases) { freq in
                            Text(freq.label).tag(RecurrenceFreq?.some(freq))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(task.recurrence?.label ?? "Never")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.nunito(size: 11, weight: .bold))
                    }
                    .font(.nunito(size: 15, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(minHeight: EvrySpace.tap)
                }
            }
            divider
            row(icon: "mappin.and.ellipse", label: "Place") {
                TextField("Add a place", text: $task.location)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .location)
                    .submitLabel(.done)
            }
            divider
            row(icon: "number", label: "Tags") {
                TextField("work, home", text: $tagsText)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .tags)
                    .submitLabel(.done)
                    .onChange(of: tagsText) {
                        task.tags = tagsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                    }
            }
            divider
            row(icon: "flag", label: "High priority") {
                Toggle("High priority", isOn: Binding(
                    get: { task.priority == .high },
                    set: { on in withAnimation(EvryMotion.hover) { task.priority = on ? .high : .normal } }
                ))
                .labelsHidden()
                .tint(palette.primary)
            }
            divider
            row(icon: "bookmark", label: "Pinned") {
                Toggle("Pinned", isOn: $task.pinned)
                    .labelsHidden()
                    .tint(palette.primary)
            }
        }
        .font(.evryBody)
        .foregroundStyle(palette.text)
        .editCard(palette)
    }

    // MARK: Subtasks

    private var subtasksCard: some View {
        VStack(spacing: 0) {
            ForEach(task.subtasks) { subtask in
                HStack(spacing: 10) {
                    Button {
                        setSubtask(subtask, completed: !subtask.completed)
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        doneGlyph(subtask.completed, palette: palette, size: 20)
                            .frame(width: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subtask.completed ? "Done" : "Not done")
                    Text(subtask.title)
                        .font(.evryBody)
                        .strikethrough(subtask.completed, color: palette.textPh)
                        .foregroundStyle(subtask.completed ? palette.textSec : palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    clearButton("Remove subtask") {
                        withAnimation(EvryMotion.settle) { task.subtasks.removeAll { $0.id == subtask.id } }
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                divider
            }
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.nunito(size: 15, weight: .bold))
                    .foregroundStyle(palette.primary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                TextField("Add subtask…", text: $newSubtask)
                    .font(.evryBody)
                    .focused($focus, equals: .subtask)
                    .submitLabel(.next)
                    // Return adds it and keeps the field ready for the next one.
                    .onSubmit(addSubtask)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
        }
        .editCard(palette)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            actionTile("Duplicate", icon: "plus.square.on.square") {
                TaskActions.duplicate(task, context: context)
                dismiss()
            }
            actionTile("Tomorrow", icon: "arrow.right") {
                TaskActions.snooze(task)
                dismiss()
            }
            actionTile("Delete", icon: "trash") {
                dismiss()
                onDelete(task)
            }
        }
    }

    private func actionTile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.nunito(size: 16, weight: .semibold))
                Text(title)
                    .font(.nunito(size: 13, weight: .bold))
            }
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, minHeight: 60)
            .editCard(palette)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: Pieces

    private var divider: some View {
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

    private func chipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.nunito(size: 14, weight: .bold))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(palette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
                .frame(minHeight: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    private func clearButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.nunito(size: 11, weight: .bold))
                .foregroundStyle(palette.textSec)
                .frame(width: 32, height: EvrySpace.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Date & time

    private var due: Date { task.dueDate ?? startOfDay(Date()) }

    /// Midnight means "no time" (the app's convention).
    private var hasTime: Bool {
        let c = cal.dateComponents([.hour, .minute], from: due)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }

    /// Changing the day keeps the time.
    private var dateBinding: Binding<Date> {
        Binding(get: { due }, set: { day in
            let t = cal.dateComponents([.hour, .minute], from: due)
            task.dueDate = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0,
                                    of: startOfDay(day)) ?? day
        })
    }

    /// Changing the time keeps the day.
    private var timeBinding: Binding<Date> {
        Binding(get: { due }, set: { time in
            let t = cal.dateComponents([.hour, .minute], from: time)
            task.dueDate = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0,
                                    of: startOfDay(due)) ?? time
        })
    }

    /// The next hour today, or 9 AM on another day.
    private func addTime() {
        let hour = cal.isDateInToday(due) ? min(23, cal.component(.hour, from: Date()) + 1) : 9
        withAnimation(EvryMotion.settle) {
            task.dueDate = cal.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay(due))
        }
    }

    // MARK: Subtask edits

    private func setSubtask(_ subtask: SubtaskData, completed: Bool) {
        if let idx = task.subtasks.firstIndex(where: { $0.id == subtask.id }) {
            task.subtasks[idx].completed = completed
        }
    }

    private func addSubtask() {
        let title = newSubtask.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        withAnimation(EvryMotion.settle) { task.subtasks.append(SubtaskData(title: title)) }
        newSubtask = ""
        // Keep the keyboard up for the next one.
        focus = .subtask
    }
}

extension View {
    /// The editors' cards (task and event): white, with the same light outline
    /// as the app's buttons and cards.
    func editCard(_ palette: Palette) -> some View {
        background(palette.card, in: RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1))
    }
}

// MARK: - Shared sheet chrome (private to this file)

/// Field chrome for the quick-add fields: white fill and the same light 1pt
/// outline as the card's round notes/location buttons (`evryButtonFace`), on
/// radius-card corners — no dark ring, focused or not. `emphasised` (high
/// priority) uses the sky outline high-priority tasks carry.
private struct QuickAddFieldChrome: ViewModifier {
    let palette: Palette
    var focused: Bool
    var emphasised = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: EvryRadius.card, style: .continuous)
        content
            .background(palette.card, in: shape)
            .overlay(
                shape.strokeBorder(emphasised ? Color.evrySky : palette.border,
                                   lineWidth: emphasised ? 2 : 1)
            )
    }
}

/// The done/not-done glyph for checklist rows: the sky check disc with a navy
/// tick when done, a navy-60 ring when not.
@ViewBuilder
private func doneGlyph(_ done: Bool, palette: Palette, size: CGFloat) -> some View {
    if done {
        Image(systemName: "checkmark.circle.fill")
            .font(.nunito(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(palette.onSky, Palette.doneFill)
    } else {
        Image(systemName: "circle")
            .font(.nunito(size: size))
            .foregroundStyle(palette.textPh)
    }
}

// MARK: - Location picker

@Observable
private final class CurrentLocationProvider: NSObject, CLLocationManagerDelegate {
    /// Made on first use: the quick-add card is rebuilt often, and a location
    /// search is the only thing that needs this.
    @ObservationIgnored private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return m
    }()
    var coordinate: CLLocationCoordinate2D?

    /// A one-off fix (no continuous GPS). The last known location is used
    /// straight away so the first search is already biased nearby.
    func locate() {
        if coordinate == nil { coordinate = manager.location?.coordinate }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix: searches simply aren't biased to the current area.
    }
}

// MARK: - Map item helpers (shared by the quick-add bubble and the picker sheet)

// The app targets iOS 26.5, so these use MapKit's current address API only
// (the old `placemark` is deprecated).
private func mapItemLabel(_ item: MKMapItem, fallback: String) -> String {
    let name = item.name ?? fallback
    let city = item.addressRepresentations?.cityName ?? ""
    return city.isEmpty ? name : "\(name), \(city)"
}

private func mapItemSubtitle(_ item: MKMapItem) -> String {
    item.address?.shortAddress ?? item.address?.fullAddress ?? ""
}

private func mapItemCoordinate(_ item: MKMapItem) -> CLLocationCoordinate2D? {
    item.location.coordinate
}

/// Orders results by straight-line distance from `coord` so the nearest places
/// appear first. Returns the input unchanged when the device location is unknown.
private func sortByDistance(_ items: [MKMapItem], near coord: CLLocationCoordinate2D?) -> [MKMapItem] {
    guard let coord else { return items }
    let origin = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
    func distance(_ item: MKMapItem) -> CLLocationDistance {
        guard let c = mapItemCoordinate(item) else { return .greatestFiniteMagnitude }
        return origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }
    return items.sorted { distance($0) < distance($1) }
}
