# 0007: Search Built on SQLite FTS5 With Our Own Text Pipeline

Status: Accepted, 2026-11-16

## Context

Search is a primary feature and must work in Chinese, Japanese, Korean, Russian, German, French, and English, over attachments and scanned documents, fast at a million messages, and for agents as well as people.

## Decision

Build `ArchiveSearch` on SQLite FTS5 in the same database as the index. Tokenize in Swift before SQLite (language detection, `NLTokenizer` segmentation, folding, per-language stemming) and keep a trigram index alongside. Rank with field-weighted BM25 plus recency and personal signals, merged by reciprocal rank fusion with on-device semantic results. A judged relevance set and speed budgets gate every change in CI.

## Consequences

One database to back up and migrate; search works offline and on Linux for tests. The tokenizer pipeline is ours to tune. Index size must be watched (trigram and vector indexes are the large parts).
