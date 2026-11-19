// Copyright 2025 Corey Mahler. All rights reserved.

import Foundation

/// Natural-language date spans (DESIGN 6A, decision 0034): the words people
/// type when they mean a period rather than a date stamp — "last March",
/// "this month", "yesterday". The numeric grammar (`2019`, `2019-06-01`)
/// stays primary; this resolver only owns the values it recognizes and
/// reports everything else as `notNatural` so the numeric parser can produce
/// its usual error.
///
/// All resolution happens in UTC against a caller-supplied `now`, so the
/// same query compiles the same way no matter when it runs, and tests can
/// pin the clock. Weeks start Monday (ISO 8601). Spans are half-open:
/// start is inclusive, end is exclusive, and both are ISO-8601 UTC strings
/// that sort the way the stored date columns do.
///
/// Resolution rules:
/// - `today`, `yesterday` — the calendar day.
/// - `this week`, `last week` — the Monday-based week.
/// - `this month`, `last month`, `this year`, `last year` — calendar spans.
/// - A bare month name ("march", "sept") names the most recent occurrence
///   of that month whose first day is on or before today; early in the year
///   that is the year before.
/// - "last <month>" agrees with the bare month, as people use the words:
///   "last March" from November is the March of this year.
/// - "<month> <year>" ("March 2019") pins the year exactly.
enum NaturalDate {
    enum Outcome: Equatable {
        /// Not a natural form; the numeric date grammar owns the value.
        case notNatural
        /// A resolved half-open span.
        case span(DateRange)
        /// Looks natural but is malformed, e.g. "last march 2019" — an
        /// explicit error teaches the grammar instead of silently picking
        /// one of the two readings.
        case invalid(String)
    }

    static func resolve(_ value: String, now: Date) -> Outcome {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday

        let words = value.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return .notNatural }

        func span(_ start: Date, _ end: Date) -> Outcome {
            .span(DateRange(start: iso(start, calendar), end: iso(end, calendar)))
        }

        switch words {
        case ["today"]:
            let today = calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: 1, to: today) else {
                return .notNatural
            }
            return span(today, end)
        case ["yesterday"]:
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else {
                return .notNatural
            }
            return span(start, today)
        case ["this", "week"]:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return .notNatural
            }
            return span(week.start, week.end)
        case ["last", "week"]:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
                  let start = calendar.date(byAdding: .day, value: -7, to: week.start) else {
                return .notNatural
            }
            return span(start, week.start)
        case ["this", "month"]:
            guard let month = calendar.dateInterval(of: .month, for: now) else {
                return .notNatural
            }
            return span(month.start, month.end)
        case ["last", "month"]:
            guard let month = calendar.dateInterval(of: .month, for: now),
                  let start = calendar.date(byAdding: .month, value: -1, to: month.start) else {
                return .notNatural
            }
            return span(start, month.start)
        case ["this", "year"]:
            guard let year = calendar.dateInterval(of: .year, for: now) else {
                return .notNatural
            }
            return span(year.start, year.end)
        case ["last", "year"]:
            guard let year = calendar.dateInterval(of: .year, for: now),
                  let start = calendar.date(byAdding: .year, value: -1, to: year.start) else {
                return .notNatural
            }
            return span(start, year.start)
        default:
            break
        }
        return resolveMonthName(words, now: now, calendar: calendar, span: span)
    }

    /// `[last] <month> [<year>]` — the month-name family.
    private static func resolveMonthName(
        _ words: [String],
        now: Date,
        calendar: Calendar,
        span: (Date, Date) -> Outcome
    ) -> Outcome {
        let hasLast = words[0] == "last"
        let index = hasLast ? 1 : 0
        guard index < words.count, let month = months[words[index]] else {
            return .notNatural
        }
        let rest = Array(words[(index + 1)...])
        if rest.count > 1 {
            return .invalid("a month name takes nothing but an optional year, as in \"march 2019\"")
        }
        var year: Int?
        if let first = rest.first {
            guard first.count == 4, let parsed = Int(first), first.allSatisfy(\.isNumber) else {
                return .invalid("a month name takes nothing but an optional year, as in \"march 2019\"")
            }
            if hasLast {
                return .invalid("\"last\" already picks the year; write \"march 2019\" without \"last\"")
            }
            year = parsed
        }

        let today = calendar.dateComponents([.year, .month], from: now)
        let startYear: Int
        if let year {
            startYear = year
        } else if month <= (today.month ?? 1) {
            // The most recent occurrence of this month: this year, unless
            // the month has not started yet, in which case last year.
            startYear = today.year ?? 0
        } else {
            startYear = (today.year ?? 0) - 1
        }
        guard let start = calendar.date(from: DateComponents(year: startYear, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else {
            return .notNatural
        }
        return span(start, end)
    }

    private static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8,
        "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// The ISO-8601 UTC form the stored date columns sort by, matching the
    /// numeric parser's output.
    private static func iso(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            c.year ?? 0, c.month ?? 1, c.day ?? 1,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
