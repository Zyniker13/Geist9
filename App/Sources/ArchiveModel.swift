// Archive model (DESIGN 12): the app shell's single source of state. One
// archive at a time; the message list, the viewer, import and export all
// read through it. The model holds no mail bytes permanently — every
// message lives content-addressed on disk inside its archive, and the
// viewer re-reads the original whenever it renders.

import ArchiveCore
import Foundation
import MailMIME
import ViewerKit

@MainActor
final class ArchiveModel: ObservableObject {
    static let appVersion = "0.1.0"

    @Published private(set) var store: ArchiveStore?
    @Published private(set) var archiveName: String?
    @Published private(set) var mailboxes: [MailboxSummary] = []
    @Published private(set) var accounts: [AccountSummary] = []
    @Published private(set) var labels: [LabelSummary] = []
    @Published private(set) var savedSearches: [SavedSearchSummary] = []
    @Published var selectedMailbox: String?
    @Published var query: String = ""
    @Published private(set) var results: [SearchRow] = []
    /// Why the last typed query produced no list (bad query syntax, for
    /// example). nil while the list is a plain mailbox listing.
    @Published private(set) var searchNotice: String?
    @Published var selection: MessageSummary?
    @Published private(set) var viewer: ViewerMessage?
    @Published var allowRemoteContent = false
    /// One-line status for the last archive action (import, export, scrub).
    @Published private(set) var notice: String?

    /// A message-list row: the row plus, for search results, the matching
    /// snippet the query engine already computed.
    struct SearchRow: Identifiable, Sendable, Equatable {
        let summary: MessageSummary
        let snippet: String?
        var id: Int64 { summary.id }
    }

    /// Everything the viewer pane needs for one message.
    struct ViewerMessage: Sendable {
        let rowID: Int64
        let document: MessageDocument.Output
        let attachments: [AttachmentInfo]
    }

    private var searchTask: Task<Void, Never>?
    /// The selected message's stored bytes, kept only while it stays
    /// selected, so "load remote content" can re-render without a re-read.
    private var selectedData: Data?

    var hasArchive: Bool { store != nil }

    // MARK: Archive lifecycle

    func createArchive(at url: URL) {
        open { try ArchiveStore.create(at: url, appVersion: Self.appVersion) }
    }

    func openArchive(at url: URL) {
        open { try ArchiveStore.open(at: url) }
    }

    func closeArchive() {
        searchTask?.cancel()
        searchTask = nil
        store = nil
        archiveName = nil
        mailboxes = []
        accounts = []
        labels = []
        savedSearches = []
        selectedMailbox = nil
        query = ""
        results = []
        searchNotice = nil
        selection = nil
        viewer = nil
        allowRemoteContent = false
        selectedData = nil
        notice = nil
    }

    private func open(_ make: () throws -> ArchiveStore) {
        do {
            store = try make()
            archiveName = store?.directory.lastPathComponent
            notice = nil
            refreshMailboxes(selectFirst: true)
        } catch {
            notice = "Could not open archive: \(describe(error))"
        }
    }

    // MARK: Sidebar

    /// Sidebar content: mailboxes of the imported account plus the account,
    /// label and saved-search listings (DESIGN 12). Import and saving both
    /// refresh it.
    func refreshMailboxes(selectFirst: Bool = false) {
        guard let store else { return }
        do {
            mailboxes = try store.listMailboxes(accountEmail: "imported")
            accounts = try store.listAccounts()
            labels = try store.listLabels(accountEmail: "imported")
            savedSearches = try store.listSavedSearches()
            if selectFirst,
               selectedMailbox == nil || !mailboxes.contains(where: { $0.name == selectedMailbox }) {
                selectedMailbox = mailboxes.first?.name
            }
            refreshList()
        } catch {
            notice = "Could not list mailboxes: \(describe(error))"
        }
    }

    func selectMailbox(_ name: String) {
        selectedMailbox = name
        if query.isEmpty { refreshList() }
    }

    /// Clicking a label runs it as a query (`label:"…"`) so the result stays
    /// a live search — new mail carrying the label appears.
    func selectLabel(_ name: String) {
        query = Self.queryForLabel(name)
        searchChanged()
    }

    /// Clicking an account runs it as a query (`account:"…"`) — same live
    /// semantics as labels.
    func selectAccount(_ email: String) {
        query = Self.queryForAccount(email)
        searchChanged()
    }

    // MARK: Saved searches

    /// Save the current query under a name. Re-saving a name replaces its
    /// query (ArchiveCore semantics).
    func saveCurrentSearch(named name: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !text.isEmpty else { return }
        do {
            try store.saveSearch(name: name, query: text)
            savedSearches = try store.listSavedSearches()
            notice = "Saved search “\(name.trimmingCharacters(in: .whitespacesAndNewlines))”."
        } catch {
            notice = "Could not save search: \(describe(error))"
        }
    }

    func selectSavedSearch(_ saved: SavedSearchSummary) {
        searchTask?.cancel()
        searchTask = nil
        query = saved.query
        runSearch(saved.query)
    }

    func deleteSavedSearch(_ saved: SavedSearchSummary) {
        guard let store else { return }
        do {
            try store.deleteSavedSearch(id: saved.id)
            savedSearches = try store.listSavedSearches()
        } catch {
            notice = "Could not delete saved search: \(describe(error))"
        }
    }

    /// `op:"value"` with quotes and quote characters handled: the scanner
    /// has no backslash escapes, so an embedded quote is dropped.
    private static func operatorQuery(_ op: String, _ value: String) -> String {
        let safe = value.replacingOccurrences(of: "\"", with: "")
        return "\(op):\"\(safe)\""
    }

    /// The query string a label row runs. Shared with the sidebar so the
    /// active-row highlight compares against the exact same text.
    static func queryForLabel(_ name: String) -> String { operatorQuery("label", name) }

    /// The query string an account row runs.
    static func queryForAccount(_ email: String) -> String { operatorQuery("account", email) }

    // MARK: Message list and search

    func refreshList() {
        guard let store, query.isEmpty else { return }
        do {
            results = try store.listMessages(mailbox: selectedMailbox ?? "")
                .map { SearchRow(summary: $0, snippet: nil) }
            searchNotice = nil
        } catch {
            notice = "Could not list messages: \(describe(error))"
        }
    }

    /// As-you-type search (DESIGN 12): debounced; an empty box falls back
    /// to the selected mailbox's newest messages.
    func searchChanged() {
        searchTask?.cancel()
        guard store != nil else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            searchNotice = nil
            refreshList()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.runSearch(text)
        }
    }

    private func runSearch(_ text: String) {
        guard let store else { return }
        do {
            let answer = try store.search(text, withSnippets: true)
            results = try answer.hits.compactMap { hit in
                guard let summary = try store.message(id: hit.messageID) else { return nil }
                return SearchRow(summary: summary, snippet: hit.snippet)
            }
            searchNotice = nil
        } catch {
            // A malformed query line is a normal typing state: show why,
            // keep the previous list.
            searchNotice = describe(error)
        }
    }

    /// Set by parts of the shell that fail outside the model (for example
    /// an attachment the system could not open).
    func reportNotice(_ text: String) {
        notice = text
    }

    func clearSearch() {
        query = ""
        searchChanged()
    }

    // MARK: Viewer

    func select(_ summary: MessageSummary) {
        selection = summary
        viewer = nil
        selectedData = nil
        allowRemoteContent = false
        guard let store else { return }
        do {
            let data = try store.messageData(summary.hash)
            selectedData = data
            viewer = try makeViewer(rowID: summary.id, data: data, allowRemote: false)
        } catch {
            notice = "Could not read message: \(describe(error))"
        }
    }

    /// Re-render with or without remote content. The decision belongs to
    /// the person; the renderer only records it (DESIGN 12).
    func setRemoteContent(_ allowed: Bool) {
        allowRemoteContent = allowed
        guard let summary = selection, let data = selectedData else { return }
        do {
            viewer = try makeViewer(rowID: summary.id, data: data, allowRemote: allowed)
        } catch {
            notice = "Could not re-render message: \(describe(error))"
        }
    }

    private func makeViewer(rowID: Int64, data: Data, allowRemote: Bool) throws -> ViewerMessage {
        let (html, plain) = Self.viewerBody(for: data)
        guard html != nil || plain != nil else {
            throw ArchiveError.corruptLayout("message \(rowID) has no text body part")
        }
        let document = MessageDocument.render(
            bodyHTML: html,
            plainText: plain,
            messageRowID: rowID,
            allowRemoteContent: allowRemote
        )
        return ViewerMessage(
            rowID: rowID,
            document: document,
            attachments: MailBridge.attachments(for: data)
        )
    }

    /// The body part a viewer renders, decoded per its charset. Never
    /// throws: unknown charsets fall back lossily rather than losing text.
    static func viewerBody(for data: Data) -> (html: String?, plain: String?) {
        guard let path = MailBridge.bodyPartPath(for: data),
              let part = MailBridge.part(at: path, in: data)
        else { return (nil, nil) }
        let text = Charset.decode(charset(of: part.contentType), [UInt8](part.data))
        if part.contentType.lowercased().hasPrefix("text/html") {
            return (text, nil)
        }
        return (nil, text)
    }

    private static func charset(of contentType: String) -> String? {
        for piece in contentType.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            guard pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        return nil
    }

    // MARK: Import, export, scrub

    func importMail(from url: URL) {
        guard let store else { return }
        do {
            let report = try MailImporter.`import`(store, from: url)
            notice = "Imported \(report.imported) new, \(report.duplicates) duplicate, "
                + "\(report.failed) failed (\(report.format.rawValue))."
            // A fresh import may have brought new mailboxes.
            selectedMailbox = nil
            refreshMailboxes(selectFirst: true)
        } catch {
            notice = "Import failed: \(describe(error))"
        }
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case emlTree = "EML files (.eml)"
        case mbox = "mbox file (.mbox)"
        var id: String { rawValue }
    }

    func exportSelection(_ format: ExportFormat, to url: URL) {
        guard let store, let selection else { return }
        let message = ExportMessage(
            hash: selection.hash,
            subject: selection.subject,
            fromEmail: selection.fromEmail,
            dateSent: selection.dateSent,
            dateReceived: selection.dateReceived
        )
        do {
            let report: ExportReport
            switch format {
            case .emlTree: report = try MailExporter.exportEMLTree(from: store, messages: [message], to: url)
            case .mbox: report = try MailExporter.exportMbox(from: store, messages: [message], to: url)
            }
            notice = "Exported \(report.filesWritten.count) file(s)."
        } catch {
            notice = "Export failed: \(describe(error))"
        }
    }

    /// Exports every message in the archive. Runs off the main actor: a
    /// large archive can take minutes, and the UI must stay responsive.
    func exportWholeArchive(_ format: ExportFormat, to url: URL) {
        guard let store else { return }
        notice = "Exporting the whole archive…"
        Task.detached(priority: .userInitiated) { [store] in
            do {
                let messages = try store.exportMessages(mailbox: nil)
                let report: ExportReport
                switch format {
                case .emlTree: report = try MailExporter.exportEMLTree(from: store, messages: messages, to: url)
                case .mbox: report = try MailExporter.exportMbox(from: store, messages: messages, to: url)
                }
                await MainActor.run {
                    self.notice = "Exported \(report.messagesExported) messages (\(report.filesWritten.count) file(s))."
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                await MainActor.run {
                    self.notice = "Export failed: \(message)"
                }
            }
        }
    }

    func scrub() {
        guard let store else { return }
        do {
            let report = try store.scrub()
            notice = report.isClean
                ? "Archive verified clean: \(report.filesVerified) messages checked."
                : "Archive issues found: \(report.missingFiles.count) missing, "
                    + "\(report.hashMismatches.count) corrupted, \(report.unindexedFiles.count) unindexed, "
                    + "\(report.corruptLayout.count) layout problems. Index repaired where possible; "
                    + "no stored message was touched."
        } catch {
            notice = "Scrub failed: \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
