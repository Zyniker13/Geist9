# 0057 — Deletion tracking by the server's live UID set

## Context

The sync engine must record when a message disappears from the server (DESIGN 5 step 6)
without ever deleting it from the archive. The first implementation marked memberships
"not seen this pass" by a `lastSeen` timestamp cutoff taken at the start of the pass.
That rule is wrong for incremental syncs: a folder's membership is only refreshed for
messages the pass actually fetched, so a message sitting below the checkpoint is not
touched, fails the cutoff test, and is wrongly marked as gone from the server.

## Decision

A membership is "gone from the server" only when the server itself says so:

1. **Per folder present in the LIST response:** after SELECT, the engine runs
   `UID SEARCH ALL` and passes the live UID set to the store
   (`markMembershipsAbsentFrom`). Any live membership in that folder whose `uid`
   is not in the set is marked `removedFromServer = 1`. Messages above the
   checkpoint survive because their UIDs are in the set whether or not they were
   fetched this pass.
2. **Folders that vanished from the LIST response:** the store
   (`markMembershipsInVanishedFolders`) marks every remaining live membership of
   the account's mailboxes that the pass's LIST did not name.
3. **Fail-safe on missing data:** if a server refuses `UID SEARCH` (NO/BAD reply),
   the engine skips deletion marking for that folder this pass — an unknown set
   never marks anything.

The generic `markUnseenMemberships` (lastSeen cutoff) store API remains for direct
callers; the engine no longer uses it.

## Consequences

- The deletion rule can no longer mark a message gone just because its folder was
  not re-fetched; the regression test `testDeletionTrackingMarksUnseenMembershipsAcrossPass`
  pins the case (message below the checkpoint stays live, message the server dropped
  is marked).
- One extra `UID SEARCH ALL` per folder per pass: cheap server-side, one round trip.
- The live-UID comparison uses a temporary SQLite table, so folders larger than the
  SQL variable limit are handled.
- Servers without SEARCH keep their mail (nothing marked), matching the priority
  that the archive never loses a message.
