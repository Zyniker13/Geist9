// Header block scanning (DESIGN 7): the byte-level first pass over a message.
// Splits headers from body, unfolds continuation lines, and keeps the raw field
// bytes so nothing is lost before higher-level parsers (encoded words, addresses,
// dates, parameters) take their turn. Tolerant of real-world breakage: bare LFs,
// missing blank lines, headerless bodies, junk after a folded line.

import Foundation

/// One header field, unfolded, with its raw bytes preserved.
public struct HeaderField: Sendable, Equatable {
    /// Field name exactly as it appeared, e.g. "Subject"; compare case-insensitively.
    public let name: String
    /// Unfolded value bytes: continuation lines joined with their leading whitespace.
    public let valueBytes: [UInt8]

    public init(name: String, valueBytes: [UInt8]) {
        self.name = name
        self.valueBytes = valueBytes
    }

    /// The value as UTF-8 text with invalid sequences replaced (lossy view).
    public var valueText: String {
        String(decoding: valueBytes, as: UTF8.self)
    }
}

/// The parsed header block of a message.
public struct HeaderBlock: Sendable, Equatable {
    public let fields: [HeaderField]
    /// Byte offset in the source data where the body starts (after the blank line).
    public let bodyStart: Int

    public init(fields: [HeaderField], bodyStart: Int) {
        self.fields = fields
        self.bodyStart = bodyStart
    }

    /// Case-insensitive lookup, first match.
    public func first(_ name: String) -> HeaderField? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Case-insensitive lookup, all matches in order (e.g. multiple Received).
    public func all(_ name: String) -> [HeaderField] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether the block has the named field at all.
    public func contains(_ name: String) -> Bool {
        first(name) != nil
    }
}

public enum HeaderScanner {
    /// Scans a complete message: header block + body start offset.
    ///
    /// Header fields are lines up to the first blank line (CRLFCRLF, LFLF, or
    /// a lone CR/LF pair of either flavor). A line starting with space or tab
    /// continues the previous field. A line with no colon and no leading
    /// whitespace is appended to the previous field's value (broken software
    /// does this); if it is the first line, the whole block is treated as a
    /// headerless body.
    public static func scan(_ data: Data) -> HeaderBlock {
        var fields: [HeaderField] = []
        var currentName: String?
        var currentValue: [UInt8] = []
        var isHeader = true
        var offset = 0
        let bytes = [UInt8](data)
        var bodyStart = bytes.count

        func flush() {
            if let name = currentName {
                // Trim leading and trailing whitespace of the unfolded value,
                // as RFC 5322 allows arbitrary FWS around the colon and end.
                var value = currentValue
                while let f = value.first, f == 0x20 || f == 0x09 { value.removeFirst() }
                while let l = value.last, l == 0x20 || l == 0x09 || l == 0x0D || l == 0x0A { value.removeLast() }
                fields.append(HeaderField(name: name, valueBytes: value))
            }
            currentName = nil
            currentValue = []
        }

        while offset < bytes.count, isHeader {
            // Find the end of this line (accept CRLF, LF, CR).
            var lineEnd = offset
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A, bytes[lineEnd] != 0x0D { lineEnd += 1 }
            var next = lineEnd
            if next < bytes.count, bytes[next] == 0x0D { next += 1 }
            if next < bytes.count, bytes[next] == 0x0A { next += 1 }
            let line = Array(bytes[offset..<lineEnd])

            if line.isEmpty {
                // Blank line: headers end here; body starts after it.
                flush()
                bodyStart = next
                isHeader = false
                break
            }

            if line.first == 0x20 || line.first == 0x09 {
                // Continuation of the previous field.
                if currentName == nil {
                    // An indented first line is a headerless body.
                    flush()
                    bodyStart = offset
                    isHeader = false
                    break
                }
                var content = line
                while let f = content.first, f == 0x20 || f == 0x09 { content.removeFirst() }
                if !currentValue.isEmpty { currentValue.append(0x20) }
                currentValue.append(contentsOf: content)
                offset = next
                continue
            }

            guard let colon = line.firstIndex(of: 0x3A) else {
                // Junk line with no colon: broken writers emit these mid-header.
                // If nothing is open yet, the message has no header block at all.
                if currentName == nil {
                    flush()
                    bodyStart = offset
                    isHeader = false
                    break
                }
                currentValue.append(contentsOf: line)
                currentValue.append(0x20)
                offset = next
                continue
            }

            flush()
            let name = String(decoding: line[..<colon], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            // Field names are printable US-ASCII without colon/space inside; a
            // name containing a space is a sign of a headerless body line.
            if name.isEmpty || name.contains(where: { $0 == " " || $0 == "\t" }) {
                if fields.isEmpty && currentName == nil {
                    bodyStart = offset
                    isHeader = false
                    break
                }
                currentName = nil
                offset = next
                continue
            }
            currentName = name
            currentValue = Array(line[(colon + 1)...])
            offset = next
        }

        if isHeader {
            // No blank line found: everything scanned was headers.
            flush()
            bodyStart = bytes.count
        }

        return HeaderBlock(fields: fields, bodyStart: bodyStart)
    }
}
