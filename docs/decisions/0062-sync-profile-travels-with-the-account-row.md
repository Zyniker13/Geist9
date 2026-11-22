# Decision 0062: the sync profile travels with the account row

## Context

The sync scheduler (M4 Done-when: "start/stop per account, background
cadence, per-account politeness") must be able to run a pass for an
account after the app relaunches, without asking onboarding again. What
it needs per account is the `ProviderProfile` (host, TLS, quirks,
politeness, confirmed fingerprints) and the credential-store key — but
the index `account` table (core-v1) stores only
`(email, displayName, providerKind)`, and nothing else persists a
profile. Keeping profiles in app preferences would desync them from the
archive they belong to: archives are meant to move between machines, and
a copy of the archive opened elsewhere would have accounts it cannot
sync (or, worse, silently sync against guessed defaults).

## Decision

Make `ProviderProfile` `Codable` (every field already is) and store its
JSON on the account row: core-v17 adds a nullable `providerJSON` column
to `account`, written by `addAccount` (and updated on re-add). The
scheduler lists sync-eligible accounts with
`providerKind = 'imap' AND providerJSON IS NOT NULL` and decodes the
profile from the row. Imports and pseudo-accounts keep `providerJSON
NULL` and are never scheduled. The column is nullable, so opening an
older archive migrates with no data rewrite and nothing else reads it.

## Consequences

- The archive alone is sufficient to schedule and run a sync pass
  (credentials still come from the credential store; a missing secret
  makes the account skip its pass and surface "unlock to continue").
- A profile upgrade (a provider's settings change in a later build) is
  applied by re-adding the account or by a later migration; the stored
  profile is what the person confirmed, not live provider data.
- `providerJSON` is a schema change: DESIGN 6's table list and this
  record land in the same commit, per AGENTS.md.
