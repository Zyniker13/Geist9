# 0056: Sync-State Persistence

Date: 2026-11-21

## Context

The sync engine (M4 task 3) must be resumable and must never re-fetch or
skip a folder incorrectly (DESIGN 5). Two facts drive where its state lives:

- The index is disposable by design — a rebuild regenerates it from the
  `.eml` files. The one thing that cannot be regenerated from the stored
  bytes is the per-mailbox high-water mark: which UIDs have already been
  fetched and stored, and under which UIDVALIDITY.
- A killed sync must resume from its last completed checkpoint, and a
  server-side UIDVALIDITY change must reset the high-water UID to zero so a
  folder is re-fetched from the start rather than skipped (DESIGN 5 step 3).

Storing that checkpoint in the index is the only place it survives a rebuild
without touching the stored message bytes, and it keeps the sync engine's
state out of the content-addressed store entirely.

## Decision

Add a `sync_state` table (index migration `core-v16`) keyed by
`(accountID, mailboxID)`, holding one JSON checkpoint per mailbox:
`uidValidity`, `highestUID`, `highestModSeq` (nil when the server lacks
CONDSTORE), and `updatedAt`. The engine reads it before opening a folder and
writes it after each batch.

The checkpoint is stored as a JSON document in a single column rather than
separate columns, so adding a field to `SyncState` is a code change, not a
schema migration, and a corrupt document is detected on read (thrown as
`ArchiveError.corruptLayout`, never silently dropped). The account and
mailbox rows are created on demand when a checkpoint is first written, so a
folder that holds no new messages still records its checkpoint. `version`
stays 13: the on-disk file layout is unchanged, and the migration only adds
an index table.

## Consequences

A sync is resumable and idempotent: re-opening a folder after a crash
continues from the last stored UID, and a UIDVALIDITY change forces a clean
re-fetch. Because the checkpoint lives in the index, a rebuild preserves it
(the rebuild drops and recreates the FTS and entity tables but keeps
`sync_state`), so a person who rebuilds the index does not re-download their
mail. The trade-off is that the index must be treated as the source of truth
for sync progress — deleting the index file resets every mailbox to a fresh
full sync, which is the correct, safe behavior (a full re-fetch re-stores
identical bytes and never loses a message).
