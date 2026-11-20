// RTF-to-text decoding for search (M2.3, ROADMAP line 69). An RTF
// attachment is pure markup at the byte level: control words, groups, hex
// and unicode escapes. This decoder keeps the visible text a search index
// can use and drops everything else — destination groups (font and color
// tables, pictures, field instructions), formatting words, binary data.
// Like the other strict extractors it yields nil for bytes that are not
// RTF, for oversized input, and when nothing legible was found; the
// original bytes stay archived either way.

enum RTFText {
    /// Bytes at or above this size are rejected up front: real RTF
    /// attachments are far smaller, and the cap bounds decode cost.
    static let maxInputBytes = 24_000_000

    /// Cap on produced characters, matching the other extractors.
    static let maxOutputCharacters = 1_000_000

    /// Destinations whose whole group carries no indexable text. The
    /// `\*` marker already skips every unknown destination, so this
    /// list only needs the well-known ones (which `\*` does not cover).
    private static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "listtable", "listoverridetable",
        "revtbl", "rsidtbl", "generator", "info", "pict", "object",
        "fldinst", "header", "footer", "headerl", "headerr", "headerf",
        "footerl", "footerr", "footerf", "filetbl", "pgptbl", "xmlnstbl",
        "latentstyles", "datastore", "mmathPr", "wgrf", "objdata",
    ]

    /// Windows-1252 decodes the high bytes of the common codepage;
    /// outside the table the plain Latin-1 value stands in.
    private static let windows1252: [UInt8: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
        0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
        0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
        0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
        0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
        0x9E: 0x017E, 0x9F: 0x0178,
    ]

    static func text(_ data: [UInt8]) -> String? {
        guard data.count <= maxInputBytes else { return nil }
        guard startsWithRTFHeader(data) else { return nil }

        var out = String.UnicodeScalarView()
        var emitted = 0
        // Skip state per open group: once a group is marked skipped, its
        // whole subtree is, so a nested push inherits the parent flag.
        var skip: [Bool] = [false]
        // Fallback units still to hide after a \uN escape (the \ucN value).
        var ucSkip = 0
        // The active skip count for later \uN escapes (\ucN word, default 1).
        var ucDefault = 1

        func emit(_ scalar: Unicode.Scalar) {
            guard emitted < maxOutputCharacters else { return }
            out.append(scalar)
            emitted += 1
        }

        var i = 0
        while i < data.count {
            let b = data[i]
            if b == UInt8(ascii: "{") {
                skip.append(skip.last ?? false)
                ucSkip = 0
                i += 1
                continue
            }
            if b == UInt8(ascii: "}") {
                if skip.count > 1 { skip.removeLast() }
                ucSkip = 0
                i += 1
                continue
            }
            if b == UInt8(ascii: "\\") {
                i += 1
                guard i < data.count else { break }
                let c = data[i]
                if c == UInt8(ascii: "'") {
                    // \'hh: a codepage byte. Counts as one fallback unit.
                    if i + 2 < data.count,
                       let value = hex(data[i + 1]), let second = hex(data[i + 2]) {
                        let byte = value << 4 | second
                        i += 3
                        if ucSkip > 0 {
                            ucSkip -= 1
                        } else if !(skip.last ?? false) {
                            emit(scalar(forByte: byte))
                        }
                    } else {
                        i += 1
                    }
                    continue
                }
                if c == UInt8(ascii: "*") {
                    // Unknown destination marker: skip the group unless the
                    // word names a destination this decoder understands
                    // (only \fldrslt, the field result text).
                    i += 1
                    let (word, _, next) = controlWordWithParameter(data, at: i)
                    i = next
                    if word != "fldrslt" {
                        skip[skip.count - 1] = true
                    }
                    continue
                }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "}")
                    || c == UInt8(ascii: "\\") {
                    // Escaped brace or backslash: one literal, one unit.
                    i += 1
                    if ucSkip > 0 {
                        ucSkip -= 1
                    } else if !(skip.last ?? false) {
                        emit(Unicode.Scalar(c))
                    }
                    continue
                }
                if isLetterByte(c) {
                    let (word, rawParameter, next) = controlWordWithParameter(data, at: i)
                    i = next
                    if skippedDestinations.contains(word) {
                        skip[skip.count - 1] = true
                        continue
                    }
                    if word == "uc" {
                        ucDefault = rawParameter ?? 1
                        continue
                    }
                    if word == "u" {
                        if let parameter = rawParameter {
                            let value = parameter < 0 ? parameter + 65_536 : parameter
                            if !(skip.last ?? false), let scalar = Unicode.Scalar(UInt32(value)) {
                                emit(scalar)
                            }
                        }
                        ucSkip = ucDefault
                        continue
                    }
                    if word == "bin" {
                        // \binN: the next N bytes are raw binary, skip them.
                        if let count = rawParameter, count > 0 {
                            i = min(data.count, i + count)
                        }
                        continue
                    }
                    if !(skip.last ?? false) {
                        switch word {
                        case "par", "line", "softline", "sect":
                            emit("\n")
                        case "cell", "row":
                            emit("\n")
                        case "tab", "emspace", "enspace":
                            emit(" ")
                        case "emdash":
                            emit("\u{2014}")
                        case "endash":
                            emit("\u{2013}")
                        case "lquote":
                            emit("\u{2018}")
                        case "rquote":
                            emit("\u{2019}")
                        case "ldblquote":
                            emit("\u{201C}")
                        case "rdblquote":
                            emit("\u{201D}")
                        case "bullet":
                            emit("\u{2022}")
                        case "_":
                            emit("-")
                        default:
                            break  // formatting words carry no text
                        }
                    }
                    continue
                }
                // A control symbol like \{ was handled above; any other
                // non-letter byte after a backslash is dropped.
                i += 1
                continue
            }
            // A plain byte: text, or a fallback unit after \uN.
            i += 1
            if ucSkip > 0 {
                if b != 0x0D && b != 0x0A { ucSkip -= 1 }
            } else if !(skip.last ?? false) {
                if b == 0x0D || b == 0x0A {
                    continue  // raw line breaks are not markup, not text
                }
                emit(scalar(forByte: b))
            }
        }

        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Accepts optional leading whitespace, `{\rtf`, in bytes.
    private static func startsWithRTFHeader(_ data: [UInt8]) -> Bool {
        var i = 0
        while i < data.count, data[i] == 0x20 || data[i] == 0x09
            || data[i] == 0x0D || data[i] == 0x0A { i += 1 }
        guard i + 5 <= data.count,
            data[i] == UInt8(ascii: "{"),
            data[i + 1] == UInt8(ascii: "\\"),
            data[i + 2] == UInt8(ascii: "r"),
            data[i + 3] == UInt8(ascii: "t"),
            data[i + 4] == UInt8(ascii: "f")
        else { return false }
        return true
    }

    private static func isLetterByte(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
    }

    private static func isDigitByte(_ b: UInt8) -> Bool {
        b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
    }

    /// A control word: letters, then an optional signed integer, then one
    /// optional space delimiter. Returns the word and the next index.
    private static func controlWordWithParameter(
        _ data: [UInt8], at start: Int
    ) -> (word: String, parameter: Int?, next: Int) {
        var i = start
        var word = ""
        while i < data.count, isLetterByte(data[i]) {
            word.append(Character(Unicode.Scalar(data[i])))
            i += 1
        }
        var parameter: Int? = nil
        var negative = false
        if i < data.count, data[i] == UInt8(ascii: "-") {
            negative = true
            i += 1
        }
        var digits = ""
        while i < data.count, isDigitByte(data[i]) {
            digits.append(Character(Unicode.Scalar(data[i])))
            i += 1
        }
        if !digits.isEmpty {
            parameter = (negative ? -1 : 1) * (Int(digits) ?? 0)
        }
        if i < data.count, data[i] == UInt8(ascii: " ") { i += 1 }
        return (word, parameter, i)
    }

    private static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func scalar(forByte b: UInt8) -> Unicode.Scalar {
        if b < 0x80 { return Unicode.Scalar(b) }
        if let mapped = windows1252[b] { return Unicode.Scalar(mapped)! }
        return Unicode.Scalar(b)
    }
}
