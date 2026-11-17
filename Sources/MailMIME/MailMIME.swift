/// RFC 5322/2045–2049 MIME parsing: headers, structure, transfer encodings, charsets,
/// encoded words, RFC 2231 parameters, and threading (DESIGN 7).
///
/// The hardest code in the app after sync. Real mail breaks every rule, and the archive
/// must never lose bytes because of it: parsing feeds the index and the viewer, and the
/// original `.eml` bytes stay untouched whatever the parser makes of them.
///
/// Implemented in M1. The parser is streaming (a message can be many megabytes),
/// tolerant of real-world breakage, and corpus- and fuzz-tested from day one.
public enum MailMIME {}
