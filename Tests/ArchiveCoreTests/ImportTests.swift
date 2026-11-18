// Import (DESIGN 9): every format imports through MailBridge + Ingest, keeps
// the source's bytes exactly as attested, isolates per-message failures, and
// reports counts that add up (found = imported + duplicates + failed).

import XCTest
import GRDB
@testable import ArchiveCore

final class ImportTests: XCTestCase {
    private var tempDir: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try ArchiveStore.create(at: archiveURL, appVersion: "0.1.0")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private var archiveURL: URL { tempDir.appendingPathComponent("Test.emailarchive") }

    // MARK: Helpers

    private func count(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> Int {
        try store.db.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
    }

    private func scalar(_ sql: String, _ arguments: StatementArguments = StatementArguments()) throws -> String? {
        try store.db.read { db in try String.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func eml(
        subject: String, body: String = "hello", headers: String = "",
        date: String = "Mon, 04 Mar 2024 10:00:00 +0000"
    ) -> Data {
        Data(
            """
            From: Alice <alice@example.com>\r
            To: Bob <bob@example.org>\r
            Subject: \(subject)\r
            Message-ID: <\(subject)@example.com>\r
            Date: \(date)\r
            \(headers)\r
            \(body)\r
            
            """.utf8
        )
    }

    /// The stored bytes for the (only) message with this subject.
    private func storedBytes(subject: String) throws -> Data {
        let hashBytes = try store.db.read { db in
            try Data.fetchOne(
                db, sql: "SELECT hash FROM message WHERE subject = ?", arguments: [subject]
            )
        }!
        let hash = MessageHash(bytes: hashBytes)
        return try Data(
            contentsOf: store.directory.appendingPathComponent(ArchiveStore.relativePath(for: hash))
        )
    }

    private func storedDateReceived(subject: String) throws -> Date? {
        let text = try scalar(
            "SELECT dateReceived FROM message WHERE subject = ?", [subject]
        )
        guard let text else { return nil }
        return Timestamp.date(text)
    }

    private func mailboxesOf(subject: String) throws -> [String] {
        try store.db.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT mailbox.name FROM message_mailbox mm
                JOIN mailbox ON mailbox.id = mm.mailboxID
                JOIN message m ON m.id = mm.messageID
                WHERE m.subject = ? ORDER BY mailbox.name
                """,
                arguments: [subject]
            )
        }
    }

    private func labelsOf(subject: String) throws -> [String] {
        try store.db.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT label.name FROM message_label ml
                JOIN label ON label.id = ml.labelID
                JOIN message m ON m.id = ml.messageID
                WHERE m.subject = ? ORDER BY label.name
                """,
                arguments: [subject]
            )
        }
    }

    /// One mbox entry (mboxo unless the caller escapes body lines itself).
    private func mboxEntry(
        subject: String,
        sender: String = "alice@example.com",
        fromLine: String = "From alice@example.com Mon Mar  4 10:00:00 2024",
        body: String = "hello",
        headers: String = ""
    ) -> String {
        """
        \(fromLine)
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: \(subject)
        Message-ID: <\(subject)@example.com>
        Date: Mon, 04 Mar 2024 10:00:00 +0000
        \(headers)
        \(body)


        """
    }

    /// An .emlx payload: decimal length line, message bytes, plist trailer.
    private func emlx(_ message: String) -> String {
        "\(message.utf8.count)\n\(message)\n<plist junk/>"
    }

    private func assertArithmetic(_ report: ImportReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            report.messagesFound,
            report.imported + report.duplicates + report.failed,
            "report counts must add up", file: file, line: line
        )
    }

    private var importTime: Date { Timestamp.date("2024-06-01T12:00:00Z")! }

    // MARK: .eml folder tree

    func testEMLFolderImportsRecursivelyAndDerivesMailboxes() throws {
        try write(eml(subject: "Root"), to: tempDir.appendingPathComponent("root.eml"))
        try write(
            eml(subject: "Archived"),
            to: tempDir.appendingPathComponent("Archive/2024/old.eml")
        )
        try write(eml(subject: "SentOne"), to: tempDir.appendingPathComponent("Sent/s.eml"))
        try write("not mail", to: tempDir.appendingPathComponent("notes.txt"))

        let report = try MailImporter.import(
            store, from: tempDir, now: importTime
        )

        XCTAssertEqual(report.format, .emlFolder)
        XCTAssertEqual(report.filesSeen, 3)
        XCTAssertEqual(report.messagesFound, 3)
        XCTAssertEqual(report.imported, 3)
        XCTAssertEqual(report.failed, 0)
        assertArithmetic(report)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM message"), 3)
        XCTAssertEqual(try mailboxesOf(subject: "Archived"), ["Archive/2024"])
        XCTAssertEqual(try mailboxesOf(subject: "SentOne"), ["Sent"])
        XCTAssertEqual(try mailboxesOf(subject: "Root"), ["Imported"])
        XCTAssertEqual(try scalar("SELECT importSource FROM message WHERE subject = 'Archived'"), "eml")
        // Import time is the arrival date for folder imports.
        XCTAssertEqual(
            try storedDateReceived(subject: "Archived"), importTime
        )
    }

    func testEMLFolderMailboxOverride() throws {
        try write(eml(subject: "One"), to: tempDir.appendingPathComponent("a.eml"))
        try write(eml(subject: "Two"), to: tempDir.appendingPathComponent("sub/b.eml"))

        let report = try MailImporter.import(
            store, from: tempDir, mailbox: "Everything", now: importTime
        )

        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(try mailboxesOf(subject: "One"), ["Everything"])
        XCTAssertEqual(try mailboxesOf(subject: "Two"), ["Everything"])
    }

    func testEMLFolderContinuesPastUnreadableFile() throws {
        try write(eml(subject: "Good"), to: tempDir.appendingPathComponent("good.eml"))
        // A directory named like a message. Even a privileged process (CI
        // containers run as root, which bypasses permission bits) cannot
        // read it as a file, so the import must fail that entry and continue.
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Broken.eml"), withIntermediateDirectories: false
        )

        let report = try MailImporter.import(store, from: tempDir, now: importTime)

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.failedFiles, ["Broken.eml"])
        assertArithmetic(report)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM message"), 1)
    }

    func testEMLReimportIsIdempotent() throws {
        try write(eml(subject: "One"), to: tempDir.appendingPathComponent("a.eml"))
        try write(eml(subject: "Two"), to: tempDir.appendingPathComponent("sub/b.eml"))

        let first = try MailImporter.import(store, from: tempDir, now: importTime)
        XCTAssertEqual(first.imported, 2)

        let second = try MailImporter.import(store, from: tempDir, now: importTime)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.duplicates, 2)
        assertArithmetic(second)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM message"), 2)
        // No duplicate memberships either.
        XCTAssertEqual(try count("SELECT COUNT(*) FROM message_mailbox"), 2)
    }

    func testSingleEMLFile() throws {
        let file = tempDir.appendingPathComponent("standalone.eml")
        try eml(subject: "Solo").write(to: file)

        let report = try MailImporter.import(store, from: file, now: importTime)

        XCTAssertEqual(report.format, .emlFolder)
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(try mailboxesOf(subject: "Solo"), ["Imported"])
    }

    // Regression: imported mail must be searchable by words in its body.
    // ingestOne used to leave `searchText` nil, so bodies were never indexed
    // and a two-word body query found nothing on imported mail.
    func testImportIndexesBodyForSearch() throws {
        let file = tempDir.appendingPathComponent("bodysearch.eml")
        try eml(
            subject: "Quarterly budget",
            body: "The xylophone repair invoice is inside the broomstick folder."
        ).write(to: file)

        _ = try MailImporter.import(store, from: file, now: importTime)
        let expected = try rowIDOf(subject: "Quarterly budget")

        let results = try store.search("xylophone broomstick")
        XCTAssertEqual(
            results.hits.map(\.messageID),
            [expected],
            "a body-word query must find imported mail"
        )
    }

    /// The message row's id for a subject, failing the test when absent.
    private func rowIDOf(subject: String) throws -> Int64 {
        try store.db.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM message WHERE subject = ?", arguments: [subject]
            ) ?? -1
        }
    }

    // MARK: mbox

    func testMboxImportKeepsSourceBytesAndUsesEnvelopeDate() throws {
        var entry = mboxEntry(subject: "First")
        // Precisely control the bytes: strip the trailing blank line, add it back.
        entry = "From alice@example.com Mon Mar  4 10:00:00 2024\n"
        entry += "From: Alice <alice@example.com>\nSubject: First\nMessage-ID: <first@example.com>\n"
        entry += "Date: Mon, 04 Mar 2024 10:00:00 +0000\n\nhello\n"
        let second = mboxEntry(subject: "Second", sender: "bob@example.org",
                               fromLine: "From bob@example.org Tue Mar  5 11:00:00 2024")
        let file = tempDir.appendingPathComponent("Inbox.mbox")
        try write(entry + second, to: file)

        let report = try MailImporter.import(store, from: file, now: importTime)

        XCTAssertEqual(report.format, .mbox)
        XCTAssertEqual(report.messagesFound, 2)
        XCTAssertEqual(report.imported, 2)
        assertArithmetic(report)
        // Stored bytes equal exactly what the file attests (no From_ line).
        let expected = entry.split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst().joined(separator: "\n")
        XCTAssertEqual(try storedBytes(subject: "First"), Data(expected.utf8))
        // The envelope date is the arrival date.
        XCTAssertEqual(
            try storedDateReceived(subject: "First"),
            Timestamp.date("2024-03-04T10:00:00Z")
        )
        XCTAssertEqual(
            try storedDateReceived(subject: "Second"),
            Timestamp.date("2024-03-05T11:00:00Z")
        )
        // Mailbox name comes from the file name.
        XCTAssertEqual(try mailboxesOf(subject: "First"), ["Inbox"])
        XCTAssertEqual(try scalar("SELECT importSource FROM message WHERE subject = 'First'"), "mbox")
    }

    func testMboxRdUnquotesStoredBytesButMboxoKeepsThem() throws {
        let mboxrd = mboxEntry(subject: "Rd", body: "one line\n>From the archives\nlast line")
        let mboxo = mboxEntry(subject: "Oo", body: "one line\n>From the archives\nlast line")
        let rdFile = tempDir.appendingPathComponent("rd.mbox")
        let ooFile = tempDir.appendingPathComponent("oo.mbox")
        try write(mboxrd, to: rdFile)
        try write(mboxo, to: ooFile)

        let rdReport = try MailImporter.import(store, from: rdFile, now: importTime)
        // Content detection cannot tell mboxo from mboxrd here - both files
        // carry ">From " - so the mboxo file pins its variant explicitly.
        let ooReport = try MailImporter.import(
            store, from: ooFile, mboxVariant: .mboxo, now: importTime
        )

        XCTAssertEqual(rdReport.imported, 1)
        XCTAssertEqual(ooReport.imported, 1)
        // mboxrd: quoting undone, the body's "From " line is real text again.
        let rdStored = try String(decoding: storedBytes(subject: "Rd"), as: UTF8.self)
        XCTAssertTrue(rdStored.contains("\nFrom the archives\n"), rdStored)
        XCTAssertFalse(rdStored.contains(">From"), rdStored)
        // mboxo: bytes stay as the file attests them.
        let ooStored = try String(decoding: storedBytes(subject: "Oo"), as: UTF8.self)
        XCTAssertTrue(ooStored.contains("\n>From the archives\n"), ooStored)
    }

    func testMboxoSplitsOnBareFromInBody() throws {
        // Classic mboxo behavior: an unescaped body line starting "From <token>"
        // is a boundary. The file attests two messages, so two are stored.
        let data = mboxEntry(subject: "Before") + "From the desk of nobody\nplain text\n"
        let file = tempDir.appendingPathComponent("split.mbox")
        try write(data, to: file)

        let report = try MailImporter.import(store, from: file, now: importTime)

        XCTAssertEqual(report.messagesFound, 2)
        XCTAssertEqual(report.imported, 2)
        assertArithmetic(report)
    }

    func testMboxcl2TrustsContentLength() throws {
        let body = "line one\nFrom the desk of nobody\nline three"
        // Content-Length covers the body plus its final newline and the blank
        // separator line before the next From_ line.
        let contentLength = body.utf8.count + 2  // + the blank line's \n
        let entry = mboxEntry(
            subject: "Cl2", body: body,
            headers: "Content-Length: \(contentLength)\n"
        )
        let file = tempDir.appendingPathComponent("cl2.mbox")
        try write(entry, to: file)

        let report = try MailImporter.import(store, from: file, now: importTime)

        XCTAssertEqual(report.messagesFound, 1, "Content-Length keeps the From-line inside the body")
        XCTAssertEqual(report.imported, 1)
        let stored = try String(decoding: storedBytes(subject: "Cl2"), as: UTF8.self)
        XCTAssertTrue(stored.contains("\nFrom the desk of nobody\n"), stored)
        XCTAssertTrue(stored.contains("Content-Length: \(contentLength)"))
    }

    func testMboxSkipsLeadingGarbage() throws {
        let data = "random junk before the first message\n\n" + mboxEntry(subject: "Real")
        let file = tempDir.appendingPathComponent("junk.mbox")
        try write(data, to: file)

        let report = try MailImporter.import(store, from: file, now: importTime)

        XCTAssertEqual(report.messagesFound, 1)
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(
            report.skippedLeadingBytes,
            "random junk before the first message\n\n".utf8.count
        )
    }

    func testMboxEmptyFileImportsNothing() throws {
        let file = tempDir.appendingPathComponent("empty.mbox")
        try write("", to: file)

        let report = try MailImporter.import(store, from: file, now: importTime)

        XCTAssertEqual(report.messagesFound, 0)
        XCTAssertEqual(report.imported, 0)
        assertArithmetic(report)
    }

    func testMboxRoundTripExportIsByteIdentical() throws {
        // An mboxrd file: ">From " in the body, double-space asctime day.
        let original =
            "From alice@example.com Mon Mar  4 10:00:00 2024\n"
            + "From: Alice <alice@example.com>\nSubject: Trip\nMessage-ID: <trip@example.com>\n"
            + "Date: Mon, 04 Mar 2024 10:00:00 +0000\n\n"
            + "one\n>From the archives\n>From two levels\nplain\n\n"
        let file = tempDir.appendingPathComponent("trip.mbox")
        try write(original, to: file)

        _ = try MailImporter.import(store, from: file, now: importTime)

        // Export: the stored bytes, requoted, behind a regenerated From_ line.
        let stored = try storedBytes(subject: "Trip")
        let fromLine = String(
            decoding: MboxFormat.fromLine(sender: "alice@example.com",
                                          date: Timestamp.date("2024-03-04T10:00:00Z")!),
            as: UTF8.self
        )
        let exported = fromLine + String(
            decoding: MboxFormat.quoteBodyForExport(stored), as: UTF8.self
        )
        XCTAssertEqual(exported, original, "mboxrd import → export must reproduce the file")
    }

    func testMboxExportQuotesBareFromLines() throws {
        // A message whose body has a bare "From " line (as stored from an
        // mboxrd import of ">From " must come back escaped).
        let data = "From alice@example.com Mon Mar  4 10:00:00 2024\n"
            + "From: Alice <alice@example.com>\nSubject: Q\nMessage-ID: <q@example.com>\n\n"
            + ">From the archive\n\n"
        let file = tempDir.appendingPathComponent("q.mbox")
        try write(data, to: file)
        _ = try MailImporter.import(store, from: file, now: importTime)
        let report = try MailImporter.import(store, from: file, now: importTime)

        let stored = try storedBytes(subject: "Q")
        let quoted = String(decoding: MboxFormat.quoteBodyForExport(stored), as: UTF8.self)
        XCTAssertTrue(quoted.contains("\n>From the archive\n"), quoted)
        // Re-splitting the export must yield exactly one message. An export
        // is the envelope From_ line plus the quoted message (same shape the
        // round-trip test above checks).
        let fromLine = String(
            decoding: MboxFormat.fromLine(sender: "alice@example.com",
                                          date: Timestamp.date("2024-03-04T10:00:00Z")!),
            as: UTF8.self
        )
        var splitter = MboxSplitter(data: Data((fromLine + quoted).utf8))
        var found = 0
        while splitter.next() != nil { found += 1 }
        XCTAssertEqual(found, 1)
    }

    func testSniffedExtensionlessMbox() throws {
        let file = tempDir.appendingPathComponent("mailbox-archive")
        try write(mboxEntry(subject: "Sniffed"), to: file)

        let report = try MailImporter.import(store, from: file, now: importTime)

        XCTAssertEqual(report.format, .mbox)
        XCTAssertEqual(report.imported, 1)
    }

    func testUnrecognizedFileThrows() throws {
        let file = tempDir.appendingPathComponent("notes.txt")
        try write("not mail", to: file)

        XCTAssertThrowsError(try MailImporter.import(store, from: file, now: importTime)) { error in
            guard case ImportError.unrecognized = error else {
                return XCTFail("expected unrecognized, got \(error)")
            }
        }
    }

    func testMissingSourceThrows() throws {
        XCTAssertThrowsError(
            try MailImporter.import(store, from: tempDir.appendingPathComponent("nope"), now: importTime)
        ) { error in
            guard case ImportError.sourceNotFound = error else {
                return XCTFail("expected sourceNotFound, got \(error)")
            }
        }
    }

    // MARK: Apple Mail

    func testAppleMailPackageImportsEmlxAndSkipsPartial() throws {
        let package = tempDir.appendingPathComponent("Archive.mbox/Messages")
        try write(
            emlx(String(decoding: eml(subject: "EmlxOne"), as: UTF8.self)),
            to: package.appendingPathComponent("1.emlx")
        )
        try write(
            emlx(String(decoding: eml(subject: "EmlxTwo", body: "second"), as: UTF8.self)),
            to: package.appendingPathComponent("2.emlx")
        )
        try write(
            emlx(String(decoding: eml(subject: "Partial", body: "truncated"), as: UTF8.self)),
            to: package.appendingPathComponent("3.partial.emlx")
        )

        let report = try MailImporter.import(
            store, from: tempDir.appendingPathComponent("Archive.mbox"), now: importTime
        )

        XCTAssertEqual(report.format, .appleMail)
        XCTAssertEqual(report.filesSeen, 2)
        XCTAssertEqual(report.messagesFound, 2)
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(report.skippedLeadingBytes, 1, "one .partial.emlx skipped")
        assertArithmetic(report)
        XCTAssertEqual(try mailboxesOf(subject: "EmlxOne"), ["Archive"])
        // Stored bytes are the message section only — no plist trailer, and
        // the section ends with a proper line terminator. (Byte check: Swift's
        // grapheme clustering makes "\r\n".hasSuffix("\n") false.)
        let stored = try storedBytes(subject: "EmlxOne")
        XCTAssertFalse(stored.contains(Data("plist".utf8)), String(decoding: stored, as: UTF8.self))
        XCTAssertEqual(stored.last, UInt8(0x0A), "message section ends with a newline")
        XCTAssertEqual(try scalar("SELECT importSource FROM message WHERE subject = 'EmlxOne'"), "apple-mail")
    }

    func testAppleMailLegacyPackageImportsBareMbox() throws {
        let legacy = tempDir.appendingPathComponent("Old.mbox/mbox")
        try write(mboxEntry(subject: "Legacy"), to: legacy)

        let report = try MailImporter.import(
            store, from: tempDir.appendingPathComponent("Old.mbox"), now: importTime
        )

        XCTAssertEqual(report.format, .appleMail)
        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(try mailboxesOf(subject: "Legacy"), ["Old"])
        XCTAssertEqual(
            try scalar("SELECT importSource FROM message WHERE subject = 'Legacy'"), "apple-mail"
        )
    }

    func testAppleMailFolderOfPackagesDerivesNestedMailboxes() throws {
        try write(
            emlx(String(decoding: eml(subject: "InInbox"), as: UTF8.self)),
            to: tempDir.appendingPathComponent("Work/Inbox.mbox/Messages/1.emlx")
        )
        try write(
            emlx(String(decoding: eml(subject: "InArchive"), as: UTF8.self)),
            to: tempDir.appendingPathComponent("Work/Archive.mbox/Messages/1.emlx")
        )

        // Two packages nested in a folder: importing the folder finds both,
        // and each package's mailbox is its path relative to the folder.
        let report = try MailImporter.import(store, from: tempDir, now: importTime)

        XCTAssertEqual(report.format, .appleMail)
        XCTAssertEqual(report.imported, 2)
        XCTAssertEqual(try mailboxesOf(subject: "InInbox"), ["Work/Inbox"])
        XCTAssertEqual(try mailboxesOf(subject: "InArchive"), ["Work/Archive"])
    }

    func testEmlxLengthLineParses() throws {
        let message = "Subject: x\n\nbody"
        let payload = emlx(message)
        let parsed = try MailImporter.EmlxFile.messageBytes(Data(payload.utf8))
        XCTAssertEqual(String(decoding: parsed, as: UTF8.self), message)

        XCTAssertThrowsError(try MailImporter.EmlxFile.messageBytes(Data("no digits here".utf8)))
        XCTAssertThrowsError(try MailImporter.EmlxFile.messageBytes(Data("999\nshort".utf8)))
        XCTAssertThrowsError(try MailImporter.EmlxFile.messageBytes(Data("".utf8)))
    }

    func testAppleMailCorruptEmlxIsolatesFailure() throws {
        try write(
            emlx(String(decoding: eml(subject: "Fine"), as: UTF8.self)),
            to: tempDir.appendingPathComponent("P.mbox/Messages/1.emlx")
        )
        try write(
            "not-a-length-line\n", to: tempDir.appendingPathComponent("P.mbox/Messages/2.emlx")
        )

        let report = try MailImporter.import(
            store, from: tempDir.appendingPathComponent("P.mbox"), now: importTime
        )

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.failedFiles, ["Messages/2.emlx"])
        assertArithmetic(report)
    }

    // MARK: Google Takeout

    func testTakeoutImportsLabelsAndThreadIDs() throws {
        let first =
            "From alice@example.com Mon Mar  4 10:00:00 2024\n"
            + "From: Alice <alice@example.com>\nSubject: Labeled\nMessage-ID: <l@example.com>\n"
            + "X-Gmail-Labels: ^uds,^i,^u,Important,Receipts,141b401f6db38f37\r\n"
            + "X-GM-THRID: 1712345678901234\n"
            + "Date: Mon, 04 Mar 2024 10:00:00 +0000\n\nbody one\n\n"
        let second =
            "From bob@example.org Tue Mar  5 11:00:00 2024\n"
            + "From: Bob <bob@example.org>\nSubject: Other\nMessage-ID: <o@example.org>\n"
            + "Date: Mon, 05 Mar 2024 11:00:00 +0000\n\nbody two\n\n"
        let mboxFile = tempDir.appendingPathComponent("Takeout/Mail/All mail Including Spam and Trash.mbox")
        try write(first + second, to: mboxFile)

        let report = try MailImporter.import(store, from: tempDir, now: importTime)

        XCTAssertEqual(report.format, .googleTakeout)
        XCTAssertEqual(report.imported, 2)
        assertArithmetic(report)
        XCTAssertEqual(
            try scalar("SELECT importSource FROM message WHERE subject = 'Labeled'"), "takeout"
        )
        // Human labels survive; separator markers and hex digests do not.
        XCTAssertEqual(Set(try labelsOf(subject: "Labeled")), ["Important", "Receipts"])
        XCTAssertEqual(try labelsOf(subject: "Other"), [])
        XCTAssertEqual(
            try scalar("SELECT providerThreadID FROM message WHERE subject = 'Labeled'"),
            "1712345678901234"
        )
        // Mailbox falls back to the mbox file name.
        XCTAssertEqual(try mailboxesOf(subject: "Labeled"), ["All mail Including Spam and Trash"])
    }

    func testTakeoutWithEmptyMailDirectoryThrows() throws {
        try write("placeholder", to: tempDir.appendingPathComponent("Takeout/Mail/.keep"))

        XCTAssertThrowsError(try MailImporter.import(store, from: tempDir, now: importTime)) { error in
            guard case ImportError.unrecognized = error else {
                return XCTFail("expected unrecognized, got \(error)")
            }
        }
    }

    // MARK: Cross-format behavior

    func testSameBytesAcrossFormatsDeduplicate() throws {
        let messageBytes = eml(subject: "Shared")
        let emlFile = tempDir.appendingPathComponent("A/first.eml")
        try write(String(decoding: messageBytes, as: UTF8.self), to: emlFile)
        let first = try MailImporter.import(store, from: tempDir.appendingPathComponent("A"), now: importTime)
        XCTAssertEqual(first.imported, 1)

        // The identical bytes in an mbox land as a duplicate, but the new
        // mailbox membership is still recorded. No trailing separator: the
        // stored bytes must match the .eml import byte for byte.
        let mboxData =
            "From alice@example.com Mon Mar  4 10:00:00 2024\n"
            + String(decoding: messageBytes, as: UTF8.self)
        let mboxFile = tempDir.appendingPathComponent("B/Shared.mbox")
        try write(mboxData, to: mboxFile)
        let second = try MailImporter.import(store, from: mboxFile, now: importTime)

        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.duplicates, 1)
        assertArithmetic(second)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM message"), 1)
        // first.eml sits at the root of the import folder, so its mailbox is
        // the "no directory" fallback, like every root-level .eml.
        XCTAssertEqual(
            Set(try mailboxesOf(subject: "Shared")), ["Imported", "Shared"]
        )
    }
}
