# 0029: Attachment text is searchable

Date: 2026-11-19

## Context

The M2 judged relevance set (decision 0028) measures nDCG@10 and recall@50
over a curated corpus. Its first run scored 0.9165 / 0.8825 and exposed a
real gap the fixtures were designed to catch: tokens that existed only
inside a text attachment (a part number in a CSV line-item list, "fire
drill" in a schedule file) could not be found, because the attachments
column of the search index held only attachment file names. Attachment
extraction is an M2 roadmap task ("Attachment extraction: PDF, plain text,
CSV, HTML, ...").

## Decision

- `SearchText` gains an `attachments` field; MailBridge fills it while
  parsing: every leaf part whose Content-Disposition is `attachment` and
  whose content type is `text/*` contributes its decoded text (charset
  honored, HTML reduced with the same reducer as HTML bodies), in part
  order, capped at 1,000,000 characters per message.
- Ingest appends that text to the `attachments` FTS5 column after the
  attachment names, and to the trigram column's source. No stem column for
  attachments: attachment text is mostly machine-written data, where
  stemming adds noise rather than recall (consistent with decision 0026,
  which stems subject, body, and quoted only).
- `TextIndexVersion` moves to v4, so existing archives gain the text by
  the ordinary backfill (`reindexOutdated`), which re-indexes older rows
  from their stored bytes. Stored bytes are never rewritten.
- PDF, Office, iWork, image OCR and the other non-text extractors stay
  open roadmap work; this decision covers the text/* family only.

## Consequences

- Bare terms, phrases and trigram substrings now reach attachment text;
  `filename:` and `has:attachment` keep working unchanged.
- The judged set improved from 0.9165/0.8825 to 0.9882/0.9946
  (nDCG@10/recall@50), and the fixture queries that only made sense with
  attachment text moved off the worst-queries list.
- The same run also exposed a compiler bug the fixtures caught: a text
  leaf re-wrapped its per-token groups in the leaf's base columns, and
  nested FTS5 column filters intersect, so every stem-only match was
  invisible. Fixed with regression tests; the judged set's stem queries
  ("seats", the German invoice family) found their documents afterwards.
- The 1M-message benchmark corpus has no attachments, so the recorded
  as-you-type budgets are unaffected.
- A text attachment up to 1 MB is indexed in full; larger ones are
  clipped, and the clip point is tested.
