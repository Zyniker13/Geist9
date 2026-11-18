// Attachment scheme handler (DESIGN 8, decision 0019): the only web
// origin inside the viewer that can reach message data, serving attachment
// bytes straight from the archive, and nothing else.

import Foundation
import WebKit

/// The lookup the viewer uses to fetch attachment bytes for a message:
/// message row id and the cid (or, later, file name) named by the message.
public struct AttachmentSource: Sendable {
    public var resolve: @Sendable (_ messageRowID: Int64, _ contentID: String) -> (data: Data, contentType: String)?

    public init(resolve: @escaping @Sendable (_ messageRowID: Int64, _ contentID: String) -> (data: Data, contentType: String)?) {
        self.resolve = resolve
    }

    /// A source that answers nothing: renders broken images, touches no data.
    public static let none = AttachmentSource { _, _ in nil }
}

/// URL shapes: `x-bc-mail://message/<rowid>/cid/<content id>`.
public enum AttachmentScheme {
    public static let name = "x-bc-mail"
}

public final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let source: AttachmentSource

    public init(source: AttachmentSource) {
        self.source = source
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let (rowID, contentID) = Self.parse(url),
              let hit = source.resolve(rowID, contentID)
        else {
            Self.respondNotFound(urlSchemeTask)
            return
        }
        let response = URLResponse(
            url: url, mimeType: hit.contentType,
            expectedContentLength: hit.data.count, textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(hit.data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Responses are delivered synchronously; nothing to cancel.
    }

    /// Parse an attachment URL. Anything that is not exactly the documented
    /// shape for the message namespace answers nothing.
    static func parse(_ url: URL) -> (rowID: Int64, contentID: String)? {
        guard url.scheme?.lowercased() == AttachmentScheme.name,
              url.host?.lowercased() == "message"
        else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 3,
              components[1].lowercased() == "cid",
              let rowID = Int64(components[0])
        else { return nil }
        let contentID = components[2].removingPercentEncoding ?? String(components[2])
        return (rowID, contentID)
    }

    private static func respondNotFound(_ task: WKURLSchemeTask) {
        let response = HTTPURLResponse(
            url: task.request.url ?? URL(string: "x-bc-mail://message/0/cid/x")!,
            statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
    }
}
