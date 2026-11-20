import XCTest
@testable import MailMIME

/// Deep message/rfc822 nesting must stop at a fixed cap: the parser must
/// never descend without bound, while the raw bytes of anything beyond the
/// cap stay preserved in a leaf.
final class NestedDepthTests: XCTestCase {
    private func plainMessage(subject: String, body: String) -> String {
        """
        Message-ID: <inner@example.com>
        From: alice@example.com
        To: bob@example.org
        Subject: \(subject)
        Content-Type: text/plain; charset=utf-8

        \(body)
        """
    }

    private func forwardingMessage(subject: String, boundary: String, inner: String) -> String {
        """
        Message-ID: <wrap@example.com>
        From: alice@example.com
        To: bob@example.org
        Subject: \(subject)
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary=\(boundary)

        --\(boundary)
        Content-Type: text/plain; charset=utf-8

        Keeping this on file.
        --\(boundary)
        Content-Type: message/rfc822
        Content-Disposition: attachment; filename="forwarded.eml"

        \(inner)
        --\(boundary)--
        """
    }

    private func nestedChain(levels: Int) -> String {
        var payload = plainMessage(
            subject: "Innermost payload survives",
            body: "The bytes must remain readable."
        )
        for level in stride(from: levels - 1, through: 1, by: -1) {
            payload = forwardingMessage(
                subject: "Forwarded note \(level)",
                boundary: "BOUND-\(level)",
                inner: payload
            )
        }
        return payload
    }

    private func nestedHops(_ part: MIMEPart) -> Int {
        if part.kind == .nestedMessage {
            return 1 + (part.children.first.map(nestedHops) ?? 0)
        }
        return part.children.map(nestedHops).max() ?? 0
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    private func anyLeafContains(_ part: MIMEPart, _ needle: [UInt8]) -> Bool {
        if part.kind == .leaf, contains(part.bodyBytes, needle) { return true }
        return part.children.contains { anyLeafContains($0, needle) }
    }

    func testNestedDepthCapStopsDescentWithoutDataLoss() throws {
        let data = Data(nestedChain(levels: 40).utf8)
        let parsed = MIMEParser.parse(data)
        // The cap is 32 levels; must match MailMIME's nesting depth limit.
        XCTAssertEqual(nestedHops(parsed), 32, "descent must stop at the nesting limit")
        let needle = [UInt8]("The bytes must remain readable.".utf8)
        XCTAssertTrue(anyLeafContains(parsed, needle), "innermost bytes must survive the cap")
    }
}
