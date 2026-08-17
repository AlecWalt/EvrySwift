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

private let weekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEEE"
    return f
}()

private let iso8601Formatter = ISO8601DateFormatter()

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
        if diff >= 2 && diff < 7 {
            datePart = weekdayFormatter.string(from: date)
        } else if diff >= 7 && diff < 14 {
            datePart = "Next \(weekdayFormatter.string(from: date))"
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
private let monthWords = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"

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

/// The upcoming Saturday — unless today is already the weekend (Saturday or
/// Sunday), in which case it skips to the *following* weekend's Saturday.
/// Shared by the typed "weekend"/"next weekend" keyword and the swipe-left
/// schedule gesture so both entry points always agree.
func nextWeekend() -> Date {
    let todayIdx = Calendar.current.component(.weekday, from: Date()) - 1 // 0=Sun … 6=Sat
    var saturday = thisWeekday(6) // upcoming Saturday (could be today)
    if todayIdx == 0 || todayIdx == 6 {
        saturday = addDays(saturday, 7)
    }
    return saturday
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
    // "weekend" / "next weekend" — resolved by the shared nextWeekend() rule.
    // Listed before "next week" so "next weekend" isn't shadowed.
    DatePattern(regex: rx(#"\b(?:next\s+)?weekend\b"#)) { _ in nextWeekend() },
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

/// Resolves a bare date keyword ("today", "tomorrow", "next weekend", "friday", …)
/// to a `Date` using the exact same `datePatterns` that back quick-add parsing.
/// This is the single source of truth for what a keyword means, so typed input
/// and the swipe-to-schedule gestures never drift apart.
func resolveDateKeyword(_ keyword: String) -> Date? {
    for pattern in datePatterns {
        if let m = pattern.regex.firstGroups(in: keyword) {
            return pattern.resolve(m.groups)
        }
    }
    return nil
}

func parseTaskInput(_ raw: String) -> ParsedTask {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

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
        date: date, tags: tags, priority: priority
    )
}

// MARK: - Live input highlighting

/// Renders the quick-add input's keywords (tags, priorities, times, dates) inline
/// in the editing text view, so the highlighted text is
/// rendered by the text view itself (keeping the caret aligned) rather than a
/// separate overlay.
func attributedTaskInputNS(_ raw: String, palette: Palette, fontSize: CGFloat) -> NSAttributedString {
    let base = UIFont.systemFont(ofSize: fontSize)
    let semibold = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    let result = NSMutableAttributedString(
        string: raw,
        attributes: [.font: base, .foregroundColor: UIColor(palette.text)]
    )

    func apply(_ swiftRange: Range<String.Index>, color: UIColor, background: UIColor? = nil) {
        let nr = NSRange(swiftRange, in: raw)
        result.addAttribute(.foregroundColor, value: color, range: nr)
        result.addAttribute(.font, value: semibold, range: nr)
        if let background { result.addAttribute(.backgroundColor, value: background, range: nr) }
    }

    for range in tagPattern.allRanges(in: raw) { apply(range, color: UIColor(palette.primary)) }

    for (regex, value) in priorityPatterns {
        let color: UIColor
        switch value {
        case .high:   color = UIColor(Palette.danger)
        case .medium: color = UIColor(Palette.warning)
        case .low:    color = UIColor(Palette.success)
        case .normal: color = UIColor(palette.text)
        }
        for range in regex.allRanges(in: raw) { apply(range, color: color) }
    }

    for pattern in timePatterns {
        if let match = pattern.regex.allRanges(in: raw).first {
            apply(match, color: UIColor(palette.primary), background: UIColor(palette.primaryLight))
            break
        }
    }
    for pattern in datePatterns {
        if let match = pattern.regex.allRanges(in: raw).first {
            apply(match, color: UIColor(palette.primary), background: UIColor(palette.primaryLight))
            break
        }
    }

    return result
}
