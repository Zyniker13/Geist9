# Archive Format

The on-disk format of a Bristlecone archive, documented so third-party tools can read
one without this app. The format is the contract decision 0001 commits to: the `.eml`
files are the truth, the index is rebuildable, and a stored message's original bytes are
never rewritten. This is the v1 draft; M1 finalizes it as it implements it, and any
later change bumps the version and ships a migration in the same commit.

A format change means: a change to the directory layout, the manifest fields, the index
schema, or the meaning of any stored value. Additions that old readers can ignore
(new optional manifest fields, new tables) are compatible and do not bump the version
for readers; they still ship with a migration test.

## Layout

```
<name>.emailarchive/
  manifest.json                 format version, identity, creation, encryption info
  messages/ab/cd/<sha256>.eml   original bytes, never rewritten (see "Messages")
  index.sqlite                  SQLite index, WAL mode (see "Index Schema v1")
  attachments-text/             extracted text cache, rebuildable, keyed by content hash
  logs/                         operational logs, redacted at write time (DESIGN 10)
```

`attachments-text/` entries are named `<message-hash>/<attachment-index>.txt` and may be
deleted at any time; the app regenerates them. Nothing else in the archive is
regenerable except `index.sqlite` (see "Recovery").

## Messages

- One `.eml` file per distinct message body, named by the lowercase hex SHA-256 of its
  bytes, sharded two hex digits deep: `messages/ab/cd/<64-hex>.eml`. The name is the
  whole integrity promise: a file whose bytes do not hash to its name is corrupt.
- The same bytes stored for two accounts, folders, or imports share one file. Membership
  lives in the index, never in the file name or the bytes.
- Files are written atomically: write to a temporary file in the destination directory,
  `fsync` the file, rename over the final name, then `fsync` the directory. A crash
  therefore leaves either the old file, the new file, or a temporary file, never a
  half-written message. Temporary files are named `<hash>.eml.tmp-<pid>-<n>` and are
  safe to delete during a scrub.
- Importers and sync must parse nothing to store a message: the bytes are stored
  verbatim, and parsing feeds only the index.
- Encrypted archives (1.1): files are sealed envelopes and names become keyed HMACs of
  the plaintext (so names do not reveal known messages); the manifest's `encryption`
  field says so and carries the KDF parameters. Unencrypted archives have
  `"encryption": null`. Readers that only support plaintext refuse an encrypted archive
  with a clear error rather than half-reading it.

## manifest.json

UTF-8 JSON, written atomically like a message file. Required fields:

| Field | Meaning |
| --- | --- |
| `format` | `1` in v1. Bumped on any incompatible change, with a migration. |
| `created_at` | RFC 3339 UTC timestamp of archive creation. |
| `app_version` | The app build that last wrote the manifest. |
| `archive_id` | A random UUID generated at creation, stable for the archive's life. |
| `encryption` | `null` in v1 unencrypted archives; an object with scheme and KDF parameters in 1.1. |

Writers may add optional fields (for example statistics) that older readers ignore.

## Index Schema v1

SQLite, WAL mode, accessed through GRDB in the app. Schema version is stored with
SQLite's `PRAGMA user_version`; `1` is the version below. A third-party tool may read
the index read-only (WAL mode allows concurrent readers) but the `.eml` files remain
the truth when index and files disagree.

| Table | Columns | Notes |
| --- | --- | --- |
| `account` | `id`, `kind` (`imap`/`jmap`/`import`/`bridge`), `email`, `display_name`, `provider`, `created_at` | Accounts never store secrets here. |
| `mailbox` | `id`, `account_id`, `name`, `special_use`, `uidvalidity`, `uidnext`, `highestmodseq`, `highest_uid_seen` | One row per folder or, for Gmail, the synthesized label view; `special_use` from IMAP SPECIAL-USE. |
| `message` | `id`, `sha256`, `size`, `internal_date`, `received_date`, `subject_normalized`, `message_id`, `in_reply_to`, `references_json`, `thread_id`, `sender_json`, `flags_json`, `import_source`, `removed_from_server_at` | `sha256` matches the file name. `subject_normalized` is the folded, whitespace-collapsed subject. Threading per DESIGN 7 (JWZ + provider thread IDs). |
| `message_mailbox` | `message_id`, `mailbox_id`, `uid`, `flags_json`, `first_seen_at`, `last_seen_at` | Membership; a message can belong to many mailboxes or labels. |
| `label` | `id`, `account_id`, `name` | Gmail labels and equivalent provider labels. |
| `message_label` | `message_id`, `label_id` | The Gmail label map synced from `X-GM-LABELS`. |
| `thread` | `id`, `subject_normalized`, `first_date`, `last_date` | Groups conversations. |
| `address` | `id`, `message_id`, `kind` (`from`/`to`/`cc`/`bcc`/`reply_to`), `name`, `email`, `local_part`, `domain` | Split for search (DESIGN 6A, address-aware tokens). |
| `attachment` | `id`, `message_id`, `index`, `filename`, `content_type`, `size`, `content_id`, `sha256`, `is_text_extracted` | Attachments stay inside the `.eml` bytes; the index locates them. |
| `search` | FTS5 tables and trigram tables per DESIGN 6A | Owned by ArchiveSearch; tokenized text with the tokenizer version recorded. |
| `extractor_state` | `id`, `kind`, `version`, `entity`, `state_json` | Background queue progress: which attachments are extracted, OCR'd, embedded. |
| `sync_state` | `account_id`, `mailbox_id`, `checkpoint_json` | Resumable checkpoints per folder (UIDVALIDITY, high-water UID, HIGHESTMODSEQ, JMAP state strings). |

Migrations are versioned and tested on archives made by every earlier released version
(TESTING, "Migration"); a migration never touches message files and is resumable after
a crash.

## Recovery

- **Scrub:** recompute the SHA-256 of every file and compare with its name; report and
  quarantine mismatches (never delete them silently). Delete stray `.tmp-*` files.
  Verify every `message` row's file exists.
- **Rebuild index:** the index can be rebuilt from the `.eml` files plus `sync_state`.
  Every milestone with index changes proves a rebuild produces the same search results.
- The index is disposable by design; no archive value lives only in it except
  `sync_state`, which is regenerable by a full re-sync that downloads nothing twice
  (content addressing collapses duplicates).

## Rules for Writers

1. Never rewrite a stored message's bytes. A correction to a bad parse or a re-import
   writes new index rows, not new files.
2. Never delete a message file as a side effect of sync. Only a person-initiated
   deletion of archive content may remove a file, and it must remove the index rows in
   the same transaction and the file only after.
3. Write atomically (temp, `fsync`, rename, `fsync` directory) for every file in the
   archive, including the manifest.
4. One writer at a time: the app and the login item coordinate through a single-writer
   lock (DESIGN 5); readers (the MCP helper) open the index in WAL read mode.
