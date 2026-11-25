# Spike: local Stalwart 1.2.0 for JMAP (2026-11-25)

Goal: prove the M6 Done-when "JMAP full and incremental sync pass against local
Stalwart" is reachable locally. Probe of stalwart 1.2.0 (macOS aarch64 release
tarball, binary alone, no config file).

## What works in 1.2.0 (vs the parked 1.1.1)

- `./stalwart` with no config starts in bootstrap mode on the HTTP recovery
  listener (`*:8080`, IPv4 is taken by another process; IPv6 `[::1]` reaches
  Stalwart). `STALWART_RECOVERY_ADMIN=admin:<password>` sets the bootstrap
  admin password at first start.
- `/jmap/session` works over Basic auth and Bearer tokens; primary account id
  is short-form (`d333333`); mailboxes Inbox/Trash/Junk/Drafts/Sent pre-created
  (`a`..`e`).
- Verified method calls: `Core/echo`, `Mailbox/query`, `Mailbox/get`,
  `Email/query` (filter `inMailbox`, position/limit), `Email/get`
  (`bodyValues` with `fetchTextBodyValues`, `blobId`, `receivedAt`),
  `Email/import`, `Email/set` (destroy), `Email/changes`,
  `Email/queryChanges` (`removed`/`added`, `calculateTotal`).
- State strings advance on every mutation (`sae` → `sai` → `sam` → `saq`);
  `Email/changes` returns created/destroyed ids; `queryChanges` returns
  removed/added per query state. This is exactly the full+incremental shape
  the engine needs.
- Blob download: `GET /jmap/download/{accountId}/{blobId}/{name}` returns the
  uploaded bytes byte-for-byte (sha256 checked on both seeds) — the raw
  original-message path the archive stores from.
- Error shapes: unknown capability → HTTP 400 `urn:ietf:params:jmap:error:unknownCapability`;
  unknown method → per-call `error/unknownMethod`; malformed JSON → HTTP 400
  `notJSON`; missing/invalid token → HTTP 401. Unknown `accountId` does NOT
  error: it answers with an empty list and a fresh queryState (see quirks).
- OAuth: `/.well-known/oauth-authorization-server` exposes the new login UI
  flow. Dynamic client registration (`POST /auth/register`, token_endpoint_auth
  `none`) + PKCE (S256) + scopes `urn:ietf:params:oauth:scope:full` (mail-scope
  was rejected for the registered client) → `authorization_code` grant through
  `/api/auth` (`authCode` → `consentRequired` + token → `authConsent` → redirect
  with code) → `POST /auth/token` → access token → JMAP session works.
  Grants: authorization_code, refresh_token, device_code. No client_credentials,
  no password grant.

## Quirks (fixtures for the client's quirk replay)

1. `Email/import` with an inline base64 `blobId` is rejected ("Invalid blob
   id"); upload via `POST /jmap/upload/{accountId}` first, then import the
   returned blobId.
2. `Email/query` `sort` is `unsupportedSort` (at least for subject); paging by
   position/limit and state-string advancement is the portable sync shape.
3. Unknown accountId: empty list + fresh queryState, no error — validate the
   accountId from the session doc before first use.
4. Bootstrap mode creates no IMAP/SMTP listeners; JMAP only. Capability-table
   IMAP rows stay from the parked 1.1.1 probe (marked ?) until a maintainer
   run or a full-config bring-up.

## Capability table row (JMAP, observed locally)

| Server | jmap:mail | Email/changes | queryChanges | blob download exact |
| --- | --- | --- | --- | --- |
| Stalwart 1.2.0 (bootstrap) | ✓ | ✓ | ✓ | ✓ sha256-equal |

Decision 0066 records the resulting client/server choices.
