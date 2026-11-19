# 0035 — Typos are rescued by a one-edit vocabulary fallback

Date: 2026-11-19

## Context

DESIGN 6A gives a bare term three chances: the exact index (folded and
stemmed), then the trigram substring fallback on a zero-hit retry. Both miss
the most common real-world zero-hit query — a mistyped word. `"shiping"`
shares no substring of the trigram minimum with `"shipping"` (the shared
spans are 4 and 3 characters: `ing`, `hip` — `ship` fails because one side
has the doubled `p`), so the fallback finds nothing, and the user gets an
empty page for a query that has six matching messages one keystroke away.

## Decision

When a query's text leaf still has zero hits after the trigram fallback, and
that leaf is a single folded term, the index tries a **one-edit vocabulary
rescue**: it generates every one-edit variant of the term (substitutions,
adjacent transpositions, deletions, insertions), keeps only the variants that
are real indexed terms in the `vocabulary` table, and re-runs the ranked
query against exactly the columns the original leaf searched. Hits found this
way are flagged `SearchHit.viaTypo = true`, so callers can say honestly where
a result came from.

The guard is deliberately narrow:

- **Single-term leaves only.** A phrase's tokens are only meaningful
  together, and for a multi-word query the trigram fallback is the better
  ladder. Multi-token correction (correct each token, AND the groups) is
  future work, recorded here as not yet built.
- **Same columns as the original leaf.** The rescue expression is
  `{cols} : ("correction" OR ...)` with the leaf's own base columns, so a
  `subject:shiping` typo is rescued within subject, and a bare-term typo
  never reaches quoted text (DESIGN 6A).
- **Corrections only from the vocabulary.** A variant that is not an indexed
  term cannot match anything, so it is dropped before the query; a typo with
  no real one-edit neighbours stays an honest zero, and the rescue never
  invents results.
- **Corrections match exactly.** The rescued expression contains the
  corrected folded terms only — no stem expansion of the correction, which
  would multiply false positives (correcting to "shipping" must not open the
  door to "shipment").

The variant generator (`Typo`, in ArchiveSearch) is pure and DB-free;
vocabulary lookup stays in ArchiveCore where the database lives. The
`vocabulary` table is rebuilt by `Index.rebuildAll`; incremental ingests
(`applyDeltas`) extend it, so a term just indexed is immediately available as
a correction. The rescue covers both `search` and `searchAsYouType`, which
route through the same zero-hit path.

## Consequences

- `"shiping"` finds the messages of `"shipping"`, flagged `viaTypo`; the
  regression test pins the set, the flag on rescue hits, the flag's absence
  on exact hits, field-filter preservation, and the honest zero.
- Precision trade-off: when two real neighbours exist ("typeing" → "typing",
  "typing" being the far more frequent), both are offered; BM25 ranks the
  frequent reading first. This is a last-resort path that only runs when the
  exact index and trigrams found nothing.
- Budget: the rescue adds one vocabulary lookup (a few hundred bound
  parameters, chunked at 400) plus one ranked query, and only runs on the
  zero-hit path — it costs nothing on keystrokes that already found hits, and
  only a cheap extra query on ones that already failed.
- The `viaTypo` flag joins `viaTrigram` in the result surface; both are part
  of the honest-provenance story agents rely on (M3).
- Facets follow the rescue: `SearchExecutor.typoRescueExpression` is shared
  by the ranked path and the facet-count path, so when the rescue fires the
  entity facets describe the rescued set the hits show — the counts on
  screen always belong to the results beside them (`testFacetsFollowTheTypoRescue`).

## Alternatives considered

- **Trigram-only rescue** (no vocabulary): cannot fix insertions, deletions
  or transpositions by construction; kept as-is for what it can do.
- **Accept every variant as a query term without the vocabulary check**: the
  FTS query would still work (unmatched terms match nothing), but stem
  columns would let near-misses through and the expression would balloon to
  ~400 alternatives per term; the vocabulary check keeps the expression small
  and the match exact.
- **Edit distance 2 / SymSpell-style precomputed deletes**: overkill for a
  per-mailbox vocabulary of thousands of terms; one edit against the
  mailbox's own vocabulary catches the overwhelming majority of real typos,
  and the mailbox vocabulary already knows what words exist in this corpus —
  better than any generic dictionary.
