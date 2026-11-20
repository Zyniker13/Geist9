import Foundation

/// iCalendar (RFC 5545) attachment text for the search index
/// (decision 0044). SUMMARY, DESCRIPTION and LOCATION values from
/// VEVENT, VTODO and VJOURNAL components become prose, with folded
/// lines unfolded and text escapes decoded. Identifiers, dates,
/// recurrence rules, parameters and base64 attachments never reach
/// the index.
public enum ICalText {
    public static let maxInputBytes = 24_000_000
    public static let maxOutputCharacters = 1_000_000

    /// Properties whose values are prose worth searching.
    private static let proseProperties: Set<String> = ["SUMMARY", "DESCRIPTION", "LOCATION"]
    /// Components whose prose properties are read.
    private static let proseComponents: Set<String> = ["VEVENT", "VTODO", "VJOURNAL"]

    public static func text(_ bytes: [UInt8]) -> String? {
        if bytes.count > maxInputBytes { return nil }

        let raw = String(decoding: bytes, as: UTF8.self)
        let unfolded = unfold(raw.components(separatedBy: CharacterSet.newlines))

        // Envelope: the first non-blank line must open a VCALENDAR.
        guard let first = unfolded.first(where: { !$0.isEmpty }),
              first.uppercased() == "BEGIN:VCALENDAR" else { return nil }

        var out: [String] = []
        var inProseComponent = false
        for line in unfolded {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:") {
                let name = String(upper.dropFirst("BEGIN:".count))
                inProseComponent = proseComponents.contains(name)
                continue
            }
            if upper.hasPrefix("END:") {
                inProseComponent = false
                continue
            }
            guard inProseComponent, let colon = line.firstIndex(of: ":") else { continue }
            let left = String(line[line.startIndex..<colon])
            let name = String(left.prefix(while: { $0 != ";" })).uppercased()
            guard proseProperties.contains(name) else { continue }
            let value = unescape(String(line[line.index(after: colon)...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { out.append(value) }
        }

        var joined = out.joined(separator: "\n")
        if joined.count > maxOutputCharacters {
            joined = String(joined.prefix(maxOutputCharacters))
        }
        joined = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// RFC 5545 folding: a continuation line begins with a space or tab.
    /// Blank lines (the empty half of a split CRLF pair, or real blank
    /// lines) are skipped so a continuation always folds onto its actual
    /// property line.
    private static func unfold(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if line.isEmpty { continue }
            let first = line.first
            if (first == " " || first == "\t"), !out.isEmpty {
                out[out.count - 1] += String(line.dropFirst())
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// RFC 5545 §3.3.11 text escapes.
    private static func unescape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var iterator = value.makeIterator()
        var pending = iterator.next()
        while let current = pending {
            pending = iterator.next()
            if current == "\\", let next = pending {
                pending = iterator.next()
                switch next {
                case "n", "N": out.append("\n")
                case ",": out.append(",")
                case ";": out.append(";")
                case "\\": out.append("\\")
                default:
                    out.append(next)
                }
            } else {
                out.append(current)
            }
        }
        return out
    }
}
