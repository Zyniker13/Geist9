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

Search budgets are in [DESIGN.md](DESIGN.md#search-quality-testing) and enforced from M2. Other budgets enforced in CI from M7: sync parsing at least 200 messages per second on an Apple silicon Mac mini, steady memory under 500 MB during a full sync.

### Relevance Targets for the Judged Set (chosen in M0)

Measured on the M0 FTS5 spike's synthetic corpus (95 generated queries with known answers, 100,000 messages; [spike result](spikes/fts5-search.md)): recall@50 = 1.000, nDCG@10 = 0.638, first-ten p95 = 9.8 ms, ranked-page p95 = 12.6 ms, ingest 363 messages/s. That corpus is self-referential — its queries come from its own vocabulary — so it is a floor, not a prediction: the real judged set (about 300 curated queries over Enron plus the multilingual and attachment fixtures) is harder.

Targets for the real judged set, enforced in CI from M2 on every change touching `ArchiveSearch`:

- **recall@50 ≥ 0.75** across the full set.
- **nDCG@10 ≥ 0.45** across the full set.
- A change that drops either metric by more than **0.02** from the recorded baseline fails the build, even if it stays above the target.
- The budgets above stand unchanged: first keystroke results under 50 ms, a ranked page under 200 ms (the spike's 13–16 ms p95 on 100k synthetic messages leaves the headroom for real text and 1M messages).

### Embedding Model Tests

`ArchiveEmbedApple` (macOS-only, decision 0039) is tested two ways. The toy-model tests run everywhere a Mac runs: a tiny generated Core ML model plus a two-word vocabulary pin the tokenizer, the adapter contract, the truncation path, and the app wiring. The real-weights tests (`RealCoreMLEmbeddingTests`) run the actual converted `bge-small-en-v1.5` package: 384 dimensions, unit-normalized vectors, a query ordering its relevant passage above an unrelated one, and determinism. They are skipped unless `BRISTLECONE_REAL_EMBEDDING_MODEL` points at a directory holding `bge-small-en-v1.5.mlpackage` and `bge-small-en-v1.5-vocab.txt`, as written by `scripts/convert-embedding-model.py`. CI never needs the weights, and the weights are never committed.

### Vector Benchmark Modes (decision 0046)

`bench-search` (not part of CI; run by hand on a Mac) has six vector modes. `vector-prepare <dir> <count> <seed>` builds a fresh embedding-only archive of random unit vectors; `vector-cluster <dir> <queries> <seed>` builds the clusters and checks coverage and the 300 ms scan budget; `vector-recall <dir> <queries> <seed>` sweeps `nprobe` against the exact-scan baseline. Random vectors carry no semantic structure, so their recall is a conservative bound. The two `-real` modes measure on real natural-language embeddings instead: `vector-prepare-real <dir> <model-dir> [count] [seed]` embeds a deterministic 18-topic English corpus (invented proper nouns, no personal data) with the converted model, and `vector-recall-real <dir> <model-dir> [queries] [seed]` clusters it, embeds 30 held-out query phrasings worded differently from the corpus templates, and runs the same sweep. Both need the model directory from `scripts/convert-embedding-model.py` and run on macOS only. The operating point chosen from these measurements is recorded in STATUS.md.


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
