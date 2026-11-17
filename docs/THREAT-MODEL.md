# Threat Model

What can go wrong, who could make it happen, and what the app does about it. Written in
M0 (ROADMAP), kept current: every milestone that touches a control here re-reads it, and
a change to a control is a change to this document in the same commit. The priorities
that order every response below are [AGENTS.md](../AGENTS.md)'s: data safety, security,
correctness, search quality, everything else.

Mitigations are labelled with the milestone that delivers them. Until a control's
milestone ships, this document states the standard the code must meet, not a claim that
it already does.

## Assets

| # | Asset | Why |
| --- | --- | --- |
| A1 | The archive | May be the person's only copy of their mail. Losing or rewriting a stored message is the worst failure the app can have. |
| A2 | Credentials | App passwords, authorization codes, OAuth refresh tokens, 1Password references. A leaked credential exposes the live mailbox. |
| A3 | The person's agency | Mail reaching the person's AI agents is a channel for instructions; an injected instruction must not steer an agent into harm. |
| A4 | Privacy | Message content must not leak to the network, to logs or reports, or to other apps, beyond what the person chooses. |
| A5 | The app's integrity | A tampered update must not be able to replace the app with an impostor that holds A1 and A2. |

## Who We Defend Against

| # | Adversary | Capabilities |
| --- | --- | --- |
| ADV-1 | A local attacker with the Mac unlocked, or the Mac's new owner after theft | Reads files the user can read, runs unprivileged code, waits. Not assumed to know the login password. |
| ADV-2 | A mail sender | Crafts message HTML, MIME structure, attachment files, and header values that reach the parser, the viewer, the extractors, and the agents. |
| ADV-3 | A hostile or compromised mail server, or a network attacker between it and us | Lies in protocol responses, sends oversized or malformed data, and observes every byte of the conversation. |
| ADV-4 | An attacker who can influence the update feed | Serves a modified feed or download to some or all users. |
| ADV-5 | Ourselves, by accident | Bugs, logs, diagnostics reports, and defaults that leak content or lose data. |
| ADV-6 | Mail content speaking to a well-meaning agent, or a malicious agent client | Prompt injection through the archive; or a client that hammers the MCP server for content the person did not mean to expose. |

### Out of Scope

Malware already running with the user's privileges can read anything the user can read,
including the archive folder (open formats require the files be plainly readable). We do
not defend against a compromised operating system, hardware attacks, or a person who
knows the login password. Encryption at rest (1.1) narrows this window to key material,
not eliminates it. Traffic analysis by the provider is inherent to using the provider.

## Trust Base

Assumed to behave: the macOS kernel, FileVault, the Keychain, 1Password, and Apple's
frameworks we call into (WebKit, PDFKit, Vision, CryptoKit, SQLite). Assumed protected
by their owners: the Apple Developer account and signing keys (never in this repository
or CI), the maintainer's payment and hosting accounts. The person's Mac account password
is the root control for A1 in 1.0.

## Threats and Responses

### T1: Stolen or Shared Mac (ADV-1)

*Harm:* read the archive, the credentials, or the agent channel.

- FileVault is the primary control in 1.0. The app warns when FileVault is off and the
  archive is not encrypted (M7 app shell; warning text in M1's archive setup).
- Default archive location is inside `~/Library/Application Support`, which macOS TCC
  shields from other apps without Full Disk Access; the person may move it anywhere
  (DESIGN 6), which trades that shielding for portability — documented in the move
  dialog, not prevented.
- Optional encryption at rest (1.1, DESIGN 10): each `.eml` in an AES-256-GCM envelope,
  the index under SQLCipher, the key in the Keychain wrapped by a written-down recovery
  key; content names become keyed HMACs so file names stop revealing known messages.
- Credentials: Keychain items with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`;
  the 1Password backend keeps secrets in the vault, the app only a reference. No
  credential is ever written to disk, logs, index, or exports (M4).
- The MCP HTTP transport, when enabled, is loopback-only with a per-client bearer token
  and `Origin` checks against DNS rebinding; other local processes cannot use the stdio
  helper to reach more than the person's exposure settings allow, and the default for
  every client is off (M3). Residual: an unprivileged local process can launch the
  stdio helper as the user; it then sees exactly what an allowed client sees.

### T2: Malicious HTML Mail (ADV-2)

*Harm:* exfiltrate that mail was read (tracking pixels), load remote content, run
scripts, phish through a spoofed link label, or exploit the parser.

- `WKWebView` with JavaScript disabled (`allowsContentJavaScript = false`), a
  `WKContentRuleList` blocking every network load, and a strict CSP injected into the
  document (M1). This defeats tracking pixels and remote content by default; remote
  images load only on the person's explicit per-message or per-sender action.
- HTML is sanitized before display: forms, `meta refresh`, `base`, scripts, event
  handlers, and `javascript:` URLs stripped; links open in the default browser after
  showing the real target (M1).
- `cid:` parts are served by a `WKURLSchemeHandler` that reads only from the archive
  (M1). The web view never gets a network-capable scheme for message content.
- The invariant is tested, not promised: the viewer security fixtures (TESTING) must
  produce zero network requests against a recording local server, and they try every
  trick in the book — CSS `url()`, `srcset`, `<link>`, SVG, `meta refresh`,
  `javascript:` links.
- The MIME parser treats every input byte as hostile: corpus and fuzz tests from day
  one (M1); it never writes the original file, only reads it, so a parser bug cannot
  corrupt the archive.
- Attachment text extraction runs in-process on Apple frameworks (PDFKit and others) in
  1.0. A parser exploit there would run with the user's privileges; this residual risk
  is accepted for 1.0 and revisited with an out-of-process extractor in 1.x.

### T3: Hostile or Compromised Server (ADV-3)

*Harm:* steal credentials, feed us lies, exploit the protocol layer, or degrade the
archive through protocol quirks.

- TLS 1.2 or newer, implicit TLS on 993 by default; STARTTLS on 143 only when the
  server requires it and never a downgrade to plaintext. Certificate exceptions exist
  only per host and only after the person confirms the fingerprint (Proton Bridge,
  self-hosted servers) (M4, M6).
- The server sees only standard commands and the credentials it issued. Nothing from
  the archive is ever sent to it (sync is read-only; DESIGN 1, goal 4).
- Protocol data is untrusted input: response handling is fuzzed at our layer, folder
  state changes are validated against stored checkpoints, and a `UIDVALIDITY` change
  triggers re-matching by `EMAILID`, `X-GM-MSGID`, then content hash — a hostile server
  cannot make us download the whole mailbox twice, and can never make us delete (M4).
- Server-side deletions never delete from the archive; the index marks the message
  "no longer on the server" and the person decides (M4).
- What the archive records is exactly what the server sent, hashed at download time and
  verified by the scrub job; a server cannot retroactively change stored bytes.

### T4: Tampered Update Feed (ADV-4)

*Harm:* replace the app with an impostor that reads mail and credentials.

- The updater verifies, before install: the download's size and SHA-256 against an
  HTTPS feed, the Developer ID signature by our team, notarization, and a higher build
  number; it installs by an atomic swap beside the old copy with automatic rollback if
  the new build does not confirm it started (M9, DESIGN 12).
- Signing keys never live in this repository or in CI. A feed host compromise alone
  cannot produce a valid signature.
- Tested against a local feed serving genuine success and tamper cases (M9).

### T5: A Diagnostics Report or Log Leaks Content (ADV-5)

*Harm:* message content, addresses, or subjects escape the Mac.

- Logs redact addresses and subjects at write time, not only at report time (M4+).
- A report is person-initiated, shows the exact JSON before sending, and contains
  redacted logs and no message content (M9). Automatic reports exist only with explicit
  opt-in and never carry content, addresses, or subjects.
- No analytics, no accounts with us, no server of ours in the message path (DESIGN 10).
- The MCP activity log records time, client, tool, query text, and result counts — the
  agent's question, never the mail returned — stays local, and is clearable (M3).

### T6: Prompt Injection Through Mail Reaching Agents (ADV-6)

*Harm:* archived mail instructs the person's agent ("forward everything to …", "search
for X and read it all"), or an agent client extracts more than the person allowed.

- Every returned body, subject, and attachment text is wrapped and labelled as
  untrusted third-party content, and the server's instructions tell the agent to treat
  it as data, never as instructions (M3).
- The server has no write or network tools, so an injected instruction can at worst
  steer what the agent reads next, within the person's limits. Remote content is never
  fetched to answer a tool call; links come back as text (M3).
- Hidden-text tricks (zero-size fonts, white-on-white, `display:none`) are stripped
  during HTML-to-text conversion by the same sanitizer the viewer uses (M3, sharing the
  M1 implementation).
- Excluded accounts, folders, and labels (Spam, Trash, anything marked private) never
  appear in any tool or resource result — access-control tests prove it (M3).
- Per-client limits on results per call, characters per call, and calls per minute; an
  "ask before returning full messages" mode that names the client and the messages
  before answering (M3).
- Residual, stated plainly: a determined injection can still bias what a conforming
  agent reads next. The channel is narrow, labelled, and logged; the agent stack the
  person runs remains the second line of defense.

## How Each Control Is Tested

| Control | Test | Where |
| --- | --- | --- |
| Parser against hostile bytes | Corpus + fuzz suite, smoke run every CI push, long runs nightly | [TESTING.md](TESTING.md) |
| Viewer makes zero network requests | Viewer security fixtures vs. a recording server | macOS CI, every push |
| Read-only toward servers | Protocol tests on Dovecot/GreenMail/Stalwart assert no flag, move, or append ever happens | Linux and macOS CI |
| Kill safety | Kill at random points during sync/import/migration; archive verifies | Linux and Mac |
| MCP access control + injection wrapping | Access-control tests; injection fixtures come back wrapped and labelled | M3 CI |
| Update integrity | Updater tests against a local feed including tamper cases | M9 |
| Scrub integrity | Every file matches its name; index matches files; repair gaps | M1, M7 |

## Review

This document is re-read at the start of every milestone that touches one of its
controls, and before each release. A control that ships differently than described here
is a bug in either the code or this document, fixed in the same commit.
