// Container attachment extraction through the indexing path (DESIGN 6A,
// M2.3): Office Open XML and OpenDocument attachments must reach the search
// index via MailBridge, hostile containers must yield no text, and a row
// indexed by the previous pipeline version must gain the text by backfill.
// The ZIP fixtures are built in-test (stored entries only), so every byte
// going through the bridge is machine-constructed.

import XCTest

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
        static func zip(_ pairs: [(name: String, body: String)]) -> Data {
            var bytes: [UInt8] = []
            var central: [UInt8] = []
            var offset = 0
            for (name, body) in pairs {
                let nameBytes = Array(name.utf8)
                let payload = Array(body.utf8)
                let crc = crc32(payload)
                let local: [UInt8] = [0x50, 0x4B, 0x03, 0x04] +
                    le16(20) + le16(0) + le16(0) + le16(0) + le16(0) +
                    le32(Int(crc)) + le32(payload.count) + le32(payload.count) +
                    le16(nameBytes.count) + le16(0) + nameBytes
                bytes += local + payload
                let entry: [UInt8] = [0x50, 0x4B, 0x01, 0x02] +
                    le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) +
                    le32(Int(crc)) + le32(payload.count) + le32(payload.count) +
                    le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) +
                    le32(0) + le32(offset) + nameBytes
                central += entry
                offset += local.count + payload.count
            }
            let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] +
                le16(0) + le16(0) + le16(pairs.count) + le16(pairs.count) +
                le32(central.count) + le32(offset) + le16(0)
            return Data(bytes + central + eocd)
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
}
