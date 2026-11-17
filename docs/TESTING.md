# Testing

How every layer is tested. `scripts/check.sh` runs everything that does not need a real account; CI runs the same script.

The project's priority order: data safety, then security, then correctness, then speed, then features. A test is never skipped or loosened to get CI green.

| Layer | What | Where it runs |
| --- | --- | --- |
| Unit | MIME parser, charset decoding, mbox variants, query parser, provider database, sync state machine, Keychain wrapper (mocked) | Linux and macOS CI |
| Corpus | 2,000+ real-world messages with expected parse results, built from public corpora (Enron, the Apache SpamAssassin public corpus, Mozilla and Dovecot test messages) plus messages we craft for each charset and quirk. No private mail ever goes in the repository | Linux and Mac |
| Fuzz | MIME parser, header decoder, mbox splitter, IMAP response handling at our layer, HTML sanitizer, MCP request parsing | A short smoke run in every CI run; long runs nightly on Linux (libFuzzer via `swift build -sanitize=fuzzer`) |
| Protocol | Sync engine against real servers in containers: Dovecot (with and without CONDSTORE/QRESYNC, with forced `UIDVALIDITY` changes), GreenMail, Stalwart (IMAP and JMAP) | Linux and macOS CI, every push |
| Quirk replay | A scriptable fake IMAP server that replays sanitized transcripts of each provider's behavior: Gmail labels and `X-GM-*`, 163's `ID` requirement, Outlook throttling and localized folders, Yahoo disconnects, Bridge's self-signed certificate | Linux and macOS CI |
| Live canaries | One test account per provider with a seeded mailbox, synced nightly; alerts when a provider changes behavior | Set up by the maintainer after the repository goes private; never in public CI. Until then, the quirk replays stand in |
| Crash safety | Kill the process at random points during sync, import, encryption, and migration; then verify the archive (every file matches its hash, the index matches the files, the next sync resumes) | Linux and Mac |
| Scale | Synthetic archive of 1 million messages / 100 GB: initial index time, search latency, memory ceiling, launch time | Mac, weekly and before releases |
| Viewer security | Fixtures that try every remote-load and script trick (CSS `url()`, `srcset`, `<link>`, SVG, `meta refresh`, `javascript:` links); the test fails on any network request | Mac (XCTest with a local server that records hits) |
| Round trip | Import then export each format, byte-compare; restore to a Dovecot server and compare | Linux and Mac |
| UI | XCUITest for onboarding per provider type, search, viewer, import, export | Mac |
| Migration | Every released archive and index version opened by the new build | Mac and Linux |

Search budgets and the relevance set are in [DESIGN.md](DESIGN.md#search-quality-testing) and enforced from M2. Other budgets enforced in CI from M7: sync parsing at least 200 messages per second on an Apple silicon Mac mini, steady memory under 500 MB during a full sync.


## Local Test Servers

Tests never reach the internet. These run locally, started and stopped by the test harness, with throwaway mailboxes seeded from fixtures:

| Server | Covers | Linux | macOS |
| --- | --- | --- | --- |
| Dovecot | IMAP with and without CONDSTORE/QRESYNC, forced `UIDVALIDITY` changes, namespaces, large folders, restore by `APPEND` | Package or container | Homebrew `dovecot`, run unprivileged on a high port |
| GreenMail | A second, simpler IMAP implementation, to catch assumptions that only hold on Dovecot | Standalone jar | Standalone jar |
| Stalwart | JMAP, plus a third IMAP implementation | Release binary | Release binary |
| Quirk replay server (ours) | Provider-specific behavior from sanitized transcripts: Gmail `X-GM-*` and labels, 163's `ID` requirement, Outlook throttling and localized folders, Yahoo disconnects, Bridge's self-signed certificate | Swift | Swift |
| OAuth test server (ours) | Authorization code with PKCE, refresh rotation, revocation, error responses | Swift | Swift |
| Fake 1Password (ours) | The `CredentialStore` 1Password backend against a fake SDK helper or CLI with the same JSON shapes | Swift | Swift |

A test that needs a server it can't start fails with a clear message; it never silently skips.

## Corpus Rules

The corpus is public material only: the Enron corpus, the Apache SpamAssassin public corpus, test messages from open-source mail projects whose licenses allow it, and messages we write by hand for each charset, structure, and quirk. Each file's source and license is listed in `Tests/Corpus/SOURCES.md`. No real person's private mail is ever added.
