# Decision 0066: JMAP over URLSession with an upload-then-import seeding path

## Context

M6 needs a JMAP client (DESIGN 5: Fastmail first, then any JMAP server such as
Stalwart) and the Done-when line "JMAP full and incremental sync pass against
local Stalwart". The M0 IMAP spike parked Stalwart 1.1.1: the released binary
served neither the management API its docs describe nor any way to seed mail
headlessly. A probe of the fresh 1.2.0 release (2026-11-23) changed the picture.

## Decision

1. **Stalwart 1.2.0 is the local JMAP test server.** It starts from the release
   binary alone, serves the JMAP surface over HTTP on the recovery listener
   (bootstrap mode, `[::1]:8080`), and accepts `Email/import` after an upload
   round-trip — enough to run full and incremental sync tests without a config
   file. The 1.1.1 parking in the IMAP spike stays as history; the capability
   table's Stalwart row moves from "?" to JMAP-specific findings.
2. **The client is our own small JMAP layer over URLSession** (as DESIGN 5
   already reads), not a dependency. It is built against the RFC shapes plus
   Stalwart's observed behavior, with Fastmail quirks handled by the same
   seam-tests that hold Stalwart in replay.
3. **Seeding and fetching both route through the server's upload/download
   endpoints.** Observed: `Email/import` with an inline base64 blobId is
   rejected ("Invalid blob id"); `POST /jmap/upload/{accountId}` then
   referencing the returned `blobId` works. Blob download returns the original
   bytes byte-for-byte (sha256-verified), which is what the archive's
   original-bytes guarantee rides on.
4. **Sync relies on state strings, not server sort.** Stalwart 1.2.0 rejects
   most `Email/query` `sort` values with `unsupportedSort`; the engine pages
   with `position`/`limit` and advances via `Email/changes` and
   `Email/queryChanges` state strings, which both work.
5. **An unknown accountId answers with an empty list and a fresh queryState,
   not an error.** The client validates the accountId from the session document
   before first use and treats a not-found account as a configuration error
   rather than an empty mailbox.

## Consequences

- The M6 Done-when "JMAP full and incremental sync pass against local
  Stalwart" is exercisable locally in CI, no maintainer step needed.
- The probe quirks (no inline blobId import, no sort, lenient accountId) become
  quirk-replay fixtures so the client is exercised against recorded behavior.
- OAuth for Stalwart exists (dynamic client registration + PKCE, URN scopes,
  grants: authorization_code/refresh_token/device_code) and differs from
  Fastmail's `mail.jmap.read` scope form; provider-specific scope strings stay
  in `OAuthProviders` per decision 0064.
- The bootstrap server has no IMAP/SMTP listeners, so Stalwart IMAP capability
  rows remain parked/pending maintainer runs; nothing M6 needs is blocked.
