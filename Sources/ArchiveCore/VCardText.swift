import Foundation

/// vCard (RFC 6350 / RFC 2426) attachment text for the search index
/// (decision 0044). Names, organizations, titles, notes, nicknames and
/// addresses become prose; photos, identifiers, parameters and the
/// property machinery never reach the index. Quoted-printable values
/// (the common vCard 2.1 encoding) decode to UTF-8.
public enum VCardText {
    public static let maxInputBytes = 24_000_000
    public static let maxOutputCharacters = 1_000_000

    /// Properties whose values are prose worth searching. Structured
    /// values (N, ORG) are space-joined component lists.
    private static let plainProperties: Set<String> = ["FN", "TITLE", "NOTE", "EMAIL", "NICKNAME"]
    private static let componentProperties: Set<String> = ["N", "ORG", "ADR"]

    public static func text(_ bytes: [UInt8]) -> String? {
        if bytes.count > maxInputBytes { return nil }

        let raw = String(decoding: bytes, as: UTF8.self)
        let lines = raw.components(separatedBy: CharacterSet.newlines)
        // Envelope: at least one explicit BEGIN:VCARD line.
        guard lines.contains(where: { $0.uppercased() == "BEGIN:VCARD" }) else { return nil }
        let unfolded = unfold(lines)

        var out: [String] = []
        var inCard = false
        for line in unfolded {
            let upper = line.uppercased()
            if upper == "BEGIN:VCARD" {
                inCard = true
                continue
            }
            if upper == "END:VCARD" {
                inCard = false
                continue
            }
            guard inCard, let colon = line.firstIndex(of: ":") else { continue }
            let left = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
            guard !value.isEmpty else { continue }

            let segments = left.split(separator: ";", omittingEmptySubsequences: false)
            guard let first = segments.first else { continue }
            let name = String(first).uppercased()
            let parameters = segments.dropFirst().map { String($0).uppercased() }

            var decoded = value
            if isQuotedPrintable(parameters) {
                decoded = decodeQuotedPrintable(value)
            }

            if plainProperties.contains(name) {
                append(decoded, to: &out)
            } else if componentProperties.contains(name) {
                let components = decoded.split(separator: ";", omittingEmptySubsequences: true)
                    .map { String($0) }
                if !components.isEmpty {
                    append(components.joined(separator: " "), to: &out)
                }
            }
        }

        var joined = out.joined(separator: "\n")
        if joined.count > maxOutputCharacters {
            joined = String(joined.prefix(maxOutputCharacters))
        }
        joined = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func append(_ value: String, to out: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out.append(trimmed) }
    }

    /// Quoted-printable appears as ENCODING=QUOTED-PRINTABLE (3.0+)
    /// or a bare QUOTED-PRINTABLE parameter (2.1).
    private static func isQuotedPrintable(_ parameters: [String]) -> Bool {
        parameters.contains { parameter in
            parameter == "QUOTED-PRINTABLE" || parameter == "ENCODING=QUOTED-PRINTABLE"
        }
    }

    private static func decodeQuotedPrintable(_ value: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count)
        var iterator = value.unicodeScalars.makeIterator()
        var pending = iterator.next()
        while let current = pending {
            pending = iterator.next()
            guard current == "=", let next = pending else {
                bytes.append(contentsOf: Array(String(current).utf8))
                continue
            }
            pending = iterator.next()
            if next == "\r" || next == "\n" {
                if next == "\r", pending == "\n" { pending = iterator.next() }
                continue
            }
            if next == " " {
                bytes.append(0x20) // the fold space remains part of the text
                continue
            }
            guard let high = next.hexValue, let low = pending?.hexValue else {
                bytes.append(0x3D) // literal "="
                pending = next == nil ? pending : Optional(Unicode.Scalar(next))
                continue
            }
            pending = iterator.next()
            bytes.append(UInt8(high << 4 | low))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// RFC 5545 folding: a continuation line begins with a space or tab,
    /// and that single whitespace is removed when unfolding. vCard 2.1
    /// quoted-printable soft breaks (`=CRLF`) are the exception: the
    /// whitespace after the break may be real content, so when the
    /// previous line ends with `=` the continuation is kept verbatim.
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
                if out[out.count - 1].hasSuffix("=") {
                    out[out.count - 1] += line
                } else {
                    out[out.count - 1] += String(line.dropFirst())
                }
            } else {
                out.append(line)
            }
        }
        return out
    }
}

extension Unicode.Scalar {
    var hexValue: Int? {
        switch value {
        case 0x30...0x39: return Int(value) - 0x30
        case 0x41...0x46: return Int(value) - 0x37
        case 0x61...0x66: return Int(value) - 0x57
        default: return nil
        }
    }
}
