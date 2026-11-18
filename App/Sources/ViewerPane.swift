// Viewer pane (DESIGN 12): one message's rendered document in the
// locked-down web view (ViewerKit), plus its attachment list. Message and
// attachment bytes reach the web view only through the `x-bc-mail` scheme
// handler; nothing else can read the archive while a message is open.
// Remote content stays off unless the person turns it on for this message.

import ArchiveCore
import MailMIME
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

    private var attachmentList: some View {
        List(message.attachments, id: \.partIndex) { attachment in
            Button {
                openAttachment(attachment)
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
            .help("Open in its default application")
        }
        .listStyle(.plain)
    }

    /// Saves the decoded part to a temporary file and hands it to the
    /// system opener. The file carries no quarantine attribute because it
    /// is not a download: it came from the person's own archive.
    private func openAttachment(_ attachment: AttachmentInfo) {
        guard
            let summary = try? store.message(id: message.rowID),
            let data = try? store.messageData(summary.hash),
            let part = MailBridge.part(at: attachment.partIndex, in: data)
        else { return }

        let name = attachment.filename ?? "attachment-\(attachment.partIndex)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString)
            .appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try part.data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            // Surfaced by the app shell's notice line.
            NotificationCenter.default.post(name: .viewerAttachmentFailed, object: error.localizedDescription)
        }
    }
}

extension Notification.Name {
    static let viewerAttachmentFailed = Notification.Name("viewerAttachmentFailed")
}
