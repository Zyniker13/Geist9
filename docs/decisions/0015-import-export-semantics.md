# 0015 — Import and export semantics (mbox, provenance, idempotence)

**Date:** 2026-11-18
**Status:** accepted

## Context

M1.10 imports `.eml` folder trees, mbox files, Apple Mail exports
(`.emlx`, `.partial.emlx`, `.mbox` packages), and Google Takeout mboxes.
Import writes stored message bytes; the archive may be someone's only copy
of their mail, so the rules for what bytes enter the store must be explicit
and conservative. The index schema gains `importSource` and
`providerThreadID` (schema `core-v2`), and export must round-trip byte-for-
byte through import.

## Decision

**Stored bytes are what the source attests.**

- The mbox splitter recognizes all four classic variants (mboxo, mboxrd,
  mboxcl, mboxcl2). Only the From_ separator line is dropped, and only
  mboxrd/mboxcl2 `>From ` quoting is undone on import. For mboxo/mboxcl a
  `>From ` line stays in the stored bytes (mboxo never quotes; mboxcl
  quoting cannot be distinguished from literal content once `From_` lines
  are misquoted).
- `Content-Length` is trusted only in mboxcl/mboxcl2, and only when the
  span it claims ends exactly at a following `From_` line boundary. If the
  framing does not verify, the splitter falls back to scanning and records
  the fallback (`skippedLeadingBytes`/reports) rather than guessing.
- Variant detection between mboxo and mboxrd is a heuristic; callers may
  pin the variant explicitly (`MailImporter.import(mboxVariant:)`), and a
  pinned non-mboxrd variant disables unquoting even when heuristics would
  suggest it. Unverified frames with an rd hint or content evidence are
  unquoted; everything else is stored verbatim as mboxo.
- Export (`MboxFormat`) quotes every bare `From ` line with `>` (RFC 4155
  style), so re-importing an export reproduces the original bytes apart
  from that reversible quoting.
- Apple Mail `.emlx` files carry a leading byte-count; `.partial.emlx`
  messages are rebuilt from the attachment parts Apple Mail stores beside
  them. Apple's legacy mbox format inside `.mbox` packages is routed
  through the mbox path and reported as the `apple-mail` source.
- Takeout labels come from `X-Gmail-Labels` (RFC 2047-decoded, split on
  commas, system `^`-labels dropped); `X-GM-THRID` becomes
  `providerThreadID`.

**Provenance and idempotence.**

- Every imported message records `importSource` (`eml`, `mbox`,
  `apple-mail`, `takeout`) and, where the source has one, `providerThreadID`.
- Content addressing makes re-import free: the same bytes hash to the same
  file, and ingest's membership upsert (`ON CONFLICT DO UPDATE`) adds no
  duplicate rows.
- Per-message error isolation: one malformed message fails alone; the
  report counts it and import continues.
- Importing a directory that is itself an archive (contains `manifest.json`)
  is refused loudly, not silently skipped, so an archive dropped into a
  source tree cannot be re-ingested as if it were mail.

## Consequences

- Import never rewrites message bytes beyond the documented mbox quoting
  rules; export round-trips back to them (tested both directions).
- The index schema version and the manifest `formatVersion` are 2; opening
  a v1 archive migrates the index forward without touching stored rows
  (compatibility-tested).
- Third-party mbox writers that disagree with our variant guess can pin
  the variant through the API instead of being misread silently.
