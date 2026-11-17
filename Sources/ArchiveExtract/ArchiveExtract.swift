/// Attachment text extraction, entity extraction, OCR, and embeddings (DESIGN 6A).
/// Everything runs on the device: nothing is sent anywhere to be indexed.
///
/// Text-bearing extractors (PDF, Office, OpenDocument, iWork preview, iCS, vCard, ZIP
/// names, nested mail) are implemented in M2. On-device OCR (Vision) and embeddings
/// (Core ML) are Apple-only and build behind `#if os(macOS)`; text-only extractors
/// also build on Linux so their tests run in Linux CI.
public enum ArchiveExtract {}
