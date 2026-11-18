// RFC 5322 address parsing (DESIGN 7): From/To/Cc/Reply-To and friends.
//
// Covers: bare addr-spec, display names (atoms, quoted strings, 2047 already
// decoded by the caller), angle-addr (with obsolete routes dropped), groups,
// comments in any position, folded whitespace, and RFC 6532 UTF-8. Tolerant:
// unparseable entries are skipped, never fatal.

import Foundation

public struct EmailAddress: Sendable, Equatable {
    /// Display name, already decoded; empty if none.
    public let name: String
    /// The addr-spec local@domain.
    public let address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    /// "Name <address>" or bare address.
    public var display: String {
        name.isEmpty ? address : "\(name) <\(address)>"
    }
}

public enum AddressParser {
    /// Parses an address-list header value (already unfolded; encoded words
    /// already decoded). Returns the addresses it could salvage.
    public static func parse(_ value: String) -> [EmailAddress] {
        var result: [EmailAddress] = []
        let scalars = Array(value.unicodeScalars)
        var i = 0
        var pendingName = ""

        func emit(name: String, address: String) {
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            result.append(EmailAddress(name: name.trimmingCharacters(in: .whitespaces), address: trimmed))
        }

        func skipCommentsAndSpace(_ index: inout Int) {
            while index < scalars.count {
                let s = scalars[index]
                if s == " " || s == "\t" || s == "\r" || s == "\n" {
                    index += 1
                } else if s == "(" {
                    var depth = 1
                    index += 1
                    while index < scalars.count, depth > 0 {
                        if scalars[index] == "\\" { index += 1 } // quoted pair
                        else if scalars[index] == "(" { depth += 1 }
                        else if scalars[index] == ")" { depth -= 1 }
                        index += 1
                    }
                } else {
                    break
                }
            }
        }

        func readQuoted(_ index: inout Int) -> String {
            // index at opening quote
            var out = ""
            index += 1
            while index < scalars.count {
                let s = scalars[index]
                if s == "\\", index + 1 < scalars.count {
                    out.unicodeScalars.append(scalars[index + 1])
                    index += 2
                } else if s == "\"" {
                    index += 1
                    break
                } else {
                    out.unicodeScalars.append(s)
                    index += 1
                }
            }
            return out
        }

        while i < scalars.count {
            skipCommentsAndSpace(&i)
            if i >= scalars.count { break }
            let s = scalars[i]

            if s == "," { // separator between entries
                i += 1
                continue
            }

            if s == "\"" {
                pendingName = readQuoted(&i)
                skipCommentsAndSpace(&i)
                continue
            }

            if s == "<" {
                // Angle-addr: take the addr-spec, drop any route.
                var inner = ""
                i += 1
                var depth = 0
                while i < scalars.count {
                    let c = scalars[i]
                    if c == "\\", i + 1 < scalars.count {
                        inner.unicodeScalars.append(scalars[i + 1])
                        i += 2
                        continue
                    }
                    if c == "<" { depth += 1 }
                    if c == ">" {
                        if depth == 0 { i += 1; break }
                        depth -= 1
                    }
                    inner.unicodeScalars.append(c)
                    i += 1
                }
                // Obsolete route: <@a,@b:user@host> → user@host
                if let colon = inner.firstIndex(of: ":"), inner.contains("@") {
                    let afterColon = inner[inner.index(after: colon)...]
                    if afterColon.contains("@") || inner.hasPrefix("@") {
                        inner = String(afterColon)
                    }
                }
                let name = pendingName
                pendingName = ""
                emit(name: name, address: inner)
                skipCommentsAndSpace(&i)
                continue
            }

            if s == ":" {
                // Group start: everything until ';' belongs to the group;
                // members are flattened (the archive flattens groups for search).
                pendingName = ""
                i += 1
                continue
            }

            if s == ";" {
                i += 1
                continue
            }

            // Accumulate a token (display-name word or bare addr-spec).
            var token = ""
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\r" || c == "\n" || c == "," || c == "<" || c == ":" || c == ";" || c == "(" { break }
                token.unicodeScalars.append(c)
                i += 1
            }
            skipCommentsAndSpace(&i)
            if !token.isEmpty {
                if token.contains("@") {
                    // An @-token completes an entry: any accumulated words were
                    // its display name.
                    emit(name: pendingName, address: token)
                    pendingName = ""
                } else {
                    // Part of a display name.
                    if !pendingName.isEmpty { pendingName += " " }
                    pendingName += token
                }
            }
        }
        return result
    }
}
