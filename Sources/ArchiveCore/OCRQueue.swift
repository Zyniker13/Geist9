// Pausable OCR queue (decision 0050): runs the on-device OCR on the
// `pending` attachment parts, stores the text in `attachment.text`, and
// re-indexes the message. The pending parts are the `textState = 'pending'`
// rows, so a restart resumes where it stopped. The queue is low-priority:
// the app starts it after the import completes and runs it on a background
// queue; it yields to the foreground (search, sync).

import Foundation
import GRDB

/// A pausable, persistent queue that runs the on-device OCR on the
/// `pending` attachment parts (decision 0050). The pending parts are the
/// `textState = 'pending'` rows in the `attachment` table, so a restart
/// resumes where it stopped.
public final class OCRQueue: @unchecked Sendable {
    private let store: ArchiveStore
    private let lock = NSLock()
    private var _isPaused = false

    public init(store: ArchiveStore) {
        self.store = store
    }

    /// Pauses the queue. The current part finishes; no new parts start.
    public func pause() {
        lock.lock()
        _isPaused = true
        lock.unlock()
    }

    /// Resumes the queue.
    public func resume() {
        lock.lock()
        _isPaused = false
        lock.unlock()
    }

    /// True when the queue is paused.
    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isPaused
    }

    /// Processes up to `limit` pending parts. Returns the number of parts
    /// processed. The queue is pausable: a `pause()` between parts stops the
    /// run (the current part finishes, but no new parts start).
    ///
    /// Every `pending` row is OCR-eligible by construction: ingest marks only
    /// the OCR-deferred parts `pending` (decision 0050), so no eligibility
    /// filter is needed here. Parts are taken newest-first (`message.dateSent`
    /// DESC, then insertion order), so recent mail is made searchable before
    /// the backlog (DESIGN.md). A part whose stored bytes cannot be read is
    /// skipped and left `pending` — never marked `noText`, because a missing
    /// part means the stored message is damaged and must stay visible — and
    /// is retried on the next run, at most once per run so it cannot spin
    /// this loop.
    @discardableResult
    public func process(limit: Int = 100) throws -> Int {
        var processed = 0
        var attempted = Set<String>()
        while processed < limit {
            if isPaused { break }
            // The next batch of pending parts, newest first. The batch is
            // small so the queue keeps yielding to the foreground.
            let batch: [(messageID: Int64, hash: Data, partIndex: String)] = try store.db.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT a.messageID, m.hash, a.partIndex
                    FROM attachment a
                    JOIN message m ON m.id = a.messageID
                    WHERE a.textState = 'pending'
                    ORDER BY m.dateSent DESC, a.messageID DESC, a.partIndex
                    LIMIT 64
                    """,
                    arguments: []
                ).compactMap { row in
                    let messageID = (row["messageID"] as Int64?) ?? 0
                    guard let partIndex = row["partIndex"] as String? else { return nil }
                    let key = "\(messageID)|\(partIndex)"
                    guard !attempted.contains(key) else { return nil }
                    guard let hash = row["hash"] as Data?, hash.count == 32, messageID > 0 else {
                        attempted.insert(key)
                        return nil
                    }
                    attempted.insert(key)
                    return (messageID: messageID, hash: hash, partIndex: partIndex)
                }
            }
            guard !batch.isEmpty else { break }
            for part in batch {
                if processed >= limit || isPaused { break }
                if try processPart(messageID: part.messageID, hash: part.hash, partIndex: part.partIndex) {
                    processed += 1
                }
            }
        }
        if processed > 0 {
            // The queue re-indexed messages; refresh the as-you-type
            // vocabulary tables built from their text (decision 0025).
            try store.refreshAsYouTypeVocabulary()
        }
        return processed
    }

    /// Processes one pending part: read the message bytes, look up the part,
    /// run the OCR, store the text, and re-index the message. Returns false
    /// when the part could not be processed (its state is left `pending`).
    private func processPart(
        messageID: Int64,
        hash: Data,
        partIndex: String
    ) throws -> Bool {
        let url = store.fileURL(for: MessageHash(bytes: hash))
        guard let data = try? Data(contentsOf: url) else { return false }
        // Look up the part bytes.
        guard let part = MailBridge.part(at: partIndex, in: data) else { return false }
        // Run the OCR (the same on-device engine as the inline path).
        let partBytes = [UInt8](part.data)
        let text = MailBridge.pdfAttachmentText(main: part.contentType, filename: part.filename, data: partBytes)
            ?? MailBridge.imageAttachmentText(main: part.contentType, filename: part.filename, data: partBytes)
        // Store the text and update the textState.
        try store.db.write { db in
            if let text, !text.isEmpty {
                try db.execute(
                    sql: "UPDATE attachment SET text = ?, textState = 'done' WHERE messageID = ? AND partIndex = ?",
                    arguments: [text, messageID, partIndex]
                )
            } else {
                try db.execute(
                    sql: "UPDATE attachment SET textState = 'noText' WHERE messageID = ? AND partIndex = ?",
                    arguments: [messageID, partIndex]
                )
            }
        }
        // Re-index the message, composing strictly from the stored results
        // (decision 0050): the message's other pending parts contribute no
        // text yet and are not re-OCRed here — each is stored and reindexed
        // when the queue reaches it.
        try store.reindexMessage(id: messageID, hash: hash, allowInlineOCRFallback: false)
        return true
    }
}
