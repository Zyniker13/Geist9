// RFC 2231 parameter parsing (DESIGN 7): Content-Type and Content-Disposition
// parameters, with parameter value continuations (name*0=, name*0*=) and
// charset'lang'percent-encoded values. Tolerant of real-world junk.

import Foundation

public enum HeaderParameters {
    /// Splits a structured header value (Content-Type, Content-Disposition)
    /// into the main value and its parameters. Quoted strings may contain
    /// semicolons; backslash escapes are honored.
    public static func split(_ value: String) -> (main: String, parameters: [(name: String, value: String)]) {
        var main = ""
        var parameters: [(String, String)] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var segments: [String] = []

        func flushSegment() {
            segments.append(current)
            current = ""
        }

        for s in value {
            if escaped {
                current.append(s)
                escaped = false
                continue
            }
            if s == "\\", inQuotes {
                current.append(s)
                escaped = true
                continue
            }
            if s == "\"" {
                inQuotes.toggle()
                current.append(s)
                continue
            }
            if s == ";", !inQuotes {
                flushSegment()
                continue
            }
            current.append(s)
        }
        flushSegment()

        for (index, segment) in segments.enumerated() {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            if index == 0 {
                main = trimmed
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            // Unquote.
            if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
                raw = String(raw.dropFirst().dropLast())
                raw = raw
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            parameters.append((name, raw))
        }
        return (main, parameters)
    }

    /// Joins RFC 2231 continuations and decodes extended values.
    /// Returns simple name → value pairs with duplicate names collapsed.
    public static func resolve(_ parameters: [(name: String, value: String)]) -> [String: String] {
        var result: [String: String] = [:]

        // Collect continuation segments: name → [index → (encoded?, value)]
        var continuations: [String: [Int: (Bool, String)]] = [:]
        var order: [String] = []

        for (name, value) in parameters {
            // RFC 2231 name forms: name (plain), name* (full extended),
            // name*<n> (plain segment), name*<n>* (encoded segment).
            var isEncoded = false
            var core = name
            if core.hasSuffix("*") {
                isEncoded = true
                core.removeLast()
            }
            if let star = core.lastIndex(of: "*") {
                let indexText = core[core.index(after: star)...]
                if !indexText.isEmpty, indexText.allSatisfy(\.isNumber) {
                    let base = String(core[..<star])
                    continuations[base, default: [:]][Int(indexText)!] = (isEncoded, value)
                    if !order.contains(base) { order.append(base) }
                    continue
                }
            }
            if isEncoded {
                // Full extended value: name*=charset'lang'percent-encoded
                continuations[core, default: [:]][0] = (true, value)
                if !order.contains(core) { order.append(core) }
            } else {
                if result[core] == nil { result[core] = value }
                if !order.contains(core) { order.append(core) }
            }
        }

        for key in order {
            guard let segments = continuations[key] else { continue }
            let sorted = segments.sorted { $0.key < $1.key }
            var bytes: [UInt8] = []
            var charset: String?
            var pendingCharset = true
            for (_, (isEncoded, text)) in sorted {
                if isEncoded {
                    // charset'lang'percent-encoded — the charset may appear only
                    // in the first segment.
                    if let quote = text.firstIndex(of: "'") {
                        let head = String(text[..<quote])
                        let rest = String(text[text.index(after: quote)...])
                        // Skip the language tag.
                        let payload: String
                        if let secondQuote = rest.firstIndex(of: "'") {
                            payload = String(rest[rest.index(after: secondQuote)...])
                        } else {
                            payload = rest
                        }
                        if pendingCharset, !head.isEmpty { charset = head }
                        pendingCharset = false
                        bytes.append(contentsOf: percentDecode(payload))
                    } else {
                        bytes.append(contentsOf: percentDecode(text))
                    }
                } else {
                    bytes.append(contentsOf: Array(text.utf8))
                }
            }
            result[key] = Charset.decode(charset, bytes)
        }
        return result
    }

    static func percentDecode(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "%", i + 3 <= scalars.count {
                let hex = String(String.UnicodeScalarView(scalars[(i + 1)..<(i + 3)]))
                if let v = UInt8(hex, radix: 16) {
                    out.append(v)
                    i += 3
                    continue
                }
            }
            // Non-escape scalars > 255 cannot be a single byte; keep their UTF-8.
            if s.value > 255 {
                out.append(contentsOf: Array(String(s).utf8))
            } else {
                out.append(UInt8(s.value))
            }
            i += 1
        }
        return out
    }
}
