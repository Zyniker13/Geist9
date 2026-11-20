import Foundation

/// RFC 4180 CSV turned into plain text for the search index
/// (decision 0044). Records become lines, cells become space-joined
/// values: no commas, no quote noise, and quoted cells keep their
/// embedded newlines. Any non-empty input parses — CSV has no invalid
/// form — so strictness is limited to empty and oversized inputs.
public enum CSVText {
    public static let maxInputBytes = 24_000_000
    public static let maxOutputCharacters = 1_000_000

    public static func text(_ bytes: [UInt8]) -> String? {
        if bytes.count > maxInputBytes { return nil }

        var start = bytes.startIndex
        if bytes.count >= 3,
           bytes[start] == 0xEF, bytes[start + 1] == 0xBB, bytes[start + 2] == 0xBF {
            start += 3
        }

        var out: [UInt8] = []
        out.reserveCapacity(min(bytes.count, 1 << 20))
        var row: [[UInt8]] = []
        var field: [UInt8] = []
        var fieldStarted = false
        var inQuoted = false

        func flushField() {
            if fieldStarted {
                row.append(field)
                field = []
                fieldStarted = false
            }
        }

        func flushRow(into out: inout [UInt8]) -> Bool {
            flushField()
            if row.isEmpty { return true }
            if !out.isEmpty { out.append(0x0A) }
            for (index, cell) in row.enumerated() {
                if index > 0 { out.append(0x20) }
                out.append(contentsOf: cell)
            }
            row = []
            return out.count < maxOutputCharacters
        }

        var i = start
        while i < bytes.count {
            if out.count >= maxOutputCharacters { break }
            let byte = bytes[i]
            if inQuoted {
                if byte == 0x22 {
                    if i + 1 < bytes.count && bytes[i + 1] == 0x22 {
                        field.append(0x22)
                        i += 2
                        continue
                    }
                    inQuoted = false
                    i += 1
                    continue
                }
                field.append(byte)
                i += 1
                continue
            }
            switch byte {
            case 0x2C: // , — always ends a field, even an empty one
                row.append(field)
                field = []
                fieldStarted = false
                i += 1
            case 0x0D, 0x0A: // CR, LF
                flushField()
                if !flushRow(into: &out) { i = bytes.count; continue }
                if byte == 0x0D && i + 1 < bytes.count && bytes[i + 1] == 0x0A { i += 2 } else { i += 1 }
            case 0x22: // "
                if !fieldStarted {
                    inQuoted = true
                    fieldStarted = true
                    i += 1
                } else {
                    field.append(byte)
                    i += 1
                }
            default:
                fieldStarted = true
                field.append(byte)
                i += 1
            }
        }
        if out.count < maxOutputCharacters { _ = flushRow(into: &out) }

        var text = String(decoding: out.prefix(maxOutputCharacters), as: UTF8.self)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
