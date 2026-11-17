# 0001: Archive Format

Status: Accepted, 2026-11-16

## Context

The archive may be someone's only copy of their mail, must outlive the app, and must be readable by other tools.

## Decision

Store each message's original bytes as one `.eml` file named by its SHA-256, sharded by the first two byte pairs, and never rewrite it. Keep everything else (accounts, folders, labels, flags, threads, search) in a SQLite index accessed through GRDB, in WAL mode, rebuildable from the files plus a small sync-state table. Document the format in `docs/ARCHIVE-FORMAT.md`.

## Consequences

Duplicates across accounts and imports cost nothing, and a scrub can verify every file against its name. The index can be rebuilt after corruption or a schema change. Encrypted archives (1.1) need a keyed hash instead of a plain one so names don't reveal known messages.
