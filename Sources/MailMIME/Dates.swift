// RFC 5322 date-time parsing (DESIGN 7), including the obsolete forms real
// mail still uses: two-digit years, alphabetic zones (EST, GMT, ...), missing
// seconds, comments between tokens, and military zones treated as UTC.

import Foundation

public enum MessageDate {
    /// Parses a Date: header value. nil when nothing parseable remains.
    public static func parse(_ value: String) -> Date? {
        // Strip comments (they may contain the weekday, e.g. "(Wednesday)").
        var scalars: [Unicode.Scalar] = []
        var i = 0
        var depth = 0
        let all = Array(value.unicodeScalars)
        while i < all.count {
            let s = all[i]
            if s == "\\" { i += 2; continue }
            if s == "(" { depth += 1; i += 1; continue }
            if s == ")" { depth = max(0, depth - 1); i += 1; continue }
            if depth == 0 { scalars.append(s) }
            i += 1
        }
        let tokens = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
            .map(String.init)

        // Drop a leading weekday (Mon/Tue/... with optional comma).
        var parts = tokens
        if let first = parts.first, isWeekday(first) {
            parts.removeFirst()
            if parts.first == "," { parts.removeFirst() }
        }

        guard parts.count >= 3 else { return nil }

        // Day: 1-31, possibly 1-2 digits.
        guard let day = Int(parts[0]), (1...31).contains(day) else { return nil }

        // Month name.
        guard let month = monthNumber(parts[1]) else { return nil }

        // Year: 4 digits, or obsolete 2 digits (00-49 → 20xx, 50-99 → 19xx).
        var yearText = parts[2]
        if yearText.count == 2, let y = Int(yearText) {
            yearText = String(y < 50 ? 2000 + y : 1900 + y)
        }
        guard let year = Int(yearText), (1...9999).contains(year) else { return nil }

        // Time hh:mm[:ss].
        var hour = 0, minute = 0, second = 0
        var zoneOffsetSeconds = 0
        var zoneConsumed = 0
        let timeText = parts[3]
        let timeComponents = timeText.split(separator: ":")
        guard timeComponents.count >= 2, timeComponents.count <= 3 else { return nil }
        guard let h = Int(timeComponents[0]), (0...23).contains(h) else { return nil }
        guard let m = Int(timeComponents[1]), (0...59).contains(m) else { return nil }
        hour = h
        minute = m
        if timeComponents.count == 3 {
            guard let s = Int(timeComponents[2]), (0...60).contains(s) else { return nil }
            second = min(s, 59)
        }
        zoneConsumed = 1

        // Zone: +HHMM / -HHMM, or an alphabetic name.
        if parts.count > 4 {
            let zoneText = parts[4].uppercased()
            zoneConsumed = 2
            if zoneText.count == 5, zoneText.first == "+" || zoneText.first == "-" {
                let sign = zoneText.first == "-" ? -1 : 1
                let digits = zoneText.dropFirst()
                if let zh = Int(digits.prefix(2)), let zm = Int(digits.suffix(2)), (0...23).contains(zh), (0...59).contains(zm) {
                    zoneOffsetSeconds = sign * (zh * 3600 + zm * 60)
                } else {
                    zoneOffsetSeconds = 0
                }
            } else {
                switch zoneText {
                case "UT", "GMT", "Z": zoneOffsetSeconds = 0
                case "EST": zoneOffsetSeconds = -5 * 3600
                case "EDT": zoneOffsetSeconds = -4 * 3600
                case "CST": zoneOffsetSeconds = -6 * 3600
                case "CDT": zoneOffsetSeconds = -5 * 3600
                case "MST": zoneOffsetSeconds = -7 * 3600
                case "MDT": zoneOffsetSeconds = -6 * 3600
                case "PST": zoneOffsetSeconds = -8 * 3600
                case "PDT": zoneOffsetSeconds = -7 * 3600
                default: zoneOffsetSeconds = 0 // military zones and junk → UTC
                }
            }
        }
        _ = zoneConsumed

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let local = calendar.date(from: components) else { return nil }
        // The header states local time + offset; convert to UTC instant.
        return local.addingTimeInterval(TimeInterval(-zoneOffsetSeconds))
    }

    static func isWeekday(_ token: String) -> Bool {
        let base = token.replacingOccurrences(of: ",", with: "").uppercased()
        return ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"].contains(base.prefix(3))
    }

    static func monthNumber(_ token: String) -> Int? {
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        guard token.count >= 3 else { return nil }
        let prefix = token.uppercased().prefix(3)
        return months.firstIndex(of: String(prefix)).map { $0 + 1 }
    }
}
