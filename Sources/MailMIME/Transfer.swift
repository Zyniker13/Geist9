// Transfer encodings (RFC 2045) plus the two legacy body encodings real
// mail still carries: uuencode and BinHex. All decoders are tolerant:
// they never throw and never drop a part; garbage in yields best-effort
// bytes out.

import Foundation

public enum Transfer {
    /// Decode a body according to its Content-Transfer-Encoding header.
    /// Unknown or missing encodings pass the bytes through unchanged.
    public static func decode(encoding: String?, _ bytes: [UInt8]) -> [UInt8] {
        guard let raw = encoding else { return bytes }
        let e = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch e {
        case "base64": return base64(bytes)
        case "quoted-printable": return quotedPrintable(bytes)
        case "7bit", "8bit", "binary", "": return bytes
        default: return bytes
        }
    }

    private static func starts(_ a: [UInt8], with prefix: String) -> Bool {
        let b = Array(prefix.utf8)
        guard b.count <= a.count else { return false }
        for k in 0..<b.count where a[k] != b[k] { return false }
        return true
    }

    // MARK: - Base64

    private static let b64Table: [Int8] = {
        var t = [Int8](repeating: -1, count: 128)
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for (i, c) in alphabet.enumerated() { t[Int(c.asciiValue!)] = Int8(i) }
        return t
    }()

    /// Tolerant base64: ignores whitespace and any non-alphabet characters,
    /// and tolerates missing or wrong padding. A trailing group of one
    /// character (length % 4 == 1) is malformed and dropped.
    public static func base64(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var acc = 0
        var nbits = 0
        for b in bytes {
            guard b < 128 else { continue }
            let v = b64Table[Int(b)]
            guard v >= 0 else { continue }
            acc = (acc << 6) | Int(v)
            nbits += 6
            while nbits >= 8 {
                nbits -= 8
                out.append(UInt8((acc >> nbits) & 0xFF))
            }
        }
        // nbits is 0 or 6 here; 6 leftover bits is not a full byte.
        return out
    }

    // MARK: - Quoted-Printable

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    /// Tolerant quoted-printable: `=XX` hex pairs decode, `=CRLF` is a soft
    /// line break, and a bare `=` (not followed by a hex pair) stays literal.
    public static func quotedPrintable(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 2 < bytes.count {
                    if let h1 = hexValue(bytes[i + 1]), let h2 = hexValue(bytes[i + 2]) {
                        out.append(UInt8(h1 * 16 + h2))
                        i += 3
                        continue
                    }
                    if bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                        i += 3 // soft line break
                        continue
                    }
                }
                out.append(0x3D) // bare '='
                i += 1
                continue
            }
            out.append(b)
            i += 1
        }
        return out
    }

    // MARK: - Line helpers

    /// Split on LF (CR stripped). A trailing run without a final LF is kept.
    static func splitLines(_ bytes: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        for b in bytes {
            if b == 0x0A {
                if let last = current.last, last == 0x0D { current.removeLast() }
                lines.append(current)
                current = []
            } else {
                current.append(b)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: - uuencode

    private static func uuValue(_ c: UInt8) -> Int {
        // uuencode alphabet: value v -> chr(v + 32), so space(0x20) is 0
        // and tilde(0x7E) is 62. Inverse: v = c - 0x20.
        if c >= 0x20, c <= 0x7E { return Int(c - 0x20) }
        return -1
    }

    /// Decode a uuencoded body (`begin [mode] name` ... `end`).
    /// Returns nil when the body is not uuencoded.
    public static func uuencode(_ bytes: [UInt8]) -> [UInt8]? {
        let lines = splitLines(bytes)
        guard let beginIdx = lines.firstIndex(where: { starts($0, with: "begin") }) else {
            return nil
        }
        var out: [UInt8] = []
        var i = beginIdx + 1
        while i < lines.count {
            let line = lines[i]
            if starts(line, with: "end") { break }
            guard let first = line.first else { i += 1; continue }
            let n = Int(first - 0x20)
            guard n >= 0, n <= 45 else { i += 1; continue }
            var emitted = 0
            var acc = 0
            var nbits = 0
            for c in line.dropFirst() {
                if emitted >= n { break }
                let v = uuValue(c)
                if v < 0 { break }
                acc = (acc << 6) | v
                nbits += 6
                while nbits >= 8, emitted < n {
                    nbits -= 8
                    out.append(UInt8((acc >> nbits) & 0xFF))
                    emitted += 1
                }
            }
            i += 1
        }
        return out
    }

    /// The file name from a uuencode `begin` line, if any.
    public static func uuencodeName(_ bytes: [UInt8]) -> String? {
        let lines = splitLines(bytes)
        guard let line = lines.first(where: { starts($0, with: "begin") }) else { return nil }
        var rest = Array(line.dropFirst("begin".utf8.count))
        // optional 3-digit octal mode
        if rest.first == 0x20 {
            rest.removeFirst()
            let isMode = rest.count >= 4
                && rest[0] >= 0x30 && rest[0] <= 0x37
                && rest[1] >= 0x30 && rest[1] <= 0x37
                && rest[2] >= 0x30 && rest[2] <= 0x37
                && rest[3] == 0x20
            if isMode { rest.removeFirst(4) }
        }
        let name = String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - BinHex

    /// Decode a BinHex ("M"-encoded) body. The first line is
    /// `;File: name` (optionally `;Size: NNN`); data lines start with `M`
    /// followed by base64 characters. Each line's characters are decoded
    /// as standard base64 and every full byte is emitted, so a final
    /// partial line (1 or 2 data bytes) is handled. Returns nil when the
    /// body is not BinHex.
    ///
    /// Note: this reads the line-oriented M-encoded form and does not
    /// verify Apple's per-line checksum byte; the raw body is always kept
    /// in the archive, so nothing is lost either way.
    public static func binhex(_ bytes: [UInt8]) -> (name: String, bytes: [UInt8])? {
        let lines = splitLines(bytes)
        guard let first = lines.first, starts(first, with: ";File:") else { return nil }
        var name = String(decoding: Array(first.dropFirst(";File:".utf8.count)), as: UTF8.self)
        if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
        name = name.trimmingCharacters(in: .whitespaces)

        var b64: [UInt8] = []
        for line in lines.dropFirst() {
            guard line.first == 0x4D else { break } // 'M'
            if line.dropFirst().allSatisfy({ $0 == 0x3D }) { break }
            b64.append(contentsOf: line.dropFirst())
        }
        return (name, base64(b64))
    }
}
