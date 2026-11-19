# 0033 — Entity facets beside the results

Date: 2026-11-19

## Context

DESIGN 6A promises facets beside the results with live counts, and the entity
store (decisions 0031 and 0032) now has one row per extracted entity. A facet
answers "what is in this result set" without another search round trip. The
question was what the first facet slice covers and how its counts relate to
the hits a search returns.

## Decision

Entity facets are the first slice, served straight off the `message_entity`
table; no new schema is needed because the `message_entity_message
(messageID)` index already exists. `ArchiveStore.entityFacets(matching:)`
returns, per entity kind, how many distinct messages in the query's full match
set carry at least one entity of that kind. `ArchiveStore.entityValues(_:matching:limit:)`
drills into one kind and ranks its written values by distinct-message count,
breaking ties by value ascending so the ranking is deterministic and capped by
`limit` (default 20). The drill-in's value is the written form as extracted
("$1,234.56"), which is the display form; normalized values stay an index-side
concern.

The facet's match set is defined to be exactly the hits' match set: the same
parse, the same compile with the query's detected language, the same exact
predicate — and the same whole-tree zero-hit trigram retry, so a substring
query ("2214" inside "INV221488") counts the rescued set, not nothing. When
the exact predicate matches nothing and the tree can fall back, the facet path
re-probes with the fallback predicate and counts that; otherwise it counts the
exact predicate's rows. Empty or malformed queries count nothing.

Counts are per message (`COUNT(DISTINCT messageID)`), so several occurrences
of one value in one message count once, and kinds with no matching messages
are absent from the dictionary rather than listed as zero. `EntityKind` became
public and Hashable so callers can key facet results by kind.

Account, sender, folder, and timeline facets need sources that only exist from
M5 on (accounts, folders, flags); they are deferred, not dropped — the
UI-level facet line in DESIGN 6A stays as the target, and they will run under
the same 300 ms faceted-counts budget.

## Consequences

- A search interface can offer drill-ins with one extra query over an already
  filtered id set; the existing indexes serve the kind filter and the
  message-id join.
- Facet counts are honest about the match set even when the hits came from the
  trigram fallback (regression-tested in `FacetTests`).
- Facet counts change when extraction improves; that is index-side truth, not
  a ranking change, so the judged-relevance baselines are unaffected.
