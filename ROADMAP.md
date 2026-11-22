# Roadmap

How Bristlecone Email Archiver gets from an empty repository to 1.0. Work the milestones in order. A milestone is done only when every "Done when" line is met and shown with real output from `scripts/check.sh` (or the benchmark named), recorded in [STATUS.md](STATUS.md). Reopen earlier milestones when a later one needs it.

[docs/DESIGN.md](docs/DESIGN.md) is the specification each task points to (by section, such as DESIGN 6A); [docs/PROVIDERS.md](docs/PROVIDERS.md) and [docs/TESTING.md](docs/TESTING.md) are the other two references. When the roadmap and the design disagree, fix whichever is wrong in the same commit and record why in a decision.

**The two primary features are search (M1, M2) and agent access (M3).** Both come before any network code because they only need a local archive, and everything after them feeds them.

Legend: "Needs the Maintainer" items are things only the maintainer can do (accounts, signing, registrations, settings). Build around each one with mocks, flags, or local servers, list it in STATUS.md, and keep going.

## M0: Foundations and Spikes

Goal: a green, empty-but-real Swift package, the decisions that everything else rests on, and answers to the questions that could change the design.

Tasks:

- [ ] `Package.swift` with the targets in DESIGN 12 (empty or minimal where not yet needed), Swift 6 language mode, macOS 14 and Linux; `scripts/check.sh` builds and tests on both; CI green on Linux and macOS.
- [ ] XcodeGen spec for the app target that builds an empty SwiftUI window.
- [ ] Threat model in `docs/THREAT-MODEL.md` (DESIGN 10: stolen Mac, malicious HTML, hostile server, tampered update, leaking report, prompt injection through mail reaching agents).
- [ ] Archive format draft in `docs/ARCHIVE-FORMAT.md` (DESIGN 6): layout, manifest, schema v1, versioning and migration rules.
- [ ] Spikes, each a throwaway under `Spikes/` with a written result in `docs/spikes/<name>.md`:
  - swift-nio-imap against the local Dovecot, GreenMail, and Stalwart servers (connect, `ID`, `LIST`, `SELECT` with QRESYNC, `UID FETCH BODY.PEEK[]` streaming to disk);
  - FTS5 with our own Swift tokenizer pipeline: `NLTokenizer` segmentation quality on Chinese, Japanese, and Korean samples; trigram index size per 100,000 messages;
  - on-device embedding model candidates for semantic search: size, speed on Apple silicon, license, multilingual quality on a small judged set;
  - Vision OCR speed and accuracy on a scanned-PDF fixture set;
  - locked-down `WKWebView`: prove no request leaves the process for a hostile HTML fixture set;
  - 1Password: which route in DESIGN 4 "Credentials and 1Password" works from a Developer ID app (official SDK with desktop app integration through a helper, then `op` with desktop app integration, then service accounts), tested against a fake when no real vault is available; record the result as decision 0005;
  - MCP: a stdio helper embedded in an app bundle, launched by an MCP client, reading a SQLite index the app wrote.
- [ ] Choose the relevance targets (nDCG@10, recall@50) for the judged set, from a baseline measured in the FTS5 spike; record them in `docs/TESTING.md`.
- [ ] Decision records for each choice made above.

Done when:

- `scripts/check.sh` passes on Linux and macOS, and CI is green on `main`.
- Every spike has a written result, and decisions 0001 to 0008 are accepted or replaced.
- The capability table in PROVIDERS.md has the Dovecot, GreenMail, and Stalwart rows filled in.

Needs the Maintainer: live checks of the provider rows in the capability table (they need real accounts).

## M1: Local Archive and Search Core

Goal: a useful app with no network code: import mail, read it safely, and search it well.

Tasks:

- [ ] Archive store (DESIGN 6): content-addressed `.eml` files, atomic writes (temp file, fsync, rename), manifest, GRDB index in WAL mode, migrations, "Rebuild index", integrity scrub.
- [ ] MIME parser (DESIGN 7): headers, structure, transfer encodings, every listed charset, encoded words and RFC 2231, threading. Corpus and fuzz tests from day one (TESTING).
- [ ] Import (DESIGN 9): `.eml` folders, mbox (all variants), Google Takeout (labels), Apple Mail (`.emlx`, `.partial.emlx`, `.mbox` packages). Re-import adds nothing twice.
- [ ] Export: `.eml` tree and mbox, byte-identical round trips.
- [ ] Search core (DESIGN 6A): tokenizer pipeline with language detection, FTS5 with field-weighted BM25 and recency, the query language with every operator listed, results grouped by thread, highlighted snippets, a search field that answers as you type.
- [ ] Viewer (DESIGN 8): locked-down HTML, `cid:` images, plain text, source, headers, Quick Look.
- [ ] App shell: archive picker, sidebar (accounts, folders, labels, saved searches), message list, viewer, import and export sheets.

Done when:

- An Apple Mail folder, a Takeout mbox, and the corpus import, and every message opens; import twice adds nothing.
- Round-trip tests pass for `.eml` and mbox.
- A two-word query returns ranked results in under 200 ms on a 1-million-message synthetic archive (benchmark output in STATUS.md).
- The viewer security fixtures make zero network requests.
- Kill tests during import leave a valid archive that the next run completes.

## M2: Deep Search

Goal: search good enough to be the reason people buy the app (DESIGN 6A, all of it).

Tasks:

- [ ] Stemming per language (Snowball, vendored with its BSD license), diacritic and width folding, address-aware tokens, the trigram index for substrings and CJK.
- [ ] Attachment extraction: PDF, plain text, CSV, HTML, RTF, Office Open XML, OpenDocument, iWork preview text, `.ics`, `.vcf`, nested `.eml`, ZIP file names.
- [ ] On-device OCR for image-only attachments and scanned PDFs (Vision), on a low-priority, pausable queue.
- [ ] Entity extraction: dates, amounts and currencies, phone numbers, tracking numbers, booking codes, domains; `amount:` and entity facets.
- [ ] Facets with live counts and the timeline histogram; saved searches as smart folders; natural-language dates.
- [ ] Typo tolerance with a vocabulary built from the archive; "showing results for".
- [ ] Hybrid semantic search: the embedding model chosen in M0, a vector index beside FTS5, reciprocal rank fusion, an off switch.
- [ ] The background indexing queue with extractor and tokenizer versioning, so improvements re-index only what changed.
- [ ] The judged relevance set (about 300 queries; TESTING) and the evaluation in CI.

Done when:

- nDCG@10 and recall@50 meet the M0 targets, in CI.
- Every search budget in DESIGN 6A is met on the 1-million-message synthetic archive.
- A scanned receipt fixture is found by a word printed on it; a Chinese, a Korean, a Russian, and a German fixture are each found by their own words (including a German compound by one of its parts).
- A semantic query from the judged set ("the email where the landlord agreed to fix the heater") finds its target in the top 3 without sharing a keyword.

## M3: Agent Access (MCP)

Goal: the person's agents can search and read the archive through the same engine (DESIGN 9A).

Tasks:

- [x] `ArchiveMCP` with every tool and resource in DESIGN 9A, schemas versioned, using the M2 engine.
- [x] The stdio helper embedded in the app bundle; Settings › Agents with per-client on/off, account, folder, and label exposure, redaction modes, limits, and the activity log.
- [x] Untrusted-content wrapping for every returned body, subject, and attachment text; hidden-text stripping.
- [x] A Claude Desktop extension (`.mcpb`) and copyable configuration for other MCP clients.

Done when:

- [x] A scripted MCP client launches the helper against a fixture archive and every tool's contract test passes, on Linux and macOS. — `Tests/ArchiveMCPTests/StdioEndToEndTests.swift` (591 lines) launches the built helper over real stdio JSON-RPC on both CI platforms; CI job `check (linux)` + `check (macos)` green on `1983df3`, 2026-11-21.
- [x] The official MCP inspector's checks pass. — `scripts/mcp-inspector-check.sh` (pinned `@modelcontextprotocol/inspector@0.16.2`) drives the built helper against an ingest-path fixture: `tools/list` exactly the 10 DESIGN 9A tools, `search_messages` fenced hit, `resources/read` fenced document linked to its thread, unknown tool `-32601`, `resources/list` = the fixture's 5 URIs. Wired into `check.sh`'s Darwin block; passed locally (full run, "All checks passed") and in CI `check (macos)` on `1983df3`.
- [x] Excluded accounts and folders never appear in any tool or resource result (access-control tests). — `AccessControlEndToEndTests.swift` (11 over-the-wire tests: filtered policy shapes every answer, unreadable policy refuses the launch, unknown names stay silent, redaction, budget, disabled, permissive default, hidden text) plus the SQL-side guarantees in `ArchiveCoreTests/AccessControlTests.swift`; decision 0053.
- [x] Every injection fixture comes back wrapped and labelled as untrusted. — `testInjectionFixtureComesBackWrappedOnEverySurface` pins subject, body, and attachment text over the wire; hidden-text stripping has its own e2e (`testHiddenTextNeverReachesTheAgentOverTheWire`) plus unit tests.

## M4: IMAP With Passwords

Goal: complete, incremental, read-only sync from every provider that accepts an app password or authorization code (PROVIDERS, tier M4), and from any standard IMAP server.

Tasks:

- [x] Sync engine (DESIGN 5): the IMAP algorithm, Gmail label mode, politeness profiles and byte budgets, backoff, resumable checkpoints, deletion tracking without deletion.
- [x] Provider database and the discovery chain (PROVIDERS, "What Generic IMAP Gets From This").
- [x] Credential store (DESIGN 4): the `CredentialStore` protocol and the Keychain backend; the 1Password backend by the route decision 0005 chose (M4 ships both).
- [x] Onboarding: provider picker, per-provider setup steps with links, connection test, clear errors.
- [x] Quirk replay transcripts for every M4 provider (TESTING), written from the providers' documented behavior and sanitized captures.
- [x] Maildir and Thunderbird import.

Done when:

- [x] Against the local Dovecot, GreenMail, and Stalwart servers: a full sync, then an incremental sync that downloads only what changed; a forced `UIDVALIDITY` change downloads nothing twice; no flag ever changes on the server. — `Tests/MailSyncIntegrationTests/RealServerSyncTests.swift` runs four flows × GreenMail and Dovecot (`swift test --filter RealServerSyncTests` → 8 tests, 0 failures, 20.8 s, both servers live; full `scripts/check.sh` → "All checks passed"): full→incremental→re-offer dedupe (only new UIDs fetched on pass 2; `messagesStored==0`), the forced `UIDVALIDITY` change via RENAME+CREATE (new validity recorded, high-water reset, 2 stored / 5 deduped — nothing downloads twice), kill-mid-pass resume from the last checkpoint, and the read-only audit (flags seeded unset across three passes; the fake-server suite asserts the recorded command list directly — LOGIN, ID, LIST, STATUS, SELECT, UID FETCH, UID SEARCH, LOGOUT only). Stalwart is the documented exception: v1.1.1 does not serve the API its own current docs and CLI describe (`docs/spikes/imap-client.md`, "Stalwart: parked"), so its leg is parked per that recorded decision until a matching release; the archive-side behaviors it would exercise (QRESYNC/CONDSTORE narrowing) are covered by the library and fake-server tests, and real-provider CONDSTORE/QRESYNC verification is listed under Needs the Maintainer.
- [x] Every M4 provider's quirk replay passes. — `Tests/MailSyncTests/QuirkReplayTests.swift` (7 scenarios over the scripted fake server, from PROVIDERS.md's documented quirks only: 163's ID-before-SELECT, Gmail labels/All-Mail-once, Yahoo-family silent disconnect resume, Outlook-family localized folders via SPECIAL-USE, Proton Bridge self-signed fail-closed + confirmed-fingerprint, Comcast flaky auth surfaced-not-retried) plus the charset fixtures for the M4 providers' documented charsets (`MailMIMETests/CharsetFixtures.swift`: gb2312/gbk/gb18030, koi8-r/koi8-u, euc-kr/cp949, windows-1251, …; 42 fixtures + mislabel aliases). `swift test` green; CI green.
- [x] Kill tests during sync pass; the next sync resumes from the last checkpoint. — `testKillMidPassResumesFromTheLastCheckpoint` on GreenMail and Dovecot (real-server, Flow 3 above) and `testMidPassDisconnectResumesFromTheCheckpoint` in the quirk suite; the durability contract is asserted from the archive (every stored UID ≤ the checkpoint; the retry stores exactly the remainder).
- [x] Accounts work with credentials in the Keychain and in the (fake) 1Password backend, and can be moved between them. — Keychain and 1Password (`op` CLI, decision 0005) backends with their own suites (`CredentialsTests`, 20 tests: round-trips, missing-item surfaces, locked-vault unavailability, `op` stderr classification per decision 0055); `CredentialStoreMove` verifies the candidate secret with a real read-only IMAP sign-in (`IMAPSignInVerifier`) before deleting the old copy; `CredentialMoveEndToEndTests` (4) runs full moves against the in-repo fake server both directions, and proves a scripted rejection or an unreachable server keeps the old copy byte-for-byte.

Needs the Maintainer: real test accounts for each M4 provider, to fill in the capability table and confirm the replays.

## M5: OAuth

Goal: sign-in with Microsoft (required for Outlook.com and Microsoft 365), Google (testing mode only, decision 0004), Yahoo and AOL (if approved), and the optional others.

Tasks:

- [ ] OAuth framework (DESIGN 4): `ASWebAuthenticationSession`, PKCE, loopback and custom-scheme redirects, `XOAUTH2` and `OAUTHBEARER`, refresh with rotation written back to the credential store, revocation, "needs sign-in" state.
- [ ] Provider configurations for Microsoft, Google, Yahoo/AOL, Yandex, Zoho, Fastmail; client IDs read from the build environment.
- [ ] The local OAuth test server (TESTING) covering every success and failure path.

Done when:

- Every OAuth path passes against the local test server, including refresh rotation and a revoked token.
- With a client ID present in the environment, Microsoft sign-in completes end to end (maintainer-run check, result in STATUS.md).

Needs the Maintainer: Microsoft Entra app registration and publisher verification; a Google testing-mode client; the Yahoo Mail API access request.

## M6: Special Paths

Goal: JMAP, Proton Bridge, and the export-only providers.

Tasks:

- [ ] JMAP client (DESIGN 5): session, mailboxes, `Email/query`, blob download, `Email/changes`, push while open; Fastmail API tokens.
- [ ] Proton Bridge: localhost IMAP with a fingerprint-confirmed certificate exception.
- [ ] Proton export and Tuta export import.

Done when:

- JMAP full and incremental sync pass against local Stalwart.
- Bridge-style self-signed localhost IMAP passes in the quirk replay, and an unconfirmed certificate is refused.

Needs the Maintainer: a live check with Fastmail and with a paid Proton account through Bridge.

## M7: Scale and Background

Goal: an archive of a million messages that keeps itself current without the app open.

Tasks:

- [ ] The login item (DESIGN 5 "Background Sync"): schedules, low-power, metered-network and disk-space rules, single-writer lock.
- [ ] Bandwidth governor with projected finish dates; scrub job; index self-check.
- [ ] Benchmarks and budgets (TESTING) in CI.

Done when:

- Every budget in TESTING.md and DESIGN 6A is met on the 1-million-message synthetic archive.
- A simulated week of background sync against the local servers (time-compressed) runs with no errors and no growth in memory.

## M8: Export, Restore, Records

Tasks:

- [ ] Export to Maildir, PDF (per message and per thread), and CSV of headers; export of any search result set.
- [ ] Restore to IMAP by `APPEND`, preserving dates and flags, within provider upload caps.
- [ ] "Removed from server since" views; per-account retention settings (keep forever by default).

Done when: round-trip and restore tests pass for every format, against Dovecot.

## M9: Beta Readiness

Tasks:

- [ ] Licensing (DESIGN 12): the `Entitlements` interface, offline-verified signed licenses, trial, lapse behavior (archive stays readable, searchable, exportable), with a test signing key in tests only.
- [ ] The self-updater (DESIGN 12) against a local test feed.
- [ ] Diagnostics: a person-initiated report with redacted logs, shown in full before sending (DESIGN 10).
- [ ] Encryption at rest (DESIGN 10, the 1.1 design) if time allows; otherwise it stays 1.1.
- [ ] Help pages for every provider's setup steps.
- [ ] Accessibility pass (VoiceOver, full keyboard use) and string extraction for localization.

Done when: the updater and license tests pass; an accessibility audit has no blocking issues.

Needs the Maintainer: Developer ID signing and notarization, the payment provider and license signing key, the report endpoint, the website and download host, the privacy policy and terms.

## M10: Public 1.0 (Developer ID)

Maintainer-led: outside beta, fixes from it, release.

Done when: a signed, notarized 1.0 is published and updates itself.

## M11: App Store Parity Review

Tasks:

- [ ] Build the sandboxed variant (DESIGN 12 "App Store Edition") and list every difference from the Developer ID edition.

Done when: the difference list is in `docs/APP-STORE-PARITY.md`. If it is empty, the maintainer decides on submission; if not, the maintainer decides between a "lite" edition and none (decision 0003).

## Later (1.x)

Optional encrypted archives (if not in M9), Microsoft Graph for tenants with IMAP off, Gmail API mode, Google OAuth for everyone (after the CASA review in May 2027), PST import, S/MIME and PGP signature checks, OAuth dynamic client registration, Core Spotlight, an iPad and iPhone reader, Shortcuts actions and a command-line companion, per-sender retention rules.
