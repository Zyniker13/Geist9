// Viewer pane (DESIGN 12): one message's rendered document in the
// locked-down web view (ViewerKit), plus its attachment list. Message and
// attachment bytes reach the web view only through the `x-bc-mail` scheme
// handler; nothing else can read the archive while a message is open.
// Remote content stays off unless the person turns it on for this message.

import ArchiveCore
import AppKit
import MailMIME
import QuickLookUI
import SwiftUI
import ViewerKit

struct ViewerPane: View {
    let store: ArchiveStore
    let message: ArchiveModel.ViewerMessage
    let openLink: @MainActor @Sendable (URL) -> Void

    var body: some View {
        HSplitView {
            MessageWebView(
                configuration: .init(
                    attachmentSource: Self.source(for: store),
                    onOpenLink: { url in
                        Task { @MainActor in openLink(url) }
                    }
                ),
                document: message.document,
                rowID: message.rowID,
                allowRemoteHosts: []
            )
            .frame(minWidth: 420, idealWidth: 560)

            if !message.attachments.isEmpty {
                attachmentList
                    .frame(minWidth: 170, maxWidth: 260)
            }
        }
    }

    /// The scheme handler's byte source: the original .eml is re-read from
    /// the archive for every attachment request and the part is found by
    /// Content-ID. A mismatched row id gets nothing.
    private static func source(for store: ArchiveStore) -> AttachmentSource {
        AttachmentSource { rowID, contentID in
            guard let summary = try? store.message(id: rowID),
                  let data = try? store.messageData(summary.hash)
            else { return nil }
            return MailBridge.attachment(contentID: contentID, for: data)
                .map { (data: $0.data, contentType: $0.contentType) }
        }
    }

    // MARK: Attachments

    /// Quick Look is the primary open path (DESIGN 8, THREAT-MODEL): it
    /// renders the attachment without executing it, so a malicious payload
    /// gets far fewer chances than a full application launch. "Open with
    /// app" stays available in the context menu.
    private var attachmentList: some View {
        List(message.attachments, id: \.partIndex) { attachment in
            Button {
                previewAttachment(attachment)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename ?? "(unnamed)")
                            .font(.callout)
                            .lineLimit(1)
                        Text(attachment.contentType)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Quick Look")
            .contextMenu {
                Button("Open in Default Application") {
                    openWithApp(attachment)
                }
            }
        }
        .listStyle(.plain)
        .background(PreviewPanelHost(box: previewPanelBox))
    }

    @State private var previewPanelBox = PreviewPanelBox()

    /// Writes the decoded part to a temporary file and previews it in the
    /// system Quick Look panel. The file carries no quarantine attribute
    /// because it is not a download: it came from the person's own archive.
    private func previewAttachment(_ attachment: AttachmentInfo) {
        do {
            let url = try writeAttachment(attachment)
            // Drop the previous preview's temporary file first (unlinking a
            // file Quick Look still has open is safe on POSIX).
            if let previous = previewPanelBox.bridge?.urls.first {
                try? FileManager.default.removeItem(at: previous)
            }
            previewPanelBox.bridge?.urls = [url]
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        } catch {
            // Surfaced by the app shell's notice line.
            NotificationCenter.default.post(name: .viewerAttachmentFailed, object: error.localizedDescription)
        }
    }

    /// The older escape hatch: hand the file to the system opener, which
    /// launches the default application for its type. Explicitly requested
    /// by the person via the context menu.
    private func openWithApp(_ attachment: AttachmentInfo) {
        guard let url = try? writeAttachment(attachment) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Saves the decoded part to a unique temporary file.
    private func writeAttachment(_ attachment: AttachmentInfo) throws -> URL {
        guard let summary = try? store.message(id: message.rowID) else {
            throw ArchiveError.io(underlying: "message not found")
        }
        guard let data = try? store.messageData(summary.hash) else {
            throw ArchiveError.messageNotFound(summary.hash)
        }
        guard let part = MailBridge.part(at: attachment.partIndex, in: data) else {
            throw ArchiveError.io(underlying: "attachment part not found")
        }

        let name = attachment.filename ?? "attachment-\(attachment.partIndex)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try part.data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Quick Look panel bridge (DESIGN 8)

/// Bridges the system Quick Look panel (`QLPreviewPanel`) into the SwiftUI
/// viewer. The bridge's view sits in the window's responder chain; when the
/// panel looks for a controller it takes control here, and the bridge serves
/// the attachment file URLs written by `ViewerPane`. Quick Look renders a
/// file without executing it (THREAT-MODEL).
private final class PreviewPanelBridge: NSView, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    var urls: [URL] = [] {
        didSet { reloadPanelIfControlling() }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }

    private func reloadPanelIfControlling() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              (QLPreviewPanel.shared().currentController as AnyObject) === self
        else { return }
        QLPreviewPanel.shared().reloadData()
    }
}

/// Holds the bridge view once SwiftUI has placed it in the hierarchy, so the
/// button action can update its URLs without a state-update round trip.
@MainActor
private final class PreviewPanelBox {
    var bridge: PreviewPanelBridge?
}

private struct PreviewPanelHost: NSViewRepresentable {
    let box: PreviewPanelBox

    func makeNSView(context: Context) -> PreviewPanelBridge {
        let bridge = PreviewPanelBridge()
        box.bridge = bridge
        return bridge
    }

    func updateNSView(_ nsView: PreviewPanelBridge, context: Context) {}
}

extension Notification.Name {
    static let viewerAttachmentFailed = Notification.Name("viewerAttachmentFailed")
}
