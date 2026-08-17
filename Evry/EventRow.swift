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

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                if event.isAllDay {
                    Text("All day · \(event.calendarTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                } else {
                    Text("\(event.startDate.formatted(.dateTime.hour().minute())) – \(event.endDate.formatted(.dateTime.hour().minute())) · \(event.calendarTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSec)
                }
            }

            Spacer()

            Button(action: onImport) {
                Image(systemName: isImported ? "checkmark.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 22))
                    .foregroundStyle(isImported ? Palette.success : palette.primary)
            }
            .buttonStyle(.plain)
            .disabled(isImported)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .evryCard(palette)
    }
}
