// End-to-end OCR search (ROADMAP M2 "Done when"): a scanned receipt
// fixture — an image attachment whose words exist only as pixels — is
// found by a word printed on it after ingest, extraction (Vision OCR),
// indexing and search. Everything is rendered in-test; no binary blobs.

import Foundation
import Testing
import AppKit
import CoreGraphics
import CoreText
import ImageIO
@testable import ArchiveExtractApple
@testable import ArchiveCore

@Suite struct ScannedReceiptSearchTests {

    /// Renders the given lines of text into a bitmap (white background,
    /// black CoreText lines) and returns it as PNG bytes — the same fixture
    /// recipe OCRTextTests uses for the extractor contract.
    func png(_ lines: [String]) -> Data {
        let width = 900
        let height = 120 + 70 * lines.count
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        for (index, line) in lines.enumerated() {
            let attributes = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ] as CFDictionary
            let attributed = CFAttributedStringCreate(nil, line as CFString, attributes)!
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 60, y: CGFloat(height - 90 - 70 * index))
            CTLineDraw(ctLine, context)
        }
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A multipart/mixed message carrying one base64 image attachment.
    func message(id: String, attachment: Data) -> String {
        let base64 = attachment.base64EncodedString()
        return """
        Message-ID: <\(id)@example.com>
        Date: Tue, 12 Mar 2024 09:00:00 +0000
        From: Birchline Orders <orders@birchline.example.com>
        To: alice@example.com
        Subject: Scanned receipt attached
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary=BOUND

        --BOUND
        Content-Type: text/plain; charset=utf-8

        See the attached scan.
        --BOUND
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="receipt.png"

        \(base64)
        --BOUND--
        """
    }

    /// The ROADMAP line: "a scanned receipt fixture is found by a word
    /// printed on it". Ingest the image-only message, then search for a
    /// word that exists nowhere in the subject or body text.
    @Test func scannedReceiptIsFoundByAPrintedWord() throws {
        let png = png([
            "Scanned receipt from Harbor Lane",
            "Total due twenty dollars",
        ])
        let raw = message(id: "ocr-receipt-e2e", attachment: png)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-ocr-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("OCR.emailarchive"), appVersion: "0.1.0"
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        let data = Data((raw + "\n").utf8)
        let parsed = MailBridge.parse(for: data)
        let ingested = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX")],
            labels: parsed.gmailLabels.map { LabelName(name: $0) },
            attachments: parsed.attachments,
            providerThreadID: parsed.gmailThreadID,
            searchText: parsed.searchText
        )
        _ = try store.ingest(ingested, into: account)

        // "Harbor" is printed on the scan and appears nowhere else.
        let hits = try store.search("Harbor").hits
        #expect(hits.count == 1)
        // The match must come from the attachment field, not the body.
        let joined = try store.search("harbor lane").hits
        #expect(joined.count == 1)
        // And the body word still works on its own.
        let bodyHits = try store.search("scan").hits
        #expect(bodyHits.count == 1)
    }
}
