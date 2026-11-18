// Charset decoding (DESIGN 7): labels come from MIME (charset=, =?..?B?..?=)
// and are frequently wrong or exotic. M1.8 widens the table (ICU-backed); this
// core covers ASCII, UTF-8, Latin-1, UTF-16, and Windows-1252, which together
// catch the vast majority of Western mail, and falls back lossily rather than
// losing a message's text.

import Foundation

public enum Charset {
    /// Decodes bytes with a MIME charset label, lossily on failure.
    /// Never throws: a header or body must always render *something*.
    public static func decode(_ label: String?, _ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        switch normalized(label) {
        case "iso-8859-1", "latin1", "iso8859-1", "iso_8859-1", "l1", "cp819":
            return decodeLatin1(bytes)
        case "windows-1252", "cp1252", "x-cp1252":
            return decodeWindows1252(bytes)
        case "utf-16", "utf16", "unicode":
            return decodeUTF16(bytes)
        default:
            // UTF-8 / ASCII / unknown: sniff UTF-8, else Windows-1252-ish.
            if let utf8 = strictUTF8(bytes) { return utf8 }
            return decodeWindows1252(bytes)
        }
    }

    static func normalized(_ label: String?) -> String {
        guard let label else { return "" }
        return label
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
    }

    /// Strict UTF-8 decode; nil if not valid UTF-8.
    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        var string = ""
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var done = false
        while !done {
            switch decoder.decode(&iterator) {
            case .scalarValue(let v): string.unicodeScalars.append(v)
            case .emptyInput: done = true
            case .error: return nil
            }
        }
        return string
    }

    static func decodeLatin1(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            scalars.append(Unicode.Scalar(UInt32(byte))!)
        }
        return String(scalars)
    }

    // The 27 code points where Windows-1252 differs from Latin-1 (0x80-0x9F).
    static let cp1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    ]

    static func decodeWindows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            if byte >= 0x80, byte <= 0x9F {
                scalars.append(Unicode.Scalar(cp1252High[Int(byte) - 0x80])!)
            } else {
                scalars.append(Unicode.Scalar(UInt32(byte))!)
            }
        }
        return String(scalars)
    }

    static func decodeUTF16(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 2 else { return "" }
        func units(_ start: Int, bigEndian: Bool) -> [UInt16] {
            stride(from: start, to: bytes.count - 1, by: 2).map {
                bigEndian ? UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
                          : UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
            }
        }
        if bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(decoding: units(2, bigEndian: true), as: UTF16.self)
        }
        if bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(decoding: units(2, bigEndian: false), as: UTF16.self)
        }
        return String(decoding: units(0, bigEndian: false), as: UTF16.self)
    }
}
