// Import (DESIGN 9): .eml folder trees, mbox files, Apple Mail exports and
// Google Takeout all land in the archive through MailBridge and the regular
// ingest path. Content addressing makes re-imports free: the same bytes are
// stored once and only new memberships appear. Every message ingests on its
// own; one bad source file never stops the rest of the import.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The import formats M1 supports (DESIGN 9).
public enum ImportFormat: String, Sendable, CaseIterable {
    case emlFolder = "eml"
    case mbox = "mbox"
    case appleMail = "apple-mail"
    case googleTakeout = "takeout"
}

/// What an import run did. `messagesFound` equals imported + duplicates +
/// failed for every format, so callers can assert nothing silently vanished.
public struct ImportReport: Sendable, Equatable {
    public var format: ImportFormat
    /// Source files opened (mbox: one).
    public var filesSeen: Int
    /// Messages discovered in the source.
    public var messagesFound: Int
    /// Stored as new bytes (IngestResult.created).
    public var imported: Int
    /// Already present — content addressing found identical bytes.
    public var duplicates: Int
    /// Failed to read, parse or ingest; counted per message (per file for .eml).
    public var failed: Int
    /// Relative paths of files that failed, in source order.
    public var failedFiles: [String]
    /// mbox: bytes before the first From_ line. Apple Mail: .partial.emlx
    /// files skipped (they are truncated by definition).
    public var skippedLeadingBytes: Int
    public var duration: TimeInterval

    public init(
        format: ImportFormat,
        filesSeen: Int = 0,
        messagesFound: Int = 0,
        imported: Int = 0,
        duplicates: Int = 0,
        failed: Int = 0,
        failedFiles: [String] = [],
        skippedLeadingBytes: Int = 0,
        duration: TimeInterval = 0
    ) {
        self.format = format
        self.filesSeen = filesSeen
        self.messagesFound = messagesFound
        self.imported = imported
        self.duplicates = duplicates
        self.failed = failed
        self.failedFiles = failedFiles
        self.skippedLeadingBytes = skippedLeadingBytes
        self.duration = duration
    }
}

public enum ImportError: Error, Equatable, Sendable {
    case sourceNotFound(String)
    case unrecognized(String)
}

public enum MailImporter {
    /// Imports mail from `url`, detecting the format:
    ///
    /// - a directory containing `Takeout/Mail/*.mbox` → Google Takeout;
    /// - a directory whose name ends in `.mbox`, or that contains `.emlx`
    ///   files or nested `.mbox` packages → Apple Mail;
    /// - any other directory → `.eml` folder tree;
    /// - a `.mbox` file (or a file starting with "From ") → mbox;
    /// - a single `.eml` or `.emlx` file → a one-message import.
    ///
    /// `account` defaults to one pseudo-account shared by all imports;
    /// `mailbox` overrides the derived mailbox name for every message.
    /// `mboxVariant` pins the mbox flavor for mbox sources (see
    /// `MboxSplitter`); the default detects it from content.
    public static func `import`(
        _ store: ArchiveStore,
        from url: URL,
        account: AccountIdentity = AccountIdentity(
            email: "imported", displayName: "Imported mail", providerKind: "import"
        ),
        mailbox: String? = nil,
        mboxVariant: MboxVariant? = nil,
        now: Date = Date()
    ) throws -> ImportReport {
        // Resolve symlinks once at the entry point: on macOS /var is a
        // symlink to /private/var, and every relative-path derivation below
        // needs the file and its base to share the same real prefix.
        let url = URL.resolved(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.sourceNotFound(url.path)
        }
        return isDirectory.boolValue
            ? try importDirectory(store, from: url, account: account, mailbox: mailbox, now: now)
            : try importFile(
                store, from: url, account: account, mailbox: mailbox,
                mboxVariant: mboxVariant, now: now
            )
    }

    // MARK: - Directory routing

    static func importDirectory(
        _ store: ArchiveStore,
        from url: URL,
        account: AccountIdentity,
        mailbox: String?,
        now: Date
    ) throws -> ImportReport {
        let name = url.lastPathComponent

        // Google Takeout: Takeout/Mail/<name>.mbox files.
        let takeoutMail = url.appendingPathComponent("Takeout").appendingPathComponent("Mail")
        if FileManager.default.fileExists(atPath: takeoutMail.path) {
            let mboxes = ((try? FileManager.default.contentsOfDirectory(atPath: takeoutMail.path)) ?? [])
                .filter { $0.hasSuffix(".mbox") }
                .sorted()
            guard !mboxes.isEmpty else {
                throw ImportError.unrecognized("Takeout found but no .mbox under Takeout/Mail")
            }
            var report = ImportReport(format: .googleTakeout)
            let start = Date()
            for file in mboxes {
                let partial = try importMboxFile(
                    store, file: takeoutMail.appendingPathComponent(file),
                    account: account, mailbox: mailbox, importSource: "takeout", now: now
                )
                report = merging(report, with: partial)
            }
            report.duration = Date().timeIntervalSince(start)
            return report
        }

        // Apple Mail: a single .mbox package, or a folder holding several.
        if name.hasSuffix(".mbox") {
            return try importAppleMail(
                store, package: url, account: account, mailbox: mailbox, now: now
            )
        }
        let packages = appleMailPackages(in: url)
        if !packages.isEmpty {
            var report = ImportReport(format: .appleMail)
            let start = Date()
            for package in packages {
                let derived = mailboxName(for: package, relativeTo: url)
                let partial = try importAppleMail(
                    store, package: package, account: account,
                    mailbox: mailbox ?? derived, now: now
                )
                report = merging(report, with: partial)
            }
            report.duration = Date().timeIntervalSince(start)
            return report
        }

        // Otherwise: an .eml folder tree.
        return try importEMLFolder(store, root: url, account: account, mailbox: mailbox, now: now)
    }

    // MARK: - Single-file routing

    static func importFile(
        _ store: ArchiveStore,
        from url: URL,
        account: AccountIdentity,
        mailbox: String?,
        mboxVariant: MboxVariant?,
        now: Date
    ) throws -> ImportReport {
        let lowered = url.lastPathComponent.lowercased()
        if lowered.hasSuffix(".mbox") {
            return try importMboxFile(
                store, file: url, account: account, mailbox: mailbox,
                variant: mboxVariant, now: now
            )
        }
        if lowered.hasSuffix(".eml") {
            return try importSingleEML(store, file: url, account: account, mailbox: mailbox, now: now)
        }
        if lowered.hasSuffix(".emlx"), !lowered.hasSuffix(".partial.emlx") {
            return try importSingleEmlx(store, file: url, account: account, mailbox: mailbox, now: now)
        }
        // No usable extension: sniff the first bytes for an mbox From_ line.
        if let sniff = try? sniffMbox(url) {
            if sniff {
                return try importMboxFile(
                    store, file: url, account: account, mailbox: mailbox,
                    variant: mboxVariant, now: now
                )
            }
        }
        throw ImportError.unrecognized(url.lastPathComponent)
    }

    /// True when the file's first line starts with "From " (the mbox
    /// separator) or it starts directly with header text.
    static func sniffMbox(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return false }
        if data.first == UInt8(ascii: "F") {
            let prefix = data.prefix(5)
            return prefix.elementsEqual("From ".utf8, by: ==)
        }
        return false
    }

    // MARK: - .eml folder tree

    /// Imports every `.eml` file under `root`, recursively. Each file's parent
    /// path relative to the root becomes the mailbox (an .eml tree exported
    /// from another client mirrors its folder structure). Files directly in
    /// the root go to `mailbox` or the default "Imported" mailbox.
    public static func importEMLFolder(
        _ store: ArchiveStore,
        root: URL,
        account: AccountIdentity,
        mailbox: String? = nil,
        now: Date = Date()
    ) throws -> ImportReport {
        let root = URL.resolved(root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ImportError.sourceNotFound(root.path)
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
            throw ImportError.unrecognized("source is an archive, not mail to import")
        }

        let files = emlFiles(in: root)
        var report = ImportReport(format: .emlFolder, filesSeen: files.count)
        let start = Date()
        for file in files {
            report.messagesFound += 1
            do {
                let data = try Data(contentsOf: file)
                let relative = file.path(relativeTo: root)
                let derived = relative.split(separator: "/").dropLast().joined(separator: "/")
                let box = mailbox ?? (derived.isEmpty ? "Imported" : derived)
                let parsed = MailBridge.parse(for: data)
                let result = try ingestOne(
                    store, data: data, parsed: parsed, importSource: "eml",
                    account: account,
                    membership: Membership(mailbox: box, uid: nil, flags: [], dateReceived: now),
                    dateReceived: now, gmailMetadata: false, now: now
                )
                report.count(result: result)
            } catch {
                report.failed += 1
                report.failedFiles.append(relativeSafe(file, to: root))
            }
        }
        report.duration = Date().timeIntervalSince(start)
        // As-you-type vocabulary (decision 0025): refresh the first-letter
        // tables now that every row of this import is in the index.
        try store.refreshAsYouTypeVocabulary()
        return report
    }

    /// One standalone .eml file.
    static func importSingleEML(
        _ store: ArchiveStore,
        file url: URL,
        account: AccountIdentity,
        mailbox: String?,
        now: Date
    ) throws -> ImportReport {
        var report = ImportReport(format: .emlFolder, filesSeen: 1)
        let start = Date()
        report.messagesFound = 1
        do {
            let data = try Data(contentsOf: url)
            let box = mailbox ?? "Imported"
            let parsed = MailBridge.parse(for: data)
            let result = try ingestOne(
                store, data: data, parsed: parsed, importSource: "eml",
                account: account,
                membership: Membership(mailbox: box, uid: nil, flags: [], dateReceived: now),
                dateReceived: now, gmailMetadata: false, now: now
            )
            report.count(result: result)
        } catch {
            report.failed = 1
            report.failedFiles = [url.lastPathComponent]
        }
        report.duration = Date().timeIntervalSince(start)
        // As-you-type vocabulary (decision 0025): refresh the first-letter
        // tables now that every row of this import is in the index.
        try store.refreshAsYouTypeVocabulary()
        return report
    }

    // MARK: - mbox

    /// Imports one mbox file through the streaming splitter. Message bytes
    /// are ingested exactly as the file attests them (DESIGN 9 / decision
    /// 0015): the From_ separator is dropped and ">From " quoting is undone
    /// only for mboxrd/mboxcl2 sources. Gmail labels and thread ids are
    /// picked up from X-Gmail-Labels / X-GM-THRID when present, which also
    /// covers a Takeout mbox pointed at directly.
    /// - Parameters:
    ///   - variant: optional pin for the mbox flavor; see `MboxSplitter`.
    public static func importMboxFile(
        _ store: ArchiveStore,
        file url: URL,
        account: AccountIdentity,
        mailbox: String? = nil,
        importSource: String = "mbox",
        variant: MboxVariant? = nil,
        now: Date = Date()
    ) throws -> ImportReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.sourceNotFound(url.path)
        }

        let box = mailbox ?? url.deletingPathExtension().lastPathComponent
        var splitter: MboxSplitter
        do {
            splitter = try MboxSplitter(url: url, variant: variant)
        } catch {
            throw ImportError.sourceNotFound(url.path)
        }

        var report = ImportReport(format: .mbox, filesSeen: 1)
        let start = Date()
        while let message = splitter.next() {
            report.messagesFound += 1
            do {
                let data = Data(message.data)
                let parsed = MailBridge.parse(for: data)
                let arrival = message.envelopeDate ?? now
                let result = try ingestOne(
                    store, data: data, parsed: parsed, importSource: importSource,
                    account: account,
                    membership: Membership(mailbox: box, uid: nil, flags: [], dateReceived: arrival),
                    dateReceived: arrival, gmailMetadata: true, now: now
                )
                report.count(result: result)
            } catch {
                report.failed += 1
            }
        }
        // Read only after the loop: the splitter records the leading-garbage
        // span when it finds the first boundary, which happens inside next().
        report.skippedLeadingBytes = splitter.skippedLeadingBytes
        report.duration = Date().timeIntervalSince(start)
        // As-you-type vocabulary (decision 0025): refresh the first-letter
        // tables now that every row of this import is in the index. Kept
        // out of the reported duration, which measures message ingestion.
        try store.refreshAsYouTypeVocabulary()
        return report
    }

    // MARK: - Apple Mail

    /// Imports one Apple Mail `.mbox` package. Modern packages hold a
    /// `Messages/` folder of `.emlx` files; legacy packages hold a bare
    /// `mbox` file. Both are handled. `.partial.emlx` files are skipped:
    /// they are truncated by definition and ingesting them would store
    /// bytes their own name declares incomplete.
    public static func importAppleMail(
        _ store: ArchiveStore,
        package url: URL,
        account: AccountIdentity,
        mailbox: String? = nil,
        now: Date = Date()
    ) throws -> ImportReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.sourceNotFound(url.path)
        }
        let package = URL.resolved(url)

        let box = mailbox ?? appleMailboxName(of: url)
        var emlxFiles: [URL] = []
        var legacyMbox: URL? = nil
        var skippedPartial = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: nil
        ) else {
            throw ImportError.sourceNotFound(url.path)
        }
        while let file = enumerator.nextObject() as? URL {
            let name = file.lastPathComponent
            if name.hasSuffix(".emlx") {
                if name.hasSuffix(".partial.emlx") {
                    skippedPartial += 1
                } else {
                    emlxFiles.append(file)
                }
            } else if name == "mbox", file.isRegularFile {
                legacyMbox = file
            }
        }

        if !emlxFiles.isEmpty {
            var report = ImportReport(
                format: .appleMail, filesSeen: emlxFiles.count,
                skippedLeadingBytes: skippedPartial
            )
            let start = Date()
            for file in emlxFiles.sorted(by: { $0.path < $1.path }) {
                report.messagesFound += 1
                do {
                    let data = try EmlxFile.messageBytes(from: file)
                    let parsed = MailBridge.parse(for: data)
                    let result = try ingestOne(
                        store, data: data, parsed: parsed, importSource: "apple-mail",
                        account: account,
                        membership: Membership(mailbox: box, uid: nil, flags: [], dateReceived: now),
                        dateReceived: now, gmailMetadata: false, now: now
                    )
                    report.count(result: result)
                } catch {
                    report.failed += 1
                    report.failedFiles.append(relativeSafe(file, to: package))
                }
            }
            report.duration = Date().timeIntervalSince(start)
            // As-you-type vocabulary (decision 0025): refresh the
            // first-letter tables now that every row of this import is in
            // the index. (The legacy-mbox path refreshes inside
            // importMboxFile.)
            try store.refreshAsYouTypeVocabulary()
            return report
        }

        if let legacy = legacyMbox {
            var report = try importMboxFile(
                store, file: legacy, account: account, mailbox: box,
                importSource: "apple-mail", now: now
            )
            // The mbox helper reports its own format; a legacy package is
            // still an Apple Mail import to the caller.
            report.format = .appleMail
            return report
        }

        throw ImportError.unrecognized(
            "Apple Mail package without Messages/*.emlx or legacy mbox file"
        )
    }

    /// One standalone .emlx file.
    static func importSingleEmlx(
        _ store: ArchiveStore,
        file url: URL,
        account: AccountIdentity,
        mailbox: String?,
        now: Date
    ) throws -> ImportReport {
        var report = ImportReport(format: .appleMail, filesSeen: 1)
        let start = Date()
        report.messagesFound = 1
        do {
            let data = try EmlxFile.messageBytes(from: url)
            let parsed = MailBridge.parse(for: data)
            let result = try ingestOne(
                store, data: data, parsed: parsed, importSource: "apple-mail",
                account: account,
                membership: Membership(
                    mailbox: mailbox ?? "Imported", uid: nil, flags: [], dateReceived: now
                ),
                dateReceived: now, gmailMetadata: false, now: now
            )
            report.count(result: result)
        } catch {
            report.failed = 1
            report.failedFiles = [url.lastPathComponent]
        }
        report.duration = Date().timeIntervalSince(start)
        // As-you-type vocabulary (decision 0025): refresh the first-letter
        // tables now that every row of this import is in the index.
        try store.refreshAsYouTypeVocabulary()
        return report
    }

    /// Parses one `.emlx` file into its message bytes: a decimal length line,
    /// then that many message bytes, then an optional plist trailer.
    public enum EmlxFile {
        public static func messageBytes(from url: URL) throws -> Data {
            try messageBytes(Data(contentsOf: url))
        }

        public static func messageBytes(_ data: Data) throws -> Data {
            // The length line ends at the first LF; parse its digits.
            guard let lineEnd = data.firstIndex(of: 0x0A) else {
                throw ArchiveError.corruptLayout("emlx: no length line")
            }
            let prefix = data[data.startIndex..<lineEnd]
            let digits = String(decoding: prefix, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let length = Int(digits), length > 0 else {
                throw ArchiveError.corruptLayout("emlx: length line is not a number")
            }
            let bodyStart = data.index(after: lineEnd)
            guard let bodyEnd = data.index(
                bodyStart, offsetBy: length, limitedBy: data.endIndex
            ) else {
                throw ArchiveError.corruptLayout("emlx: declared length exceeds file size")
            }
            guard bodyEnd > bodyStart else {
                throw ArchiveError.corruptLayout("emlx: empty message")
            }
            return Data(data[bodyStart..<bodyEnd])
        }
    }

    // MARK: - Shared ingestion

    /// One message into the store: date it from the source (envelope date for
    /// mbox, import time otherwise), then ingest atomically. Returns which
    /// ingest outcome happened so the caller can count it.
    static func ingestOne(
        _ store: ArchiveStore,
        data: Data,
        parsed: MailBridge.ParsedMail,
        importSource: String,
        account: AccountIdentity,
        membership: Membership,
        dateReceived: Date?,
        gmailMetadata: Bool,
        now: Date
    ) throws -> IngestResult {
        var record = parsed.record
        record.dateReceived = dateReceived
        let labels = gmailMetadata ? parsed.gmailLabels.map { LabelName(name: $0) } : []
        let threadID = gmailMetadata ? parsed.gmailThreadID : nil
        let message = IngestedMessage(
            record: record,
            data: data,
            memberships: [membership],
            labels: labels,
            attachments: parsed.attachments,
            importSource: importSource,
            providerThreadID: threadID,
            // Bodies must be searchable on imported mail: carry the parsed
            // search text through, or the index stores no body tokens.
            searchText: parsed.searchText
        )
        return try store.ingest(message, into: account, now: now)
    }

    // MARK: - Format discovery helpers

    /// All `.mbox` package directories under `directory`, at any depth.
    /// A package inside another package is skipped (the outer one owns it).
    static func appleMailPackages(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [], errorHandler: nil
        ) else { return [] }
        var packages: [URL] = []
        while let file = enumerator.nextObject() as? URL {
            guard file.lastPathComponent.hasSuffix(".mbox") else { continue }
            guard file.isDirectoryCandidate else { continue }
            packages.append(file)
            enumerator.skipDescendants()
        }
        return packages
    }

    /// Mailbox name for an Apple .mbox package: its relative path from the
    /// import root with each component's ".mbox" suffix removed.
    static func mailboxName(for package: URL, relativeTo root: URL) -> String {
        let relative = package.path(relativeTo: root)
        return relative.split(separator: "/")
            .map { component in
                component.hasSuffix(".mbox") ? String(component.dropLast(5)) : String(component)
            }
            .joined(separator: "/")
    }

    /// Apple package directory name without its ".mbox" suffix.
    static func appleMailboxName(of package: URL) -> String {
        let name = package.lastPathComponent
        return name.hasSuffix(".mbox") ? String(name.dropLast(5)) : name
    }

    static func emlFiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        // A directory holding manifest.json is an archive root: never walk
        // into one, so re-importing a source folder that contains the
        // archive does not ingest the archive's own stored copies.
        if fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) {
            return []
        }
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [], errorHandler: nil
        ) else { return [] }
        var files: [URL] = []
        while let file = enumerator.nextObject() as? URL {
            if file.isDirectoryCandidate,
               fm.fileExists(atPath: file.appendingPathComponent("manifest.json").path) {
                enumerator.skipDescendants()
                continue
            }
            // Anything with an .eml name is a claimed message: collect it
            // even if it is not a regular file, so reading it fails and the
            // import reports a per-file failure instead of silently skipping
            // an entry the tree says is a message.
            guard file.lastPathComponent.hasSuffix(".eml") else { continue }
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func merging(_ base: ImportReport, with partial: ImportReport) -> ImportReport {
        var report = base
        report.filesSeen += partial.filesSeen
        report.messagesFound += partial.messagesFound
        report.imported += partial.imported
        report.duplicates += partial.duplicates
        report.failed += partial.failed
        report.failedFiles += partial.failedFiles
        report.skippedLeadingBytes += partial.skippedLeadingBytes
        return report
    }

    /// A relative path that stays inside the report even for files the
    /// enumerator found outside the root (symlink escapes): fall back to
    /// the file name so nothing about the source is lost.
    static func relativeSafe(_ file: URL, to root: URL) -> String {
        let relative = file.path(relativeTo: root)
        return relative.contains("..") ? file.lastPathComponent : relative
    }
}

// MARK: - Small URL helpers

extension URL {
    /// A URL whose path has every symlink component resolved (on macOS
    /// /var → /private/var). Uses `realpath(3)`: the Foundation helpers
    /// (`resolveSymlinksInPath`, `standardizedFileURL`) leave some symlinks
    /// unexpanded, which breaks prefix-stripping. Returns the URL unchanged
    /// when the path does not exist.
    static func resolved(_ url: URL) -> URL {
        guard let c = realpath(url.path, nil) else { return url }
        defer { free(c) }
        return URL(fileURLWithPath: String(cString: c))
    }

    /// True when the URL points at a regular file.
    var isRegularFile: Bool {
        (try? resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Cheap directory check without throwing.
    var isDirectoryCandidate: Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    /// Path relative to `base` using POSIX separators; ".." segments can
    /// appear when the file is not actually below `base` (symlink escapes).
    func path(relativeTo base: URL) -> String {
        var mine = pathComponents
        var baseComponents = base.pathComponents
        while !mine.isEmpty, !baseComponents.isEmpty, mine.first == baseComponents.first {
            mine.removeFirst()
            baseComponents.removeFirst()
        }
        return mine.joined(separator: "/")
    }
}

extension ImportReport {
    mutating func count(result: IngestResult) {
        switch result {
        case .created: imported += 1
        case .duplicate: duplicates += 1
        }
    }
}
