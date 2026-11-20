# 0043 — RTF attachment text

Date: 2026-11-20
Status: Accepted

## Context

Rich-text attachments (`application/rtf`, `text/rtf`, `.rtf`) are common
from word processors and mail clients. The bridge's `text/*` branch would
either yield nothing (`application/rtf` is not `text/*`) or, for
`text/rtf`, index the raw RTF source — control words like `\fonttbl`
become searchable noise. ROADMAP M2 lists RTF attachment text as
outstanding.

## Decision

- A pure-Swift RTF decoder, `RTFText` in `ArchiveCore` (Linux-compatible,
  no dependencies), extracts visible text: `RTFText.text(_ bytes: [UInt8])`
  returns the extracted text or nil (strict, like the other extractors —
  a file that is not RTF yields no text, and the part stays listed).
- The decoder walks RTF groups and control words, skipping destination
  groups that carry no prose (`\fonttbl`, `\colortbl`, `\pict`,
  `\stylesheet`, `\info`, and friends), field instructions
  (`\*\fldinst`) while keeping field results (`\fldrslt`), and unknown
  `\*` destination groups. Ignored formatting words (`\b`, `\fs24`,
  `\deff0`, …) keep the text that follows them. `\par` and `\line`
  become newlines, `\tab` a tab; raw CR/LF bytes between tokens are
  ignored, as the RTF spec directs readers to do.
- Escapes decode: Windows-1252 hex escapes (`\'92` → ’) and `\uN`
  unicode escapes with their one-byte ANSI fallback skipped — a pending
  fallback-skip never leaks past a group boundary, where it is cleared.
- Bounds mirror the other extractors: 24 MB input cap, 1 MB output cap,
  trimmed result; a truncated file still yields the text before the
  cut.
- The bridge dispatches RTF attachments (by MIME type first —
  `application/rtf` or `text/rtf` — then by `.rtf` filename extension)
  to the decoder before the `text/*` branch, so raw RTF source is never
  indexed.
- `TextIndexVersion` bumps v11 → v12: stored indexes reindex once on
  upgrade, and RTF text appears in search results. The archive never
  rewrites the message: the attachment bytes remain in the stored
  message exactly as downloaded; this is an index change only.

## Consequences

- RTF attachments become searchable by their visible prose; font tables
  and control words no longer pollute the index.
- The decoder is deliberately minimal: `\uN` fallbacks that are
  themselves control words (e.g. `\u8212\par`) skip only the backslash,
  and `\binN` data is skipped without decoding — both acceptable for
  indexing prose and noted here as known limits. RTFD packages (RTF
  with embedded attachments) are not part of this decision.
- Linux builds are unaffected: the decoder is dependency-free Swift.
- Tests: `RTFTextTests` (paragraphs, ignored control words, destination
  skips, hex and unicode escapes, tabs/lines/raw newlines, field
  results, truncated files, binary data, garbage/empty/oversized
  inputs, output cap) and bridge-level tests for indexed text and the
  v12 backfill.
