# 0053 — Per-person access policy for the MCP helper

Date: 2026-11-21

## Context

DESIGN 9A promises that the person controls what agents can see: which
accounts, folders, and labels; redaction; per-client budgets. An MCP helper
serves an archive that may hold decades of private mail, and a policy that
fails to load must never degrade into "everything visible". Enforcing
visibility after a query (post-filtering) would leak through counts,
offsets, and pagination: a page that shrinks tells the caller where hidden
rows sit.

## Decision

The helper resolves one access policy at startup from
`BRISTLECONE_ACCESS_POLICY` (a JSON file path; absent, or set to blank,
means the next source below), then from the app's standard policy
location (decision 0054) — the file this app's Settings writes — and
only when neither exists does the default policy apply; against the
archive's own index.

**Policy shape.** The policy names things, not ids: accounts by address,
mailboxes by name, labels by name, so a policy written against one archive
still means something against a rebuilt one. `excludeJunkAndTrash` defaults
to true when the key is absent — the fail-safe reading of silence. Names
that match nothing in this archive stay silent and begin matching the
moment such a row appears. Only a policy file that cannot be read or
decoded fails the launch: starting with a silently permissive filter is the
one failure this server must never have.

**Enforcement is SQL-side.** `MessageVisibility` (in ArchiveCore) holds the
resolved id sets and renders an inline SQL predicate; search counts,
ranking, typo rescue, folder summaries, and thread reads AND that predicate
into the WHERE clause before LIMIT/OFFSET, so pages, counts, and facets are
consistent and leak nothing. Semantic search (vector index) scans in Swift,
so it over-fetches by a bounded factor and post-filters with an SQL `IN`
query over the same predicate; the permissive path adds no overhead.
Accounts and mailboxes report filtered counts; a zero count is the caller's
signal to hide the row.

**Redaction.** `full` (default) and `headersOnly`. In `headersOnly` the
body, snippets, and rendered text are withheld and the response carries an
explicit `body_omitted: true` marker: absence alone would be
indistinguishable from "no body was stored".

**The master switch.** `enabled: false` (the app writes it when the person
turns agents off in Settings) refuses every tool call and resource read
with a distinct error — agents-off -32003, message "agents are turned off
in Bristlecone Email Archiver's Settings" — before any rate-limit slot is
spent, so the person can copy a configuration only while the switch is on
and an agent pointed at a disabled archive learns that rather than
thrashing on failures. Absent from the JSON it defaults to true.
`tools/list` stays static: refusing schema advertisement would only break
client setup steps without protecting any message.

**Refusals.** Rate limiting (`callsPerMinute`, enforced at dispatch) and
tool errors map onto JSON-RPC errors with readable messages — bad arguments
-32602, unknown tool -32601, rate limited -32000, not found -32002, agents
off -32003 — never the SDK's opaque "Internal error". A hidden id answers
exactly as an unknown one (`notFound`), at every surface: tools, resources,
threads, attachments, contacts. A partially visible thread answers as a
thread whose messages are the visible ones, with the subject taken from the
first visible message; a fully hidden thread does not exist.

**Accountability.** Every tool call and every resource read passes one gate
(`AccessContext.beginRequest`/`endRequest`): the master switch, then the
rate limit (one shared bucket — listings and reads of resources count
toward it, or an agent could pull whole mailboxes around a tight tool
budget), then the activity log (time, tool, arguments shape, result count;
refusals log too). The log is best-effort and never records returned
content.

## Consequences

- The permissive path answers byte-for-byte as an unfiltered archive, so a
  policy that excludes nothing costs nothing.
- Adding any future MCP surface (a new tool, resource, or transport) must
  thread `MessageVisibility` and redaction through it; the access-control
  tests pin the existing surfaces and will not cover a new one silently.
- The over-fetch factor on semantic search is a bound, not a guarantee of
  full pages under heavy filtering; the keyword path is exact.
- Tests: `Tests/ArchiveCoreTests/AccessControlTests.swift` (store-level:
  counts never leak, hidden ids indistinguishable, permissive parity) and
  `Tests/ArchiveMCPTests/AccessControlEndToEndTests.swift` (over stdio:
  fail-fast launch, every surface filtered, redaction markers, rate-limit
  refusal, silent unknown names).
