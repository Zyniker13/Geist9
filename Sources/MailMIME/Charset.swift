// Charset decoding (DESIGN 7): labels come from MIME (charset=, =?..?B?..?=)
// and are frequently wrong or exotic. Coverage:
//   - hand-decoded exact paths: Latin-1, Windows-1252, UTF-16 (BOM + forced
//     endianness) — byte-exact, no Foundation converter involved;
//   - everything else routes through Foundation's string converters
//     (ICU-backed on both macOS and Linux corelibs) via NSStringEncoding
//     numbers: the classic small values, or 0x80000000 | kCFStringEncoding
//     for the extended set;
//   - mislabelled real-world mail maps per DESIGN 222: gb2312 decodes as
//     GB18030 (superset), ks_c_5601-1987/euc-kr decode as CP949 (superset),
//     shift-jis decodes as the Windows Shift-JIS converter (CP932 superset).
// Never throws: a header or body must always render *something*; a decoder
// that refuses the bytes falls back to strict UTF-8 then Windows-1252.

import Foundation

public enum Charset {
    /// Decodes bytes with a MIME charset label, lossily on failure.
    /// Never throws: a header or body must always render *something*.
    public static func decode(_ label: String?, _ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        switch lookup(normalized(label)) {
        case .latin1:
            return decodeLatin1(bytes)
        case .cp1252:
            return decodeWindows1252(bytes)
        case .utf16BOM:
            return decodeUTF16(bytes)
        case .utf16BE:
            return decodeUTF16(bytes, forcedBigEndian: true)
        case .utf16LE:
            return decodeUTF16(bytes, forcedBigEndian: false)
        case .foundation(let nsEncoding):
            if let string = String(data: Data(bytes), encoding: String.Encoding(rawValue: nsEncoding)) {
                return string
            }
            return fallback(bytes)
        case .defaultSniff:
            return fallback(bytes)
        }
    }

    /// Strict UTF-8 when the bytes are valid UTF-8, else Windows-1252-ish.
    static func fallback(_ bytes: [UInt8]) -> String {
        if let utf8 = strictUTF8(bytes) { return utf8 }
        return decodeWindows1252(bytes)
    }

    enum Kind: Equatable, Sendable {
        case latin1
        case cp1252
        case utf16BOM
        case utf16BE
        case utf16LE
        case foundation(UInt)
        case defaultSniff
    }

    /// Alias table: normalized label -> decoder. First alias wins on repeats.
    static let table: [String: Kind] = {
        var table: [String: Kind] = [:]
        func add(_ kind: Kind, _ labels: [String]) {
            for label in labels where table[label] == nil {
                table[label] = kind
            }
        }
        add(.defaultSniff, [
            "us-ascii", "ascii", "ansi_x3.4-1968", "ansi_x3.4-1986", "iso-ir-6",
            "iso646-us", "us", "csascii", "default", "ibm367", "cp367", "646",
            "utf-8", "utf8", "unicode-1-1-utf-8",
            "unknown", "unknown-8bit", "x-unknown", "8bit", "7bit", "binary",
        ])
        add(.latin1, [
            "iso-8859-1", "iso8859-1", "iso_8859-1", "iso_8859-1:1987",
            "latin1", "latin-1", "l1", "cp819", "csisolatin1", "ibm819",
            "iso-ir-100", "8859-1",
        ])
        add(.cp1252, ["windows-1252", "cp1252", "x-cp1252", "x-ansi"])
        add(.utf16BOM, [
            "utf-16", "utf16", "unicode", "unicode-1-1-utf-16", "csunicode",
            "iso-10646-ucs-2", "ucs-2", "ucs2",
        ])
        add(.utf16BE, ["utf-16be", "utf16be", "unicodebig", "ucs-2be", "ucs2be"])
        add(.utf16LE, ["utf-16le", "utf16le", "unicodelittle", "ucs-2le", "ucs2le"])

        // ISO 8859 family (1 is handled above; 12 does not exist).
        add(.foundation(9), [
            "iso-8859-2", "iso8859-2", "iso_8859-2", "iso_8859-2:1987",
            "latin2", "latin-2", "l2", "csisolatin2", "iso-ir-101", "8859-2",
        ])
        add(.foundation(0x80000203), [
            "iso-8859-3", "iso8859-3", "iso_8859-3", "latin3", "latin-3",
            "l3", "csisolatin3", "iso-ir-109", "8859-3",
        ])
        add(.foundation(0x80000204), [
            "iso-8859-4", "iso8859-4", "iso_8859-4", "latin4", "latin-4",
            "l4", "csisolatin4", "iso-ir-110", "8859-4",
        ])
        add(.foundation(0x80000205), [
            "iso-8859-5", "iso8859-5", "iso_8859-5", "cyrillic",
            "csisolatincyrillic", "iso-ir-144", "8859-5",
        ])
        add(.foundation(0x80000206), [
            "iso-8859-6", "iso8859-6", "iso_8859-6", "arabic", "asmo-708",
            "ecma-114", "csisolatinarabic", "iso-ir-127", "8859-6",
        ])
        add(.foundation(0x80000207), [
            "iso-8859-7", "iso8859-7", "iso_8859-7", "greek", "greek8",
            "ecma-118", "elot-928", "csisolatingreek", "iso-ir-126", "8859-7",
        ])
        add(.foundation(0x80000208), [
            "iso-8859-8", "iso8859-8", "iso_8859-8", "hebrew",
            "csisolatinhebrew", "iso-ir-138", "8859-8",
        ])
        add(.foundation(0x80000209), [
            "iso-8859-9", "iso8859-9", "iso_8859-9", "latin5", "latin-5",
            "l5", "csisolatin5", "iso-ir-148", "8859-9",
        ])
        add(.foundation(0x8000020A), [
            "iso-8859-10", "iso8859-10", "iso_8859-10", "latin6", "latin-6",
            "l6", "csisolatin6", "iso-ir-157", "8859-10",
        ])
        add(.foundation(0x8000021B), [
            "iso-8859-11", "iso8859-11", "iso_8859-11", "thai", "tis-620",
            "iso-ir-166", "8859-11",
        ])
        add(.foundation(0x8000020D), [
            "iso-8859-13", "iso8859-13", "iso_8859-13", "baltic",
            "iso-ir-179", "8859-13",
        ])
        add(.foundation(0x8000020E), [
            "iso-8859-14", "iso8859-14", "iso_8859-14", "celtic", "latin8",
            "iso-celtic", "iso-ir-199", "8859-14",
        ])
        add(.foundation(0x8000020F), [
            "iso-8859-15", "iso8859-15", "iso_8859-15", "latin9", "latin-9",
            "l9", "csisolatin9", "iso-ir-203", "8859-15",
        ])
        add(.foundation(0x80000210), [
            "iso-8859-16", "iso8859-16", "iso_8859-16", "latin10", "latin-10",
            "csisolatin10", "iso-ir-226", "8859-16",
        ])

        // Windows code pages (1252 is handled above).
        add(.foundation(15), ["windows-1250", "cp1250", "x-cp1250"])
        add(.foundation(11), ["windows-1251", "cp1251", "x-cp1251"])
        add(.foundation(13), ["windows-1253", "cp1253", "x-cp1253"])
        add(.foundation(14), ["windows-1254", "cp1254", "x-cp1254"])
        add(.foundation(0x80000505), ["windows-1255", "cp1255", "x-cp1255"])
        add(.foundation(0x80000506), ["windows-1256", "cp1256", "x-cp1256"])
        add(.foundation(0x80000507), ["windows-1257", "cp1257", "x-cp1257"])
        add(.foundation(0x80000508), ["windows-1258", "cp1258", "x-cp1258"])

        // Cyrillic KOI8.
        add(.foundation(0x80000A02), ["koi8-r", "koi8r", "koi8_r", "koi8", "cskoi8r", "koi"])
        add(.foundation(0x80000A08), ["koi8-u", "koi8u", "koi8_u"])

        // Chinese: gb2312 decodes as GB18030 (superset), per DESIGN 222.
        add(.foundation(0x80000632), [
            "gb2312", "gb-2312", "gb_2312", "gb2312-80", "gb2312-1980",
            "cn-gb", "csgb2312", "chinese", "iso-ir-58", "csiso58gb231280",
            "gbk", "cp936", "ms936", "windows-936",
            "gb18030", "gb-18030", "gb18030-2000", "gb18030-2022",
        ])
        add(.foundation(0x80000A03), [
            "big5", "big-5", "big-five", "bigfive", "cn-big5", "csbig5",
        ])
        add(.foundation(0x80000A06), ["big5-hkscs", "big5hkscs", "big5-hkscs:1999"])
        add(.foundation(0x80000A05), ["hz-gb-2312", "hz"])

        // Japanese: shift-jis decodes as the Windows converter (CP932
        // superset of plain Shift-JIS), per DESIGN 222's mislabel rules.
        add(.foundation(8), [
            "shift-jis", "shift_jis", "sjis", "cp932", "ms932", "windows-31j",
            "cswindows31j", "csshiftjis", "ms-kanji", "ms_kanji",
        ])
        add(.foundation(3), [
            "euc-jp", "eucjp", "euc_jp", "x-euc-jp", "ujis",
            "cseucjpkdfmtjapanese",
        ])
        add(.foundation(21), [
            "iso-2022-jp", "iso-2022-jp-1", "iso-2022-jp-2", "csiso2022jp",
        ])

        // Korean: euc-kr labels decode as CP949 (superset), per DESIGN 222.
        add(.foundation(0x80000422), [
            "euc-kr", "euckr", "euc_kr", "cseuckr", "ks-c-5601-1987",
            "ks_c_5601-1987", "ks-c5601-1987", "ksc5601", "ksc-5601",
            "iso-ir-149", "korean", "csksc56011987",
            "cp949", "ms949", "windows-949", "uhc",
        ])

        // Mac Roman, common in old Apple mail.
        add(.foundation(30), ["mac-roman", "macintosh", "macroman", "x-mac-roman", "csmacintosh"])

        return table
    }()

    static func lookup(_ normalized: String) -> Kind {
        guard !normalized.isEmpty else { return .defaultSniff }
        return table[normalized] ?? .defaultSniff
    }

    static func normalized(_ label: String?) -> String {
        guard let label else { return "" }
        var value = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        value = value.replacingOccurrences(of: "_", with: "-")
        while value.contains("--") {
            value = value.replacingOccurrences(of: "--", with: "-")
        }
        return value
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
    // The five bytes Windows-1252 leaves undefined (0x81 0x8D 0x8F 0x90 0x9D)
    // keep their Latin-1 C1 values, per WHATWG windows-1252.
    static let cp1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
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

    static func decodeUTF16(_ bytes: [UInt8], forcedBigEndian: Bool? = nil) -> String {
        guard bytes.count >= 2 else { return "" }
        var start = 0
        var bigEndian = forcedBigEndian ?? false
        if bytes[0] == 0xFE, bytes[1] == 0xFF {
            bigEndian = true
            start = 2
        } else if bytes[0] == 0xFF, bytes[1] == 0xFE {
            bigEndian = false
            start = 2
        }
        var units: [UInt16] = []
        var i = start
        while i + 1 < bytes.count {
            let hi = UInt16(bytes[i])
            let lo = UInt16(bytes[i + 1])
            units.append(bigEndian ? (hi << 8) | lo : hi | (lo << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
