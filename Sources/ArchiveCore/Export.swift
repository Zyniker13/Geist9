// Export (DESIGN 9, decision 0016): the stored bytes are the export unit.
// An .eml tree copies every message's stored bytes verbatim under folders
// that mirror its mailbox path; an mbox file writes a From_ envelope line
// plus the RFC 4155 quoting of decision 0015, so re-import reproduces the
// stored bytes exactly. Export never touches the archive.

import Foundation
import GRDB

/// One message selected for export, as the index reports it. `mailboxPath`
/// is the full mailbox name ("/"-separated hierarchy); nil means the
/// destination root.
public struct ExportMessage: Sendable, Equatable {
    public var hash: MessageHash
    public var mailboxPath: String?
    public var subject: String?
    public var fromEmail: String?
    public var dateSent: Date?
    public var dateReceived: Date?

    public init(
        hash: MessageHash, mailboxPath: String? = nil, subject: String? = nil,
        fromEmail: String? = nil, dateSent: Date? = nil, dateReceived: Date? = nil
    ) {
        self.hash = hash
        self.mailboxPath = mailboxPath
        self.subject = subject
        self.fromEmail = fromEmail
        self.dateSent = dateSent
        self.dateReceived = dateReceived
    }
}

public struct ExportReport: Sendable, Equatable {
    /// Destinations written, relative to the export root: file paths for
    /// .eml trees, the destination's name for mbox.
    public var filesWritten: [String] = []
    public var messagesExported: Int = 0
    public var bytesWritten: Int = 0
    public var duration: TimeInterval = 0

    public init() {}
}

public enum ExportError: Error, Equatable, Sendable {
    /// The destination exists and is not empty; exporting would mix with
    /// someone else's files, so it is refused.
    case destinationNotEmpty(String)
    /// A message whose index row was handed to export is not in the store.
    case messageMissing(MessageHash)
}

public enum MailExporter {
    /// Exports messages as an `.eml` tree: one file per message, named
    /// `<hash12>-<subject>.eml`, under folders mirroring the mailbox path
    /// (components split on "/" only, so `MailImporter.importEMLFolder`
    /// maps the tree back to the same mailbox names). Refuses a
    /// non-empty destination.
    public static func exportEMLTree(
        from store: ArchiveStore, messages: [ExportMessage], to root: URL
    ) throws -> ExportReport {
        let fm = FileManager.default
        let root = URL.resolved(root)
        if fm.fileExists(atPath: root.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            if !contents.isEmpty { throw ExportError.destinationNotEmpty(root.path) }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var report = ExportReport()
        let start = Date()
        for message in messages {
            let data = try store.messageData(message.hash)
            let folder = components(of: message.mailboxPath)
                .map { sanitizePathComponent($0) }
                .joined(separator: "/")
            let directory = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(message.hash.hex.prefix(12))-\(sanitizePathComponent(message.subject ?? "No Subject")).eml"
            try AtomicWrite.write(data, to: directory.appendingPathComponent(name))
            report.filesWritten.append(folder.isEmpty ? name : "\(folder)/\(name)")
            report.messagesExported += 1
            report.bytesWritten += data.count
        }
        report.duration = Date().timeIntervalSince(start)
        return report
    }

    /// Exports messages as one mbox file: a From_ envelope line plus the
    /// RFC 4155 quoting of decision 0015, concatenated back to back — the
    /// splitter recognizes a From_ at line start, so no filler belongs
    /// between messages (decision 0015: only the From_ line is framing).
    /// Refuses an existing destination. Streams message by message to a
    /// temp file and renames, so an interrupted export never keeps the
    /// destination's name.
    public static func exportMbox(
        from store: ArchiveStore, messages: [ExportMessage], to file: URL
    ) throws -> ExportReport {
        let file = URL.resolved(file)
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) {
            throw ExportError.destinationNotEmpty(file.path)
        }
        var report = ExportReport()
        let start = Date()
        let directory = file.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(
            ".\(file.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw ArchiveError.io(underlying: "cannot create \(temp.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: temp)
        do {
            for message in messages {
                let data = try store.messageData(message.hash)
                let envelope = MboxFormat.fromLine(
                    sender: message.fromEmail ?? "MAILER-DAEMON",
                    date: message.dateSent ?? message.dateReceived ?? Date(timeIntervalSince1970: 0)
                )
                var quoted = [UInt8](MboxFormat.quoteBodyForExport(data))
                // The mbox frame requires every message to end on a line
                // boundary. A stored message without a final newline (the
                // rare exception, documented in decision 0016) gains one
                // frame newline here; the splitter never counts it as
                // message content on re-import.
                if !MboxFormat.endsWithLineTerminator(quoted) {
                    quoted.append(0x0A)
                }
                try handle.write(contentsOf: Data(envelope))
                try handle.write(contentsOf: Data(quoted))
                report.messagesExported += 1
                report.bytesWritten += envelope.count + quoted.count
            }
            try handle.close()
            try AtomicWrite.finalize(temp: temp, to: file)
        } catch {
            try? handle.close()
            try? fm.removeItem(at: temp)
            throw error
        }
        report.filesWritten = [file.lastPathComponent]
        report.duration = Date().timeIntervalSince(start)
        return report
    }

    /// Exports as an Apple Mail `.mbox` package: a `<name>.mbox` directory
    /// holding a bare legacy `mbox` file (the same code path as
    /// `exportMbox`). No `table_of_contents` is written: it is a private
    /// index Apple Mail rebuilds itself, and the importer does not require
    /// it. Refuses an existing package directory.
    public static func exportAppleMailPackage(
        from store: ArchiveStore, messages: [ExportMessage], name: String, to directory: URL
    ) throws -> ExportReport {
        let directory = URL.resolved(directory)
        let package = directory.appendingPathComponent("\(sanitizePathComponent(name)).mbox")
        let fm = FileManager.default
        if fm.fileExists(atPath: package.path) {
            throw ExportError.destinationNotEmpty(package.path)
        }
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        do {
            return try exportMbox(from: store, messages: messages, to: package.appendingPathComponent("mbox"))
        } catch {
            try? fm.removeItem(at: package)
            throw error
        }
    }

    /// A path component safe for every filesystem: "/", NUL, control and
    /// DEL bytes become "-", whitespace runs collapse, the result is
    /// capped at 64 scalars and never ends in a dot or space.
    static func sanitizePathComponent(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if out.count >= 64 { break }
            switch scalar.value {
            case 0x2F, 0x00, 0x01...0x1F, 0x7F:
                out.append("-")
            case 0x20:
                if out.last != " " { out.append(scalar) }
            default:
                out.append(scalar)
            }
        }
        var text = String(String.UnicodeScalarView(out))
            .trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") || text.hasSuffix(" ") { text.removeLast() }
        return text.isEmpty ? "No Subject" : text
    }

    /// "/"-separated path components of a mailbox name, empty for nil.
    static func components(of mailboxPath: String?) -> [String] {
        guard let mailboxPath, !mailboxPath.isEmpty else { return [] }
        return mailboxPath.split(separator: "/").map(String.init)
    }
}

extension ExportMessage: FetchableRecord {
    public init(row: Row) throws {
        self.init(
            hash: MessageHash(bytes: row["hash"] as Data),
            mailboxPath: row["mailboxPath"],
            subject: row["subject"],
            fromEmail: row["fromEmail"],
            dateSent: (row["dateSent"] as String?).flatMap(Timestamp.date),
            dateReceived: (row["dateReceived"] as String?).flatMap(Timestamp.date)
        )
    }
}

public extension ArchiveStore {
    /// Export rows for one mailbox (every account sharing the name), or
    /// for the whole archive when `mailbox` is nil — deduplicated by hash
    /// (the first membership in id order wins), in stable message order.
    func exportMessages(mailbox: String?) throws -> [ExportMessage] {
        try db.read { db in
            if let mailbox {
                return try ExportMessage.fetchAll(
                    db,
                    sql: """
                    SELECT m.hash, m.subject, m.fromEmail, m.dateSent, m.dateReceived,
                           mb.name AS mailboxPath
                    FROM message m
                    JOIN message_mailbox mm ON mm.messageID = m.id
                    JOIN mailbox mb ON mb.id = mm.mailboxID
                    WHERE mb.name = ?
                    ORDER BY mm.id
                    """,
                    arguments: [mailbox]
                )
            }
            return try ExportMessage.fetchAll(
                db,
                sql: """
                SELECT m.hash, m.subject, m.fromEmail, m.dateSent, m.dateReceived,
                       (SELECT mb.name FROM mailbox mb
                        JOIN message_mailbox mm2 ON mm2.mailboxID = mb.id
                        WHERE mm2.messageID = m.id ORDER BY mm2.id LIMIT 1) AS mailboxPath
                FROM message m
                ORDER BY m.id
                """
            )
        }
    }
}
