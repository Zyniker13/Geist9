# 0041 — Nested message/rfc822 attachment text

Date: 2026-11-20
Status: Accepted

## Context

A forwarded message arrives as a `message/rfc822` part: a complete email
embedded as an attachment. The parser already structures these parts
(`nestedMessage` kind with the inner message's headers and body), and
`walkLeaves` descends into them, but only attachment leaves survive the
disposition guard — the forwarded message's own subject and body text never
reached the search index. A forwarded thread's content was effectively
invisible to search. Recursion is also unbounded: a maliciously or
accidentally deep chain could exhaust the stack.

## Decision

- The bridge collects a nested message's subject plus its text body as
  attachment prose. `walkNestedMessages` descends into `nestedMessage`
  parts and calls a visitor with each inner message;
  `nestedMessageText` builds "subject\nbody" text, preferring
  `text/plain` and reducing `text/html` through the existing HTML reducer.
  Encoded-word subjects decode through the existing header machinery.
- Nested prose shares the same `maxAttachmentTextLength` budget as other
  attachment text, collected before attachment leaves.
- The parser caps nesting depth (`MIMEParser.nestingDepthLimit = 32`).
  At the cap the remaining nested message is kept as a raw leaf part, so
  bytes stay preserved and indexing stops descending. 32 covers every
  real forwarding chain we know of and bounds recursion linearly.
- `TextIndexVersion` bumps v10 → v11: stored indexes reindex once on
  upgrade, and nested subjects/bodies appear in search results.
- The archive never rewrites the message: the nested part's bytes remain
  in the stored message exactly as downloaded; this is an index change
  only.

## Consequences

- Forwarded conversations are searchable by their forwarded subject and
  body text, including encoded-word subjects and HTML bodies.
- Deeply nested chains stop contributing text after 32 levels; the raw
  bytes remain in the archive and can be re-extracted later if the limit
  changes (a future version bump would reindex).
- Linux builds are unaffected: the nested-text path uses only MailMIME
  and the existing HTML reducer.
- Tests: MailMIMETests/NestedDepthTests (cap + byte preservation) and
  bridge-level tests for indexed text, encoded-word subjects, HTML
  reduction, the cap in the bridge, and the v11 backfill.
