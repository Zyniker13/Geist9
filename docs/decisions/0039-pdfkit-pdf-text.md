# Decision 0039: PDF attachment text via PDFKit in an Apple-only target

Date: 2026-11-19

## Context

M2.3 indexes attachment text. Office Open XML, OpenDocument, and iWork
packages were handled by decisions 0036–0038 through the ZIP reader in
`ArchiveExtract` (pure Swift, portable to Linux). PDFs are the next
text-bearing format on the roadmap (M2.3). Two ways to read them exist:

- a pure-Swift PDF parser (portable, but a large, dangerous surface to
  write from scratch — PDF content streams, font encodings, and repair
  rules are a long tail where a wrong parse silently produces wrong
  index text);
- Apple's PDFKit, which is correct, maintained, and free, but macOS-only
  — while `AGENTS.md` requires core packages to build and test on Linux.

## Decision

PDF attachment text is extracted with PDFKit, isolated in a new
macOS-only SwiftPM target `ArchiveExtractApple` (product
`ArchiveExtractApple`, test target `ArchiveExtractAppleTests`). Later
Apple-framework extractors (Vision OCR) join the same target.

- `Package.swift` defines the target only under `#if os(macOS)`;
  `ArchiveCore` gains `ArchiveExtractApple` as a dependency only on
  macOS, and every call site is guarded by
  `#if canImport(ArchiveExtractApple)`. The Linux build never
  references the target and behaves exactly as before (no PDF text,
  attachment row still lists the part).
- The entry point is `PDFText` with `text(_:) -> String?` (joined page
  text) and `pages(_:) -> [String]?` (per-page text, in document order,
  for later page attribution — DESIGN 6A "matched in invoice.pdf,
  page 2").
- Strictness mirrors the ZIP reader contract (0036): input over the
  attachment budget (24 MB) is refused; a document PDFKit cannot open
  yields nil; a document with no extractable text at all (image-only
  scan until OCR) yields nil, so the index stores nothing rather than
  an empty or misleading row. Accumulated text is capped so a crafted
  document cannot balloon an index row.
- `MailBridge.extractAttachmentText` adds a `pdfAttachmentText` branch
  (MIME type `application/pdf` first, `.pdf` filename extension as the
  fallback for broken MIME parts), before the container branch — PDFs
  are not ZIP containers.
- `TextIndexVersion` bumps v8 → v9: the backfill re-indexes older rows
  from their stored bytes to add PDF text, never rewriting stored
  files.

## Consequences

- macOS users get searchable PDF attachment text; Linux CI and any
  Linux build of the core packages keep compiling and passing with no
  behavior change.
- The extractor is only as strict as PDFKit: a file PDFKit repairs and
  reads is treated as readable. We accept this for PDFs (read-only
  text extraction; the stored bytes are never touched), unlike ZIP,
  where a wrong parse could silently hand the index wrong bytes from a
  hostile container.
- Page attribution ("matched in ..., page N") can be built later on
  `PDFText.pages` without re-reading the file.
- Vision OCR for scanned PDFs and images joins `ArchiveExtractApple`
  later (decision to be recorded when implemented).

## Tests

- `Tests/ArchiveExtractAppleTests/PDFExtractTests.swift` (macOS-only):
  hand-built minimal PDF 1.4 fixtures with correct xref offsets;
  two-page text extraction in order, per-page exposure, nil for
  garbage bytes, nil for truncated input, nil for an image-only page,
  refusal over the input cap.
- `Tests/ArchiveCoreTests/ContainerAttachmentTests.swift` (PDF tests
  under `#if canImport(ArchiveExtractApple)`): MIME and filename-
  fallback wiring through `MailBridge.parse`, and the v9 backfill
  restoring PDF text from stored bytes.
