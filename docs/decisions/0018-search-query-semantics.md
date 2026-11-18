# 0018 — Search query language semantics (M1 core)

Date: 2026-11-18

## Context

DESIGN 6A defines the query language: free text plus operators (`from:`, `to:`,
`subject:`, `is:`, `has:`, dates, sizes, …), quoted phrases, `OR`, parentheses,
and `-` to exclude. The M1 core needs one engine that both the app and the MCP
server call, running on SQLite FTS5 with pre-tokenized columns (decision 0007).

## Decision

**Grammar.** Operators are exactly what DESIGN 6A lists. Adjacent terms mean
AND. The bare word `AND` is *not* an operator — it is an ordinary search term,
and `cats AND dogs` therefore parses as three terms (`cats`, `and`, `dogs`),
not as a conjunction. `OR`, parentheses, and `-term` carry the boolean
structure. `NOT` is likewise an ordinary term. (Gmail-compatible `AND`-skipping
can be added later as a separate decision; until then the contract above is
authoritative.)

**Recipients.** The FTS table stores one merged `recipients` column (to + cc +
bcc, display names and addresses tokenized). A bare-word recipient query
(`to:carol`) searches that merged column and cannot distinguish kinds —
documented and tested. The address form (`to:carol@example.com`) adds a kind
filter over the normalized `recipient` table rows and *can* distinguish, so
`to:` never sees a CC-only recipient when the query names an address.

**From.** `from_addr` is stored folded-but-raw (`jane.doe@example.com`
lowercased, unchanged otherwise); unicode61 splits it at query time into the
address-aware tokens, and `from:a@b.c` compiles to a phrase over it. A `from:`
value containing `@` also adds a `message.from` equality filter.

**Ranking vs browsing.** A query that is a single text leaf runs the ranked
FTS5 path: `bm25(message_text, 12, 8, 6, 5, 1, 0.4, 0.3)` over columns
(subject, from_name, from_addr, recipients, body, quoted, attachments) is both
the score and the sort, and `snippet()` supplies highlights. Anything with a
filter or boolean structure runs as a SQL predicate (FTS5 reached through
`m.id IN (SELECT rowid FROM message_text WHERE message_text MATCH ?)`
subqueries, other leaves as table predicates) and answers newest-first;
ranking is a text-leaf concern. `rank`/`snippet` are nil on that path.

**Recency boost (DESIGN 6A).** The ranked path multiplies the bm25 score by a
recency factor in `(1.0, 1.1]`: `1 + 0.10 / (1 + age_days/30)`, computed over
`COALESCE(dateSent, dateReceived)`; a message without a usable date gets
factor 1.0. bm25 is negative (more negative = better), so the factor favors
newer messages in proportion to their match strength — a fresh weak match
never outranks a strong old one, and a bm25 tie between byte-identical texts
is decided by date (tested). Predicate-structured queries stay newest-first
and unranked; ranking is a text-leaf concern.

**Thread grouping (DESIGN 6A).** `search(_, groupByThread: true)` returns one
hit per thread — the thread's best-ranked hit for ranked queries, its newest
hit for predicate queries. The collapse happens in SQL with
`ROW_NUMBER() OVER (PARTITION BY COALESCE(threadID, -id) …)`, so paging stays
correct no matter how much collapses (a thread with no row keeps its own
partition). Every hit carries `threadID` so callers can expand a collapsed
thread. Message grouping itself is JWZ threading at ingest (M1.9), already
stored in `message.threadID`.

**Phrases include quoted text.** An unquoted-field phrase (`subject:"budget
review"`) and field-less phrases rank over a column set that includes `quoted`
at its low weight, so the message that was replied to still surfaces; bare
terms exclude `quoted` (per DESIGN 6A's separate-weight rule).

**Placeholders.** `amount:` warns ("entity extraction not indexed yet") and
matches nothing in M1; typed entities (dates, amounts, tracking numbers) are
an M2 extractor concern.

**Empty matches.** A leaf that compiles to an impossible FTS5 expression (for
example an operator value that tokenizes to nothing) yields an empty result
set, not an error, so a bad term narrows the answer instead of failing it.
Parser-level syntax errors (unbalanced parens, dangling `OR`) still throw.

## Consequences

- Tests encode each of these behaviors; the merged-recipients limitation and
  the `AND`-as-term reading are pinned by tests, not folklore.
- Changing field weights means changing both the ranked path and the spike's
  proven numbers; the weights live in one constant next to the compiler.
- If M2 adds stemmers, spell-correction, or `AND` skipping, the grammar rules
  here get revised by a new decision, not silently.
