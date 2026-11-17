/// Encryption at rest (DESIGN 10): the 1.1 per-message envelope (AES-256-GCM with
/// HKDF-SHA256 key derivation, CryptoKit) and the SQLCipher glue for the index, with
/// published test vectors. 1.0 relies on FileVault. Not used until M9 at the earliest.
public enum ArchiveCrypto {}
