# 0040 — Vision OCR for image attachments

**Date:** 2026-11-19
**Status:** Accepted

## Context

PDF attachments with no text layer (scanned documents) and image attachments
(png, jpeg, tiff, bmp, webp, heic, heif) carry information that must be
searchable. PDFKit can extract text from text-bearing PDFs, but it cannot
extract text from images. macOS provides Apple Vision for on-device OCR.

## Decision

- Use `VNRecognizeTextRequest` (Vision framework) for OCR of image attachments
  and image-only PDF pages.
- Create `OCRText` public enum in the macOS-only `ArchiveExtractApple` target,
  mirroring the `PDFText` API shape (`text(_:)`, `pages(_:)`, `pdfText(_:)`).
- `OCRText.text(_:)` — single image (CGImage) → recognized text.
- `OCRText.pages(_:)` — PDF document, per-page: PDFKit text if available,
  else render page to bitmap and OCR.
- `OCRText.pdfText(_:)` — joins page results for the attachment column.
- Wire `OCRText` into `MailBridge` via `#if canImport(ArchiveExtractApple)`:
  - `imageAttachmentText(main:filename:data:)` dispatches image MIME types
    and extensions to `OCRText.text`.
  - `pdfAttachmentText` falls through to `OCRText.pdfText` when PDFKit finds
    no text layer.
- Image MIME types handled: `image/png`, `image/jpeg`, `image/tiff`,
  `image/bmp`, `image/webp`. Extensions: png, jpg, jpeg, tiff, tif, bmp,
  webp, heic, heif.
- PDF page rendering at 2.5x scale (~180 DPI) for good OCR accuracy.
- `TextIndexVersion` bumps v9 → v10 (M2.4).

## Consequences

- Vision OCR is macOS-only; the Linux build continues to return nil for
  image attachments.
- First Vision call loads the recognition model (~15 s); subsequent calls are
  fast. Test fixture count kept small.
- Image-based PDF pages (created via `PDFPage(image:)`) have a top-left
  mediaBox origin and render correctly without coordinate flip. Standard
  scanned PDFs (bottom-left origin) may need flip handling in a future
  refinement.
- The attachment column now includes OCR text for image attachments,
  improving search recall for scanned documents and image-based emails.
