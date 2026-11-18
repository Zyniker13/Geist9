# 0009 — OCR Engine

**Date:** 2026-11-17
**Status:** accepted

## Context

The app needs to extract text from image attachments (scanned documents, photos of documents, PDF pages rendered as images). We need an on-device OCR engine that is fast, accurate, and supports the app's target languages.

## Options Evaluated

| Engine | Latency (single line) | Latency (20-line page) | Accuracy (clean) | Accuracy (noisy) | Multilingual | On-device |
|--------|----------------------|------------------------|------------------|-------------------|--------------|-----------|
| Apple Vision (`VNRecognizeTextRequest`) | ~100-600 ms (first run ~15 s model load) | ~192 ms | 100% | 100% | English, Chinese, Japanese, Korean (with language config) | Yes |
| Tesseract (pytesseract) | ~76-164 ms | ~418 ms | 100% | 100% | 100+ languages | Yes |

Tests ran on synthetic Helvetica images (clean, noisy at 5% pixel noise, 20-line page) on Apple silicon.

## Decision

**Use Apple Vision framework** (`VNRecognizeTextRequest`) as the primary OCR engine.

### Rationale

1. **Native and on-device.** Vision is part of macOS/iOS, requires no external dependencies, and runs entirely on-device (no network, no privacy concerns).
2. **Good accuracy.** 100% on clean and noisy synthetic images; Vision's text recognition is mature and well-integrated with the platform.
3. **Competitive speed.** After the one-time model load (~15 s on first invocation, then cached), Vision is faster than Tesseract on page-sized images (192 ms vs 418 ms). For single-line images, Tesseract is faster but the difference is negligible (< 100 ms).
4. **No external dependencies.** Tesseract requires `libtesseract` and `leptonica` as system dependencies, adding complexity to the build and distribution. Vision requires nothing beyond the standard macOS SDK.
5. **Language support.** Vision supports the app's target languages (English, Chinese, Japanese, Korean) via `VNTextRecognitionLanguage` configuration.

### Consequences

- **First-run latency.** The first invocation on a device will have a ~15 s model-load penalty. Mitigation: preload the model at app launch or during onboarding, cache it, and show a progress indicator.
- **CJK on synthetic fonts.** Vision struggled with Chinese text rendered via PIL's font system in testing. Real-world scanned Chinese documents (not synthetic) need validation. The app should test with actual scanned fixtures.
- **No Tesseract fallback in M0.** If Vision proves insufficient for CJK in real-world testing, Tesseract can be added as a fallback in M1+.
- **PDF handling.** For PDF attachments, render pages to images at 150-300 DPI before OCR. The FTS5 spike already handles text extraction from PDFs via native PDF parsing; OCR is for scanned/inline images only.
