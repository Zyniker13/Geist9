# 0044 — Structured attachment text: CSV, iCalendar, vCard; ZIP entry names

Date: 2026-11-20
Status: accepted

## Context

M2 remaining attachment formats (ROADMAP M2, line 69) are the structured
text formats CSV, `.ics` and `.vcf`, plus the entry names inside ZIP
attachments. Before this decision the bridge fell back to raw `text/*`
decoding for the first three (decision 0029). That indexes property
names, identifiers, dates, recurrence rules and base64 blobs as if
they were prose: a calendar invite would put `DTSTART`, `UID` and
base64 `ATTACH` strings into the full-text index, and a contact card
would put `VERSION:3.0` and parameter noise next to the person's name.
ZIP entry names were never indexed (only attachment part names,
decision 0029), yet the names inside a scanned bundle — "Invoice",
"Contract" — are exactly what a person searches for.

## Decision

- **CSV** (`text/csv`, `application/csv`, or filename `.csv`):
  `CSVText.text` in `ArchiveCore`. An RFC 4180 parser turns each record
  into one index line and each cell into a space-separated value, so
  "Hotel,4200" is found as `hotel 4200`. Quoted cells keep embedded
  newlines; doubled quotes unescape; CR, LF and CRLF all separate
  records; a UTF-8 BOM is stripped. No headers heuristic: every row is
  indexed (a header row adds a few useful words).
- **iCalendar** (`text/calendar`, `text/x-vcalendar`, or `.ics`/`.ical`):
  `ICalText.text` in `ArchiveCore`. Only SUMMARY, DESCRIPTION and
  LOCATION values of VEVENT, VTODO and VJOURNAL components are prose.
  Line folding unfolds; RFC 5545 text escapes (`\n`, `\,`, `\;`, `\\`)
  decode. The container must open with `BEGIN:VCALENDAR` (nil
  otherwise). UID, DTSTART, RRULE, base64 ATTACH and all parameters
  never reach the index.
- **vCard** (`text/vcard`, `text/x-vcard`, or `.vcf`/`.vcard`):
  `VCardText.text` in `ArchiveCore`. FN, TITLE, NOTE, EMAIL and
  NICKNAME are prose; N, ORG and ADR are space-joined component lists
  (so `N:Doe;Jane` is found as `doe jane`). Quoted-printable values
  decode to UTF-8 (the common vCard 2.1 encoding), with the vCard 2.1
  soft-break exception: a continuation line after `=` keeps its
  leading whitespace because there it may be content, not a fold
  marker. The container must contain `BEGIN:VCARD` (nil otherwise).
  PHOTO, UID, REV, VERSION and parameters never reach the index.
- **ZIP entry names** (`application/zip`, `application/x-zip-compressed`,
  or `.zip`): `zipAttachmentText` in `MailBridge` opens the ZIP with
  the existing strict reader (decision 0036, `ZIP.Limits.attachments`)
  and indexes only the entry names, one per line — never entry
  contents. An unreadable ZIP yields no text, per decision 0036.
- All three structured parsers share the standard caps
  (`maxInputBytes = 24_000_000`, `maxOutputCharacters = 1_000_000`),
  are pure Swift in `ArchiveCore` (Linux-compatible, no dependencies),
  and return nil on input that does not parse as their format, so a
  mislabeled part falls through to the next branch instead of indexing
  garbage.
- Dispatch order in `extractAttachmentText`: RTF (0043), then the new
  structured formats, then the raw `text/*` branch (which the
  structured formats must precede), then PDF (0039), image OCR (0040),
  ZIP names, then containers (0037/0038).
- `TextIndexVersion` bumps v12 → v13; the backfill re-indexes older
  rows from stored bytes, replacing raw `text/*` output with the
  deliberate parse.

## Consequences

- Calendar invites, contact cards and spreadsheets index their human
  text and nothing else; search quality matches the other deliberate
  extractors.
- Structured formats no longer depend on correct MIME labels: the
  filename extension is a second chance, and a wrong-label part whose
  bytes still parse still gets deliberate text.
- The archive stays safe: all four paths are read-only transforms of
  stored bytes, and each commit keeps the raw message untouched.
- Three more pure-Swift parsers to maintain; each is small and covered
  by unit tests plus a bridge-level test, and each nils out rather
  than guessing on foreign input.
