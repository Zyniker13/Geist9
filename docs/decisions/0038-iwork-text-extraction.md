# Decision 0038: iWork package text extraction

## Context

M2.3 extracts text from container attachments. Decision 0036 added the ZIP
container reader and decision 0037 wired Office Open XML and OpenDocument
packages into the index. iWork packages (.pages, .key, .numbers) remain:
they are ZIP containers too, and the M2 extractor list in DESIGN 6A names
them.

An iWork package from the index.xml era (iWork '09 through '12) holds its
document text in `index.xml` as XML in the `http://schemas.apple.com/iWork/
document` and `http://schemas.apple.com/2008/sf` namespaces: paragraphs and
text runs appear as `p` and `span` elements (the `sf:` prefix by
convention), tables carry their cell text in the same elements, and
line/tab structure appears as `br` and `tab` elements. Style, theme, and
font subtrees hold design data — font names, colour labels, cell-style
identifiers — which is noise for search and must not be indexed. iWork '13
and later moved to a binary protobuf-based `index.xml`; that is not XML.

## Decision

`OfficeExtract.iWorkText` reads an iWork package the same strict way as
the other container formats (decision 0036): `ZIP.open` with the
`attachments` limits; no `index.xml`, no text; any container error, no
text.

The shared `XMLTextSink` gains an `iwork` kind:

- Text is captured inside `p` and `span` elements only.
- Every element whose name contains "style", or is `theme` or `fonts`,
  is skipped entirely (start/end counting), so style text never reaches
  the index even when it sits around content elements.
- `br` becomes a newline and `tab` a tab (outside skipped subtrees).
- Every `p` element closes a piece; pieces join with a newline.
- A parse error poisons the whole result: the extraction returns nothing
  rather than a partial text, so nothing quietly wrong is indexed.

The binary `index.xml` of iWork '13 and later fails XML parsing and yields
no text; the part is still listed with its real bytes. No iWork plist or
protobuf decoder is added for now: the index.xml era covers readable text
cheaply, and a binary decoder would be a new, larger surface.

`MailBridge.containerAttachmentText` dispatches iWork on MIME type first
(`application/vnd.apple.pages`, `application/vnd.apple.keynote`,
`application/vnd.apple.numbers`), falling back to the filename extension
(.pages, .key, .numbers) for broken MIME parts.

`TextIndexVersion` bumps from v7 to v8: ingest marks new rows v8, and
`reindexOutdated` re-derives older rows from their stored bytes, adding
iWork text to previously indexed mail. No schema change: the attachments
column keeps its shape.

## Consequences

- .pages/.key/.numbers attachments in the readable-XML era become
  searchable; iWork '13+ packages keep working at the ZIP layer (listed,
  verified) but contribute no text until a binary reader is built.
- Style text stays out of the index; a package whose only text is inside
  style subtrees yields no text rather than font names.
- The strictness contract carries over unchanged: a hostile container —
  lying sizes, wrong CRC, malformed XML, a non-ZIP file with an iWork
  name — yields no text but the part is still listed.
- Older rows backfill at the next reindex pass, one version-bump cost
  like 0037.
- A future binary iWork reader can replace the no-text path without a new
  decision number if it keeps this contract; it would bump
  `TextIndexVersion` again.
