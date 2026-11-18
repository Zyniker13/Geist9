# 0016 — Export semantics: .eml trees and mbox files

Date: 2026-11-18
Status: Accepted

## Context

M1 needs export alongside import (DESIGN 9): an `.eml` tree and mbox
files. The archive may be someone's only copy of their mail, so the
export must reproduce stored messages exactly — export is the other
half of decision 0015's "stored bytes are what the source attests"
convention, and the round-trip tests are the acceptance proof.

## Decision

- **The stored bytes are the export unit.** Export reads message bytes
  from the store (`ArchiveStore.messageData`) and never parses or
  re-serializes them. An `.eml` tree copy is byte-identical by
  construction; an mbox export only adds RFC 4155 framing.
- **`.eml` tree layout.** One file per message named
  `<hash12>-<subject>.eml` (first 12 hex characters of the SHA-256
  content hash, then a sanitized subject, `No Subject` when empty).
  The hash prefix makes names unique and stable; sanitizing maps "/",
  NUL, control and DEL bytes to "-", collapses whitespace, caps at 64
  scalars, and never ends in a dot or space. Folders mirror the
  mailbox name split on "/" only — the same rule the `.eml` importer
  uses to derive mailbox names — so a tree round trip restores the
  same mailbox names. mbox-delimiter names ("INBOX.Sent") stay one
  folder; the mapping is exactly reversible under the same rule.
- **mbox variant written: mboxrd quoting.** Export writes a From_
  envelope line (sender from the index's From address,
  `MAILER-DAEMON` when unknown; date from Date, then received date,
  then the epoch) followed by `quoteBodyForExport(stored)`. Messages
  are concatenated back to back: the splitter recognizes a From_ at
  line start, so no filler belongs between messages, and adding none
  keeps round trips byte-identical. Re-importing the export with
  mboxrd (or auto-detection, which sees the `>From ` evidence)
  reproduces the stored bytes.
- **The frame-newline exception.** A stored message that does not end
  on a line boundary cannot be represented in mbox: export appends one
  newline as frame, and the re-imported copy is `stored + "\n"`
  (different hash, one byte). This is documented behavior, not loss:
  `.eml` export of the same message is byte-identical, and messages
  imported from real sources (mbox, .eml, .emlx) always end on a line
  boundary. The frame newline is never counted as message content on
  re-import.
- **Selection and dedup.** `ArchiveStore.exportMessages(mailbox:)`
  returns index rows for one mailbox, or for the whole archive
  deduplicated by hash (first membership in id order wins, stable id
  order). A whole-archive `.eml` tree writes each message once, under
  its first mailbox; per-mailbox exports write it under each mailbox
  it belongs to.
- **Destinations are never clobbered.** An `.eml` tree export refuses
  a non-empty root; an mbox export refuses an existing file. Export
  writes are durable and atomic: `.eml` files go through
  `AtomicWrite.write`, the mbox file is streamed to a hidden temp file
  and finalized with `AtomicWrite.finalize` (fsync, rename, fsync
  directory), so an interrupted export never keeps the destination's
  name.
- **Apple Mail `.mbox` packages.** `exportAppleMailPackage` writes a
  `<name>.mbox` directory holding a bare legacy `mbox` file (the same
  code path). No `table_of_contents` is written: it is a private index
  Apple Mail rebuilds itself, and the importer does not require it.
- **Export never touches the archive** — it is read-only toward the
  store, like sync is read-only toward providers (AGENTS.md).

## Consequences

- Round trips: import → export → import yields byte-identical stored
  bytes for `.eml` (always) and mbox (except the documented
  frame-newline case), pinned by `ExportTests`.
- Filenames leak nothing but the hash and the subject the archive
  already indexed; no server metadata is needed for export.
- The mailbox-name split rule (" `/` only") must stay matched between
  `importEMLFolder` and `exportEMLTree`; a test covers both.
