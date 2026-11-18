# 0013 — SQLite Layer: GRDB

**Date:** 2026-11-17
**Status:** accepted

## Context

The archive index (DESIGN 6) is SQLite in WAL mode: accounts, mailboxes, messages,
memberships, labels, threads, addresses, attachments, and the FTS5 search tables
(DESIGN 6A). The app needs migrations that are versioned and tested, prepared
statements, transactions that group ingest work, and read-only opens for the MCP
helper. The core packages must build and test on Linux as well as macOS, and FTS5
must be available in both.

The M0 FTS5 spike used the Darwin SDK's `SQLite3` module directly, which is
macOS-only; Linux has no equivalent module surface with the same guarantees.

## Decision

Use [GRDB.swift](https://github.com/groue/GRDB.swift) 7.12.0 (exact pin, MIT) as the
SQLite layer in `ArchiveCore` and `ArchiveSearch`.

- GRDB is the maintained Swift SQLite toolkit, MIT-licensed, with first-class Linux
  support: on Linux it compiles its own bundled SQLite with FTS5 enabled, so search
  code runs identically on both platforms. On macOS it uses the system libsqlite3.
- Migrations use GRDB's `DatabaseMigrator`, which records applied migrations in the
  database and is testable against databases made by earlier versions.
- WAL mode, foreign keys, and busy timeout are set by GRDB configuration at open.
- The MCP helper opens the same file with `readOnly` set, in WAL mode, so it never
  writes and never blocks sync.

## Consequences

- One more pinned dependency; it is vendored by SwiftPM resolution, MIT-licensed.
- The Darwin-only `SQLite3` module stays out of product code; it remains acceptable
  in M0 spikes only.
- Raw FTS5 SQL (MATCH queries, bm25, snippet, trigram tables) is issued through
  GRDB's SQL escape hatch (`try DatabaseQueue.read { ... }`), which passes strings
  straight to SQLite; nothing in GRDB prevents FTS5 use.
- GRDB 7 requires Swift 6 tools and is Sendable-annotated, matching the repository's
  Swift 6 strict-concurrency rule.
