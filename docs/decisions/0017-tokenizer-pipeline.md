# 0017: Tokenizer pipeline architecture

Date: 2026-11-18
Status: Accepted
Scope: `ArchiveSearch` (DESIGN 6A "Tokenizing in Every Language")

## Context

Search is a primary feature. Text must be searchable in every language,
including Chinese, Japanese, Korean, and Thai, whose writing has no spaces
between words. The M0 FTS5 spike measured word segmentation quality, index
size, and query speed, and concluded (decision 0007) that text is tokenized
in Swift *before* it reaches SQLite FTS5: FTS5 indexes pre-tokenized text,
and a trigram column over the raw folded text covers substring and as-you-type
queries. Core packages build and test on Linux as well as macOS, but
`NaturalLanguage` is macOS-only.

## Decision

- New module `ArchiveSearch`, no dependencies. `TokenPipeline` is the single
  tokenizer: fold → segment → fold → filter. The same pipeline tokenizes at
  ingest and at query time, so a query finds what the index saw.
- **Folding** is Unicode NFKC (`precomposedStringWithCompatibilityMapping`),
  then case and diacritic folding with a nil locale. Locale independence is a
  correctness requirement: the index must be byte-identical on every machine,
  so Turkish i-variants fold the same way everywhere.
- **Segmentation** uses `NLTokenizer` with `NLLanguageRecognizer`'s dominant
  language on macOS. On Linux, where `NaturalLanguage` is unavailable, the
  documented fallback splits on whitespace and punctuation and emits one
  token per Han/Hiragana/Katakana/Hangul character. The trigram index covers
  substring queries for CJK words on both platforms; CJK equality matching is
  per-character there. Linux never runs the FTS5 search-quality benchmarks,
  which are macOS-only.
- **The token stream keeps repeats and order.** FTS5 phrase queries rely on
  token adjacency; deduplication would corrupt phrases (`把发票发给我` loses
  its trailing `我`). Only empty tokens, punctuation-only tokens, and tokens
  over 64 characters are dropped.
- **Address-aware tokens** for mailbox values: the local part's separator
  pieces (`.`, `-`, `_`, `+`), the local part when it has more than one
  piece, the domain's labels except the bare TLD, and the whole domain.
  `jane.doe@example.com` yields `jane`, `doe`, `jane.doe`, `example`,
  `example.com`. The bare TLD is not a token: `com` alone would match every
  `.com` sender.
- **Stemming** is a later step, not part of this decision's scope. When it
  lands it changes the token stream, so the index schema records the
  tokenizer version per indexed row (DESIGN 6A) and reindexing is explicit.

## Consequences

- Tokenization is deterministic and cross-platform; macOS and Linux agree on
  the token stream for non-CJK text and on the fallback for CJK.
- Segmentation quality is pinned by golden tests per language (hand-checked
  against `NLTokenizer` output): Chinese, Japanese, Korean, Russian, German,
  French, and mixed-script samples.
- The mixed-script case (`会议 invoice123 です`) shows `NLTokenizer` may split
  an alphanumeric run (`in voice 123`) under a CJK language choice; tests
  pin that letters and digits survive, and the trigram index covers
  substring queries for the whole run.
- Tests use `#if canImport(NaturalLanguage)` to pin macOS segmentation and
  XCTSkip-with-comment on Linux, where the fallback is pinned instead.
