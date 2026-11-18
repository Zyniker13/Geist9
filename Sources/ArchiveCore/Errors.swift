import Foundation

/// Errors from the archive layer. Every case is recoverable by the caller;
/// none of them silently drops or rewrites stored message bytes.
public enum ArchiveError: Error, Equatable, Sendable {
    /// The archive directory does not look like an archive (no manifest).
    case notAnArchive
    /// manifest.json is unreadable or does not decode.
    case malformedManifest
    /// The archive's format version is newer than this build supports.
    case unsupportedFormatVersion(Int)
    /// A message with the required hash is not in the store.
    case messageNotFound(MessageHash)
    /// Low-level file I/O failure; carries the underlying error's description
    /// so the value stays Equatable and Sendable.
    case io(underlying: String)
    /// An invariant of the archive format was violated (e.g. bad shard path).
    case corruptLayout(String)
    /// A saved search needs a non-empty name.
    case invalidSavedSearchName
    /// A saved search needs a non-empty query.
    case invalidSavedSearchQuery
}
