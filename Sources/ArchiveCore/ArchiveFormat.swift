/// The on-disk archive format version. See docs/ARCHIVE-FORMAT.md once it exists (M0).
public enum ArchiveFormat {
    /// Bumped on any change to the file layout or the index schema, together with a migration.
    public static let version = 1

    /// The relative path of a stored message, from its lowercase hex SHA-256: `messages/ab/cd/<hash>.eml`.
    public static func messagePath(forSHA256 hex: String) -> String? {
        let allowed = Set("0123456789abcdef")
        guard hex.count == 64, hex.allSatisfy({ allowed.contains($0) }) else { return nil }
        let a = hex.prefix(2)
        let b = hex.dropFirst(2).prefix(2)
        return "messages/\(a)/\(b)/\(hex).eml"
    }
}
