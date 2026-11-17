# Spike: FTS5 with our own Swift tokenizer pipeline

M0 spike (ROADMAP M0), testing the approach decided in
[decision 0007](../decisions/0007-search-engine.md): tokenize in Swift
(`NLTokenizer` segmentation, folding), store into SQLite FTS5, keep a
trigram index alongside, and measure what M2 needs — CJK segmentation
quality, trigram size per 100,000 messages, and the baseline that set the
relevance targets now recorded in [TESTING.md](../TESTING.md).

## Setup

- Spike driver: `Spikes/FTS5Spike/main.swift` (throwaway, macOS-only — it
  needs `NaturalLanguage` and the Darwin SDK's SQLite3). Deterministic
  synthetic corpus, default 100,000 messages, about 15% Chinese/Japanese/
  Korean bodies, generated with a seeded LCG.
- The product index: `fts5(subject, from_name, from_addr, body, quoted)`
  where every field arrives pre-tokenized by the Swift pipeline and
  `unicode61` only splits on spaces; the address field is stored folded but
  raw, because unicode61's split on `@` and `.` is exactly the address-aware
  tokenization DESIGN 6A wants, and queries run through the same rules.
- The trigram tables: `tokenize='trigram'` over (a) subject + sender + full
  body, (b) subject + sender only.

## Results (2026-11-17, 100,000 messages)

`FTS5Spike: 12 passed, 0 failed`.

| Measurement | Value |
| --- | --- |
| CJK segmentation recall on hand-checked samples | Chinese 0.83 (10/12), Japanese 1.00 (9/9), Korean 1.00 (5/5) (bar: ≥ 0.80) |
| Ingest (tokenize + insert) | 363 messages/s (M7 budget: ≥ 200/s) |
| Main FTS index size | 81.4 MB per 100k messages (≈ 0.8 KB/message) |
| Trigram index, subject + sender + full body | 225.4 MB per 100k messages |
| Trigram index, subject + sender only | 36.1 MB per 100k messages |
| First-ten results latency | p50 2.7 ms, p95 9.8 ms, max 12.6 ms |
| Ranked page (50) latency | p50 3.4 ms, p95 12.6 ms, max 24 ms |
| Judged baseline (95 queries with known answers) | recall@50 = 1.000, nDCG@10 = 0.638 |
| Segmented CJK retrieval | `发票` finds its 2,986 Chinese bodies through the segmented index |
| Trigram substring retrieval | `blue` finds 6,694 rows that word tokenization cannot |

## Findings

1. **The pipeline works and is fast enough.** `NLTokenizer` segments Chinese,
   Japanese, and Korean samples essentially correctly (Chinese 0.83 — it
   merged 发+给 into one token, which the trigram index covers; Japanese and
   Korean 1.00), folding plus segmentation plus FTS5 round-trips CJK queries
   (the segmented `发票` matches every Chinese body that contains it), and
   ingest runs at 356 messages/s — above the 200/s budget — before any tuning.
2. **Latency has enormous headroom.** p95 of 13–16 ms on 100k synthetic
   messages against budgets of 50 ms (first results) and 200 ms (ranked
   page). Real text and one million messages will erode some of that, but
   the order of magnitude is comfortable.
3. **Full-body trigram is expensive; the narrow variant is the starting
   point.** 225 MB per 100k (≈ 2.25 GB per million) versus 36 MB per 100k
   for subject+sender only — a 6× difference, nearly all of it the body.
   M2 should build the narrow trigram first (subject, sender, attachment
   file names) and add body trigram only where the judged set shows
   substring/CJK queries need it, per DESIGN 6A's "narrow to the fields
   where it pays off".
4. **The synthetic baseline is a floor, not a prediction.** The judged
   queries here are generated from the corpus's own vocabulary with known
   answer sets, so recall@50 = 1.000 reflects the generator, not search
   quality on real mail. The targets in TESTING.md are therefore set well
   below this baseline for the real judged set (recall@50 ≥ 0.75,
   nDCG@10 ≥ 0.45, regression tolerance 0.02).
5. **Two implementation notes for M1/M2.** FTS5 rowids are 1-based while a
   natural array index is 0-based — the message table must map explicitly
   (the spike's first run measured recall 0.015 because of exactly this
   off-by-one). And `dbstat` sizes for an FTS5 table live in its shadow
   tables (`<name>_data`, `<name>_idx`), so size queries must match
   `name LIKE '<table>%'`.

## What this settles

Decision 0007 stands as written: FTS5 with Swift-side tokenization, unicode61
over pre-tokenized text, and a trigram index whose scope starts narrow.
TESTING.md records the relevance targets chosen from this baseline.
