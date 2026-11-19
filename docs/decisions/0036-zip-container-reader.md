# Decision 0036: ZIP container reader

**Context.** The M2 attachment-extraction work needs text out of the container
formats mail actually carries: Office Open XML (`.docx`/`.xlsx`/`.pptx`),
OpenDocument (`.odt`/`.ods`/`.odp`), and iWork packages (`.pages`/`.numbers`/
`.key`). All three are ZIP archives whose text lives in well-known member
names (`word/document.xml`, `content.xml`, `Index.zip`/`SlideIndex.iv` …).
Extracting them means unzipping untrusted bytes that arrived in a message. A
wrong CRC or an unsupported layout must never hand the index silently-wrong
bytes. The reader also backs attachment name listing for `zip` parts.

**Decision.** A new `ArchiveExtract` module with a `ZIP` container reader
(backed by the system zlib through a `CZlib` system-library target — zlib's
license is permissive and the library ships with both platforms; no new
vendored dependency) parses the end-of-central-directory
record from the last possible position backwards (tolerating prefixes such as
self-extracting stubs), reads the central directory only, and inflates each
entry with the system zlib (`raw` mode, `-15`). Strictness rules:

- CRC-32 of every extracted entry is verified against the central directory
  value; mismatch throws `corruptCRC(name:)`.
- ZIP64 (offsets/sizes at the `0xFFFFFFFF` sentinel) is rejected as
  `unsupported`, as are multi-disk archives; support can be added later
  without changing the safe path.
- Encrypted entries (general-purpose bit 0) are rejected as `unsupported`
  rather than handed to the extractor layer as garbage.
- Only stored (0) and deflate (8) methods are extracted; other methods are
  skipped but their names still appear in listings.
- Inflation is bounded by `Limits` (`maxEntries`, `maxInflatedBytes` total and
  per entry) checked **before** decompressing from the central-directory
  declared sizes and **during** the inflate loop against actual output, so a
  lying header cannot allocate a gigabyte or overflow a signed size (zip-bomb
  guard). A mismatch between declared and produced size throws `truncated` —
  malformed, never silently accepted.
- Names decode as UTF-8 when the UTF-8 flag (bit 11) is set, otherwise
  CP-437; the raw bytes are kept for callers that need them.
- The extract loop iterates central-directory entries in file order and uses
  local headers only to locate the data (sizes are re-verified); data
  descriptors (bit 3) make the central directory sizes authoritative.

**Inflate protocol handling.** The loop feeds the whole entry at once and
pumps until `Z_STREAM_END`, treating `Z_BUF_ERROR` with zero progress as
`truncated` (the input is complete, so this can only mean corruption).
`Z_NEED_DICT` and unknown streams throw `unsupported`; any negative code is
`malformed` surfaced as `truncated`. Trailing bytes after the final block
(`avail_in != 0` at `Z_STREAM_END`) are rejected — a raw-deflate stream that
does not end with its data is corrupt.

**Consequences.**
- Test fixtures are built by an in-test `ZIPBuilder` writing spec-ordered
  fields (local header: CRC @14, compressed @18, uncompressed @22; central:
  CRC @16, compressed @20, uncompressed @24; data descriptor: CRC, compressed,
  uncompressed) plus two machine-generated deflate streams embedded as byte
  literals, each round-trip-verified (decompressed with Python `zlib` from the
  committed test file itself and compared to the raw data) so a transcription
  error in a literal cannot silently become a false test pass.
- 15 tests cover: directory reading with and without extraction, stored and
  deflated entries, UTF-8 and CP-437 names, unsupported-method skip, CRC
  rejection for both methods, data-descriptor entries, truncated archives,
  junk before the archive, ZIP64 rejection, and both inflation limits.
- `Package.swift` restructured (products/dependencies into separate `let`
  arrays) to stay under the SwiftPM manifest type-checking limit; the `CZlib`
  system-library target places `module.modulemap` and `shim.h` at the target
  root (SwiftPM does not look in `include/`).
- Linux CI needs `zlib1g-dev` (declared as the apt provider); macOS links the
  system libz.
