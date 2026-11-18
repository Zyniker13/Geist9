// Export tests (DESIGN 9, decision 0016): round trips are byte-identical —
// export writes the stored bytes (verbatim in .eml trees, RFC 4155-quoted
// behind a From_ envelope in mbox), and re-importing the export reproduces
// every stored byte.

import XCTest
import GRDB
@testable import ArchiveCore

final class ExportTests: XCTestCase {
    private var tempDir: URL!
    private var store: ArchiveStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-export-\(UUID().uuidString)")
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

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func eml(
        subject: String, body: String = "hello",
        date: String = "Mon, 04 Mar 2024 10:00:00 +0000", trailingNewline: Bool = true
    ) -> Data {
        // Built by concatenation, not a multiline literal: the exact final
        // bytes matter (a stored message may lack the final newline).
        var text = "From: Alice <alice@example.com>\r\n"
            + "To: Bob <bob@example.org>\r\n"
            + "Subject: \(subject)\r\n"
            + "Message-ID: <\(subject)@example.com>\r\n"
            + "Date: \(date)\r\n"
            + "\r\n"
            + body
        if trailingNewline { text += "\r\n" }
        return Data(text.utf8)
    }

    private func mboxEntry(
        subject: String, sender: String = "alice@example.com", body: String = "hello"
    ) -> String {
        """
        From \(sender) Mon Mar  4 10:00:00 2024
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: \(subject)
        Message-ID: <\(subject)@example.com>
        Date: Mon, 04 Mar 2024 10:00:00 +0000

        \(body)


        """
    }

    /// Every message's stored bytes in the store, keyed by hash hex.
    private func allStoredBytes(_ target: ArchiveStore) throws -> [String: Data] {
        let rows = try target.db.read { db in
            try Data.fetchAll(db, sql: "SELECT hash FROM message ORDER BY id")
        }
        var result: [String: Data] = [:]
        for hashBytes in rows {
            let hash = MessageHash(bytes: hashBytes)
            result[hash.hex] = try target.messageData(hash)
        }
        return result
    }

    private func mailboxes(_ target: ArchiveStore) throws -> Set<String> {
        try target.db.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM mailbox"))
        }
    }

    // MARK: .eml tree round trip

    func testEMLTreeRoundTripIsByteIdentical() throws {
        // Import a tree with nested mailboxes, then export and re-import.
        let source = tempDir.appendingPathComponent("source")
        try write(String(decoding: eml(subject: "first"), as: UTF8.self),
                  to: source.appendingPathComponent("Inbox/a.eml"))
        try write(String(decoding: eml(subject: "second", body: "deeper"), as: UTF8.self),
                  to: source.appendingPathComponent("Work/2024/b.eml"))
        try MailImporter.importEMLFolder(
            store, root: source,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )

        let exported = tempDir.appendingPathComponent("exported")
        let report = try MailExporter.exportEMLTree(
            from: store, messages: try store.exportMessages(mailbox: nil), to: exported
        )
        XCTAssertEqual(report.messagesExported, 2)
        XCTAssertEqual(report.filesWritten.count, 2)
        // Byte identity at the source: every exported file equals its
        // stored message exactly.
        for relative in report.filesWritten {
            let hash12 = String(relative.split(separator: "/").last!
                .split(separator: "-")[0])
            let hashHex = try XCTUnwrap(
                try store.exportMessages(mailbox: nil).first {
                    $0.hash.hex.hasPrefix(hash12)
                }?.hash.hex
            )
            let stored = try store.messageData(MessageHash(hex: hashHex)!)
            XCTAssertEqual(
                try Data(contentsOf: exported.appendingPathComponent(relative)),
                stored, "exported bytes differ for \(relative)"
            )
        }

        let second = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Second.emailarchive"), appVersion: "0.1.0"
        )
        defer { try? FileManager.default.removeItem(at: second.directory) }
        try MailImporter.importEMLFolder(
            second, root: exported,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )
        XCTAssertEqual(try allStoredBytes(second), try allStoredBytes(store))
        XCTAssertEqual(
            try mailboxes(second), Set(["Inbox", "Work/2024"]),
            "mailbox names must survive the tree round trip"
        )
    }

    // MARK: mbox round trip

    func testMboxRoundTripIsByteIdentical() throws {
        // Bodies exercise both mboxrd directions: ">From quoted" unquotes on
        // import and must re-quote on export; ">>From deep" loses and
        // regains exactly one ">".
        let source = tempDir.appendingPathComponent("source.mbox")
        try write(
            mboxEntry(subject: "one")
                + mboxEntry(subject: "quoted", body: ">From quoted at the start\nhi")
                + mboxEntry(subject: "deep", body: ">>From deep quoting\nhi"),
            to: source
        )
        try MailImporter.importMboxFile(
            store, file: source,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import"),
            variant: .mboxrd
        )

        let exported = tempDir.appendingPathComponent("exported.mbox")
        let report = try MailExporter.exportMbox(
            from: store, messages: try store.exportMessages(mailbox: nil), to: exported
        )
        XCTAssertEqual(report.messagesExported, 3)
        // The envelope sender comes from the index's From address.
        let exportedText = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(exportedText.hasPrefix("From alice@example.com "))

        let second = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Second.emailarchive"), appVersion: "0.1.0"
        )
        defer { try? FileManager.default.removeItem(at: second.directory) }
        try MailImporter.importMboxFile(
            second, file: exported,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import"),
            variant: .mboxrd
        )
        XCTAssertEqual(try allStoredBytes(second), try allStoredBytes(store))
    }

    // MARK: The frame newline exception

    func testMboxExportAddsFrameNewlineWhenStoredBytesLackOne() throws {
        let source = tempDir.appendingPathComponent("NoNewline")
        try write(String(decoding: eml(subject: "unterminated", trailingNewline: false), as: UTF8.self),
                  to: source.appendingPathComponent("a.eml"))
        try MailImporter.importEMLFolder(
            store, root: source,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )

        let exported = tempDir.appendingPathComponent("exported.mbox")
        _ = try MailExporter.exportMbox(
            from: store, messages: try store.exportMessages(mailbox: nil), to: exported
        )
        let second = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Second.emailarchive"), appVersion: "0.1.0"
        )
        defer { try? FileManager.default.removeItem(at: second.directory) }
        try MailImporter.importMboxFile(
            second, file: exported,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import"),
            variant: .mboxrd
        )

        let original = try allStoredBytes(store)
        let roundTripped = try allStoredBytes(second)
        XCTAssertEqual(roundTripped.count, 1)
        // Documented exception (decision 0016): a stored message not ending
        // on a line boundary gains one frame newline in mbox (its hash
        // therefore differs); .eml export is always byte-identical.
        XCTAssertEqual(roundTripped.values.first, original.values.first! + Data([0x0A]))
    }

    func testEMLTreeIsByteIdenticalEvenWithoutTrailingNewline() throws {
        let source = tempDir.appendingPathComponent("NoNewline")
        try write(String(decoding: eml(subject: "unterminated", trailingNewline: false), as: UTF8.self),
                  to: source.appendingPathComponent("a.eml"))
        try MailImporter.importEMLFolder(
            store, root: source,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )

        let exported = tempDir.appendingPathComponent("exported")
        _ = try MailExporter.exportEMLTree(
            from: store, messages: try store.exportMessages(mailbox: nil), to: exported
        )
        let second = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Second.emailarchive"), appVersion: "0.1.0"
        )
        defer { try? FileManager.default.removeItem(at: second.directory) }
        try MailImporter.importEMLFolder(
            second, root: exported,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )
        XCTAssertEqual(try allStoredBytes(second), try allStoredBytes(store))
    }

    // MARK: Selection, dedup, order

    func testExportAllDeduplicatesAcrossMailboxes() throws {
        let source = tempDir.appendingPathComponent("source")
        // The same Message-ID in two folders: content addressing keeps one
        // message with two memberships.
        for folder in ["Alpha", "Beta"] {
            try write(String(decoding: eml(subject: "shared"), as: UTF8.self),
                      to: source.appendingPathComponent("\(folder)/m.eml"))
        }
        try MailImporter.importEMLFolder(
            store, root: source,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )

        let rows = try store.exportMessages(mailbox: nil)
        XCTAssertEqual(rows.count, 1, "one message, two memberships")
        XCTAssertEqual(rows[0].mailboxPath, "Alpha")
        _ = try MailExporter.exportEMLTree(from: store, messages: rows, to: tempDir.appendingPathComponent("tree"))
    }

    func testExportMailboxSelectsOnlyThatMailbox() throws {
        let source = tempDir.appendingPathComponent("source")
        for (folder, subject) in [("Alpha", "in-alpha"), ("Beta", "in-beta")] {
            try write(String(decoding: eml(subject: subject), as: UTF8.self),
                      to: source.appendingPathComponent("\(folder)/m.eml"))
        }
        try MailImporter.importEMLFolder(
            store, root: source,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )

        let exported = tempDir.appendingPathComponent("alpha-only")
        let report = try MailExporter.exportEMLTree(
            from: store, messages: try store.exportMessages(mailbox: "Alpha"), to: exported
        )
        XCTAssertEqual(report.messagesExported, 1)
        XCTAssertEqual(report.filesWritten.count, 1)
        XCTAssertEqual(report.filesWritten[0].split(separator: "/").first, "Alpha")
        // The tree mirrors the mailbox: "Alpha/<hash12>-in-alpha.eml".
        XCTAssertTrue(report.filesWritten[0].hasSuffix("in-alpha.eml"))
    }

    // MARK: Refusals

    func testExportRefusesNonEmptyTreeRoot() throws {
        let root = tempDir.appendingPathComponent("occupied")
        try write("keep out", to: root.appendingPathComponent("other.txt"))
        XCTAssertThrowsError(
            try MailExporter.exportEMLTree(
                from: store, messages: try store.exportMessages(mailbox: nil), to: root
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportError, .destinationNotEmpty(URL.resolved(root).path)
            )
        }
    }

    func testExportMboxRefusesExistingFile() throws {
        let file = tempDir.appendingPathComponent("taken.mbox")
        try write("keep out", to: file)
        XCTAssertThrowsError(
            try MailExporter.exportMbox(
                from: store, messages: try store.exportMessages(mailbox: nil), to: file
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .destinationNotEmpty(URL.resolved(file).path))
        }
    }

    func testExportOfEmptySelectionWritesNothing() throws {
        let report = try MailExporter.exportEMLTree(
            from: store, messages: [], to: tempDir.appendingPathComponent("empty")
        )
        XCTAssertEqual(report.messagesExported, 0)
        XCTAssertEqual(report.filesWritten, [])
        let reportMbox = try MailExporter.exportMbox(
            from: store, messages: [], to: tempDir.appendingPathComponent("empty.mbox")
        )
        XCTAssertEqual(reportMbox.messagesExported, 0)
    }

    // MARK: Apple Mail package export

    func testAppleMailPackageRoundTripIsByteIdentical() throws {
        let source = tempDir.appendingPathComponent("source.mbox")
        try write(
            mboxEntry(subject: "one")
                + mboxEntry(subject: "quoted", body: ">From quoted at the start\nhi"),
            to: source
        )
        try MailImporter.importMboxFile(
            store, file: source,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import"),
            variant: .mboxrd
        )

        let packages = tempDir.appendingPathComponent("packages")
        _ = try MailExporter.exportAppleMailPackage(
            from: store, messages: try store.exportMessages(mailbox: nil), name: "Keep", to: packages
        )
        let package = packages.appendingPathComponent("Keep.mbox")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("mbox").path))

        let second = try ArchiveStore.create(
            at: tempDir.appendingPathComponent("Second.emailarchive"), appVersion: "0.1.0"
        )
        defer { try? FileManager.default.removeItem(at: second.directory) }
        try MailImporter.importAppleMail(
            second, package: package,
            account: AccountIdentity(email: "imported", displayName: "Imported mail", providerKind: "import")
        )
        XCTAssertEqual(try allStoredBytes(second), try allStoredBytes(store))
    }

    func testAppleMailPackageRefusesExistingDirectory() throws {
        let packages = tempDir.appendingPathComponent("packages")
        try write("keep out", to: packages.appendingPathComponent("Keep.mbox/mbox"))
        XCTAssertThrowsError(
            try MailExporter.exportAppleMailPackage(
                from: store, messages: try store.exportMessages(mailbox: nil), name: "Keep", to: packages
            )
        ) { error in
            XCTAssertEqual(
                error as? ExportError,
                .destinationNotEmpty(URL.resolved(packages.appendingPathComponent("Keep.mbox")).path)
            )
        }
    }

    // MARK: Naming

    func testSanitizePathComponent() {
        XCTAssertEqual(MailExporter.sanitizePathComponent("plain"), "plain")
        XCTAssertEqual(MailExporter.sanitizePathComponent("a/b/c"), "a-b-c")
        XCTAssertEqual(MailExporter.sanitizePathComponent("line\nbreak"), "line-break")
        XCTAssertEqual(MailExporter.sanitizePathComponent("two  spaces"), "two spaces")
        XCTAssertEqual(MailExporter.sanitizePathComponent("Report."), "Report")
        XCTAssertEqual(MailExporter.sanitizePathComponent("  "), "No Subject")
        XCTAssertEqual(MailExporter.sanitizePathComponent(""), "No Subject")
        XCTAssertEqual(MailExporter.sanitizePathComponent(String(repeating: "x", count: 100)).count, 64)
    }
}
