//
//  EventRow.swift
//  Evry
//
//  Shared external-calendar event row used by InboxView's selected-day panel.
//  (The standalone Calendar tab was replaced by the Notes tab; its month-grid
//  UI now lives inline in InboxView's "Calendar" layout.)
//

import SwiftUI

// MARK: - Event row

struct EventRow: View {
    let event: CalendarEvent
    let palette: Palette
    let isImported: Bool
    let onImport: () -> Void

    // Reused format style so each row doesn't build a fresh one per redraw.
    private static let timeStyle = Date.FormatStyle.dateTime.hour().minute()

    var body: some View {
        HStack(spacing: 12) {
            // The calendar's own colour, kept only as this slim bar (it's the
            // user's data); everything else is brand ink.
            Capsule()
                .fill(event.calendarColor)
                .frame(width: 3)
                .padding(.vertical, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.nunito(size: 16, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                Group {
                    if event.isAllDay {
                        Text("All day · \(event.calendarTitle)")
                    } else {
                        Text("\(event.startDate.formatted(Self.timeStyle))–\(event.endDate.formatted(Self.timeStyle)) · \(event.calendarTitle)")
                    }
                }
                .font(.nunito(size: 14))
                .foregroundStyle(palette.textSec)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onImport) {
                Group {
                    if isImported {
                        // Done: the sky check disc with a navy tick.
                        EvryCheck(size: 26)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.nunito(size: 18, weight: .semibold))
                            .foregroundStyle(palette.primary)
                    }
                }
                .frame(width: EvrySpace.tap, height: EvrySpace.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .disabled(isImported)
            .accessibilityLabel(isImported ? "Added to tasks" : "Add to tasks")
        }
        .padding(.vertical, 12)
        .padding(.leading, EvrySpace.gutter)
        .padding(.trailing, 8)
        .frame(minHeight: 60)
        .evryCard(palette)
    }
}
