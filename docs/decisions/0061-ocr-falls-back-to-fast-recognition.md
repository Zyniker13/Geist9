# Decision 0061: OCR falls back to fast recognition when accurate yields nothing

**Date:** 2026-11-22
**Status:** Accepted

## Context

Vision's accurate-level text recognition (`VNRecognizeTextRequest` with
`recognitionLevel = .accurate`) can fail machine-wide: on a host whose
Neural Engine compute path is unavailable, every accurate call throws
(`e5rtError: precompiled_compute_operation_create failed`) or returns
zero observations, while the same image recognizes fine at
`.recognitionLevel = .fast`. The extractor mapped any such failure to
nil, and the queue stored `noText` — so on such a host every scanned
attachment silently indexed with no text, and the OCR tests failed with
"expected non-nil value of type String".

## Decision

`OCRText.text` and the PDF page-OCR path attempt recognition levels in
order — `.accurate` first, then `.fast` — and return the first level
that yields text. A thrown error, a timeout, or zero observations moves
to the next level; exhausting the list yields nil exactly as before
(input that is genuinely not an image, or genuinely blank). The seam is
an internal `withLevels(_:data:)` used by the regression test to pin the
fallback behavior deterministically.

## Consequences

- A host with a broken accurate-level pipeline still indexes scanned
  mail (fast-level quality on the fixtures is equivalent for short
  rendered text; complex pages lose some fidelity rather than all text).
- No extra latency on healthy hosts: the fast attempt runs only after
  the accurate attempt already failed or returned nothing.
- The existing wall-clock bound applies per attempt; a wedged accurate
  call costs at most one `recognitionTimeout` before falling back.
