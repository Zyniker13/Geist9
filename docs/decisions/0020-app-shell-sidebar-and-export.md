# 0020 — App shell: sidebar semantics, saved searches, Quick Look, whole-archive export

Date: 2026-11-18

## Context

The M1 app shell (DESIGN 12) needs a sidebar with more than mailboxes,
saved searches, an attachment open path, and whole-archive export. The
query language already supports `label:"…"` and `account:"…"` operators
(decision 0018), and the index already stores per-mailbox, per-label, and
per-account message counts. DESIGN 8 says attachments should be previewed
without executing them; DESIGN 9 says export is a read-only operation on
the archive.

## Decision

1. **Sidebar rows are live searches, not filters.** Clicking a mailbox
   selects it (existing behavior). Clicking a label runs
   `label:"<name>"` and clicking an account runs `account:"<email>"` as
   the search query, so the result list is a normal live search: new mail
   carrying the label or from the account appears in the next search, and
   the row highlights only while that exact query is active. The query
   strings are built by one shared helper (`ArchiveModel.queryForLabel` /
   `queryForAccount`) so the highlight comparison and the executed query
   can never drift apart.
2. **Saved searches are stored named queries (DESIGN 12).** A new index
   schema version (core-v4) adds a `saved_search` table
   (`id`, `name` UNIQUE, `query`, `createdAt`). Saving stores the current
   query text verbatim; opening a saved search runs that query live —
   saved searches never pin results and never touch message rows. The
   index schema version is independent of the archive manifest version
   (decision recorded with core-v4): the manifest tracks the on-disk file
   layout (stays at 2), the schema tracks the SQLite layout (now 4).
3. **Quick Look is the primary attachment open path (DESIGN 8,
   THREAT-MODEL).** The attachment row's button previews the decoded part
   in a Quick Look panel (SwiftUI `quickLookPreview`), which renders
   without launching an application. "Open in Default Application"
   (the old `NSWorkspace.open` behavior) remains as an explicit
   context-menu choice. Both paths write the part to a unique temporary
   file first; the file carries no quarantine attribute because it came
   from the person's own archive, not a download.
4. **Whole-archive export (DESIGN 9).** The Export menu offers the
   existing per-message formats (EML tree, mbox) plus a "Whole Archive"
   pair. Whole-archive export uses `exportMessages(mailbox: nil)` — the
   same stored-bytes export unit, deduplicated by hash — and runs on a
   detached task because a large archive can take minutes; the UI shows
   an "Exporting…" notice and the result on completion. Export remains
   strictly read-only toward the archive.

## Consequences

- The sidebar can grow (more sections) without new query machinery: any
  row that maps to a query operator is a live search.
- Saved searches are cheap and safe: one row in the index, no result
  cache to invalidate.
- Quick Look keeps the threat model's "no execution on open" stance for
  the default path; the escape hatch is one deliberate click.
- Whole-archive export on a detached task keeps the UI responsive; the
  export itself is unchanged and still refuses non-empty destinations.
- core-v4 is additive (new table only), so existing archives migrate
  forward with no data movement; a migration test covers v3 → v4.
