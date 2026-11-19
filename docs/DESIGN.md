# Design

How Bristlecone Email Archiver is built. [ROADMAP.md](../ROADMAP.md) says in what order; [PROVIDERS.md](PROVIDERS.md) covers each provider; [TESTING.md](TESTING.md) covers tests and budgets. Section numbers are kept stable so other documents can cite them.

## 1. What the App Is

A Mac app that keeps a complete, searchable, provider-independent copy of a person's email. It reads from the providers, never changes anything there, and stores every message as a standard `.eml` file the person owns. If the app disappears tomorrow, the archive is still a folder of open-format files plus a documented SQLite index.

### Goals

1. **Find anything, fast.** Search is the primary feature. Every word in every message and every attachment (including scanned PDFs and images, by on-device OCR) is indexed, in every language the providers serve, with ranked, instant results, facets, and optional on-device semantic search, across all accounts and offline (section 6A).
2. **Agent access.** A built-in MCP server lets the person's own AI agents (Claude Desktop, Claude Code, any MCP client) search and read the archive through the same engine, locally, read-only, within limits the person sets (section 9A).
3. **Complete.** Every message in every folder or label, with its original bytes, flags, and folder or label membership, from the twenty largest providers and any standards-compliant IMAP server.
4. **Read-only toward the server.** The app never sets `\Seen`, never deletes, never moves. Restore (writing back) is a separate, explicit action.
5. **Incremental.** After the first sync, an update costs roughly what changed, not the size of the mailbox.
6. **Safe viewing.** HTML mail renders with no scripts and no remote loads unless the person asks.
7. **Open formats in and out.** Import mbox, Apple Mail, Google Takeout, `.eml` folders, Maildir, Proton and Tuta exports; export the same.
8. **Private.** Credentials in the Keychain, optional encryption at rest, no analytics, no message content in any report.
9. **1Password, first class.** People can keep every credential the app needs in a dedicated 1Password vault instead of (or as well as) the Keychain (see "Credentials and 1Password").
10. **Features first.** The app is distributed directly (Developer ID, notarized). A Mac App Store version ships only if it loses no feature; if it would, a separate "lite" edition may ship, but no feature is cut or weakened to fit App Store rules (decision 0003).

### Not in Scope for 1.0

Sending mail, acting as a full mail client, calendars and contacts, POP3, Exchange EWS, Outlook PST import (see 1.x), an iOS app, server-side or cloud storage of archives, shared or team archives, legal-hold and e-discovery features.

## 2. Recommendations at a Glance

| Topic | Recommendation |
| --- | --- |
| IMAP protocol layer | Apple's [swift-nio-imap](https://github.com/apple/swift-nio-imap) (Apache-2.0, fuzzed, builds on Linux) wrapped by our own sync engine |
| JMAP | Our own small client over URLSession (Fastmail first, then any JMAP server such as Stalwart) |
| MIME | Our own streaming parser in Swift, corpus-tested and fuzzed; charset decoding through Foundation/ICU |
| Storage | Content-addressed `.eml` files (SHA-256) in a user-chosen archive folder, plus a SQLite index via GRDB |
| Search (primary feature) | Our own search engine on SQLite FTS5: language-aware tokenizing (Apple's NaturalLanguage for CJK and Thai), BM25 with field weights and recency, typo tolerance, facets, attachment text with on-device OCR (Vision), and hybrid semantic search from on-device embeddings; a judged relevance test set gates every change |
| Viewer | `WKWebView` with JavaScript off, a content rule list blocking every remote load, and a `cid:` scheme handler |
| Auth | OAuth 2.0 with PKCE through `ASWebAuthenticationSession` where offered; app passwords and authorization codes everywhere else; Proton through Bridge on localhost |
| Encryption at rest | 1.0 relies on FileVault; 1.1 adds an optional encrypted archive (AES-256-GCM envelope with HKDF-SHA256 key derivation, CryptoKit) and SQLCipher for the index |
| Background sync | A login item registered with `SMAppService` that runs the same engine while the app is closed |
| Credentials | A `CredentialStore` with two backends: the macOS Keychain, and a dedicated 1Password vault the person chooses |
| Distribution | Developer ID, notarized, self-updating from a signed feed; a Mac App Store edition only at full feature parity (M11) |
| Price | Subscription $9.99 a year, or $119.99 lifetime; the archive always stays readable, searchable, and exportable |
| Diagnostics | A person-initiated report (the person sees the exact JSON first), with redacted logs and no message content; added in M9 |
| Agent access | A local, read-only MCP server bundled in the app (stdio helper plus optional loopback HTTP), shipped as a Claude Desktop extension too |
| Code layout | A Swift package whose core builds and tests on Linux, plus a thin macOS app target |


## 3. Providers

See [PROVIDERS.md](PROVIDERS.md).

## 4. Authentication

### OAuth Flow

- `ASWebAuthenticationSession` with PKCE (S256) and a `state` check. Works in the sandbox and in both channels.
- Redirects: a loopback redirect where the provider requires it for desktop clients (Google's desktop client type), otherwise a claimed custom scheme. Each provider's choice lives in the provider database.
- Tokens: refresh token in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, shared with the login item through the app group's Keychain access group); access tokens in memory only.
- Refresh on `AUTHENTICATIONFAILED`, once, then mark the account "needs sign-in" and stop; never loop.
- Scopes are read-only wherever the provider offers one (`mail-r` at Yahoo, Fastmail's read-only token). Google and Microsoft have no read-only IMAP scope, which the privacy policy must explain.

### Per-Provider Registration Work

| Provider | Registration | Gate before a public release | Owner |
| --- | --- | --- | --- |
| Google | Cloud project, OAuth consent screen, desktop client ID | Brand verification, then restricted-scope verification and a **CASA Tier 2** assessment by an authorized lab, renewed every year. Until then: "testing" mode, capped at 100 named test users and showing a warning screen. Needs a homepage, privacy policy, and verified domain. MailMate passed this route in 2025 ([MailMate list](https://lists.freron.com/mailmate/2025-April/018270.html)), so it is achievable for a desktop client. | Maintainer |
| Microsoft | Entra app, "accounts in any organizational directory and personal Microsoft accounts", public client | Publisher verification (needs a Microsoft Partner ID for Bristlecone IT Services) so consent screens show a verified publisher | Maintainer |
| Yahoo / AOL / AT&T | Yahoo developer app plus the Mail API access request form | Yahoo's internal review; app passwords cover the gap | Maintainer |
| Yandex, Zoho, Mail.ru | Developer apps | Optional; app passwords are the 1.0 path | Later |
| Fastmail | Read-only API token in 1.0; OAuth app registration for 1.x | Fastmail's partner process | Later |

Client IDs are injected at build time from the build environment, never committed. Until they exist, OAuth is developed and tested against a local OAuth 2.0 test server (authorization code with PKCE, refresh rotation, revocation, error cases), and the real providers are listed under "Needs the Maintainer" in STATUS.md.

Google restricted-scope verification (CASA) is deliberately not pursued at launch (decision 0004): Gmail and Google Workspace launch with app passwords, and Google OAuth stays built, tested, and enabled only for a testing-mode client. The decision is reviewed in May 2027.

### Passwords

App passwords, authorization codes, and Bridge passwords go straight to the credential store (below). The setup screen for each provider shows that provider's exact steps and a link to its page, since "create an app password" is the step people get stuck on.

### Credentials and 1Password

Everything that touches a secret goes through one `CredentialStore` protocol (`get`, `put`, `delete`, `rotate`), with two backends the person chooses between per archive, and can mix per account:

- **Keychain** (default): generic-password items, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, shared with the background helper through a Keychain access group.
- **1Password**: a dedicated vault the person picks or creates (default name "Bristlecone Email Archiver"). Each mail account is one item (category Login, or API Credential for tokens) with fields for the username, the secret (app password, authorization code, Bridge password, or OAuth refresh token), host, port, auth method, and provider, tagged `email-archiver`. The app stores only the item's secret reference (`op://<vault>/<item>/<field>` by ID, not title) and non-secret account settings.

How the app talks to 1Password, in the order M0 evaluates them (decision 0005 records the result):

1. **The official 1Password SDK with desktop app integration**, through a small bundled helper (the SDKs are Go, JavaScript, and Python; a Go helper speaking JSON over stdin and stdout keeps 1Password code out of the app process). The 1Password app handles unlock and Touch ID, and its approval prompt names our app.
2. **The 1Password CLI (`op`) with desktop app integration**, if the SDK route is not available on macOS: the app finds `op`, checks its version and signature, and runs it with a fixed argument list (never a shell).
3. **A service account token**, for unattended Macs where nobody unlocks 1Password (a Mac mini archiving overnight): the token is stored in the Keychain, scoped by 1Password to that one vault, read-only unless the person needs write-back.

Behavior:

- Secrets are read at the start of a sync and held in memory only for that session. Nothing from 1Password is written to disk, logs, the index, or exports.
- OAuth refresh tokens that the provider rotates (Microsoft does) are written back to the same item; if the vault is read-only, the person is told to keep OAuth accounts in the Keychain.
- When 1Password is locked or unreachable, background sync for those accounts waits and the app shows "Unlock 1Password to continue archiving", never a password prompt of its own.
- **Import from 1Password:** the setup screen can search the chosen vault for existing mail credentials (items with an IMAP host or a known provider domain) and add those accounts in one step.
- **Move credentials** between the Keychain and 1Password in Settings, per account or all at once, verified by a test sign-in before the old copy is deleted.
- The password fields also accept the system AutoFill, so a password manager can fill them without any integration.
- 1Password integration is one of the features that rules out the App Store sandbox for the direct build (decision 0003).

## 5. Sync Engine

### IMAP Algorithm

Per account:

1. Connect, `CAPABILITY`, `ID`, authenticate, `ENABLE QRESYNC` (or `CONDSTORE`), `COMPRESS=DEFLATE` if offered.
2. `LIST` with `SPECIAL-USE` and `STATUS (UIDVALIDITY UIDNEXT HIGHESTMODSEQ MESSAGES)`. Record new, renamed (by `OBJECTID` `MAILBOXID` where offered), and vanished folders.
3. Per folder, with a stored `(UIDVALIDITY, highest UID seen, HIGHESTMODSEQ)`:
   - **Unchanged UIDVALIDITY:** fetch new UIDs above the high-water mark; with QRESYNC, `SELECT ... (QRESYNC ...)` gives flag changes and `VANISHED` in one round trip; without it, `UID FETCH 1:* (FLAGS)` in chunks and diff.
   - **Changed UIDVALIDITY:** treat the folder as new, re-list it, and match existing archive copies by `EMAILID`, then Gmail's `X-GM-MSGID`, then content hash, so nothing downloads twice.
4. Download with `UID FETCH <set> (BODY.PEEK[] RFC822.SIZE INTERNALDATE FLAGS [X-GM-LABELS X-GM-MSGID X-GM-THRID] [EMAILID THREADID])`. `BODY.PEEK` never marks mail read. Batches sized by bytes, not count. Streams straight to a temp file, hashes as it writes, then renames into place.
5. Commit a folder's checkpoint only after its messages are durable, so a crash or kill resumes exactly where it stopped.
6. Server-side deletions never delete from the archive. The index marks the message "no longer on the server" with the date, and the person decides (setting: keep forever, the default).

Gmail special case: archive `[Gmail]/All Mail` (plus Spam and Trash if the person wants them), store each message once, and record labels from `X-GM-LABELS`. Other label folders are not downloaded at all, which avoids multiplying Gmail's 2,500 MB daily cap.

### Politeness and Limits

- A per-provider profile: maximum connections (start at 2 for most, 4 for Fastmail and self-hosted), byte budget per day (Gmail and Workspace: stay under about 2,000 MB to leave the person's own clients headroom), pacing between batches.
- A first sync of a large Gmail account will take days by design. The UI says so up front, shows the projected finish date, and lets the person raise or lower the pace.
- Exponential backoff with jitter on `BYE`, throttling responses, and timeouts; a provider-specific "come back later" when a daily cap is hit.
- `IDLE` on Inbox only while the app is open; otherwise scheduled polling (default every 30 minutes).

### JMAP

`Session` → `Mailbox/get` → `Email/query` (sorted by `receivedAt`, paged) → blob download for the raw message → later `Email/changes` and `Mailbox/changes` from stored `state` strings. Push through EventSource while open. The same storage layer as IMAP, keyed by JMAP `id`.

### Background Sync

A login item (`SMAppService.loginItem`, a helper inside the app bundle) runs the same engine on a schedule while the main app is closed. Both processes open the same archive, with SQLite in WAL mode and a single-writer lock so they never write at once. It stops when the Mac is on low battery or a metered network, and when the archive's disk is low.

## 6. Storage

### Archive Layout

```
<Archive>.emailarchive/
  manifest.json            format version, created, app version, encryption info
  messages/ab/cd/<sha256>.eml   original bytes, never rewritten
  index.sqlite             accounts, folders, messages, labels, flags, threads, FTS
  attachments-text/        extracted text cache (rebuildable)
  logs/
```

- Content addressing makes duplicates across accounts and imports free and lets a scrub job verify every file against its name.
- The `.eml` files are the truth; the index is rebuildable from them plus a small per-account sync state, and there is a "Rebuild index" command.
- Default location: the app's container. The person may move it anywhere (external disk, NAS share) through an open panel; the app keeps a security-scoped bookmark. Network volumes get a warning about SQLite on SMB.
- The schema and file layout are documented in the repository so third-party tools can read an archive.

### Index

GRDB over SQLite in WAL mode. Tables: `account`, `mailbox`, `message` (hash, size, dates, normalized headers, import source, provider thread id, `textVersion` recording which text-index pipeline indexed the row), `message_mailbox` (membership, UID, flags, first and last seen), `label`, `thread`, `address`, `attachment`, `saved_search` (sidebar smart folders), `message_text` (FTS5, exact-token index), `message_trigram` (FTS5 `trigram` tokenizer over the same columns holding raw folded text, for substring and CJK fallback; see 6A and decision 0021), and `message_entity` (rows extracted at ingest — kind, raw value, normalized number, currency; populated for amounts so far, more kinds to come; removed with their message; see 6A and decision 0031). Migrations are versioned and tested on archives made by every earlier version; rows whose `textVersion` is older than the current pipeline are re-indexed from their stored bytes by the background backfill (`reindexOutdated`), never by rewriting the stored files.

## 6A. Search and Indexing (a Primary Feature)

Search is what the person buys this app for, and the same engine answers their agents through MCP. It gets its own module (`ArchiveSearch`), its own milestone (M2, before any network code), its own test suite with relevance scoring, and performance budgets that fail CI.

### What Gets Indexed

| Source | How | When |
| --- | --- | --- |
| Headers | Subject, from, to, cc, bcc (when present), reply-to, list-id, display names and addresses split into name, local part, and domain | At ingest |
| Body | The best text part, or HTML converted to text (scripts, styles, and hidden text dropped). Quoted replies and signatures are detected and indexed separately at lower weight, so a search hits the message that said it, not the twenty replies quoting it | At ingest |
| Attachments, text-bearing | PDF (PDFKit), plain text, CSV, HTML, RTF and RTFD, Office Open XML (`.docx`, `.xlsx`, `.pptx`, read as zipped XML), OpenDocument, iWork (`.pages`, `.numbers`, `.key` preview text), `.ics` and `.vcf`, `.eml` attached inside mail, and file names inside ZIP archives | Background queue after ingest |
| Attachments, image-only | Scanned PDFs, photos of receipts, screenshots: on-device OCR with Vision (`VNRecognizeTextRequest`, accurate mode, language correction) | Background queue, lowest priority, pausable, on power only by default |
| Extracted entities | Amounts and currencies (normalized decimal), dates (UTC epoch, midnight for date-only forms), phone numbers, tracking numbers, booking codes (recognized only beside their keyword), domains from URLs and bare hosts — shared patterns on every platform, plus `NSDataDetector` on macOS for multilingual dates and national phone formats; postal addresses wait until an operator needs them | At ingest |
| Provider metadata | Gmail labels, folders, flags (read, starred, answered), importance, thread IDs, "removed from server" state | Each sync |

Nothing is sent anywhere to be indexed: every extractor, OCR, and embedding model runs on the Mac.

### Tokenizing in Every Language

The twenty providers span English, Chinese (QQ, 163), Korean (Naver), Russian (Yandex, Mail.ru), German (GMX, WEB.DE, T-Online), and French (Orange), so search must work in all of them.

- Text is tokenized in Swift before it reaches SQLite: `NLTokenizer` word segmentation (dictionary-based for Chinese, Japanese, and Thai, which have no spaces), then case folding, Unicode NFKC, and diacritic folding.
- Stemming per detected language (Snowball stemmers for the European languages, vendored with their BSD license — 12 languages: danish, dutch, english, finnish, french, german, italian, norwegian, portuguese, russian, spanish, swedish), so "invoices" finds "invoice" and "Rechnungen" finds "Rechnung". The language is detected once per message, on its longest part, with a confidence gate (decision 0026); subject, body, and quoted are stored folded **and** stemmed — both forms, so the exact folded form is always searchable no matter what the language guesses say — while addresses and attachment names keep their exact folded tokens. Query terms expand to their forms — the folded form, the stem in the query's detected language, and the stem in English — so a wrong language guess on either side can never lose the exact match. Exact-match search stays available with quotes. The two forms live in separate FTS5 columns (`message_text` has `subject_stem`, `body_stem`, `quoted_stem` beside the original columns, added by a table-rebuilding migration; decision 0026): stems cannot be interleaved into the original token stream, because that destroys phrase adjacency — "running budgets" indexed as "running run budgets budget" would make the phrase `"running budgets"` match nothing. Phrases always run on the original columns, which keep the folded stream exactly as it was; the stem columns carry one stem per token for term recall.
- A trigram index alongside, for substrings and partial words ("acct 4417", parts of order numbers) and for CJK queries the segmenter splits differently from the text. M2 measures its size on 1 million messages and narrows it to the fields where it pays off if it is too large.
- Address-aware tokens: `jane.doe@example.com` matches `jane`, `doe`, `jane.doe`, `example`, and `example.com`.
- Attachment text: the decoded text of `text/*` attachment parts (plain text, CSV, HTML reduced) is searchable in the attachments column, next to the file names, capped at 1 MB per message (decision 0029). PDF, Office, iWork and image text arrive with the later extractors.

### Ranking

- BM25 per field with weights (subject and sender above body, body above quoted text and attachments), plus a recency boost and small boosts for messages the person sent, replied to, or starred.
- Thread-level grouping: results collapse to conversations by default, with the matching message highlighted.
- Exact phrase and all-terms matches rank above partial matches. On a query that would return nothing, the index climbs a ladder (decision 0035): the exact index, then the trigram substring fallback, then a one-edit typo rescue — for a single-word text leaf, every one-edit variant that is a real word of the archive's own vocabulary is re-matched in the same columns the leaf searched (so a `subject:` typo stays within subject, and bare terms never reach quoted text). Rescue hits are flagged `viaTypo`, and the UI says "showing results for ...". Phrases and multi-word queries stop at the trigram rung.
- **Hybrid semantic search** (on by default once its model is downloaded, off-switchable): each message's subject and opening text get a sentence embedding from an on-device Core ML model (multilingual, small enough to embed 1 million messages overnight on Apple silicon), stored in a vector index beside FTS5 (sqlite-vec, MIT/Apache-2.0, or our own flat index if that is simpler to sandbox). Keyword and semantic results merge by reciprocal rank fusion, so "the email where the landlord agreed to fix the heater" finds it without those words. The model choice and license get a decision record in M0.

### Facets

- The first facet slice stands beside the results for entity kinds (decision 0033): for the query's full match set, `entityFacets(matching:)` returns how many messages carry each entity kind, and `entityValues(_:matching:)` drills into one kind, ranking its written values by message count (deterministic — value-ascending on ties, capped by `limit`). The counts cover the whole match set, not one result page, and follow the same zero-hit fallback ladder the hits follow (trigram retry, then the one-edit typo rescue — decision 0035), so the facets always describe the set on screen; kinds with no matching messages are absent, not zero. Account, sender, year-and-month (the draggable timeline histogram), folder or label, and attachment-type facets arrive with their sources in later milestones and run under the same 300 ms faceted-counts budget.

### Query Language and UI

- Free text plus operators: `from:`, `to:`, `cc:`, `subject:`, `body:`, `has:attachment`, `filename:`, `type:pdf`, `label:`, `folder:`, `account:`, `is:unread`, `is:starred`, `is:sent`, `before:`, `after:`, `on:`, `during:2019`, `larger:5MB`, `smaller:`, `amount:>100`, `domain:`, quoted phrases, `OR`, parentheses, `-` to exclude. Natural dates parse into ranges beside the numeric forms (`2019`, `2019-06`, `2019-06-01`): `yesterday`, `today`, `this`/`last week/month/year`, and month names with an optional year (`march`, `sept 2019`, `during:"last march"`). A bare month names the most recent occurrence of that month — from November, `march` means this year's March — and "last March" agrees (decision 0034). Multi-word forms are quoted (`during:"this month"`); single-word forms need no quotes (`during:yesterday`). Everything resolves in UTC against a `now` the caller supplies (`search(..., now:)`, default the current time), so the same query compiles the same way whenever it runs; a malformed form (`last march 2019`) is an explicit error, not a silent guess.
- A search field that answers as you type (first results in under 50 ms), with operator completion from real values (senders, labels, folders) and recent searches.
- Facets beside the results with live counts: account, sender, year and month (a timeline histogram you can drag across), folder or label, attachment type, has entities (amounts, tracking numbers).
- Highlighted snippets from the part that matched, including "matched in invoice.pdf, page 2", which opens the attachment at that page.
- Saved searches as smart folders in the sidebar, updated as mail arrives; exportable results (the matching set to mbox, `.eml`, PDF, or CSV of headers).
- Keyboard-first throughout: ⌘F anywhere, arrow keys through results, Return to open, Space for Quick Look.

### Keeping the Index Fresh and Correct

- Ingest indexes headers and body text in the same transaction that records the message, so anything synced is searchable at once; attachment text, OCR, and embeddings follow from a persistent, prioritized background queue (newest mail first) that survives restarts and shows its progress.
- The index records which version of each extractor and tokenizer produced each row. When a later release improves one, only the affected rows are redone, in the background, with search working throughout.
- A "Rebuild index" command and a self-check that compares index counts with the files and repairs gaps.
- Search during the first sync works on whatever has arrived, and says how much is still to come.

### Search Quality Testing

- **A judged relevance set:** about 300 queries over a fixed public corpus (Enron plus our multilingual and attachment fixtures), each with the messages a person would expect, covering names, phrases, dates, attachments, OCR text, typos, CJK, Cyrillic, German compounds, and "vague memory" questions for semantic search. CI computes nDCG@10 and recall@50 on every pull request touching `ArchiveSearch`, and a drop beyond a set tolerance fails the build.
- Tokenizer golden tests per language; extractor tests per file type with known text; OCR accuracy checked on a fixture set of scanned receipts and letters.
- **Budgets on 1 million messages** (on an Apple silicon Mac mini, enforced from M2 on a synthetic archive, weekly on the full one): first keystroke results under 50 ms, a full ranked page under 200 ms, faceted counts under 300 ms, semantic query under 300 ms; ingest indexing at least 200 messages per second; index size reported per release. Stretch target: the same budgets at 5 million messages.
- The MCP tools run the same queries through the same engine, so every search test also covers what agents get.

### Spotlight

Optional Core Spotlight donation (headers and a snippet only), off by default because it copies message text into the system index; when on, excluded folders and accounts are never donated.

## 7. MIME and Encodings

The hardest code in the app after sync. Real mail breaks every rule, and the archive must never lose bytes because of it: parsing feeds the index and the viewer, and the original file stays untouched whatever the parser makes of it.

- RFC 5322 headers, folding, and obsolete syntax; RFC 2045 to 2049 structure; RFC 2047 encoded words (including mis-split multibyte sequences); RFC 2231 parameter continuation and charset; RFC 6532 UTF-8 headers; raw 8-bit headers in unknown charsets (guess from the body charset, then fall back to Windows-1252 or the account's region).
- Transfer encodings: base64 (tolerant of bad padding and line lengths), quoted-printable (tolerant of bare `=`), 7bit, 8bit, binary; uuencode bodies; BinHex (rare, read-only).
- Charsets through ICU: UTF-8, ISO-8859-x, Windows-125x, KOI8-R/U, GB2312/GBK/GB18030, Big5, Shift_JIS, EUC-JP, ISO-2022-JP, EUC-KR/CP949, plus mislabelled ones (a `gb2312` label decoded as GB18030; `ks_c_5601-1987` as CP949).
- Structures: nested `multipart/*`, `message/rfc822` attachments rendered inline, `multipart/related` with `cid:` images, `multipart/alternative` choosing the richest renderable part, delivery status reports, `text/calendar` shown as a summary, TNEF `winmail.dat` unpacked, S/MIME and PGP shown as signed or encrypted (verification in 1.x; decrypting is out of scope).
- Threading: `Message-ID`/`In-Reply-To`/`References` (JWZ algorithm) merged with provider thread IDs where available.
- Tests: a corpus of real-world messages (see [TESTING.md](TESTING.md)), byte-for-byte round trips, and a fuzzer on the parser from M1.

## 8. Viewer

- `WKWebView` with JavaScript disabled (`allowsContentJavaScript = false`), a `WKContentRuleList` blocking every network load, and a strict CSP injected into the document. Remote images load only when the person clicks "Load remote content", per message or per sender, never by default (this also defeats tracking pixels).
- `cid:` and attachment parts served by a `WKURLSchemeHandler` from the archive.
- HTML sanitized before display (forms, `meta refresh`, `base`, scripts, event handlers, and `javascript:` URLs stripped); links open in the default browser after showing the real target.
- Plain-text view, raw source view, header view, and Quick Look for attachments.
- Print and "Save as PDF" through the web view's print operation.

## 9. Import and Export

| Format | Import | Export | Notes |
| --- | --- | --- | --- |
| `.eml` folder tree | M1 | M1 | Folder names become archive folders |
| mbox (mboxo, mboxrd, mboxcl2) | M1 | M1 | Detect the variant; handle `>From ` quoting both ways; `Content-Length` variants |
| Google Takeout mbox | M1 | | Reads `X-Gmail-Labels` and `X-GM-THRID` into labels and threads |
| Apple Mail (`~/Library/Mail/V10`, `.emlx`, `.partial.emlx`) | M1 | | Person picks the folder in an open panel (no Full Disk Access, sandbox-safe); partial messages are rebuilt from the attachment files Apple Mail stores beside them |
| Apple Mail export (`.mbox` packages) | M1 | M1 | Same mbox code |
| Maildir | M4 | M8 | Flags from file names |
| Thunderbird profile folders | M4 | | mbox plus `.msf` ignored |
| Proton export (`.eml` plus metadata JSON) | M6 | | Labels and flags from the JSON |
| Tuta export | M6 | | `.eml`/mbox |
| Outlook PST/OST | 1.x | | Own reader, since libpst is GPL; or document a "convert first" route |
| PDF | | M8 | One PDF per message or per thread, for records |
| Restore to IMAP (`APPEND`) | | M8 | Explicit action; obeys upload caps (Gmail 500 MB/day); preserves `INTERNALDATE` and flags |

Every import records its source, so an archive can show where each message came from, and re-running an import adds nothing twice.

## 9A. Agent Access (MCP)

The archive is most useful when the person's agents can use it: "find the lease renewal email from 2019", "summarize everything from my accountant this year", "which receipts mention AppleCare". The app ships its own [Model Context Protocol](https://modelcontextprotocol.io) server so any MCP client can query the archive without the mail ever leaving the Mac.

### Shape

- **Local only.** The server runs on the Mac and reads the same index and `.eml` files as the app. No message content passes through any service of ours; whatever the agent's model provider sees is only what the agent asks for and the person allows.
- **Two transports:**
  - **stdio** (the default): a small command-line helper inside the app bundle (`Contents/Helpers/email-archiver-mcp`) that MCP clients launch. It finds the person's archive from the app's settings and opens it read-only. Settings shows the exact client configuration to copy, and a one-click "Add to Claude Desktop" installs a Desktop Extension (`.mcpb`) that points at the helper.
  - **Streamable HTTP on `127.0.0.1`** (off by default): for clients that cannot launch a process. Bound to loopback only, a random port, a bearer token per client kept in the Keychain, `Origin` checks against DNS-rebinding, and a visible "agent connected" indicator in the menu bar.
- **Read-only in 1.0.** No tool sends, deletes, moves, flags, or changes the archive. Export and "save attachment to a folder the person picks" may come later, always behind a confirmation in the app.
- **Works without the app open** (the helper reads the index directly, in WAL read mode), and never blocks or slows sync.

### Tools

| Tool | What it returns |
| --- | --- |
| `search_messages` | Matches for a query in the app's own search syntax (`from:`, `after:`, `has:attachment`, `label:`, phrases), with filters for account, folder, date range; returns message IDs, date, from, to, subject, a short snippet, labels, and a thread ID. Paged, newest first or by relevance |
| `get_message` | One message's headers and readable body text (HTML converted to text), attachment list; optional `max_chars`; raw source only if the person enabled it |
| `get_thread` | The messages of a thread in order, bodies trimmed to a budget |
| `list_accounts`, `list_folders`, `list_labels` | What exists to search, with counts and date ranges |
| `list_attachments`, `get_attachment_text` | Attachment metadata and extracted text (PDF and plain text; never binary by default) |
| `find_contacts` | Addresses and names seen in the archive, with message counts and first and last dates |
| `archive_stats` | Totals by account, year, and sender, for questions like "how much mail from X per year" |

Resources expose each message as `emailarchiver://message/<id>` and each thread as `emailarchiver://thread/<id>`, so clients that browse resources can attach them. Tool descriptions and result shapes are versioned and covered by tests, since agents depend on them.

### Controls the Person Has

- On or off, per client, in Settings › Agents (off until the person turns it on).
- Which accounts, folders, and labels agents can see; Spam, Trash, and anything the person marks private are excluded by default.
- Optional redaction in results: hide email addresses, phone numbers, or bodies (headers-only mode).
- Per-client limits: results per call, characters per call, calls per minute.
- An activity log in the app listing every agent request (time, client, tool, query, how many messages it returned), kept locally and clearable. It never records the returned content.
- "Ask before returning full messages" mode: the app shows a prompt naming the client and the messages before a `get_message` or `get_thread` answers.

### Prompt-Injection Safety

Email is the classic channel for prompt injection: anyone can send the person a message addressed to their agent. So:

- Every returned body, subject, and attachment text is wrapped and labelled as untrusted content from a third party, and the server's instructions tell the agent to treat it as data, never as instructions.
- The server has no write or network tools, so an injected instruction can at worst steer what the agent reads next, within the person's limits.
- Remote content is never fetched to answer a tool call; links come back as text.
- Hidden text tricks (zero-size fonts, white-on-white, `display:none`) are stripped during HTML-to-text conversion, which the viewer's sanitizer already does.

### Testing

Contract tests for each tool's schema and output; an MCP conformance run with the official inspector in CI; access-control tests (excluded folders and accounts never appear in any tool or resource); limits and redaction tests; injection fixtures (messages crafted to give the agent instructions) checked to come back wrapped and labelled; and an end-to-end test that launches the stdio helper from a scripted MCP client against a fixture archive, on Linux and the Mac.

## 10. Security, Privacy, and Encryption at Rest

- **Threat model** (written in M0, kept in the repository): a stolen or shared Mac, malicious HTML mail, a hostile or compromised IMAP server, a tampered update feed, and a diagnostics report leaking content.
- **Credentials:** Keychain only; never in logs, reports, the index, or exports.
- **Network:** TLS 1.2 or newer; certificate exceptions only per host and only after the person confirms the fingerprint.
- **Logs:** account addresses and subjects redacted at write time, not only at report time.
- **At rest, 1.0:** the archive sits in the app's Application Support folder (or wherever the person moved it), protected by FileVault; the app warns if FileVault is off and the archive is not encrypted.
- **At rest, 1.1 (optional, per archive):** each `.eml` sealed in a versioned envelope (AES-256-GCM with CryptoKit, under a key derived with HKDF-SHA256 from a random archive key, with published test vectors); the index under SQLCipher (BSD-style license, recorded as a decision) so FTS works; the archive key held in the Keychain and wrapped by a recovery key the person writes down. Content addressing then uses an HMAC of the plaintext so duplicates still collapse without exposing hashes of known messages. Changing encryption rewrites the archive with a resumable job.
- **Privacy:** no analytics, no accounts with us, no server of ours in the message path. Diagnostics only as a report the person chooses to send, after seeing the exact JSON; automatic reports only with explicit opt-in, and never with message content, addresses, or subjects.
- **Legal:** a privacy policy and terms before the first outside tester. Google's verification also requires the policy to state the Google API Services User Data Policy "Limited Use" commitments.


## 11. Testing

See [TESTING.md](TESTING.md).

## 12. Code Layout, CI, and Distribution

### Repository

```
Package.swift
Sources/
  ArchiveCore/      models, archive format, index, migrations          (Linux + macOS)
  MailMIME/         parser, charsets, threading                        (Linux + macOS)
  MailSync/         IMAP (swift-nio-imap), JMAP, provider database     (Linux + macOS)
  ArchiveSearch/    tokenizers, FTS, ranking, facets, query language   (Linux + macOS)
  ArchiveExtract/   attachment text, OCR, entities, embeddings         (macOS; text-only extractors also Linux)
  ArchiveCrypto/    envelope, SQLCipher glue                           (Linux + macOS)
  ArchiveMCP/       MCP server: tools, resources, access policy        (Linux + macOS)
  Credentials/      CredentialStore, Keychain and 1Password backends   (macOS; protocol and mocks also Linux)
App/                SwiftUI app, viewer, onboarding                    (macOS 14+)
LoginItem/          background sync helper                             (macOS)
MCPHelper/          stdio MCP executable embedded in the app bundle    (macOS)
OnePasswordHelper/  1Password SDK bridge, if decision 0005 picks it    (macOS)
Tests/
Benchmarks/         search and sync benchmarks, relevance evaluation
docs/
scripts/            check.sh, then build, sign, notarize, and release scripts
```

Minimum macOS 14 (Sonoma); Apple silicon and Intel. The Xcode project for the app is generated (XcodeGen) from a committed spec, so the core stays a plain Swift package.

### CI

- `ci.yml` runs `scripts/check.sh` on Linux (the core packages, the local IMAP and JMAP test servers, fuzz smoke runs) and on macOS (everything, including the app build and UI tests), on every push and pull request.
- Benchmarks and the relevance evaluation run on every change to `ArchiveSearch` or `ArchiveExtract`, with the budgets in [TESTING.md](TESTING.md).
- Signing, notarization, and release workflows are added when the maintainer sets up signing; they are not part of the initial build.

### Developer ID Edition (the product)

- Hardened runtime, notarized, distributed as a signed and notarized disk image from the Bristlecone website.
- Not sandboxed where a feature needs otherwise (decision 0003): 1Password desktop integration, reading Apple Mail's folders directly (with the person's Full Disk Access grant, or an open panel without it), an MCP helper any client can launch, and a background helper.
- Self-updating from a signed feed: the app checks the download's size and SHA-256 against the feed, that it is signed by the same Developer ID team and notarized, and that its build number is higher; then installs by an atomic swap beside the old copy, with automatic rollback if the new build doesn't confirm it started.
- Licensing (M9): a subscription ($9.99 a year) or a lifetime license ($119.99), bought on the website. The app verifies an offline-checkable signed license (Ed25519) and refreshes it in the background; it never needs the network to open or search an archive. When a license lapses, sync and MCP stop, and the archive stays fully readable, searchable, and exportable. A trial gives the full app for a set period first. The payment provider is the maintainer's choice.

### App Store Edition (only at full parity)

The App Store version ships only if it can do everything the Developer ID edition does (decision 0003). The code keeps that possible without constraining the product:

- Every capability that the sandbox would block sits behind a protocol with a sandbox-compatible implementation where one exists: archive location by security-scoped bookmark, Apple Mail import by open panel, background work by `SMAppService`, the MCP helper as a sandboxed tool sharing an app group.
- 1Password: if no sandbox-compatible route exists (decision 0005), that alone blocks parity.
- Pricing sits behind one `Entitlements` interface, so an App Store build can use StoreKit (an auto-renewable yearly subscription and a non-consumable lifetime purchase) and the direct build its license.
- The App Store build drops the updater.
- At M11, a parity review lists every difference. If there are none, the App Store edition ships; if there are some, the maintainer decides between a "lite" edition and none.
