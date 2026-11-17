/// Agent access (DESIGN 9A): a local, read-only MCP server over the same engine the
/// app uses (decision 0008). A stdio helper inside the app bundle by default, an
/// optional loopback-only HTTP transport; per-client exposure, redaction, limits, and
/// an activity log. Every returned body, subject, and attachment text is wrapped and
/// labelled as untrusted content, because email is the classic prompt-injection channel.
///
/// Implemented in M3.
public enum ArchiveMCP {}
