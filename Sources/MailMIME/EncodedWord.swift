// RFC 2047 encoded words (DESIGN 7): =?charset?B|Q?text?= in headers.
//
// Works on bytes, not scalars: header values may carry raw 8-bit text, and
// converting through Unicode scalars would both trap (values > 255) and
// destroy the original bytes needed for fallback charset decoding.
//
// Real-world quirks handled: adjacent encoded words with only whitespace
// between them join without the whitespace; a multibyte character split
// across two encoded words of the same charset reassembles (bytes are
// concatenated per run before decoding); unknown charsets fall back lossily;
// malformed words stay literal so text is never dropped.

import Foundation

public enum EncodedWord {
    /// Decodes all encoded words in a header value given as raw bytes.
    /// `fallback` is a charset label for literal segments that are not valid
    /// UTF-8 (raw 8-bit headers from writers that never encoded).
    public static func decode(_ bytes: [UInt8], fallback: String?) -> String {
        var output = ""
        var literal = [UInt8]()      // literal bytes awaiting flush
        var runs: [[UInt8]] = []     // decoded byte runs from consecutive encoded words
        var runCharsets: [String] = []
        var i = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            if let utf8 = Charset.strictUTF8(literal) {
                output += utf8
            } else if let fallback, !Charset.normalized(fallback).isEmpty {
                output += Charset.decode(fallback, literal)
            } else {
                output += "\u{FFFD}"
            }
            literal = []
        }

        func flushRuns() {
            // Join consecutive runs with the same charset (split multibyte
            // repair), then decode each run once.
            var j = 0
            while j < runs.count {
                var bytes = runs[j]
                let charset = runCharsets[j]
                var k = j + 1
                while k < runs.count, Charset.normalized(runCharsets[k]) == Charset.normalized(charset) {
                    bytes.append(contentsOf: runs[k])
                    k += 1
                }
                output += Charset.decode(charset, bytes)
                j = k
            }
            runs = []
            runCharsets = []
        }

        while i < bytes.count {
            if bytes[i] == 0x3D /* = */, i + 1 < bytes.count, bytes[i + 1] == 0x3F /* ? */,
               let (word, next) = parseWord(bytes, from: i) {
                flushLiteral()
                runs.append(word.decoded)
                runCharsets.append(word.charset)
                i = next
                // Whitespace between two encoded words does not separate them
                // (RFC 2047 §6.2): if another word follows across whitespace,
                // keep scanning without flushing.
                var ws = i
                while ws < bytes.count, bytes[ws] == 0x20 || bytes[ws] == 0x09 { ws += 1 }
                if ws + 1 < bytes.count, bytes[ws] == 0x3D, bytes[ws + 1] == 0x3F,
                   parseWord(bytes, from: ws) != nil {
                    i = ws
                    continue
                } else if ws > i, ws < bytes.count {
                    // Not another word: the whitespace is literal.
                    flushRuns()
                    literal.append(contentsOf: bytes[i..<ws])
                    i = ws
                } else {
                    flushRuns()
                }
                continue
            }
            flushRuns()
            literal.append(bytes[i])
            i += 1
        }
        flushRuns()
        flushLiteral()
        return output
    }

    /// Convenience overload for already-UTF-8-clean text.
    public static func decode(_ text: String) -> String {
        decode(Array(text.utf8), fallback: nil)
    }

    /// Convenience overload with a fallback charset.
    public static func decode(_ text: String, fallback: String?) -> String {
        decode(Array(text.utf8), fallback: fallback)
    }

    struct Word {
        let charset: String
        let decoded: [UInt8]
    }

    /// Parses one =?charset?enc?data?= word starting at `from` (bytes).
    /// Returns (word, next index) on success, nil when it is not a word.
    static func parseWord(_ bytes: [UInt8], from: Int) -> (Word, Int)? {
        var i = from + 2 // past "=?"
        var charsetEnd: Int?
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3F /* ? */ { charsetEnd = i; break }
            // charset token: no space or "?" (RFC 2047 §5)
            if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A { return nil }
            i += 1
        }
        guard let ce = charsetEnd else { return nil }
        guard ce > from + 2 else { return nil } // empty charset
        let charset = String(decoding: bytes[(from + 2)..<ce], as: UTF8.self)
        guard ce + 2 < bytes.count else { return nil }
        let enc = bytes[ce + 1]
        guard enc == UInt8(ascii: "B") || enc == UInt8(ascii: "b") ||
              enc == UInt8(ascii: "Q") || enc == UInt8(ascii: "q") else { return nil }
        guard bytes[ce + 2] == 0x3F else { return nil }
        var dataEnd: Int?
        var j = ce + 3
        while j < bytes.count {
            if bytes[j] == 0x3F, j + 1 < bytes.count, bytes[j + 1] == 0x3D {
                dataEnd = j
                break
            }
            j += 1
        }
        guard let de = dataEnd else { return nil }
        let data = Array(bytes[(ce + 3)..<de])
        let next = de + 2 // past "?="
        let decoded: [UInt8]
        if enc == UInt8(ascii: "B") || enc == UInt8(ascii: "b") {
            guard let d = base64Decode(data) else { return nil }
            decoded = d
        } else {
            decoded = qDecode(data)
        }
        return (Word(charset: charset, decoded: decoded), next)
    }

    /// Q encoding on bytes: _ is space, =XX hex escapes, everything else literal.
    static func qDecode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let b = data[i]
            if b == UInt8(ascii: "_") {
                out.append(0x20)
                i += 1
            } else if b == UInt8(ascii: "="), i + 2 < data.count {
                let hex = String(decoding: data[(i + 1)...(i + 2)], as: UTF8.self)
                if let v = UInt8(hex, radix: 16) {
                    out.append(v)
                    i += 3
                } else {
                    out.append(b)
                    i += 1
                }
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    /// Tolerant base64: ignores whitespace, accepts missing padding.
    static func base64Decode(_ data: [UInt8]) -> [UInt8]? {
        var cleaned = ""
        for b in data {
            if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A { continue }
            cleaned.unicodeScalars.append(Unicode.Scalar(b))
        }
        var padded = cleaned
        let rem = padded.count % 4
        if rem == 1 { return nil } // impossible base64
        if rem > 0 { padded.append(String(repeating: "=", count: 4 - rem)) }
        guard let d = Data(base64Encoded: padded) else { return nil }
        return [UInt8](d)
    }
}
