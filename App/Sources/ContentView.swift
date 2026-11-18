// The main window (DESIGN 12): archive controls and mailboxes on the
// left, the message list (searchable, newest first) in the middle, the
// viewer on the right. Import, export and scrub run straight from the
// sidebar; every action reports through the model's notice line.

import AppKit
import ArchiveCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ArchiveModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .frame(minWidth: 940, minHeight: 540)
        .onReceive(NotificationCenter.default.publisher(for: .viewerAttachmentFailed)) { note in
            let text = note.object as? String ?? "unknown error"
            model.reportNotice("Could not open attachment: \(text)")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            archiveControls
            Divider()
            mailboxList
            Spacer(minLength: 0)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var archiveControls: some View {
        if let name = model.archiveName {
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Button("Import…") { chooseImportSource() }
                    Menu("Export") {
                        ForEach(ArchiveModel.ExportFormat.allCases) { format in
                            Button("Selected: \(format.rawValue)") { chooseExportDestination(format) }
                        }
                        .disabled(model.selection == nil)
                        Divider()
                        ForEach(ArchiveModel.ExportFormat.allCases) { format in
                            Button("Whole Archive: \(format.rawValue)") {
                                chooseWholeArchiveDestination(format)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Scrub & Verify") { model.scrub() }
                    Button("Close") { model.closeArchive() }
                }
            }
            .padding(10)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bristlecone")
                    .font(.headline)
                Button("Create Archive…") { chooseNewArchive() }
                Button("Open Archive…") { chooseExistingArchive() }
                Text("Pick an empty folder for a new archive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        if let notice = model.notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
    }

    private var mailboxList: some View {
        List {
            Section("Mailboxes") {
                ForEach(model.mailboxes, id: \.name) { mailbox in
                    sidebarRow(mailbox.name, count: mailbox.messageCount, active: model.selectedMailbox == mailbox.name && model.query.isEmpty) {
                        model.selectMailbox(mailbox.name)
                    }
                }
            }
            if !model.accounts.isEmpty {
                Section("Accounts") {
                    ForEach(model.accounts, id: \.email) { account in
                        sidebarRow(account.email, count: account.messageCount, active: model.query == ArchiveModel.queryForAccount(account.email)) {
                            model.selectAccount(account.email)
                        }
                    }
                }
            }
            if !model.labels.isEmpty {
                Section("Labels") {
                    ForEach(model.labels, id: \.name) { label in
                        sidebarRow(label.name, count: label.messageCount, active: model.query == ArchiveModel.queryForLabel(label.name)) {
                            model.selectLabel(label.name)
                        }
                    }
                }
            }
            if !model.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(model.savedSearches, id: \.id) { saved in
                        sidebarRow(saved.name, count: nil, active: model.query == saved.query) {
                            model.selectSavedSearch(saved)
                        }
                        .contextMenu {
                            Button("Delete") { model.deleteSavedSearch(saved) }
                        }
                    }
                }
            }
        }
        .alert("Save Search", isPresented: $showSaveSearch) {
            TextField("Name", text: $saveSearchName)
            Button("Save") {
                model.saveCurrentSearch(named: saveSearchName)
                saveSearchName = ""
            }
            Button("Cancel", role: .cancel) { saveSearchName = "" }
        } message: {
            Text("Saves the current search text as a named query.")
        }
    }

    @State private var saveSearchName = ""
    @State private var showSaveSearch = false

    private func sidebarRow(
        _ title: String, count: Int?, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(active ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    // MARK: Message list

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onChange(of: model.query) { _, _ in model.searchChanged() }
                if !model.query.isEmpty {
                    Button {
                        model.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    Button {
                        showSaveSearch = true
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .buttonStyle(.plain)
                    .help("Save this search")
                }
            }
            .padding(8)
            if let searchNotice = model.searchNotice {
                Text(searchNotice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            messageRows
        }
    }

    @ViewBuilder
    private var messageRows: some View {
        if model.results.isEmpty {
            emptyList
        } else {
            List(model.results, id: \.id, selection: selectedID) { row in
                MessageRow(row: row, isSearchResult: !model.query.isEmpty)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(row.summary) }
                    .listRowBackground(
                        row.id == model.selection?.id
                            ? Color.accentColor.opacity(0.18) : Color.clear
                    )
            }
            .listStyle(.plain)
        }
    }

    private var selectedID: Binding<Int64?> {
        Binding(
            get: { model.selection?.id },
            set: { newValue in
                guard let id = newValue,
                      let row = model.results.first(where: { $0.id == id })
                else { return }
                model.select(row.summary)
            }
        )
    }

    @ViewBuilder
    private var emptyList: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(model.query.isEmpty ? emptyMailboxText : "No messages match.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.query.isEmpty {
                Text("Searches subject, from, to, body text, and attachments (attachment:).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMailboxText: String {
        guard model.hasArchive else { return "Open or create an archive." }
        return model.mailboxes.isEmpty ? "Import mail to fill the archive." : "No messages here."
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let store = model.store, let viewer = model.viewer {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Toggle("Load remote content", isOn: remoteBinding)
                        .toggleStyle(.checkbox)
                        .help("Allow this message to fetch pictures and styles from the network")
                    Spacer()
                    if let summary = model.selection {
                        Text("\(summary.subject ?? "(no subject)")")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(8)
                Divider()
                ViewerPane(store: store, message: viewer) { url in
                    openExternalLink(url)
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "envelope")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Select a message")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var remoteBinding: Binding<Bool> {
        Binding(
            get: { model.allowRemoteContent },
            set: { model.setRemoteContent($0) }
        )
    }

    // MARK: Panels and link confirmation

    private func chooseNewArchive() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mail.emailarchive"
        panel.message = "Choose a folder for the new archive"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.createArchive(at: url)
    }

    private func chooseExistingArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the archive folder to open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openArchive(at: url)
    }

    private func chooseImportSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder, .mbox file, .eml or .emlx file to import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importMail(from: url)
    }

    private func chooseExportDestination(_ format: ArchiveModel.ExportFormat) {
        let panel = NSSavePanel()
        switch format {
        case .emlTree: panel.nameFieldStringValue = "Export"
        case .mbox: panel.nameFieldStringValue = "Export.mbox"
        }
        panel.message = "Where should the selected message be exported?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportSelection(format, to: url)
    }

    private func chooseWholeArchiveDestination(_ format: ArchiveModel.ExportFormat) {
        let panel = NSSavePanel()
        switch format {
        case .emlTree: panel.nameFieldStringValue = "Archive"
        case .mbox: panel.nameFieldStringValue = "Archive.mbox"
        }
        panel.message = "Where should the whole archive be exported?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportWholeArchive(format, to: url)
    }

    /// mailto hands off to the system without asking; http and https
    /// confirm first, showing the exact address (DESIGN 12).
    private func openExternalLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return
        }
        guard scheme == "http" || scheme == "https" else { return }
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        alert.informativeText = url.absoluteString
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One row of the message list: date, sender, subject, and — for search
/// results — the matching snippet (DESIGN 10).
struct MessageRow: View {
    let row: ArchiveModel.SearchRow
    let isSearchResult: Bool

    private var summary: MessageSummary { row.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.fromName ?? summary.fromEmail ?? "(unknown sender)")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if let date = summary.dateSent ?? summary.dateReceived {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(summary.subject ?? "(no subject)")
                .font(.body)
                .lineLimit(1)
            if isSearchResult, let snippet = row.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

