import Foundation
import PDFKit

/// PDF attachment text through PDFKit (DESIGN 6A, decision 0039). Apple-only:
/// this target is macOS-only in Package.swift and ArchiveCore reaches it
/// under `#if canImport(ArchiveExtractApple)`.
///
/// Strictness mirrors the ZIP reader's contract: a document the framework
/// cannot open, or one with no extractable text at all, must yield nil so
/// the caller stores nothing rather than an empty or misleading index row.
/// Page order is preserved (and exposed via `pages`) so a later milestone
/// can attribute text to page numbers without re-reading the file.
public enum PDFText {

    /// Refuses inputs larger than the attachment budget before handing
    /// bytes to the framework (same ceiling as ZIP.Limits.attachments).
    public static let maxInputBytes = 24_000_000

    /// Caps accumulated text so a crafted document cannot balloon the
    /// index row beyond the pipeline's own attachment-text cap.
    public static let maxOutputCharacters = 1_000_000

    /// Text per page, in document order; nil when the document cannot be
    /// opened. Empty strings are kept so page numbering stays aligned.
    public static func pages(_ data: Data) -> [String]? {
        guard data.count <= maxInputBytes else { return nil }
        guard let document = PDFDocument(data: data) else { return nil }
        var texts: [String] = []
        var total = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                texts.append("")
                continue
            }
            var pageText = page.string ?? ""
            if pageText.count > maxOutputCharacters - total {
                pageText = String(pageText.prefix(maxOutputCharacters - total))
            }
            total += pageText.count
            texts.append(pageText)
            if total >= maxOutputCharacters { break }
        }
        return texts
    }

    /// Joined page text in document order; nil when the document cannot be
    /// opened or no page has extractable text (e.g. an image-only scan).
    public static func text(_ data: Data) -> String? {
        guard let texts = pages(data) else { return nil }
        let joined = texts.joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : joined
    }
}
