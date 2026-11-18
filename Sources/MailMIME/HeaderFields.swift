// Typed access over a scanned header block (DESIGN 7): subject, date,
// message identity, references, list identity. Encoded words are decoded
// here; raw 8-bit literals fall back to the body charset when supplied.

import Foundation

public struct Headers {
    public let block: HeaderBlock

    public init(_ block: HeaderBlock) {
        self.block = block
    }

    /// Subject with RFC 2047 words decoded. `bodyCharset` guesses at raw
    /// 8-bit subjects written by broken software.
    public func subject(bodyCharset: String? = nil) -> String {
        guard let field = block.first("Subject") else { return "" }
        return EncodedWord.decode(field.valueBytes, fallback: bodyCharset)
    }

    /// Date header, parsed.
    public func date() -> Date? {
        guard let field = block.first("Date") else { return nil }
        return MessageDate.parse(String(decoding: field.valueBytes, as: UTF8.self))
    }

    /// The first Message-ID, normalized to the angle-bracket form
    /// `<id@host>`; empty if absent or malformed.
    public func messageID() -> String {
        guard let field = block.first("Message-ID") ?? block.first("Message-Id") else { return "" }
        return firstMessageID(in: field.valueText)
    }

    /// Message-IDs from References, in order.
    public func references() -> [String] {
        guard let field = block.first("References") else { return [] }
        return allMessageIDs(in: field.valueText)
    }

    /// Message-IDs from In-Reply-To (first one wins, per RFC 5322 it is one,
    /// but real mail sometimes lists several).
    public func inReplyTo() -> [String] {
        guard let field = block.first("In-Reply-To") else { return [] }
        return allMessageIDs(in: field.valueText)
    }

    /// List-Id value, whitespace-collapsed.
    public func listID() -> String {
        guard let field = block.first("List-Id") else { return "" }
        return field.valueText
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// All recipients of a role, addresses decoded.
    public func addresses(_ name: String) -> [EmailAddress] {
        block.all(name).flatMap { field in
            AddressParser.parse(EncodedWord.decode(field.valueBytes, fallback: nil))
        }
    }

    /// The account whose mailbox received the message (Delivered-To, X-Original-To,
    /// or the Envelope-To extension).
    public func deliveredTo() -> [EmailAddress] {
        var seen = Set<String>()
        var result: [EmailAddress] = []
        for header in ["Delivered-To", "X-Original-To", "Envelope-To"] {
            for address in addresses(header) where !seen.contains(address.address.lowercased()) {
                seen.insert(address.address.lowercased())
                result.append(address)
            }
        }
        return result
    }
}

/// Extracts the first <msg-id> from arbitrary text (comments tolerated).
public func firstMessageID(in text: String) -> String {
    allMessageIDs(in: text).first ?? ""
}

/// Extracts every <msg-id> from arbitrary text, in order.
public func allMessageIDs(in text: String) -> [String] {
    var ids: [String] = []
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        if scalars[i] == "<" {
            var id = ""
            var j = i + 1
            var closed = false
            while j < scalars.count {
                let s = scalars[j]
                if s == ">" { closed = true; break }
                if s == " " || s == "\t" || s == "\r" || s == "\n" { break }
                id.unicodeScalars.append(s)
                j += 1
            }
            if closed, !id.isEmpty, id.contains("@") {
                ids.append("<\(id)>")
                i = j + 1
                continue
            }
        }
        i += 1
    }
    return ids
}
