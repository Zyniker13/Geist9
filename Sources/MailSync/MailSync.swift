/// Sync engine: the IMAP algorithm, JMAP, politeness profiles, and the provider
/// database (DESIGN 5). Read-only toward every server: sync never sets flags, deletes,
/// moves, or appends (DESIGN 1, goal 4). Only the explicit Restore feature writes.
///
/// IMAP uses Apple's swift-nio-imap (decision 0002), wrapped by our own engine so a
/// hostile or quirky server can never confuse the archive. Implemented in M4–M6;
/// the M0 spikes validate the library against local Dovecot, GreenMail, and Stalwart.
public enum MailSync {}
