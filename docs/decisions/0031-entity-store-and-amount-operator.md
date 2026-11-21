# 0031: Entity store and the `amount:` operator

Date: 2026-11-19

## Context

DESIGN 6A lists extracted entities (dates, amounts and currencies, phone numbers,
tracking numbers, booking codes, domains, URLs) among the things indexed at
ingest, and the query grammar accepted `amount:` since M1 — but the operator was
unbacked: it warned "not indexed yet" and matched nothing. M2 (ROADMAP line 71)
calls for real entity extraction with `amount:` and entity facets. Entities need
a home that survives re-indexing, scales to millions of messages, and can back
both operators (`amount:>100`) and later facet counts ("has an amount").

## Decision

- New table `message_entity` (`messageID INTEGER NOT NULL REFERENCES message ON
  DELETE CASCADE`, `kind`, `value`, `normalized DOUBLE`, `currency`), indexed on
  `(kind, normalized)`, added by the `core-v11` migration. Rows are removed
  automatically with their message; re-indexing deletes and re-inserts the rows
  for that message. No stored message bytes are touched.
- Extraction runs at the tokenize stage of the shared `indexSearchText` write
  path, over the same prepared search text the index already gets (subject +
  body + quoted + attachment text): no extra pass over stored bytes, and both
  the ingest path and the `TextIndexVersion` backfill populate the table. The
  current pipeline version becomes v6 so existing archives are backfilled.
- `value` keeps the amount exactly as written in the message; `normalized` holds
  the plain number and `currency` the code when it is known, kept as found when
  ambiguous (the ¥ symbol stays "¥", not a guessed JPY/CNY choice).
- Amount normalization follows the message's own convention: whichever
  separator comes last in the run is the decimal separator, the others are
  thousands separators ("1,234.56" and "1.234,56" both normalize to 1234.56;
  "12,800" is twelve thousand eight hundred, "99,90" is 99.90).
- A minus directly before an amount is treated as a subtraction ("balance
  -$50", "refund -50 USD") and the amount is not extracted; signed amounts are
  added when a query needs them. A digit before the minus ("1-50 USD", a
  range) is not a sign.
- At most 200 entities per message; identical extractions are deduplicated.
- `amount:` compiles to an `EXISTS` subquery over `message_entity`, the same
  shape as `has:attachment` and `filename:`. The value takes a comparison
  operator from a closed set (`=`, `>`, `<`, `>=`, `<=`, default `=`) and a
  decimal number, thousands separators accepted. Anything that parses to no
  comparison (including `amount:abc`, `amount:5.5.5`, `amount:>`) appends a
  warning and compiles to a clause that matches nothing; a bare `amount:`
  throws the same parse error as every other operator with no value.

## Consequences

- `amount:` queries are index-backed and measured by the same latency budgets
  as every other query; the subquery is a single index seek per message on the
  `(kind, normalized)` index, so it stays inside the ranked-page budget.
- More entity kinds (dates, phone numbers, tracking numbers, booking codes,
  domains) extend the same table by `kind` value without another migration;
  each new kind gets its own query operator or facet hereafter.
- Entity facets ("has an amount", amount ranges in the sidebar) read the same
  table when M2 reaches facets, so no second representation of entities exists.
- The extraction grammar lives in one place (`EntityExtraction`) and is pure
  CPU, so it runs unchanged on macOS and Linux (no platform gating needed).
- Excluding signed amounts means a refund shown as "-50 USD" will not match
  `amount:` until sign support arrives; the warning-free empty result keeps
  this quiet. If the judged set later needs refunds, this decision is amended.

## Amendment (2026-11-20): bare two-decimal amounts

The judged set grew to 225 queries and gained its first `amount:` queries
(q216–q219). They failed before this amendment: the extraction grammar
recognized only currency-marked amounts, so an invoice total written as
"total 1,240.00" or "47,510.00" (no currency marker) produced no entity row,
and the ROADMAP's invoice answers were invisible to `amount:`.

- A number ending in an explicit two-digit fraction ("1,240.00",
  "47.510,00", "12.40") is now an amount with `currency` nil. It runs
  after every currency-marked pattern, the date, phone, tracking, booking
  and domain extractors, and the platform detector, and skips any span one
  of them claimed — so "€3.250,00" keeps its currency and the European
  date "14.02.2024" is never sliced into an amount.
- A bare integer stays unrecognized ("4 units", "2024", "#12345"): too
  ambiguous to call money. The lone-dot US reading of "1.234" also stands
  (this decision's original rule). With currency evidence, however,
  three-digit dot groups now read European: "4.800 EUR" normalizes to
  4800, since with a currency marker the German reading is the only
  sensible one.
- Regression tests: `testBareTwoDecimalNumbersAreAmounts`,
  `testBareAmountDoesNotStealClaimedSpans`,
  `testCurrencyResolvesLoneDotThousands`,
  `testAmountOperatorReadsBareTotals` (EntityTests). The four judged
  `amount:` queries (q216–q219) gate this from now on.
