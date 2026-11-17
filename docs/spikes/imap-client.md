# Spike: swift-nio-imap against local test servers

M0 spike (ROADMAP M0). Question: does swift-nio-imap 0.5.0 drive the IMAP
operations the sync engine needs, against the servers we test with, and what
do those servers actually support? The client library was already chosen in
[decision 0002](../decisions/0002-protocol-and-mime.md); this spike confirms
the choice and fills the Dovecot, GreenMail, and Stalwart rows of the
capability table in [PROVIDERS.md](../PROVIDERS.md).

## Setup

- Spike driver: `Spikes/IMAPSpike/main.swift` (throwaway, not part of the
  product targets). Runs one sequence per server: greeting, CAPABILITY,
  LOGIN, ID, LIST, ENABLE QRESYNC (only when advertised), SELECT INBOX
  (with a QRESYNC parameter when enabled), APPEND, UID FETCH
  (ENVELOPE, UID, RFC822.SIZE), UID SEARCH ALL, UID FETCH `BODY.PEEK[]`
  streamed to files on disk, IDLE, LOGOUT. Exits 0 only when every step that
  ran passed.
- Servers: GreenMail 2.1.3 standalone (`127.0.0.1:3143`) and Dovecot 2.4.5
  (`127.0.0.1:11143`), both unprivileged from a scratch folder. Passwords for
  local test users live only in the untracked scratch configuration.

## Results (2026-11-17)

GreenMail: 11 passed, 2 skipped, 0 failed.
Dovecot: 12 passed, 1 skipped, 0 failed.

| Step | GreenMail | Dovecot |
| --- | --- | --- |
| greeting, login, list, append, fetch, search, idle, logout | pass | pass |
| capability | IDLE IMAP4rev1 LITERAL+ MOVE QUOTA SORT UIDPLUS | AUTH=LOGIN AUTH=PLAIN ENABLE ID IDLE IMAP4rev1 LITERAL+ LOGIN-REFERRALS SASL-IR |
| ID | skipped — replies `BAD: Invalid command.` and the connection stays up | pass — `name=Dovecot` |
| ENABLE/SELECT QRESYNC | skipped — not advertised | skipped — not advertised |
| UID FETCH `BODY.PEEK[]` to disk | 7 messages streamed; counts match `streamingBegin`; appended message byte-identical | 4 messages streamed; streamed size equals `RFC822.SIZE`; appended message byte-identical |

## Findings

1. **The library handles all the core operations on both servers.** Connect,
   capability, login, list, select, append, uid fetch (envelope, uid, size),
   uid search, body streaming to disk, idle, and logout all work unchanged
   across a Java server and a C server. The response model (`simpleAttribute`
   vs `streamingBegin/Bytes/End`) is clean enough for the sync engine to
   write straight to disk.
2. **Line endings are rewritten by servers.** Appending a bare-LF message
   came back CRLF-normalized from both servers. The appended CRLF message
   round-tripped byte-identically. Consequence for the product: Restore (the
   only write path) must APPEND with CRLF, and the archive must store the
   bytes as fetched, never as re-encoded locally.
3. **ID is not universal.** GreenMail rejects RFC 2971 `ID` with a tagged
   BAD and keeps the connection. The sync engine should send ID once after
   login (163 requires it), and treat a NO/BAD reply as "extension not
   supported", not as a connection error.
4. **QRESYNC is not available on either current test server.** GreenMail
   never advertises it; brew's Dovecot 2.4.5 build lacks CONDSTORE/QRESYNC
   (`imap_condstore` is an unknown setting in this build). The
   `QResyncParameter` SELECT path is therefore verified only at the library
   level (upstream tests) for now. Stalwart — a QRESYNC server — is the
   intended live check; its bring-up is parked (next section). iCloud
   CONDSTORE/QRESYNC verification stays with the live-account checks in M4.
5. **GreenMail did not return RFC822.SIZE** for a fetch of
   `(ENVELOPE UID RFC822.SIZE)`; Dovecot did. The sync engine must treat
   size as advisory and take the real byte count from the streamed fetch
   (`streamingBegin` byteCount), which both servers provided correctly.

## Stalwart: parked

The plan was a third run against Stalwart. v1.1.1 (the current release) was
downloaded and runs, but the server config moved into a SQLite-backed store
configured over a management API, and the released CLI/server pair does not
serve the API surface its own current documentation and CLI describe:

- The binary accepts only a JSON store descriptor (`-c config.json`); the
  TOML form used by earlier versions is rejected ("expected value at line 1
  column 1").
- With no listeners configured it starts in bootstrap mode and creates the
  default listener set on ports 25/465/993/995/4190/443/8080; the management
  API paths used by `stalwart-cli` 2.0.0 and 1.0.14 (`/api/schema`) return
  404 with a JSON error, so accounts and an IMAP listener cannot be created
  headlessly against this build.
- The current stalw.art docs (updated the day of this spike) describe the
  object-model API (`x:NetworkListener/set`, plan files, `apply`); the
  released server evidently predates it.

Stalwart stays downloaded and the recipe attempt is recorded here. Revisit
when a server release matches the documented API, or drive it through the
web UI by hand if it becomes blocking. The IMAP client decision does not
depend on it: two heterogeneous servers already agree, and Stalwart's row in
the capability table is filled from this spike's findings until then.

## Capability table rows (observed locally, not real providers)

| Provider | CONDSTORE | QRESYNC | OBJECTID | COMPRESS | IDLE | SPECIAL-USE | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Dovecot (brew 2.4.5 build) | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | Extensions absent from this build, not from Dovecot generally |
| GreenMail 2.1.3 | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | No ID; MOVE/SORT/UIDPLUS present |
| Stalwart 1.1.1 | ? | ? | ? | ? | ? | ? | Bring-up parked, see above |

Live-provider rows remain "Needs the Maintainer" (real accounts, M4).
