# 0026 — Stemming: Snowball, per-message language detection, query-side form expansion

**Date:** 2026-11-19
**Status:** Accepted

## Context

DESIGN 6A specifies that subject, body, and quoted are stemmed (Snowball) under the message's detected language, that addresses and attachment names are not stemmed, and that query terms expand to their forms so a wrong language guess can never lose the exact match. The M2.2 milestone requires stemming in the token pipeline.

Measured facts that shape the design:

- **Language detection cost.** `NLLanguageRecognizer` takes ~0.5–0.9 ms per call (measured: 10,000 subjects in 4.42 s, 2,000 bodies in 1.73 s, `swiftc -O`). Per-field detection over a 1M-message archive would be ~6M calls (~50–90 s); once per message is ~1M calls (~5–9 s) — acceptable as a one-time backfill, and ~0.5 ms per message at steady-state ingest.
- **Detection reliability.** Reliable from two words onward ("budget report" → en 0.78, "die laufenden studien" → de). Single words are unreliable ("budget" → da 0.23, "a" → hu 0.19). A confidence gate (top hypothesis ≥ 0.5) plus a vendored-stemmer check handles both: short or ambiguous text gets no language, and its tokens are stored folded.
- **Stem-prefix mismatch.** The stem of a prefix is not a prefix of the stem of the whole word: "runn" → "runn" (unchanged) while "running" → "run". An as-you-type prefix must therefore expand to the stems of its own prefixes, not just its own stem.
- **Snowball.** v3.2.0 (BSD-3), vendored as a C target (`CStemmer`) with 12 UTF-8 stemmers: danish, dutch, english, finnish, french, german, italian, norwegian, portuguese, russian, spanish, swedish. The vendored `modules.h` is reduced to those 12; see `Sources/CStemmer/PROVENANCE.md`.

## Decision

1. **Stem subject, body, and quoted only.** Address fields (`from_addr`, `recipients`) and attachment names keep their exact folded tokens (DESIGN 6A). Stemming runs after folding, on pure-letter tokens of 4+ characters; shorter tokens and tokens with digits or punctuation are stored as-is.
2. **One language per message, detected on the longest part** (body, else quoted, else subject). All three stemmable fields are stemmed under that language. This deviates from DESIGN 6A's per-part detection by a factor of ~3 in cost; it is safe because query-side expansion (point 4) always includes the folded form, so a wrong per-part guess can only add forms, never lose the exact match.
3. **Confidence gate.** The detected language is used only when the top hypothesis has confidence ≥ 0.5 **and** the language has a vendored stemmer. Otherwise the message's tokens are stored folded (no stemming), and the query side still expands with the English stemmer for recall.
4. **Separate stem columns; original columns keep the folded stream.** Implementing point 5 inside one column broke phrase adjacency: a message containing "running budgets" indexed as "running run budgets budget" made the phrase `"running budgets"` match nothing, because interleaved stems destroy the token adjacency a phrase needs. Instead, `message_text` gains `subject_stem`, `body_stem`, `quoted_stem`: the original columns hold exactly the folded token stream (phrases stay adjacent, and a wrong language guess can never lose the exact match), and the stem columns hold one stem per token under the message's detected language — the folded form when the token is not stemmed or no language was detected, so a query that reaches the stem columns with the folded form still matches. Sender, recipient, and attachment text have no stem columns.
5. **Query-side form expansion.** Every query text token searches the OR of the folded form (original columns) and its stem forms (stem columns): the stem in the query's detected language (when detected) and the stem in English. A wrong language guess can therefore never lose the exact match — the index's folded form meets the query's folded form in every case. Phrases are the OR of the folded phrase (original columns) and one stem phrase per language (stem columns): a message's stems are all in its one detected language, so per-language phrases are the honest matches, and no per-token combination cap is needed.
6. **As-you-type prefix expansion.** The active prefix's candidates are the prefix itself plus the stems of its own prefixes (each with the FTS5 prefix marker), so "runn" matches the indexed stem "run" of "running" (point 3 of Context).
7. **Index version bump.** Stemming changes what a query can find, so `TextIndexVersion` moves to v3; existing stores converge by backfill from the stored bytes (`reindexOutdated`), never by rewriting message bytes.

## Consequences

- `CStemmer` is a new vendored C target (BSD-3, pinned to Snowball v3.2.0); `ArchiveSearch` depends on it.
- Ingest detects the language once per message (~0.5 ms); a 1M-message backfill costs ~5–9 s of detection plus the stemming itself.
- The query compiler creates one English stemmer session per query (a few microseconds); the detected-language session only when detection produced one.
- Separate `*_stem` columns add a second stemmed text index roughly the size of the original columns' (one stem per token, not the interleaved ~1.6–2×); the size checkpoint in M2 measures the real number on the 1M benchmark corpus.
- FTS expressions in tests that pin exact text (e.g. `AsYouTypeCompilerTests`) now carry the OR-of-forms expansion and are updated accordingly.
- The as-you-type benchmark's 2-char and 4-char shapes exercise the expanded prefix candidates; their budgets are unchanged.
