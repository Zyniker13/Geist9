# 0055: Classifying `op` CLI Failures

Date: 2026-11-21

## Context

The `op` CLI signals failures through stderr text with no stable exit code:
current releases exit 1 both when the vault is locked and when the requested
item does not exist. The credential store, however, must distinguish the two:
a missing item is `CredentialError.notFound` (the credential is gone; callers
tell the person to re-run onboarding), while a locked vault is
`CredentialError.unavailable` (retryable once the vault is unlocked). A store
that scraped `op`'s output text in every operation would both duplicate the
matching logic and risk classifying a locked vault as a deleted item.

## Decision

Classify `op`'s output at the runner boundary, once. `OpRunner.run` throws
`OpError.itemNotFound` when the binary ran and reported the item missing, and
`CredentialError.unavailable` for everything else. The
`OnePasswordCredentialStore` maps kinds to `CredentialError` in a single
private `run` wrapper that every operation reads and writes through, and
never interprets raw CLI output itself.

The classifier matches the exact first line of `op`'s known item-missing
messages ("no item found…", "item not found", "couldn't find the item"),
case-insensitively. Anything else — including "vault is locked" and an empty
stderr — stays `unavailable`, so an unmatched future message can only over-
report `unavailable` (safe: retryable), never invent a deletion. Deleting an
item that no longer exists is not an error, matching the Keychain and
in-memory backends; the fake `op` used in tests throws the same classified
kinds as the real runner, so the test suite pins the contract rather than
re-implementing CLI behavior.

## Consequences

Every operation surfaces the same error for the same condition, and
onboarding can tell "rotate the password" (notFound) from "unlock
1Password" (unavailable) from store output alone. If a future `op` release
changes its wording, the failure mode is over-reporting `unavailable`, which
a sync retry surfaces harmlessly; a classifier test lists the matched
phrasings so the change is found by test, not by user report.
