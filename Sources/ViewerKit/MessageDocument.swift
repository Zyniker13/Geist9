// Message document assembly (DESIGN 8, decision 0019): sanitizer output +
// cid rewrite to the attachment scheme + CSP. Everything the viewer loads is
// inert unless the person granted remote content for that message.

import Foundation
import MailMIME

public enum MessageDocument {
    /// The custom scheme that serves attachment bytes out of the archive.
    public static let attachmentSchemeName = "x-bc-mail"

    public struct Output: Sendable, Equatable {
        /// The full HTML document to load.
        public var html: String
        /// Decoded link targets, for confirm-before-open in the interface.
        public var links: [HTMLSanitizer.Link]
        /// Absolute http(s) resources the message referenced, granted or not.
        public var remoteResources: [String]
        /// The message carried script, forms, or other active content that
        /// was dropped.
        public var hadActiveContent: Bool
        /// The body was plain text, rendered escaped.
        public var isPlainText: Bool

        public init(
            html: String, links: [HTMLSanitizer.Link], remoteResources: [String],
            hadActiveContent: Bool, isPlainText: Bool
        ) {
            self.html = html
            self.links = links
            self.remoteResources = remoteResources
            self.hadActiveContent = hadActiveContent
            self.isPlainText = isPlainText
        }
    }

    /// The base URL a message document loads against; attachment URLs live
    /// under it. Hierarchical so relative resolution inside the document
    /// resolves into the same message's space.
    public static func baseURL(messageRowID: Int64) -> URL {
        URL(string: "\(attachmentSchemeName)://message/\(messageRowID)/")!
    }

    /// The URL the attachment scheme serves `contentID` under for a message.
    public static func attachmentURL(messageRowID: Int64, contentID: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "@._-")
        let encoded = contentID.addingPercentEncoding(withAllowedCharacters: allowed) ?? contentID
        return URL(string: "\(attachmentSchemeName)://message/\(messageRowID)/cid/\(encoded)")!
    }

    /// Render a message body. Pass exactly one of `bodyHTML` / `plainText`;
    /// a nil pair renders an empty document. HTML always goes through the
    /// sanitizer, even when trusted — it is the only markup source.
    public static func render(
        bodyHTML: String?,
        plainText: String?,
        messageRowID: Int64,
        allowRemoteContent: Bool
    ) -> Output {
        if bodyHTML == nil {
            let text = plainText ?? ""
            let body = "<pre class=\"bc-plain\">\(escape(text))</pre>"
            return Output(
                html: wrap(body, allowRemoteContent: false),
                links: [], remoteResources: [], hadActiveContent: false, isPlainText: true
            )
        }
        let result = HTMLSanitizer.sanitize(bodyHTML!, allowRemoteContent: allowRemoteContent)
        let body = rewriteCIDSources(result.html, messageRowID: messageRowID)
        return Output(
            html: wrap(body, allowRemoteContent: allowRemoteContent),
            links: result.links,
            remoteResources: result.remoteResources,
            hadActiveContent: result.hadActiveContent,
            isPlainText: false
        )
    }

    /// The Content-Security-Policy the document carries. Network sources are
    /// `none` by default; images may come from the attachment scheme, inline
    /// data URLs, and — only when granted — any http(s) host, which the
    /// WebKit rule list then narrows to the granted hosts.
    public static func csp(allowRemoteContent: Bool) -> String {
        var img = "img-src \(attachmentSchemeName): data:"
        if allowRemoteContent { img += " https: http:" }
        return [
            "default-src 'none'",
            "script-src 'none'",
            "object-src 'none'",
            "frame-src 'none'",
            "connect-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
            "media-src 'none'",
            "font-src data:",
            "style-src 'unsafe-inline'",
            img,
        ].joined(separator: "; ")
    }

    static func wrap(_ body: String, allowRemoteContent: Bool) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">\
        <meta name="referrer" content="no-referrer">\
        <meta http-equiv="Content-Security-Policy" content="\(csp(allowRemoteContent: allowRemoteContent))">\
        </head><body><div class="bc-message">\(body)</div></body></html>
        """
    }

    /// Escape text for text-context emission.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Rewrite `src="cid:…"` sources (emitted by the sanitizer) to the
    /// attachment scheme for the message being rendered. The sanitizer
    /// guarantees the attribute is exactly `src="cid:<value>"` with `&<>"`
    /// escaped inside, so the scan is exact.
    static func rewriteCIDSources(_ html: String, messageRowID: Int64) -> String {
        guard let range = html.range(of: "src=\"cid:", options: .caseInsensitive) else {
            return html
        }
        var result = ""
        var cursor = html.startIndex
        while let cidStart = html.range(of: "src=\"cid:", options: .caseInsensitive, range: cursor..<html.endIndex) {
            result += html[cursor..<cidStart.lowerBound]
            var valueEnd = cidStart.upperBound
            while valueEnd < html.endIndex, html[valueEnd] != "\"" { valueEnd = html.index(after: valueEnd) }
            guard valueEnd < html.endIndex else {
                // Unterminated: keep the remainder verbatim; the sanitizer
                // never emits this, so it cannot happen in practice.
                result += html[cidStart.lowerBound..<html.endIndex]
                return result
            }
            let cid = unescape(String(html[cidStart.upperBound..<valueEnd]))
            let url = attachmentURL(messageRowID: messageRowID, contentID: cid)
            result += "src=\"\(url.absoluteString)\""
            cursor = html.index(after: valueEnd)
        }
        result += html[cursor..<html.endIndex]
        return result
    }

    /// Undo the escapes the sanitizer emits inside attribute values.
    static func unescape(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let rest = text[index...]
            var matched = false
            for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
                if rest.hasPrefix(entity) {
                    out.append(character)
                    index = text.index(index, offsetBy: entity.count)
                    matched = true
                    break
                }
            }
            // No entity matched: emit the ampersand literally.
            if !matched {
                out.append("&")
                index = text.index(after: index)
            }
        }
        return out
    }
}
