# 0059: Mailbox Roles Come from SPECIAL-USE, Not Folder Names

Date: 2026-11-22

## Context

The archive stores a per-mailbox `role` (inbox, sent, drafts, trash, junk,
archive). Some providers (PROVIDERS, quirk `localizedFolders`) present
folder names in the account's language — a Japanese account's Sent folder
is 「送信済みアイテム」, its Trash 「ゴミ箱」. Matching English leaf names
fails there, and a heuristic per provider's language list would grow without
bound and misclassify anything unexpected.

RFC 6154 (SPECIAL-USE) is the protocol-level answer: the server declares a
folder's role as a LIST attribute (`\Sent`, `\Trash`, …) regardless of the
name. Every M4 provider we replay against either supports SPECIAL-USE or
has English names; the quirk marks the accounts where localization bites.

## Decision

- The mailbox role is taken from RFC 6154 SPECIAL-USE attributes when the
  server declares them. `roleForSpecialUse` maps `\Sent`→sent, `\Drafts`→
  drafts, `\Trash`→trash, `\Junk`→junk, `\Archive`→archive; `\All` and
  `\Flagged` intentionally map to nil (Gmail's All Mail is the label-mode
  superset, and `\Flagged` is a view, not a storage role).
- The name-derived guess (`Ingest.role(for:)`) remains only as the fallback
  for servers that report no attributes. A server-declared role never gets
  overwritten by a name guess; a later SPECIAL-USE answer may refine a
  nil/guessed role.
- The sync creates the mailbox row at the start of each folder pass, not
  only when the first message is ingested: a folder that is empty this pass
  (or empty on the server) still needs its row and role.
- `Membership` carries an optional `role` so a pass can attach the folder's
  declared role to the ingest without a second lookup.

## Consequences

- Localized folders get the right role with zero per-language knowledge;
  new localizations need no code.
- Servers without SPECIAL-USE keep the name-guess behavior for English
  names and nil for anything else — the safe default (no role is better
  than a wrong one).
- The LIST response is now trusted for more than existence; a server that
  lies about SPECIAL-USE could set a wrong role. Replay tests pin the
  mapping, and roles affect presentation, not data safety.
