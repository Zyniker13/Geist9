// Container attachment extraction through the indexing path (DESIGN 6A,
// M2.3): Office Open XML and OpenDocument attachments must reach the search
// index via MailBridge, hostile containers must yield no text, and a row
// indexed by the previous pipeline version must gain the text by backfill.
// The ZIP fixtures are built in-test (stored entries only), so every byte
// going through the bridge is machine-constructed.

import XCTest

#if canImport(CoreGraphics)
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
#endif

@testable import ArchiveCore

final class ContainerAttachmentTests: XCTestCase {
    // MARK: Fixture builder: stored-entry ZIPs, correct CRC and sizes.

    enum Container {
        /// Little-endian UInt32.
        private static func le32(_ value: Int) -> [UInt8] {
            [
                UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
            ]
        }

        private static func le16(_ value: Int) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        }

        /// CRC-32 (IEEE), reflected, same polynomial zlib uses.
        private static func crc32(_ bytes: [UInt8]) -> UInt32 {
            var table: [UInt32] = []
            table.reserveCapacity(256)
            for index in 0..<256 {
                var entry = UInt32(index)
                for _ in 0..<8 {
                    entry = (entry & 1) == 1 ? (entry >> 1) ^ 0xEDB8_8320 : entry >> 1
                }
                table.append(entry)
            }
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return crc ^ 0xFFFF_FFFF
        }

        /// One ZIP with all entries stored, fitting the reader's strict
        /// expectations: local headers, payload, central directory, EOCD.
        /// Fields are appended one at a time: long `+` chains over byte
        /// arrays send the Linux type checker into a timeout.
        static func zip(_ pairs: [(name: String, body: String)]) -> Data {
            var bytes: [UInt8] = []
            var central: [UInt8] = []
            var offset = 0
            for (name, body) in pairs {
                let nameBytes = Array(name.utf8)
                let payload = Array(body.utf8)
                let crc = crc32(payload)
                var local: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
                local += le16(20)
                local += le16(0)
                local += le16(0)
                local += le16(0)
                local += le16(0)
                local += le32(Int(crc))
                local += le32(payload.count)
                local += le32(payload.count)
                local += le16(nameBytes.count)
                local += le16(0)
                local += nameBytes
                bytes += local
                bytes += payload
                var entry: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
                entry += le16(20)
                entry += le16(20)
                entry += le16(0)
                entry += le16(0)
                entry += le16(0)
                entry += le16(0)
                entry += le32(Int(crc))
                entry += le32(payload.count)
                entry += le32(payload.count)
                entry += le16(nameBytes.count)
                entry += le16(0)
                entry += le16(0)
                entry += le16(0)
                entry += le16(0)
                entry += le32(0)
                entry += le32(offset)
                entry += nameBytes
                central += entry
                offset += local.count + payload.count
            }
            var eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
            eocd += le16(0)
            eocd += le16(0)
            eocd += le16(pairs.count)
            eocd += le16(pairs.count)
            eocd += le32(central.count)
            eocd += le32(offset)
            eocd += le16(0)
            var all = bytes
            all += central
            all += eocd
            return Data(all)
        }

        static let docx: Data = zip([
            ("word/document.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>
            <w:p><w:r><w:t>Quarterly numbers</w:t></w:r></w:p>
            <w:p><w:r><w:t>Revenue by region and plan tier</w:t></w:r></w:p>
            </w:body></w:document>
            """),
        ])

        static let xlsx: Data = zip([
            ("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"/>"),
            ("xl/sharedStrings.xml", """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <si><t>Falcon rollout</t></si>
            </sst>
            """),
            ("xl/worksheets/sheet1.xml", """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <sheetData>
            <row><c t="s"><v>0</v></c><c><v>12345</v></c></row>
            </sheetData></worksheet>
            """),
        ])

        static let odt: Data = zip([
            ("content.xml", """
            <office:document-content
              xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
              xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
            <office:body><office:text>
            <text:p>Studio Mac draft</text:p>
            </office:text></office:body>
            </office:document-content>
            """),
        ])

        static let pages: Data = zip([
            ("index.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <sl:document xmlns:sl="http://schemas.apple.com/standards/2006">
            <sf:stylesheet xmlns:sf="http://schemas.apple.com/2008/sf">
            <sl:SFTCellStyleProxy-2>HelveticaBold</sl:SFTCellStyleProxy-2>
            </sf:stylesheet>
            <sf:text-storage xmlns:sf="http://schemas.apple.com/2008/sf">
            <sf:section><sf:layout>
            <sf:p><sf:span>Agenda for Friday</sf:span></sf:p>
            </sf:layout></sf:section>
            </sf:text-storage>
            </sl:document>
            """),
        ])

        static let numbers: Data = zip([
            ("index.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <sl:document xmlns:sl="http://schemas.apple.com/standards/2006"
              xmlns:sf="http://schemas.apple.com/2008/sf">
            <sf:document>
            <sf:table><sf:tc>
            <sf:cell><sf:p>Q4 total</sf:p></sf:cell>
            <sf:cell><sf:p>4200</sf:p></sf:cell>
            </sf:tc></sf:table>
            </sf:document>
            </sl:document>
            """),
        ])

        static func corrupt(_ data: Data) -> Data {
            var bytes = [UInt8](data)
            bytes[bytes.count / 2] ^= 0xFF
            return Data(bytes)
        }

        /// Minimal one-page PDF with correct xref offsets: the same builder
        /// PDFExtractTests uses, trimmed to a single page.
        static func pdf(_ text: String) -> Data {
            let stream = "BT /F1 12 Tf 72 720 Td (\(text)) Tj ET"
            let streamBytes = stream.utf8.count
            var body = "%PDF-1.4\n"
            var offsets: [Int] = []
            func add(_ object: String) {
                offsets.append(body.utf8.count)
                body += object
            }
            add("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
            add("2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n")
            add("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n")
            add("4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 3 0 R >> >> >>\nendobj\n")
            add("5 0 obj\n<< /Length \(streamBytes) >>\nstream\n\(stream)\nendstream\nendobj\n")
            var xref = "xref\n0 6\n0000000000 65535 f \n"
            for offset in offsets {
                xref += String(format: "%010d 00000 n \n", offset)
            }
            xref += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(body.utf8.count)\n%%EOF\n"
            body += xref
            return Data(body.utf8)
        }

#if canImport(ArchiveExtractApple)
        /// Renders one line per element into a white bitmap with CoreText
        /// and returns it as PNG bytes (macOS-only: the OCR fixtures need
        /// real raster text).
        static func png(_ lines: [String]) -> Data {
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

        /// An image-only (scanned) PDF: PDFKit wraps the rendered bitmap
        /// into a one-page document, the shape a scanner produces.
        static func scannedPDF(_ lines: [String]) -> Data {
            let source = CGImageSourceCreateWithData(png(lines) as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))!
            let document = PDFDocument()
            document.insert(page, at: 0)
            return document.dataRepresentation()!
        }
#endif

        private static func base64(_ data: Data) -> String {
            data.base64EncodedString()
        }

        /// A multipart/mixed message carrying one container attachment.
        static func message(id: String, mimeType: String, filename: String, attachment: Data) -> String {
            """
            Message-ID: <\(id)>
            Date: Tue, 12 Mar 2024 09:00:00 +0000
            From: Birchline Orders <orders@birchline.example.com>
            To: alice@example.com
            Subject: Container attachment \(id)
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary=BOUND

            --BOUND
            Content-Type: text/plain; charset=utf-8

            See the attached document.
            --BOUND
            Content-Type: \(mimeType)
            Content-Transfer-Encoding: base64
            Content-Disposition: attachment; filename="\(filename)"

            \(base64(attachment))
            --BOUND--
            """
        }

        /// A minimal RFC 822 message with a plain-text body.
        static func plainMessage(id: String, subject: String, body: String) -> String {
            """
            Message-ID: <\(id)>
            Date: Tue, 12 Mar 2024 09:00:00 +0000
            From: alice@example.com
            To: bob@example.org
            Subject: \(subject)
            Content-Type: text/plain; charset=utf-8

            \(body)
            """
        }

        /// A multipart/mixed message that forwards one complete message as
        /// a message/rfc822 attachment.
        static func forwardingMessage(
            id: String, subject: String = "Forwarded for the record",
            boundary: String = "BOUND", inner: String
        ) -> String {
            """
            Message-ID: <\(id)>
            Date: Tue, 12 Mar 2024 09:05:00 +0000
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

        /// A chain of `levels` messages: the outermost is a forwarder and
        /// each deeper level forwards the next, for nesting-cap tests.
        static func nestedChain(levels: Int) -> String {
            var payload = plainMessage(
                id: "innermost@example.com",
                subject: "Innermost payload survives",
                body: "The bytes must remain readable."
            )
            for level in 1...max(levels, 1) {
                payload = forwardingMessage(
                    id: "chain-\(level)@example.com",
                    subject: "Forwarded note \(level)",
                    boundary: "BOUND-\(level)",
                    inner: payload
                )
            }
            return payload
        }

        /// True when `needle`'s bytes appear contiguously in `haystack`.
        static func bytes(_ haystack: [UInt8], contain needle: [UInt8]) -> Bool {
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            for start in 0...(haystack.count - needle.count) {
                if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
            }
            return false
        }
    }

    // MARK: - Extraction through the bridge

    func testDocxAttachmentTextIsIndexed() throws {
        let data = Data(Container.message(
            id: "docx-1@example.com", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            filename: "report.docx", attachment: Container.docx
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Quarterly numbers"), "got: \(attachments)")
        XCTAssertTrue(attachments.contains("Revenue by region"), "got: \(attachments)")
    }

    func testXlsxAttachmentTextIsIndexed() throws {
        let data = Data(Container.message(
            id: "xlsx-1@example.com", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            filename: "numbers.xlsx", attachment: Container.xlsx
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Falcon rollout"), "got: \(attachments)")
        XCTAssertTrue(attachments.contains("12345"), "got: \(attachments)")
    }

    func testOdtAttachmentTextIsIndexed() throws {
        let data = Data(Container.message(
            id: "odt-1@example.com", mimeType: "application/vnd.oasis.opendocument.text",
            filename: "draft.odt", attachment: Container.odt
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Studio Mac draft"), "got: \(attachments)")
    }

    func testContainerTypesAreListedAsAttachments() throws {
        // The attachment row must list the part itself, unchanged by
        // extraction: bytes and sizes are the viewer's source of truth.
        let data = Data(Container.message(
            id: "docx-2@example.com", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            filename: "report.docx", attachment: Container.docx
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        XCTAssertEqual(parsed.attachments.first?.contentType, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertEqual(parsed.attachments.first?.size, Container.docx.count)
    }

    // MARK: - Hostile containers

    func testCorruptContainerYieldsNoText() throws {
        let data = Data(Container.message(
            id: "docx-corrupt@example.com", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            filename: "broken.docx", attachment: Container.corrupt(Container.docx)
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        // The attachment is still listed with its real bytes...
        XCTAssertEqual(parsed.attachments.first?.size, Container.corrupt(Container.docx).count)
        // ...but nothing quietly wrong reaches the index.
        let text = parsed.searchText.attachments
        XCTAssertTrue(text == nil || !text!.contains("Quarterly"), "corrupt container must not produce text: \(text ?? "nil")")
    }

    // MARK: - iWork

    func testPagesAttachmentTextIsIndexed() throws {
        let data = Data(Container.message(
            id: "pages-1@example.com", mimeType: "application/vnd.apple.pages",
            filename: "plan.pages", attachment: Container.pages
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Agenda for Friday"), "got: \(attachments)")
        XCTAssertFalse(attachments.contains("HelveticaBold"), "style text must not be indexed: \(attachments)")
    }

    func testNumbersAttachmentTextIsIndexed() throws {
        let data = Data(Container.message(
            id: "numbers-1@example.com", mimeType: "application/vnd.apple.numbers",
            filename: "budget.numbers", attachment: Container.numbers
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Q4 total"), "got: \(attachments)")
        XCTAssertTrue(attachments.contains("4200"), "got: \(attachments)")
    }

    func testPagesFallbackByFilename() throws {
        let data = Data(Container.message(
            id: "pages-2@example.com", mimeType: "application/octet-stream",
            filename: "plan.pages", attachment: Container.pages
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Agenda for Friday"), "got: \(attachments)")
    }

    func testCorruptPagesYieldsNoText() throws {
        let data = Data(Container.message(
            id: "pages-corrupt@example.com", mimeType: "application/vnd.apple.pages",
            filename: "broken.pages", attachment: Container.corrupt(Container.pages)
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        XCTAssertEqual(parsed.attachments.first?.size, Container.corrupt(Container.pages).count)
        let text = parsed.searchText.attachments
        XCTAssertTrue(text == nil || !text!.contains("Agenda"), "corrupt container must not produce text: \(text ?? "nil")")
    }

    // MARK: - Backfill (version bump)

    func testVersionBumpBackfillsContainerText() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-container-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ArchiveStore.create(at: tempDir.appendingPathComponent("C.emailarchive"), appVersion: "0.1.0")

        let data = Data(Container.message(
            id: "backfill-docx@example.com", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            filename: "report.docx", attachment: Container.docx
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", flags: [])],
            labels: [],
            attachments: parsed.attachments,
            providerThreadID: nil,
            searchText: parsed.searchText
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        guard case .created(let id) = try store.ingest(message, into: account) else {
            return XCTFail("ingest must create")
        }

        // Simulate the previous pipeline: mark the row older than current
        // and blank the attachment text the old row could not have had.
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = textVersion - 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE message_text SET attachments = 'report docx' WHERE rowid = ?", arguments: [id])
        }
        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 1)
        let got = try store.db.read { db in
            try String.fetchOne(
                db, sql: "SELECT attachments FROM message_text WHERE rowid = ?", arguments: [id]
            )
        }
        let attachments = try XCTUnwrap(got)
        XCTAssertTrue(
            attachments.contains("quarterly numbers"),
            "the v7 backfill must restore container text: \(attachments)"
        )
    }

    func testVersionBumpBackfillsIWorkText() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-iwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ArchiveStore.create(at: tempDir.appendingPathComponent("C.emailarchive"), appVersion: "0.1.0")

        let data = Data(Container.message(
            id: "backfill-pages@example.com", mimeType: "application/vnd.apple.pages",
            filename: "plan.pages", attachment: Container.pages
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", flags: [])],
            labels: [],
            attachments: parsed.attachments,
            providerThreadID: nil,
            searchText: parsed.searchText
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        guard case .created(let id) = try store.ingest(message, into: account) else {
            return XCTFail("ingest must create")
        }

        // Simulate the previous pipeline: mark the row older than current
        // and blank the attachment text the old row could not have had.
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = textVersion - 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE message_text SET attachments = 'plan pages' WHERE rowid = ?", arguments: [id])
        }
        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 1)
        let got = try store.db.read { db in
            try String.fetchOne(
                db, sql: "SELECT attachments FROM message_text WHERE rowid = ?", arguments: [id]
            )
        }
        let attachments = try XCTUnwrap(got)
        XCTAssertTrue(
            attachments.contains("agenda for friday"),
            "the v8 backfill must restore iWork text: \(attachments)"
        )
    }

    // MARK: - PDF (decision 0039, macOS-only PDFKit extractor)

#if canImport(ArchiveExtractApple)
    func testPDFAttachmentTextIsIndexed() throws {
        let data = Data(Container.message(
            id: "pdf@example.com", mimeType: "application/pdf",
            filename: "invoice.pdf", attachment: Container.pdf("Quarterly numbers report")
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Quarterly numbers"), "got: \(attachments)")
        XCTAssertEqual(parsed.attachments.first?.size, Container.pdf("Quarterly numbers report").count)
    }

    func testPDFFallbackByFilename() throws {
        let data = Data(Container.message(
            id: "pdf-fallback@example.com", mimeType: "application/octet-stream",
            filename: "summary.PDF", attachment: Container.pdf("Agenda for Friday")
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Agenda for Friday"), "got: \(attachments)")
    }

    func testVersionBumpBackfillsPDFText() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ArchiveStore.create(at: tempDir.appendingPathComponent("C.emailarchive"), appVersion: "0.1.0")

        let pdfBytes = Container.pdf("Quarterly numbers report")
        let data = Data(Container.message(
            id: "backfill-pdf@example.com", mimeType: "application/pdf",
            filename: "invoice.pdf", attachment: pdfBytes
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", flags: [])],
            labels: [],
            attachments: parsed.attachments,
            providerThreadID: nil,
            searchText: parsed.searchText
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        guard case .created(let id) = try store.ingest(message, into: account) else {
            return XCTFail("ingest must create")
        }

        // Simulate the previous pipeline: mark the row older than current
        // and blank the attachment text the old row could not have had.
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = textVersion - 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE message_text SET attachments = 'invoice pdf' WHERE rowid = ?", arguments: [id])
        }
        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 1)
        let got = try store.db.read { db in
            try String.fetchOne(
                db, sql: "SELECT attachments FROM message_text WHERE rowid = ?", arguments: [id]
            )
        }
        let attachments = try XCTUnwrap(got)
        XCTAssertTrue(
            attachments.contains("quarterly numbers"),
            "the v9 backfill must restore PDF text: \(attachments)"
        )
    }

    // MARK: - OCR (decisions 0010 and 0040, macOS-only Vision extractor)

    func testImageAttachmentTextIsIndexed() throws {
        let pngBytes = Container.png(["Scanned receipt from Harbor Lane"])
        let data = Data(Container.message(
            id: "ocr@example.com", mimeType: "image/png",
            filename: "receipt.png", attachment: pngBytes
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Harbor Lane"), "got: \(attachments)")
        XCTAssertEqual(parsed.attachments.first?.size, pngBytes.count)
    }

    func testScannedPDFAttachmentTextIsIndexed() throws {
        let data = Data(Container.message(
            id: "scanned@example.com", mimeType: "application/pdf",
            filename: "scan.pdf", attachment: Container.scannedPDF(["Scanned receipt from Harbor Lane"])
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Harbor Lane"), "got: \(attachments)")
    }

    func testVersionBumpBackfillsOCRText() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ArchiveStore.create(at: tempDir.appendingPathComponent("C.emailarchive"), appVersion: "0.1.0")

        let pngBytes = Container.png(["Scanned receipt from Harbor Lane"])
        let data = Data(Container.message(
            id: "backfill-ocr@example.com", mimeType: "image/png",
            filename: "receipt.png", attachment: pngBytes
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", flags: [])],
            labels: [],
            attachments: parsed.attachments,
            providerThreadID: nil,
            searchText: parsed.searchText
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        guard case .created(let id) = try store.ingest(message, into: account) else {
            return XCTFail("ingest must create")
        }

        // Simulate the previous pipeline: mark the row older than current
        // and blank the attachment text the old row could not have had.
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = textVersion - 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE message_text SET attachments = 'scanned receipt' WHERE rowid = ?", arguments: [id])
        }
        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 1)
        let got = try store.db.read { db in
            try String.fetchOne(
                db, sql: "SELECT attachments FROM message_text WHERE rowid = ?", arguments: [id]
            )
        }
        let attachments = try XCTUnwrap(got)
        XCTAssertTrue(
            attachments.contains("harbor"),
            "the v10 backfill must restore OCR text: \(attachments)"
        )
    }
#endif

    // MARK: - Nested message/rfc822 (M2.3)

    func testForwardedMessageTextIsIndexed() throws {
        let inner = Container.plainMessage(
            id: "inner@example.com",
            subject: "Recipe exchange thread",
            body: "Curry recipe lives in the shared drive."
        )
        let data = Data(Container.forwardingMessage(id: "fwd@example.com", inner: inner).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Recipe exchange thread"), "got: \(attachments)")
        XCTAssertTrue(
            attachments.contains("Curry recipe lives in the shared drive"),
            "got: \(attachments)"
        )
    }

    func testForwardedSubjectEncodedWordIsDecoded() throws {
        let encoded = "=?utf-8?B?\(Data("Weekly status summary".utf8).base64EncodedString())?="
        let inner = Container.plainMessage(
            id: "enc@example.com", subject: encoded, body: "Standing agenda in the notes."
        )
        let data = Data(Container.forwardingMessage(id: "encfwd@example.com", inner: inner).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Weekly status summary"), "got: \(attachments)")
    }

    func testForwardedHTMLBodyIsReducedToText() throws {
        let inner = """
        Message-ID: <html@example.com>
        From: alice@example.com
        To: bob@example.org
        Subject: Schedule change
        Content-Type: text/html; charset=utf-8

        <html><body><p>Sprint review moved</p><p>to Thursday</p></body></html>
        """
        let data = Data(Container.forwardingMessage(id: "htmlfwd@example.com", inner: inner).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Sprint review moved"), "got: \(attachments)")
        XCTAssertTrue(attachments.contains("to Thursday"), "got: \(attachments)")
    }

    func testNestedChainExtractionStopsAtDepthCap() throws {
        let data = Data(Container.nestedChain(levels: 40).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Forwarded note 38"), "got: \(attachments)")
        XCTAssertFalse(
            attachments.contains("Forwarded note 6"),
            "beyond the 32-level nesting cap the text must stop: got \(attachments)"
        )
    }

    func testVersionBumpBackfillsNestedText() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ArchiveStore.create(at: tempDir.appendingPathComponent("C.emailarchive"), appVersion: "0.1.0")

        let inner = Container.plainMessage(
            id: "family@example.com",
            subject: "Family photo planning",
            body: "Album link inside."
        )
        let data = Data(Container.forwardingMessage(id: "nestedbackfill@example.com", inner: inner).utf8)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", flags: [])],
            labels: [],
            attachments: parsed.attachments,
            providerThreadID: nil,
            searchText: parsed.searchText
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        guard case .created(let id) = try store.ingest(message, into: account) else {
            return XCTFail("ingest must create")
        }

        // Simulate the previous pipeline: mark the row older than current
        // and blank the nested-message text the old row could not have had.
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = textVersion - 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE message_text SET attachments = 'family photos' WHERE rowid = ?", arguments: [id])
        }
        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 1)
        let got = try store.db.read { db in
            try String.fetchOne(
                db, sql: "SELECT attachments FROM message_text WHERE rowid = ?", arguments: [id]
            )
        }
        let attachments = try XCTUnwrap(got)
        XCTAssertTrue(
            attachments.contains("family photo planning"),
            "the v11 backfill must restore nested-message text: \(attachments)"
        )
        XCTAssertTrue(
            attachments.contains("album link inside"),
            "the v11 backfill must restore nested-message body text: \(attachments)"
        )
    }

    // MARK: - RTF (M2.3, ROADMAP line 69)

    func testRTFAttachmentTextIsIndexed() throws {
        let rtf = """
        {\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}
        \\fs24 Budget notes \\b Q4\\b0  travel\\par
        Invoice \\u8212 ? total \\'96 4,200\\par
        {\\pict fakebytes}\\field{\\*\\fldinst HYPERLINK}{\\fldrslt renewal link}}
        """
        let data = Data(Container.message(
            id: "rtfattach@example.com",
            mimeType: "application/rtf",
            filename: "budget.rtf",
            attachment: Data(rtf.utf8)
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let attachments = try XCTUnwrap(parsed.searchText.attachments)
        XCTAssertTrue(attachments.contains("Budget notes Q4"), "got \(attachments)")
        XCTAssertTrue(attachments.contains("Invoice \u{2014} total \u{2013} 4,200"), "got \(attachments)")
        XCTAssertTrue(attachments.contains("renewal link"), "got \(attachments)")
        XCTAssertFalse(attachments.contains("Helvetica"), "font tables must not reach the index")
        XCTAssertFalse(attachments.contains("HYPERLINK"), "field instructions must not reach the index")
    }

    func testVersionBumpBackfillsRTFText() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-rtf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ArchiveStore.create(at: tempDir.appendingPathComponent("C.emailarchive"), appVersion: "0.1.0")

        let rtf = "{\\rtf1\\ansi Renewal plan \\b approved\\b0  today}"
        let data = Data(Container.message(
            id: "rtfbackfill@example.com",
            mimeType: "application/rtf",
            filename: "plan.rtf",
            attachment: Data(rtf.utf8)
        ).utf8)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX", flags: [])],
            labels: [],
            attachments: parsed.attachments,
            providerThreadID: nil,
            searchText: parsed.searchText
        )
        let account = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")
        guard case .created(let id) = try store.ingest(message, into: account) else {
            return XCTFail("ingest must create")
        }

        // Simulate the previous pipeline: mark the row older than current
        // and blank the RTF text the old row could not have had.
        try store.db.write { db in
            try db.execute(sql: "UPDATE message SET textVersion = textVersion - 1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE message_text SET attachments = 'plan notes' WHERE rowid = ?", arguments: [id])
        }
        let processed = try store.reindexOutdated()
        XCTAssertEqual(processed, 1)
        let got = try store.db.read { db in
            try String.fetchOne(
                db, sql: "SELECT attachments FROM message_text WHERE rowid = ?", arguments: [id]
            )
        }
        let attachments = try XCTUnwrap(got)
        XCTAssertTrue(
            attachments.contains("renewal plan approved today"),
            "the RTF backfill must restore attachment text: \(attachments)"
        )
    }
}
