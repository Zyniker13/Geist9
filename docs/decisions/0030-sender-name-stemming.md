# 0030: Sender display names gain a stem column

Date: 2026-11-19

## Context

The M2 judged relevance set (decision 0028) left exactly one query below
full recall: "Nordwind Versicherung" could not find a message whose sender
display name reads "Nordwind Versicherungen". Decision 0026 scoped stem
columns to subject, body, and quoted; the sender name kept only its exact
folded tokens, so a query form could not reach a sender's morphology.
Sender names are the highest-signal text in mail after the subject line,
and German-Dutch-Nordic company names inflect constantly.

The exact path was not empty for that query — a sibling message matched it
— so the trigram fallback (which fires only on zero hits) correctly did
not rescue it. Only a sender stem column can close the gap.

## Decision

- `message_text` gains a fourth stem column, `from_name_stem`: the stemmed
  stream of the sender's display-name tokens under the message's detected
  language, same rules as the other stem columns (minimum stem length 4).
- Bare terms reach it (the `.any` stem set becomes subject, body, and
  sender), as do field-qualified `from:` terms without an `@`; a
  `from:a@b.c` address query stays an exact folded phrase and never stems.
- Recipients keep no stem column: their stream mixes display names with
  raw addresses, and stemming an address token adds noise, not recall.
- bm25 weight for the new column: 0.5 — below the sender name's 8.0 and
  its original-stream position, above body_stem's 0.2, matching the
  sender's rank in the exact columns.
- Schema `core-v10` rebuilds `message_text` with the wider copy (all ten
  existing columns copied row for row, rowid preserved; the new column
  left empty), and `TextIndexVersion` moves to v5 so the backfill
  re-indexes every row from its stored bytes. Stored message bytes are
  never rewritten.

## Consequences

- The judged set moved from 0.9882/0.9946 to **0.9910/0.9982**
  (nDCG@10/recall@50); every judged query now reaches full recall@50.
- The macOS gate baseline is updated to the new numbers together with this
  decision (the recorded-baseline rule allows exactly this: a documented
  ranking change). The Linux baseline is measured separately in the Linux
  container and recorded per platform: 0.9788/0.9778 — Linux has no
  language detection (decision 0026), so sender names stem with the
  English stemmer only and the German-stem queries score lower.
- Index size grows by one narrow column (a handful of tokens per message);
  the 1M benchmark corpus has no sender-name diversity that would change
  the recorded budgets materially, and the next scheduled 1M re-anchor
  re-measures them.
