// MIME structure (RFC 2045-2049): the message as a tree of parts.
//
// The original bytes are never rewritten: every part keeps its raw body
// (after the header block, before transfer decoding), and decoding is a
// pure function of those bytes. A part that cannot be parsed is a leaf
// with its raw body, so nothing is ever lost.

import Foundation

public enum MIMEKind: Sendable, Equatable {
    case leaf
    case multipart
    case nestedMessage // message/rfc822: children holds the inner message
}

public struct MIMEPart: Sendable, Equatable {
    public let headers: HeaderBlock
    /// Raw body bytes: everything after the header block, undecoded.
    public let bodyBytes: [UInt8]
    /// Children for multipart/* and message/rfc822; empty for leaves.
    public let children: [MIMEPart]
    public let kind: MIMEKind

    public init(headers: HeaderBlock, bodyBytes: [UInt8], children: [MIMEPart], kind: MIMEKind) {
        self.headers = headers
        self.bodyBytes = bodyBytes
        self.children = children
        self.kind = kind
    }

    public var isLeaf: Bool { kind == .leaf }

    // MARK: - Header access

    private var contentTypeText: String {
        headers.first("content-type")?.valueText ?? "text/plain"
    }

    public var contentType: (main: String, parameters: [String: String]) {
        let (main, params) = HeaderParameters.split(contentTypeText)
        return (main.lowercased(), HeaderParameters.resolve(params))
    }

    public var contentDisposition: [String: String] {
        guard let text = headers.first("content-disposition")?.valueText else { return [:] }
        let (main, params) = HeaderParameters.split(text)
        var result = HeaderParameters.resolve(params)
        result["content-disposition"] = main.lowercased()
        return result
    }

    /// Content-ID with angle brackets stripped, lowercased.
    public var contentID: String? {
        guard let text = headers.first("content-id")?.valueText else { return nil }
        var id = text.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("<"), id.hasSuffix(">") {
            id = String(id.dropFirst().dropLast())
        }
        return id.lowercased()
    }

    /// File name from Content-Disposition, falling back to Content-Type.
    public var filename: String? {
        if let name = contentDisposition["filename"] { return name }
        return contentType.parameters["filename"]
    }

    public var transferEncoding: String? {
        headers.first("content-transfer-encoding")?.valueText
    }

    // MARK: - Decoding

    /// Body bytes after transfer decoding.
    public var decodedBody: [UInt8] {
        Transfer.decode(encoding: transferEncoding, bodyBytes)
    }

    /// Decoded text for text/* leaves, using the part's charset.
    public var text: String? {
        guard isLeaf else { return nil }
        let (main, params) = contentType
        guard main.hasPrefix("text/") else { return nil }
        return Charset.decode(params["charset"], decodedBody)
    }

    /// All leaf parts, depth-first.
    public func leaves() -> [MIMEPart] {
        if isLeaf { return [self] }
        return children.flatMap { $0.leaves() }
    }

    /// The inner message of a message/rfc822 part.
    public var nestedMessage: MIMEPart? {
        kind == .nestedMessage ? children.first : nil
    }
}

public enum MIMEParser {
    /// Maximum message/rfc822 nesting depth the parser descends into.
    /// Deeper levels keep their raw bytes as a leaf, so nothing is lost.
    public static let nestingDepthLimit = 32

    /// Parse a complete message (headers + body) into a part tree.
    public static func parse(_ data: Data) -> MIMEPart {
        let bytes = [UInt8](data)
        let block = HeaderScanner.scan(data)
        let body = Array(bytes[block.bodyStart...])
        return makePart(headers: block, body: body, depth: 0)
    }

    private static func makePart(headers: HeaderBlock, body: [UInt8], depth: Int) -> MIMEPart {
        let (main, params) = HeaderParameters.split(
            headers.first("content-type")?.valueText ?? "text/plain"
        )
        let resolved = HeaderParameters.resolve(params)
        let type = main.lowercased()

        if type.hasPrefix("multipart/") {
            if let boundary = resolved["boundary"] {
                let children = splitMultipart(body, boundary: boundary, depth: depth)
                return MIMEPart(headers: headers, bodyBytes: body, children: children, kind: .multipart)
            }
            // A multipart without a usable boundary: keep the raw body as a leaf.
            return MIMEPart(headers: headers, bodyBytes: body, children: [], kind: .leaf)
        }

        if type == "message/rfc822" {
            // The body is a complete message; its transfer encoding applies
            // to the whole inner message. Descend only to the nesting limit;
            // deeper levels keep their raw bytes as a leaf.
            guard depth < nestingDepthLimit else {
                return MIMEPart(headers: headers, bodyBytes: body, children: [], kind: .leaf)
            }
            let encoding = headers.first("content-transfer-encoding")?.valueText
            let decoded = Transfer.decode(encoding: encoding, body)
            let inner = makePart(body: decoded, depth: depth + 1)
            return MIMEPart(headers: headers, bodyBytes: body, children: [inner], kind: .nestedMessage)
        }

        return MIMEPart(headers: headers, bodyBytes: body, children: [], kind: .leaf)
    }

    private static func makePart(body: [UInt8], depth: Int) -> MIMEPart {
        let block = HeaderScanner.scan(Data(body))
        let bytes = [UInt8](body)
        let partBody = Array(bytes[block.bodyStart...])
        return makePart(headers: block, body: partBody, depth: depth)
    }

    // MARK: - Boundary splitting

    private static func starts(_ a: [UInt8], with b: [UInt8]) -> Bool {
        guard b.count <= a.count else { return false }
        for k in 0..<b.count where a[k] != b[k] { return false }
        return true
    }

    private static func splitMultipart(
        _ body: [UInt8], boundary: String, depth: Int
    ) -> [MIMEPart] {
        let marker = [UInt8](boundary.utf8)
        var parts: [MIMEPart] = []
        var currentStart: Int? = nil
        var i = 0

        while i < body.count {
            // Find the end of this line.
            var end = i
            while end < body.count && body[end] != 0x0A { end += 1 }
            // Line content without leading WSP or a trailing CR.
            var ls = i
            while ls < end && (body[ls] == 0x20 || body[ls] == 0x09) { ls += 1 }
            var le = end
            if le > ls && body[le - 1] == 0x0D { le -= 1 }
            let content = Array(body[ls..<le])

            if starts(content, with: [0x2D, 0x2D] + marker) {
                let rest = content.dropFirst(2 + marker.count)
                if starts(Array(rest), with: [0x2D, 0x2D]) {
                    // Closing boundary: end of the multipart body.
                    if let start = currentStart {
                        parts.append(makePart(body: Array(body[start..<i]), depth: depth))
                        currentStart = nil
                    }
                    break
                }
                if rest.isEmpty || rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    // Opening boundary: start the next part.
                    if let start = currentStart {
                        parts.append(makePart(body: Array(body[start..<i]), depth: depth))
                    }
                    currentStart = end + 1
                }
                // Otherwise a longer boundary name: not ours.
            }
            i = end + 1
        }

        // Malformed multipart without a closing boundary: keep the tail.
        if let start = currentStart {
            parts.append(makePart(body: Array(body[start...]), depth: depth))
        }
        return parts
    }
}
