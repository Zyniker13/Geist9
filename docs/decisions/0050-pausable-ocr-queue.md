# 0050 — Pausable OCR queue for image and scanned-PDF attachments

**Date:** 2026-11-20
**Status:** Accepted

## Context

Decision 0040 added on-device Vision OCR for image attachments and scanned
PDFs, but it ran inline during ingest: every import paid the OCR cost on the
import path, and a large import (thousands of scanned receipts) stalled the
import for minutes. The ROADMAP M2 task asks for OCR "on a low-priority,
pausable queue." A queue also makes the OCR resumable: a killed import leaves
the pending OCR parts in the index, and the next run finishes them.

## Decision

- OCR of image and scanned-PDF attachments is **deferred** at ingest. The
  import path parses with `MailBridge.parse(for:ocr:)` in `.deferred` mode:
  the OCR text is not extracted during the parse. Eligibility is **derived
  from the attachment row's own content type and filename** — the same
  `MailBridge.isOcrCandidate(main:filename:)` predicate the extractors use —
  so the state never depends on a caller remembering to hand-carry a list.
  The attachment row is written with `textState = 'pending'` and no `text`
  when the row is OCR-eligible, and `textState = 'done'` when it is not
  (its inline extraction is already finished). Marking non-eligible rows
  `done` at ingest keeps the queue's pending set equal to the real OCR
  backlog — rows that could never be OCR'd must not sit `pending` forever
  and starve the queue.
- A new `attachment.text` column (core-v15) stores the OCR text once the
  queue runs. `textState` moves from `pending` to `done` (text found) or
  `noText` (nothing legible) when the queue finishes a part.
- A new `OCRQueue` (ArchiveCore) processes the pending parts: it selects the
  next `pending` parts newest-first (`message.dateSent DESC`, so recent mail
  becomes searchable before the backlog), re-reads the part bytes from the
  stored message, runs the on-device OCR (the same `pdfAttachmentText` /
  `imageAttachmentText` helpers), stores the text, and reindexes the
  message. Within one run each part is attempted at most once: a part whose
  stored bytes cannot be read is skipped (left `pending`, never `noText`)
  and retried on the next run, so a single unreadable part cannot spin the
  loop. It is pausable (`pause()` / `resume()`) and persistent (the pending
  parts are the `textState = 'pending'` rows, so a restart resumes where it
  stopped).
- Reindexing composes the OCR text from the stored `attachment.text`
  (`.stored` mode). A part the queue has finished (`done` / `noText`) is
  taken from storage and never re-run. A part still `pending` has no stored
  result: a version-bump backfill falls back to running the engine inline
  (older archives never stored text, so this is what keeps their extracted
  text from being lost), while the queue's own per-part reindex composes
  strictly from storage so it never double-OCRs the message's other pending
  parts.
- The queue is low-priority: the app starts it after the import completes and
  runs it on a background queue; it yields to the foreground (search, sync).

## Consequences

- The `attachment` table gains a `text` column (core-v15);
  `IndexSchema.version` moves 12 → 13. Existing archives migrate forward
  without touching stored rows.
- A freshly imported message is searchable by its body and non-OCR
  attachments immediately; its OCR parts become searchable once the queue
  reaches them. The M2 "scanned receipt found by a word" fixture runs the
  queue before searching.
- On Linux (no Vision) the queue marks OCR parts `noText`; the import path is
  unchanged.
- `MailBridge.parse(for:)` gains an `ocr:` parameter (default `.inline`), so
  existing call sites (the relevance eval, `record(for:)`) keep their
  behavior.
