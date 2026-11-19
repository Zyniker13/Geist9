# Decision 0037: Container attachment text reaches the index

**Context.** Decision 0036 built the strict ZIP reader and `OfficeExtract`
(OOXML and OpenDocument text sinks). The indexing path still only searched
`text/*` attachment parts (decision 0029), so a `.docx` or `.odt` attachment
was listed in the attachment row but its content was invisible to search —
the formats mail most often carries as attachments. The pipeline version
(`TextIndexVersion`) was at v6 (entities); index content changes require a
bump and a backfill from stored bytes, never a rewrite of stored files.

**Decision.** `MailBridge.extractAttachmentText` keeps its per-leaf walk and
its `text/*` branch unchanged, and adds a container branch for attachment
leaves whose main type is not text: a new dispatcher
`containerAttachmentText(main:filename:data:)` keys on the MIME type first
(the Office Open XML and OpenDocument types) and falls back to the filename
extension for parts whose MIME type is broken or generic. It calls
`OfficeExtract.openXMLText` (`.docx`, `.xlsx`, `.pptx` layouts) or
`OfficeExtract.openDocumentText` (`.odt`, `.ods`, `.odp`, `.odg`) and joins
the result into the attachments column under the same 1 MB per-message cap,
in part order, exactly like text parts.

- Strictness carries over unchanged: when the container fails to open (CRC,
  layout, limits) or the sink yields no text, the extractor returns nil and
  the index receives nothing — the part is still listed in the attachment
  row with its real bytes (there is no partial or guessed text).
- PDF, images, and iWork previews still return nil until their extractors
  land; they are listed, not searched.
- `TextIndexVersion` moves v6 → v7: archives indexed by an older pipeline
  get their container text back through `reindexOutdated`, which re-indexes
  from the stored bytes.

**Consequences.**
- `ArchiveCore` depends on `ArchiveExtract` (the bridge is the only caller).
- The attachment row's `size` stays the decoded byte count; extraction runs
  over the decoded bytes of the part, inside the existing ingest/backfill
  transactions.
- Tests: an in-test stored-entry ZIP builder (CRC verified against zlib's
  algorithm) wraps machine-constructed OOXML and OpenDocument parts into
  multipart MIME messages; tests cover text reaching the index for each
  layout family, hostile/corrupt containers yielding no text while the part
  is still listed, and the v6 → v7 backfill restoring container text for a
  row indexed by the previous pipeline.
