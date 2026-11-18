// HTML sanitizer for display (DESIGN 8). Turns an email's HTML body into
// markup that cannot load remote content or run script: unknown and active
// elements are dropped, attributes are allow-listed, URLs are scheme-checked
// after entity decoding, CSS that can fetch is refused, comments and raw
// elements are swallowed. The webview adds its own layers on top (JavaScript
// off, a content rule list blocking every network load, an injected CSP);
// the sanitizer is the layer that decides what markup exists at all.
//
// Tolerant, never throws: malformed markup falls out as inert text.

import Foundation

public enum HTMLSanitizer {

    public struct Link: Equatable, Sendable {
        /// The decoded target as it will be shown and opened.
        public var href: String
        /// True for http/https targets (external, confirm before opening).
        public var isExternal: Bool
        public init(href: String, isExternal: Bool) {
            self.href = href
            self.isExternal = isExternal
        }
    }

    public struct Result: Equatable, Sendable {
        /// Sanitized markup, safe to hand to the viewer.
        public var html: String
        /// Every link that survived, with its decoded target.
        public var links: [Link]
        /// Remote resources that were stripped (or, when remote content is
        /// allowed, that were kept) so the interface can tell the person.
        public var remoteResources: [String]
        /// True when the original carried script, forms, embeds, event
        /// handlers, or refreshes that were removed.
        public var hadActiveContent: Bool
        public init(
            html: String, links: [Link], remoteResources: [String],
            hadActiveContent: Bool
        ) {
            self.html = html
            self.links = links
            self.remoteResources = remoteResources
            self.hadActiveContent = hadActiveContent
        }
    }

    /// Sanitize one HTML document or fragment.
    /// - Parameters:
    ///   - allowRemoteContent: when false (the default), every remote
    ///     resource (anything not `cid:` or an inline data image) is stripped
    ///     and recorded. When true, `img src` may keep absolute http(s) URLs
    ///     because the person clicked "Load remote content" for this message.
    public static func sanitize(_ html: String, allowRemoteContent: Bool = false) -> Result {
        var sanitizer = Scanner(
            bytes: Array(html.utf8), allowRemoteContent: allowRemoteContent
        )
        sanitizer.run()
        return Result(
            html: String(decoding: sanitizer.out, as: UTF8.self),
            links: sanitizer.links,
            remoteResources: sanitizer.remoteResources,
            hadActiveContent: sanitizer.hadActiveContent
        )
    }

    // MARK: - Scanner

    /// Byte-level, tolerant HTML tokenizer. ASCII-only parsing: multibyte
    /// UTF-8 sequences pass through as text bytes untouched.
    private struct Scanner {
        let bytes: [UInt8]
        let allowRemoteContent: Bool
        var out: [UInt8] = []
        var links: [Link] = []
        var remoteResources: [String] = []
        var hadActiveContent = false
        var i = 0

        init(bytes: [UInt8], allowRemoteContent: Bool) {
            self.bytes = bytes
            self.allowRemoteContent = allowRemoteContent
        }

        mutating func run() {
            while i < bytes.count {
                guard bytes[i] == 0x3C else { // '<'
                    out.append(bytes[i])
                    i += 1
                    continue
                }
                handleLessThan()
            }
        }

        // Everything from a '<' that actually opens something.
        private mutating func handleLessThan() {
            let after = i + 1
            guard after < bytes.count else { // trailing '<'
                out.append(contentsOf: Array("&lt;".utf8))
                i += 1
                return
            }
            let c = bytes[after]
            if c == 0x21 { // '!'  comment, doctype, bogus
                skipBang()
            } else if c == 0x3F { // '?'  processing instruction
                skipToGreaterThan()
                hadActiveContent = true
            } else if c == 0x2F { // '/'  close tag
                handleClose()
            } else if isAlpha(c) {
                handleOpen()
            } else {
                // "<3", "< ", "<=" are text in HTML.
                out.append(contentsOf: Array("&lt;".utf8))
                i += 1
            }
        }

        // MARK: comments, doctypes, processing instructions

        private mutating func skipBang() {
            if i + 3 < bytes.count, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {
                // "<!--" comment: swallow to "-->" or end of input.
                var j = i + 4
                while j + 2 < bytes.count {
                    if bytes[j] == 0x2D, bytes[j + 1] == 0x2D, bytes[j + 2] == 0x3E {
                        i = j + 3
                        return
                    }
                    j += 1
                }
                i = bytes.count
                return
            }
            skipToGreaterThan()
        }

        private mutating func skipToGreaterThan() {
            while i < bytes.count, bytes[i] != 0x3E { i += 1 }
            if i < bytes.count { i += 1 } // past '>'
        }

        // MARK: close tags

        private mutating func handleClose() {
            var j = i + 2
            var name = ""
            while j < bytes.count, isNameByte(bytes[j]) {
                name.append(Character(UnicodeScalar(bytes[j])))
                j += 1
            }
            let lowered = name.lowercased()
            // Skip to '>'; attrs on close tags are ignored.
            while j < bytes.count, bytes[j] != 0x3E { j += 1 }
            i = j < bytes.count ? j + 1 : bytes.count
            if let rule = TagRule.allowed[lowered], !rule.raw {
                out.append(contentsOf: Array("</\(lowered)>".utf8))
            }
        }

        // MARK: open tags

        private struct Attr {
            var name: String
            var rawValue: String?
        }

        private mutating func handleOpen() {
            var j = i + 1
            var name = ""
            while j < bytes.count, isNameByte(bytes[j]) {
                name.append(Character(UnicodeScalar(bytes[j])))
                j += 1
            }
            let lowered = name.lowercased()
            let (attrs, selfClosed, consumed) = parseAttributes(from: j)
            i = consumed

            if let rule = TagRule.allowed[lowered] {
                if rule.raw {
                    hadActiveContent = true
                    skipRawElement(named: lowered)
                    return
                }
                emitAllowedTag(named: lowered, rule: rule, attrs: attrs)
                return
            }
            // Unlisted tag: drop the tag itself.
            if TagRule.activeDropped.contains(lowered) {
                hadActiveContent = true
            }
            if TagRule.rawSkipped.contains(lowered) {
                if !TagRule.passiveRaw.contains(lowered) {
                    hadActiveContent = true
                }
                skipRawElement(named: lowered)
                return
            }
            _ = selfClosed // children keep flowing either way
        }

        /// Parse attributes starting just after the tag name. Returns the
        /// attributes in order, whether the tag self-closed, and the index
        /// just past the closing '>'.
        private mutating func parseAttributes(from start: Int) -> (
            [Attr], Bool, Int
        ) {
            var attrs: [Attr] = []
            var j = start
            while j < bytes.count {
                skipSpace(&j)
                guard j < bytes.count else { break }
                if bytes[j] == 0x3E { // '>'
                    return (attrs, false, j + 1)
                }
                if bytes[j] == 0x2F { // '/'
                    j += 1
                    if j < bytes.count, bytes[j] == 0x3E {
                        return (attrs, true, j + 1)
                    }
                    continue
                }
                // Attribute name.
                var name = ""
                while j < bytes.count,
                    !isSpace(bytes[j]), bytes[j] != 0x3D, bytes[j] != 0x3E,
                    bytes[j] != 0x2F
                {
                    name.append(Character(UnicodeScalar(bytes[j])))
                    j += 1
                }
                skipSpace(&j)
                var value: String?
                if j < bytes.count, bytes[j] == 0x3D { // '='
                    j += 1
                    skipSpace(&j)
                    if j < bytes.count,
                        bytes[j] == 0x22 || bytes[j] == 0x27
                    { // quote
                        let quote = bytes[j]
                        j += 1
                        var raw: [UInt8] = []
                        while j < bytes.count, bytes[j] != quote {
                            raw.append(bytes[j])
                            j += 1
                        }
                        if j < bytes.count { j += 1 } // past closing quote
                        value = String(decoding: raw, as: UTF8.self)
                    } else {
                        var raw: [UInt8] = []
                        while j < bytes.count,
                            !isSpace(bytes[j]), bytes[j] != 0x3E
                        {
                            raw.append(bytes[j])
                            j += 1
                        }
                        value = String(decoding: raw, as: UTF8.self)
                    }
                }
                if !name.isEmpty {
                    attrs.append(Attr(name: name.lowercased(), rawValue: value))
                }
            }
            return (attrs, false, bytes.count) // EOF inside a tag: drop it
        }

        private mutating func skipRawElement(named tag: String) {
            // Swallow everything to the case-insensitive close tag
            // "</tag" followed by whitespace or '>', per the raw-text rule.
            let close = Array("</\(tag)".utf8)
            var j = i
            while j < bytes.count {
                if bytes[j] == 0x3C, matchesAt(j, close) {
                    var k = j + close.count
                    while k < bytes.count, isSpace(bytes[k]) { k += 1 }
                    if k < bytes.count, bytes[k] == 0x3E {
                        i = k + 1
                        return
                    }
                }
                j += 1
            }
            i = bytes.count
        }

        private mutating func skipSpace(_ j: inout Int) {
            while j < bytes.count, isSpace(bytes[j]) { j += 1 }
        }

        private func matchesAt(_ index: Int, _ pattern: [UInt8]) -> Bool {
            guard index + pattern.count <= bytes.count else { return false }
            for (offset, byte) in pattern.enumerated() {
                let b = bytes[index + offset]
                if b == byte { continue }
                // Case-fold ASCII letters only; everything else must match.
                if byte >= 0x61, byte <= 0x7A, b == byte & ~0x20 { continue }
                return false
            }
            return true
        }

        // MARK: rebuilding allowed tags

        private mutating func emitAllowedTag(
            named name: String, rule: TagRule, attrs: [Attr]
        ) {
            out.append(0x3C)
            out.append(contentsOf: Array(name.utf8))
            var seen = Set<String>()
            for attr in attrs {
                guard rule.attrs.contains(attr.name), !seen.contains(attr.name),
                    TagRule.keepAttribute(attr.name, rawValue: attr.rawValue)
                else {
                    recordDropped(attr)
                    continue
                }
                seen.insert(attr.name)
                let raw = attr.rawValue ?? ""
                switch attr.name {
                case "href":
                    guard let link = evaluateLink(raw) else {
                        hadActiveContent = true
                        continue
                    }
                    links.append(link)
                    appendAttr("href", link.href)
                case "src":
                    guard let src = evaluateImageSource(raw) else { continue }
                    appendAttr("src", src)
                default:
                    appendAttr(attr.name, raw)
                }
            }
            out.append(0x3E)
        }

        private mutating func recordDropped(_ attr: Attr) {
            // Event handlers and friends are the common active content.
            if attr.name.hasPrefix("on"), attr.rawValue != nil {
                hadActiveContent = true
            }
            if attr.name == "srcset", let v = attr.rawValue {
                if let candidate = firstAbsoluteURL(v) {
                    remoteResources.append(candidate)
                }
            }
        }

        private mutating func appendAttr(_ name: String, _ rawValue: String) {
            var escaped = ""
            escaped.reserveCapacity(rawValue.count)
            for ch in rawValue {
                switch ch {
                case "&": escaped += "&amp;"
                case "<": escaped += "&lt;"
                case ">": escaped += "&gt;"
                case "\"": escaped += "&quot;"
                default: escaped.append(ch)
                }
            }
            out.append(0x20)
            out.append(contentsOf: Array(name.utf8))
            out.append(contentsOf: Array("=\"".utf8))
            out.append(contentsOf: Array(escaped.utf8))
            out.append(0x22)
        }

        /// Scheme-check one href after entity decoding and control/whitespace
        /// stripping. Returns the link record for the interface, or nil when
        /// the URL is refused.
        private func evaluateLink(_ raw: String) -> Link? {
            let decoded = decodeEntities(raw)
            let stripped = strippedForCheck(decoded)
            if stripped.hasPrefix("#") {
                return Link(href: decoded, isExternal: false)
            }
            switch URLScheme.of(stripped) {
            case "http", "https":
                return Link(href: decoded, isExternal: true)
            case "mailto", "cid":
                return Link(href: decoded, isExternal: false)
            default:
                return nil // javascript:, data:, vbscript:, file:, unknown
            }
        }

        /// Scheme-check an image source. `cid:` parts come from the archive;
        /// inline `data:image/` URLs load no network; absolute http(s) URLs
        /// only survive when the person allowed remote content; anything else
        /// with a scheme is refused. Relative URLs resolve against the
        /// viewer's own scheme and are kept.
        private mutating func evaluateImageSource(_ raw: String) -> String? {
            let decoded = decodeEntities(raw)
            let stripped = strippedForCheck(decoded)
            switch URLScheme.of(stripped) {
            case "cid":
                return decoded
            case "data":
                return stripped.hasPrefix("data:image/") ? decoded : nil
            case "http", "https":
                remoteResources.append(decoded)
                return allowRemoteContent ? decoded : nil
            case nil:
                if stripped.hasPrefix("#") || stripped.isEmpty { return nil }
                // Relative or scheme-relative: the scheme handler answers
                // them (with nothing for paths it does not know) so no
                // network happens.
                return decoded
            default:
                return nil
            }
        }

        /// The string the scheme check sees: entity-decoded, with every
        /// control character and space removed, so "jav\tascript:" and
        /// "java\nscript:" are caught.
        private func strippedForCheck(_ value: String) -> String {
            var result = ""
            result.reserveCapacity(value.count)
            for scalar in value.unicodeScalars {
                if scalar.value <= 0x20 { continue }
                result.unicodeScalars.append(scalar)
            }
            return result.lowercased()
        }

        /// First absolute URL out of a srcset value, for reporting only.
        private func firstAbsoluteURL(_ srcset: String) -> String? {
            for token in decodeEntities(srcset)
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
            {
                let lowered = token.lowercased()
                if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
                    return String(token)
                }
            }
            return nil
        }
    }

    // MARK: - Entities

    /// Decode the entities that matter for URL and CSS checks plus the five
    /// basics. Unknown named entities stay literal, which only ever makes a
    /// URL fail the scheme check.
    static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        let chars = Array(value)
        var i = 0
        while i < chars.count {
            guard chars[i] == "&" else {
                result.append(chars[i])
                i += 1
                continue
            }
            if i + 1 < chars.count, chars[i + 1] == "#" {
                var j = i + 2
                var isHex = false
                if j < chars.count, chars[j] == "x" || chars[j] == "X" {
                    isHex = true
                    j += 1
                }
                var digits = ""
                while j < chars.count, isDigit(chars[j], hex: isHex) {
                    digits.append(chars[j])
                    j += 1
                }
                // A semicolon is optional after numeric references.
                if j < chars.count, chars[j] == ";" { j += 1 }
                if let scalar = scalarValue(digits, hex: isHex) {
                    result.unicodeScalars.append(scalar)
                    i = j
                    continue
                }
                result.append(chars[i])
                i += 1
                continue
            }
            // Named reference: longest table match without a required ';'.
            var matched = false
            for (name, replacement) in namedEntities {
                let end = i + 1 + name.count
                let noSemi = end <= chars.count && String(chars[(i + 1)..<end]) == name
                let withSemi =
                    end < chars.count && chars[end] == ";"
                    && String(chars[(i + 1)..<end]) == name
                if withSemi {
                    result += replacement
                    i = end + 1
                    matched = true
                    break
                }
                if noSemi {
                    result += replacement
                    i = end
                    matched = true
                    break
                }
            }
            if matched { continue }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    private static func scalarValue(_ digits: String, hex: Bool) -> Unicode.Scalar? {
        guard !digits.isEmpty, let value = UInt32(digits, radix: hex ? 16 : 10),
            value != 0, value < 0x110000, !(0xD800...0xDFFF).contains(value)
        else { return nil }
        return Unicode.Scalar(value)
    }

    private static func isDigit(_ ch: Character, hex: Bool) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return false
        }
        let v = scalar.value
        if v >= 0x30, v <= 0x39 { return true }
        if hex, v >= 0x41, v <= 0x46 { return true }
        if hex, v >= 0x61, v <= 0x66 { return true }
        return false
    }

    /// Named entities whose values affect URL or CSS checks (whitespace,
    /// ':', '/', '\') plus the five basics for faithful re-escaping.
    private static let namedEntities: [(String, String)] = [
        ("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("apos", "'"),
        ("colon", ":"), ("semi", ";"), ("sol", "/"), ("bsol", "\\"),
        ("tab", "\t"), ("newline", "\n"), ("period", "."), ("lpar", "("),
    ]

    // MARK: - Byte classes

    private static func isAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    /// Tag and attribute name bytes: letters, digits, hyphen, underscore,
    /// colon (namespaced names parse as one name and then fail the
    /// allow-list, which is what we want).
    private static func isNameByte(_ byte: UInt8) -> Bool {
        isAlpha(byte) || (0x30...0x39).contains(byte) || byte == 0x2D
            || byte == 0x5F || byte == 0x3A || byte == 0x2E
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }
}

/// URL scheme extraction on the check string: a colon that appears before
/// any "/", "?" or "#" means a scheme is present, whatever characters lead
/// up to it. Anything that is not a recognized scheme is refused, so the
/// unknown ones never reach the webview.
private enum URLScheme {
    /// The lowercased scheme, or nil when the string has none (a relative
    /// reference).
    static func of(_ stripped: String) -> String? {
        guard let colon = stripped.firstIndex(of: ":") else { return nil }
        let head = stripped[stripped.startIndex..<colon]
        if head.contains("/") || head.contains("?") || head.contains("#") {
            return nil // "example.com:80/x" style hosts, not a scheme
        }
        return head.lowercased()
    }
}

// MARK: - Tag rules

/// The allow-list. Everything not listed here is dropped (tag gone, children
/// kept) unless it is in `rawSkipped`, which also swallows the element's
/// content. Attributes are per-tag allow-lists; event handlers can never
/// pass because no `on*` name is listed.
private struct TagRule {
    var attrs: Set<String>
    var raw = false

    static let rawSkipped: Set<String> = [
        "script", "style", "iframe", "object", "applet", "frameset",
        "svg", "math", "template", "xmp", "noembed", "noframes",
        "title", "textarea",
    ]

    /// Raw elements whose content is swallowed without marking the message
    /// as active content: ordinary full-document mail carries them as
    /// boilerplate.
    static let passiveRaw: Set<String> = ["title", "textarea"]

    /// Dropped tags that mark the message as having carried active content
    /// (worth telling the person about); other unknown tags are dropped
    /// quietly. `embed` and `frame` are void elements with no content to
    /// swallow, so they drop as plain tags.
    static let activeDropped: Set<String> = [
        "form", "input", "button", "select", "option", "optgroup", "fieldset",
        "legend", "datalist", "output", "keygen", "meter", "progress",
        "meta", "link", "base", "dialog", "canvas", "embed", "frame",
    ]

    static let allowed: [String: TagRule] = [
        "a": TagRule(attrs: ["href"]),
        "abbr": TagRule(attrs: ["title"]),
        "acronym": TagRule(attrs: ["title"]),
        "address": TagRule(attrs: []),
        "b": TagRule(attrs: []),
        "bdi": TagRule(attrs: []),
        "bdo": TagRule(attrs: ["dir"]),
        "big": TagRule(attrs: []),
        "blockquote": TagRule(attrs: ["type", "style"]),
        "br": TagRule(attrs: []),
        "caption": TagRule(attrs: ["align"]),
        "center": TagRule(attrs: []),
        "cite": TagRule(attrs: []),
        "code": TagRule(attrs: []),
        "col": TagRule(attrs: ["span", "width", "align", "valign"]),
        "colgroup": TagRule(attrs: ["span", "width", "align", "valign"]),
        "dd": TagRule(attrs: []),
        "del": TagRule(attrs: []),
        "dfn": TagRule(attrs: []),
        "div": TagRule(attrs: ["align", "style", "class"]),
        "dl": TagRule(attrs: []),
        "dt": TagRule(attrs: []),
        "em": TagRule(attrs: []),
        "figcaption": TagRule(attrs: []),
        "figure": TagRule(attrs: []),
        "font": TagRule(attrs: ["color", "face", "size"]),
        "h1": TagRule(attrs: ["align", "style", "class"]),
        "h2": TagRule(attrs: ["align", "style", "class"]),
        "h3": TagRule(attrs: ["align", "style", "class"]),
        "h4": TagRule(attrs: ["align", "style", "class"]),
        "h5": TagRule(attrs: ["align", "style", "class"]),
        "h6": TagRule(attrs: ["align", "style", "class"]),
        "hr": TagRule(attrs: ["width", "size", "align", "noshade"]),
        "i": TagRule(attrs: []),
        "img": TagRule(attrs: ["src", "alt", "width", "height", "align", "hspace", "vspace", "border", "style"]),
        "ins": TagRule(attrs: []),
        "kbd": TagRule(attrs: []),
        "li": TagRule(attrs: ["type", "value"]),
        "mark": TagRule(attrs: []),
        "nobr": TagRule(attrs: []),
        "ol": TagRule(attrs: ["type", "start", "reversed"]),
        "p": TagRule(attrs: ["align", "style", "class"]),
        "pre": TagRule(attrs: ["style", "class"]),
        "q": TagRule(attrs: []),
        "s": TagRule(attrs: []),
        "samp": TagRule(attrs: []),
        "small": TagRule(attrs: []),
        "span": TagRule(attrs: ["style", "class"]),
        "strike": TagRule(attrs: []),
        "strong": TagRule(attrs: []),
        "sub": TagRule(attrs: []),
        "sup": TagRule(attrs: []),
        "table": TagRule(attrs: ["border", "cellpadding", "cellspacing", "width", "align", "bgcolor"]),
        "tbody": TagRule(attrs: ["align", "valign", "bgcolor"]),
        "td": TagRule(attrs: ["align", "valign", "width", "height", "colspan", "rowspan", "bgcolor", "nowrap", "style"]),
        "tfoot": TagRule(attrs: ["align", "valign", "bgcolor"]),
        "th": TagRule(attrs: ["align", "valign", "width", "height", "colspan", "rowspan", "bgcolor", "nowrap", "scope", "style"]),
        "thead": TagRule(attrs: ["align", "valign", "bgcolor"]),
        "tr": TagRule(attrs: ["align", "valign", "bgcolor"]),
        "tt": TagRule(attrs: []),
        "u": TagRule(attrs: []),
        "ul": TagRule(attrs: ["type"]),
        "wbr": TagRule(attrs: []),
    ]
}

// MARK: - CSS screening

/// Inline `style` values are kept only when they cannot fetch or execute.
/// A refused value drops the whole attribute: partial keeping would change
/// meaning in ways CSS parsing rules make hard to predict.
enum CSSScreen {
    /// Substrings that make a style value unsafe. `url` alone (not just
    /// `url(`) catches `url/**/(` and CSS-escaped spellings; `\` catches
    /// identifier escapes like `\75 rl(`.
    static let forbidden: [String] = [
        "url", "@import", "expression", "behavior", "binding", "javascript",
        "image-set", "cross-fade", "element", "attr", "<", "&", "\\",
    ]

    static func isAllowed(_ value: String) -> Bool {
        let lowered = value.lowercased()
        for needle in forbidden where lowered.contains(needle) {
            return false
        }
        return true
    }
}

extension TagRule {
    /// Screening hook for `style`: applied by the scanner through the rule's
    /// attribute list check.
    static func keepAttribute(_ name: String, rawValue: String?) -> Bool {
        guard name == "style", let value = rawValue else { return true }
        return CSSScreen.isAllowed(value)
    }
}
