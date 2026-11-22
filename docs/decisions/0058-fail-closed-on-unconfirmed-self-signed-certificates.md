# 0058: Fail Closed on Unconfirmed Self-Signed Certificates

Date: 2026-11-22

## Context

M6 brings Proton Bridge: a local IMAP server on 127.0.0.1 whose TLS
certificate is self-signed (quirk `selfSignedLocalhost`). An engine that
"just connects" to such a server would trust whatever certificate the
endpoint presents — on a compromised machine, a hostile process listening
on the same port receives the account's password in the LOGIN command and
then serves forged mail into the archive.

The person-facing alternative — a "trust this certificate?" dialog — must
not be bypassed by the sync engine deciding trust on its own.

## Decision

- A profile carrying `selfSignedLocalhost` may only be used after the
  person confirmed the server's SHA-256 certificate fingerprint
  (`confirmedFingerprints`).
- Both `sync` and `testConnection` throw `certificateNotConfirmed` before
  any network I/O when the quirk is present and no fingerprint is
  confirmed. Fail closed: no LOGIN is ever sent to an unconfirmed
  endpoint.
- Confirming a fingerprint is the app's job (out of M4 scope); the engine
  only enforces the gate and reports a clear reason.

## Consequences

- A Proton Bridge account cannot be synced until the fingerprint flow
  exists; the failure message says exactly what is missing.
- The check precedes connection setup, so no credential can leak to an
  impostor server through a forgotten path.
- Replay tests cover both directions (refusal without a confirmed
  fingerprint, connection with one).
