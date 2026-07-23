//
//  TaskParsing.swift
//  Evry
//
//  Natural-language quick-add parsing + date formatting, ported from the
//  webapp's js/utils/dateParser.js. Typing "call mom tom 3pm #family !high"
//  yields title "call mom", tomorrow at 3pm, tag family, high priority.
//  The bare word "note" anywhere turns the entry into a note and skips all
//  other parsing.
//

import Foundation
import SwiftUI

// MARK: - Date helpers

func startOfDay(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }

func addDays(_ d: Date, _ n: Int) -> Date {
    startOfDay(Calendar.current.date(byAdding: .day, value: n, to: startOfDay(d)) ?? d)
}

func isTodayDate(_ date: Date?) -> Bool {
    guard let date else { return false }
    return startOfDay(date) == startOfDay(Date())
}

func isOverdueDate(_ date: Date?) -> Bool {
    guard let date else { return false }
    return startOfDay(date) < startOfDay(Date())
}

// MARK: - Date category (drives chip color coding)

enum DateCategory {
    case overdue, today, tomorrow, week, nextweek, later
}

func dateCategory(_ date: Date?) -> DateCategory? {
    guard let date else { return nil }
    let d = startOfDay(date)
    let today = startOfDay(Date())
    if d < today { return .overdue }
    let diff = Calendar.current.dateComponents([.day], from: today, to: d).day ?? 0
    if diff == 0 { return .today }
    if diff == 1 { return .tomorrow }
    if diff <= 6 { return .week }
    if diff <= 13 { return .nextweek }
    return .later
}

/// "Today", "Tomorrow", "Friday", "Next Friday", "Jan 15" — plus
/// " at 3:00 PM" when the date carries a time component.
func formatDueDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    let today = startOfDay(Date())
    let day = startOfDay(date)

    let datePart: String
    if day == today {
        datePart = "Today"
    } else if day == addDays(Date(), 1) {
        datePart = "Tomorrow"
    } else {
        let diff = Calendar.current.dateComponents([.day], from: today, to: day).day ?? 99
        let weekdayFmt = DateFormatter()
        weekdayFmt.dateFormat = "EEEE"
        if diff >= 2 && diff < 7 {
            datePart = weekdayFmt.string(from: date)
        } else if diff >= 7 && diff < 14 {
            datePart = "Next \(weekdayFmt.string(from: date))"
        } else {
            datePart = date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
    let hasTime = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0
    guard hasTime else { return datePart }
    return "\(datePart) at \(date.formatted(date: .omitted, time: .shortened))"
}

// MARK: - Parsing

struct ParsedTask {
    var title: String
    var date: Date?
    var tags: [String]
    var priority: TaskPriority
    var isNote: Bool
}

private struct DatePattern {
    let regex: NSRegularExpression
    let resolve: ([String]) -> Date?
}

private func rx(_ pattern: String) -> NSRegularExpression {
    // Patterns are compile-time constants; a failure here is a programmer error.
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private let weekdayWords = "sun(?:day)?|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?"
private let monthWords = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"

/// 0=Sun … 6=Sat from a matched weekday word.
private func weekdayIndex(_ word: String) -> Int {
    switch word.lowercased().prefix(3) {
    case "sun": return 0
    case "mon": return 1
    case "tue": return 2
    case "wed": return 3
    case "thu": return 4
    case "fri": return 5
    default: return 6
    }
}

private func monthIndex(_ word: String) -> Int {
    let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    return months.firstIndex(of: String(word.lowercased().prefix(3))) ?? 0
}

/// 0–6 days away, inclusive of today ("this saturday").
private func thisWeekday(_ target: Int) -> Date {
    let todayIdx = Calendar.current.component(.weekday, from: Date()) - 1 // 0=Sun
    let diff = ((target - todayIdx) + 7) % 7
    return addDays(Date(), diff)
}

/// 1–7 days away, never today (bare "saturday").
private func nextWeekday(_ target: Int) -> Date {
    let todayIdx = Calendar.current.component(.weekday, from: Date()) - 1
    var diff = ((target - todayIdx) + 7) % 7
    if diff == 0 { diff = 7 }
    return addDays(Date(), diff)
}

/// 7–13 days away — always the following week ("next saturday").
private func followingWeekday(_ target: Int) -> Date {
    addDays(thisWeekday(target), 7)
}

private func resolveMonthDay(_ month: String, _ day: Int) -> Date {
    let today = startOfDay(Date())
    let year = Calendar.current.component(.year, from: today)
    var comps = DateComponents(year: year, month: monthIndex(month) + 1, day: day)
    var d = Calendar.current.date(from: comps) ?? today
    if startOfDay(d) < today {
        comps.year = year + 1
        d = Calendar.current.date(from: comps) ?? d
    }
    return startOfDay(d)
}

// Most-specific first — same ordering as the webapp's DATE_PATTERNS.
private let datePatterns: [DatePattern] = [
    DatePattern(regex: rx(#"\bnext\s+week\b"#)) { _ in addDays(Date(), 7) },
    DatePattern(regex: rx("\\bnext\\s+(\(weekdayWords))\\b")) { g in followingWeekday(weekdayIndex(g[1])) },
    DatePattern(regex: rx("\\bthis\\s+(\(weekdayWords))\\b")) { g in thisWeekday(weekdayIndex(g[1])) },
    DatePattern(regex: rx(#"\b(?:tod|today)\b"#)) { _ in startOfDay(Date()) },
    DatePattern(regex: rx(#"\b(?:tom|tmr|tomorrow)\b"#)) { _ in addDays(Date(), 1) },
    DatePattern(regex: rx("\\b(\(weekdayWords))\\b")) { g in nextWeekday(weekdayIndex(g[1])) },
    DatePattern(regex: rx("\\b(\(monthWords))\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b")) { g in
        resolveMonthDay(g[1], Int(g[2]) ?? 1)
    },
    DatePattern(regex: rx("\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+(\(monthWords))\\b")) { g in
        resolveMonthDay(g[2], Int(g[1]) ?? 1)
    },
    DatePattern(regex: rx(#"\b(\d{1,2})[/\-](\d{1,2})\b"#)) { g in
        let today = startOfDay(Date())
        let year = Calendar.current.component(.year, from: today)
        var comps = DateComponents(year: year, month: Int(g[1]), day: Int(g[2]))
        var d = Calendar.current.date(from: comps) ?? today
        if startOfDay(d) < today {
            comps.year = year + 1
            d = Calendar.current.date(from: comps) ?? d
        }
        return startOfDay(d)
    },
]

private struct TimePattern {
    let regex: NSRegularExpression
    let resolve: ([String]) -> (hours: Int, minutes: Int)
}

private func amPm(_ hour: Int, _ minute: Int, _ suffix: String) -> (hours: Int, minutes: Int) {
    var h = hour
    let isPM = suffix.lowercased().hasPrefix("p")
    if isPM && h != 12 { h += 12 }
    if !isPM && h == 12 { h = 0 }
    return (h, minute)
}

private let timePatterns: [TimePattern] = [
    TimePattern(regex: rx(#"\b(?:at\s+)?(\d{1,2}):(\d{2})\s*([ap])\.?m?\.?\b"#)) { g in
        amPm(Int(g[1]) ?? 0, Int(g[2]) ?? 0, g[3])
    },
    TimePattern(regex: rx(#"\b(?:at\s+)?(\d{1,2})\s*([ap])\.?m?\.?\b"#)) { g in
        amPm(Int(g[1]) ?? 0, 0, g[2])
    },
    TimePattern(regex: rx(#"\b(?:at\s+)?noon\b"#)) { _ in (12, 0) },
    TimePattern(regex: rx(#"\b(?:at\s+)?midnight\b"#)) { _ in (0, 0) },
]

private let notePattern = rx(#"\bnote\b"#)
private let tagPattern = rx(#"#(\w+)"#)

private let priorityPatterns: [(NSRegularExpression, TaskPriority)] = [
    (rx(#"(?<!\w)!high\b"#), .high),
    (rx(#"(?<!\w)!med(?:ium)?\b"#), .medium),
    (rx(#"(?<!\w)!low\b"#), .low),
]

private extension NSRegularExpression {
    /// Every whole-match range, in order.
    func allRanges(in text: String) -> [Range<String.Index>] {
        let ns = NSRange(text.startIndex..., in: text)
        return matches(in: text, range: ns).compactMap { Range($0.range, in: text) }
    }

    /// First match's capture groups (group 0 = whole match), or nil.
    func firstGroups(in text: String) -> (range: Range<String.Index>, groups: [String])? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = firstMatch(in: text, range: ns),
              let whole = Range(m.range, in: text) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return (whole, groups)
    }
}

func parseTaskInput(_ raw: String) -> ParsedTask {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // A note skips date/time/tag/priority parsing entirely.
    if let noteMatch = notePattern.firstGroups(in: text) {
        text.removeSubrange(noteMatch.range)
        return ParsedTask(
            title: text.split(separator: " ").joined(separator: " "),
            date: nil, tags: [], priority: .normal, isNote: true
        )
    }

    var tags: [String] = []
    while let m = tagPattern.firstGroups(in: text) {
        tags.append(m.groups[1].lowercased())
        text.removeSubrange(m.range)
    }

    var priority: TaskPriority = .normal
    for (regex, value) in priorityPatterns {
        if let m = regex.firstGroups(in: text) {
            priority = value
            text.removeSubrange(m.range)
        }
    }

    var time: (hours: Int, minutes: Int)?
    for pattern in timePatterns {
        if let m = pattern.regex.firstGroups(in: text) {
            time = pattern.resolve(m.groups)
            text.removeSubrange(m.range)
            break
        }
    }

    var date: Date?
    for pattern in datePatterns {
        if let m = pattern.regex.firstGroups(in: text) {
            date = pattern.resolve(m.groups)
            text.removeSubrange(m.range)
            break
        }
    }

    if let time {
        let base = date ?? startOfDay(Date())
        date = Calendar.current.date(bySettingHour: time.hours, minute: time.minutes, second: 0, of: base)
    }

    return ParsedTask(
        title: text.split(separator: " ").joined(separator: " "),
        date: date, tags: tags, priority: priority, isNote: false
    )
}

// MARK: - Live input highlighting

/// Renders the quick-add input with its recognized keywords color-coded, matching
/// how `parseTaskInput` interprets the same text: notes, tags, priorities, times,
/// and dates each get their own accent. Everything else stays in the body color.
func attributedTaskInput(_ raw: String, palette: Palette, fontSize: CGFloat) -> AttributedString {
    var attr = AttributedString(raw)
    attr.font = .system(size: fontSize)
    attr.foregroundColor = palette.text

    func range(_ swiftRange: Range<String.Index>) -> Range<AttributedString.Index> {
        let lower = raw.distance(from: raw.startIndex, to: swiftRange.lowerBound)
        let upper = raw.distance(from: raw.startIndex, to: swiftRange.upperBound)
        let start = attr.characters.index(attr.startIndex, offsetBy: lower)
        let end = attr.characters.index(attr.startIndex, offsetBy: upper)
        return start..<end
    }

    func highlight(_ swiftRange: Range<String.Index>, color: Color) {
        let r = range(swiftRange)
        attr[r].foregroundColor = color
        attr[r].font = .system(size: fontSize, weight: .semibold)
    }

    // Date/time keywords get a filled highlight behind the text in the app's
    // accent color, rather than just recoloring the glyphs.
    func highlightBackground(_ swiftRange: Range<String.Index>) {
        let r = range(swiftRange)
        attr[r].backgroundColor = palette.primaryLight
        attr[r].foregroundColor = palette.primary
        attr[r].font = .system(size: fontSize, weight: .semibold)
    }

    // A note short-circuits parsing, so highlight only the "note" keyword.
    if let noteRange = notePattern.allRanges(in: raw).first {
        highlight(noteRange, color: palette.primary)
        return attr
    }

    for range in tagPattern.allRanges(in: raw) {
        highlight(range, color: palette.primary)
    }

    for (regex, value) in priorityPatterns {
        let color: Color
        switch value {
        case .high:   color = Palette.danger
        case .medium: color = Palette.warning
        case .low:    color = Palette.success
        case .normal: color = palette.text
        }
        for range in regex.allRanges(in: raw) {
            highlight(range, color: color)
        }
    }

    for pattern in timePatterns {
        if let match = pattern.regex.allRanges(in: raw).first {
            highlightBackground(match)
            break
        }
    }

    for pattern in datePatterns {
        if let match = pattern.regex.allRanges(in: raw).first {
            highlightBackground(match)
            break
        }
    }

    return attr
}
