# 0034 — Natural-language dates resolve against a caller-supplied `now`

Date: 2026-11-19

## Context

DESIGN 6A promises natural dates ("last March", "2019") that parse into
ranges. The numeric grammar already covers `2019`, `2019-06`, and
`2019-06-01`, but words like "yesterday", "this month", or "last march" have
no meaning yet. Relative words only mean something relative to a moment, and
if that moment is the wall clock, the same query compiles differently every
time it runs — which makes parsing untestable, makes saved searches drift,
and would make agent answers (M3) unreproducible.

## Decision

Natural forms are a fallback layer behind the numeric grammar: every date
operator value first tries the numeric parse as before, and only when that
does not apply does `NaturalDate.resolve` run. The grammar is small and
closed: `today`, `yesterday`, `this`/`last week/month/year`, month names with
an optional four-digit year (`march`, `sept 2019`), and the `last` prefix
(`during:"last march"`). Multi-word forms must be quoted, because the scanner
only keeps spaces inside quotes; single-word forms work unquoted. Everything
not on this list stays with the numeric grammar, whose error messages are
unchanged.

A bare month names the most recent occurrence of that month whose first day
is on or before today — from November, `march` is this year's March; in
February it is last year's. "Last <month>" agrees with the bare month, as
people use the words: "last March" said in November means the March of this
year, not eleven months ahead. `before:`/`after:` take a natural span's start
instant; `on:`/`during:` take the span. Weeks start Monday (ISO 8601). Spans
are half-open and written in the same ISO-8601 UTC form the numeric parser
emits, so the index-side comparisons do not change at all.

The `now` every relative form resolves against is a parameter, not the wall
clock: `QueryParser.parse(_:now:)` threads it down to the date operators, and
`ArchiveStore.search`, `searchAsYouType`, `entityFacets`, and `entityValues`
take `now: Date? = nil` and pass it through, so facets always describe the
same set the hits do. The default is the current time, so callers that do not
care keep working. All resolution happens in UTC.

Malformed natural values — "last march 2019", where "last" and the explicit
year contradict, or "march foo" — throw the operator's usual
`badOperatorValue` error with a sentence that states the grammar, instead of
silently picking one reading. "Last march 2019" could mean March 2019 or
March 2026; an explicit error teaches the form and beats a guess.

## Consequences

Saved queries and MCP answers are reproducible: callers that pin `now` get
byte-identical parses regardless of when they run, and the tests pin `now` to
fixture dates instead of sleeping until the calendar agrees with them. The
grammar is closed rather than fuzzy: "in march", "last 3 months", and "next
week" are errors today, and extending the grammar later is additive. The
repository's own date arithmetic is used for month and year lengths (including
leap years), so no month-length tables are hand-maintained. Nothing in the
index schema changes; this is a query-layer feature only.
