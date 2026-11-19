# 0032 — Entity extraction for the remaining kinds

## Context

Decision 0031 gave every message an entity store (`message_entity`) and backed the
`amount:` operator with it. The extraction stage, however, only produced amounts.
The entity row in [DESIGN.md](../DESIGN.md) promises dates, phone numbers, tracking
numbers, booking codes, and domains as well, and the next entity work — facets —
needs all kinds present to be worth building. `EntityKind` already carried the
cases; nothing produced them.

Extraction runs at the tokenize stage of the shared `indexSearchText` write path,
inside the ingest transaction, with a cap of 200 entities per message. Whatever
runs there must behave identically on macOS and Linux, because both CI legs index
the same fixtures and the judged set runs on both.

## Decision

The remaining kinds are extracted by shared patterns that run on every platform,
with the macOS platform detector (`NSDataDetector`) adding coverage the shared
patterns cannot carry. Shared patterns run first and own the ranges they match;
the detector adds only matches that do not overlap a shared hit.

- **Dates.** Shared patterns: ISO 8601 dates with optional `T` time and optional
  offset; month-name forms in English (full and abbreviated) in "month day, year"
  and "day month year" order, optional time; numeric `M/D/YYYY` and `D.M.YYYY`
  (the second only for days and months 1–12, since `13.5.2024` is ambiguous and
  stays out). Values normalize to a UTC epoch: the written time when one is
  given, midnight otherwise. Weekday and relative references ("Friday",
  "next Tuesday", "today") and month-year or time-only fragments are not dates.
  A match whose reading is impossible ("31.02.2024") is skipped, and its range
  is still claimed so the detector cannot rescue a clamped reading of it.
- **Phone numbers.** Shared pattern: leading-plus international forms, digits
  grouped by spaces, dots, hyphens, or parentheses; stored normalized to digits
  with a leading plus. On macOS the detector adds national formats and stores
  its normalization.
- **Tracking numbers.** UPS `1Z` + 16 alphanumerics, and runs of 20–22 digits
  (the common carrier shapes; more carriers wait for operators that need them).
- **Booking codes.** Six characters of letters and digits containing both —
  recognized only immediately beside a marker word (PNR, booking, confirmation,
  reservation, reference), so ordinary six-letter words stay out.
- **Domains.** Hosts from `http(s)://` URLs, and bare hosts with a common-TLD
  allowlist (`com`, `org`, `net`, `edu`, `gov`, `io`, `co`, `dev`, and the
  two-letter country codes), lowercased, including subdomains and trailing path
  or punctuation boundaries.

On macOS, a detector date counts only when the written form carries a full date
(a four-digit year and a day number); date-only forms normalize to midnight
rather than the detector's default hour, matching the shared-pattern semantics.
The detector never overrides a shared-pattern value for the same span.

Postal addresses are deliberately absent: no operator needs them yet, and
address parsing is weak. They land when an operator does.

Extraction stays deterministic per platform; the same platform extracts the same
values from the same bytes. macOS and Linux may differ in coverage (the detector
adds forms on macOS), which mirrors decision 0026's stance on language detection.

## Consequences

- 20 new tests cover every kind, the ISO/time and midnight rules, rejected
  readings, keyword-guarded booking codes, and detector semantics (`EntityTests`,
  38 tests green).
- Re-indexing (`TextIndexVersion.v6`, decision 0031) picks the new kinds up for
  existing archives; no schema change — the `kind` column already distinguishes.
- The cap of 200 entities per message applies across all kinds, amounts first in
  the order extraction runs; heavy traffic mail fills amounts before dates.
- No query operator consumes the new kinds yet; facets (next step) are their
  first consumer.
