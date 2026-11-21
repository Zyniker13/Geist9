# 0052 — Read-only archive access for MCP readers

Date: 2026-11-21

## Context

DESIGN 9A: the MCP helper serves an archive to agents. It must never write
to the archive — the archive may be someone's only copy of their mail — and
it must never migrate, because a reader that upgrades the schema out from
under the app (or a second helper) would be a write path in disguise. The
app's `ArchiveStore.open` migrates and creates directories, so it cannot be
used by the helper.

## Decision

`ArchiveStore.openReadOnly(at:)` opens an existing archive for readers:

- the manifest is validated exactly as in `open` (missing manifest →
  `ArchiveError.notAnArchive`);
- the index is opened through GRDB's `Configuration.readonly`, so SQLite
  itself refuses any write; no writer ever runs while a helper is up;
- the reader checks `grdb_migrations` against the current build's migration
  count (`IndexSchema.migrationTargetCount`) and throws
  `ArchiveError.schemaBehind(applied:target:)` instead of migrating. The
  person opens the archive in the app once so it upgrades, then agents can
  read it;
- no directories are created, no files are touched. SQLite may attach a
  `-shm` sidecar (shared-memory cache) when it opens a WAL database
  read-only; that is cache, not data, and the untouched-archive tests
  allow-list it.

The helper (`MCPHelper`) and any script that reads an archive use
`openReadOnly`; only the app uses `open`.

## Consequences

- A helper pointed at an archive from an older app build fails fast with a
  clear error instead of silently serving a stale schema or upgrading it.
- `openReadOnly` returns a plain `ArchiveStore`, so the MCP layer uses the
  same query API as the app — one code path for reads, and the read-only
  guarantee lives in the database layer, not in discipline.
- Tests (`Tests/ArchiveCoreTests/ReadOnlyTests.swift`) prove: reads work,
  writes throw at the SQLite layer, a schema-behind archive is refused
  without touching the directory, and non-archive directories are refused.
