# Status

- **Current milestone:** M0 (Foundations and Spikes)
- **Last done:** both M0 search/IMAP spikes complete: IMAP spike green on GreenMail and Dovecot (docs/spikes/imap-client.md; decision 0002 confirmed, exact pin 0.5.0), FTS5 spike green (docs/spikes/fts5-search.md: CJK segmentation 0.83–1.00, ingest 356 msg/s, first-ten p95 13 ms, trigram full-body 225 MB vs subject+sender 36 MB per 100k messages, synthetic baseline recall@50 1.000 / nDCG@10 0.628) and the relevance targets recorded in docs/TESTING.md.
- **Next step:** remaining M0 spikes: on-device embedding model candidates for semantic search (size, speed, license, multilingual quality), Vision OCR speed/accuracy fixture, locked-down WKWebView zero-network proof, 1Password route (decision 0005), MCP stdio helper; then M0 "Done when" sweep.
- **Blocked on:** nothing. (Stalwart bring-up parked, not blocking: released 1.1.1 does not serve the API its own current docs and CLI describe; revisit on a matching release.)

## Needs the Maintainer

- Real test mail accounts for the provider rows of the capability table (M0, M4). iCloud CONDSTORE/QRESYNC verification is among them (the local test servers cannot exercise QRESYNC: GreenMail lacks it, brew Dovecot lacks the build-time extension).
- Microsoft Entra app registration and publisher verification; a Google testing-mode OAuth client; the Yahoo Mail API access request (M5).
- Developer ID signing and notarization, the payment provider and license signing key, the report endpoint, the website and download host, the privacy policy and terms (M9).

## Benchmarks

None yet.

## Log

- 2026-11-16: Repository created. M0 starts.
- 2026-11-17: DESIGN, PROVIDERS, TESTING docs; Package.swift (eight targets per DESIGN 12); check.sh + CI (Linux + macOS); threat model; archive format v1 draft; XcodeGen app spec and placeholder window; app target builds unsigned in check.sh.
- 2026-11-17: CI fix: macOS job now installs xcodegen before check.sh.
- 2026-11-17: Test servers: GreenMail 2.1.3 standalone serving IMAP on 127.0.0.1:3143 (test user alice@example.com, password in the local untracked scratch config only). Dovecot 2.4.5 config migration in progress (2.4 renamed settings; static driver removed — using passwd-file). Stalwart v1.1.1 downloaded; v1.1 changed config to a data-store-only config.json plus registry plans applied over the API, so full bring-up (IMAP listener + test account) is queued after the IMAP spike code compiles.
- 2026-11-17: IMAP spike green on GreenMail and Dovecot (docs/spikes/imap-client.md). Findings: servers normalize bare-LF APPENDs to CRLF (Restore must send CRLF); ID is not universal (GreenMail tags BAD and stays up); QRESYNC unavailable on both (GreenMail lacks it; brew Dovecot lacks the build-time extension) so it is library-tested only until Stalwart comes up; GreenMail omits RFC822.SIZE for a combined fetch, so the streamed byteCount is the trusted size. Stalwart bring-up parked: 1.1.1 is store-configured but the released CLI (1.0.14 and 2.0.0) gets 404 on /api/schema, so headless provisioning does not work against it. Decision 0002 confirmed (exact pin 0.5.0); PROVIDERS test-server rows filled.
- 2026-11-17: FTS5 spike green (docs/spikes/fts5-search.md): NLTokenizer pipeline segments CJK samples (Chinese 0.83, Japanese/Korean 1.00), ingest 363 messages/s, first-ten p95 9.8 ms and ranked-page p95 12.6 ms on 100k synthetic messages, CJK retrieval and trigram substrings verified, trigram full-body 225 MB vs subject+sender-only 36 MB per 100k messages (start narrow). Relevance targets for the judged set recorded in docs/TESTING.md from this baseline (recall@50 ≥ 0.75, nDCG@10 ≥ 0.45, 0.02 regression tolerance).
