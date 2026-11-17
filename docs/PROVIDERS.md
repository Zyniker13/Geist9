# The Twenty Providers

Which email providers the archiver supports, how each one is reached, and what each one needs. Researched November 2026. Several details come from third-party guides and forums rather than the providers' own documentation (marked "reported" or "unofficial"); the M0 spikes in [ROADMAP.md](../ROADMAP.md) confirm each one against a live account before code depends on it, and the findings go in the capability table at the end of this page.

## How the Twenty Were Chosen

No provider publishes audited mailbox counts, and third-party estimates vary widely (Gmail around 1.8 billion, iCloud up to about 950 million counting all iCloud accounts, Outlook around 400 million, Yahoo around 225 million, Proton around 100 million accounts, GMX around 20 million, Zoho around 15 million; [EmailToolTester](https://www.emailtooltester.com/en/blog/most-popular-email-service-providers/), [SellCell](https://sellcell.com/blog/most-popular-email-provider-by-number-of-users)). The list below combines those estimates with the large regional providers (China, Russia, Korea, Germany, France) and the big US ISP mailboxes, and counts the consumer and business halves of Google and Microsoft separately because their auth differs. The order is approximate; what matters is the coverage.

Fastmail is added as a twenty-first because it is the reference JMAP implementation. Tuta is listed because people will ask, but it has no IMAP.

## Provider Matrix

"Tier" says when the provider is supported: **M4** (password-family IMAP), **M5** (OAuth), **M6** (special paths), or **Import** (no live sync possible).

| # | Provider | Access | Auth for a third-party app | What the person must do first | Known limits and quirks | Tier |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | **Gmail** (consumer) | IMAP `imap.gmail.com:993` (Gmail API is an alternative, same scope class) | OAuth scope `https://mail.google.com/` (restricted: needs Google verification plus a yearly CASA Tier 2 assessment for public apps). App passwords still work for accounts with 2-Step Verification, except Advanced Protection. "Less secure apps" ended May 2025. | Nothing for OAuth. For an app password: turn on 2-Step Verification, create the app password. IMAP is always on since 2025. | 2,500 MB/day IMAP download, 500 MB/day upload ([Google](https://knowledge.workspace.google.com/admin/gmail/gmail-bandwidth-limits)); about 15 connections (unofficial). Labels appear as folders, so one message shows up many times; use `X-GM-EXT-1` (`X-GM-MSGID`, `X-GM-THRID`, `X-GM-LABELS`) and sync `[Gmail]/All Mail` once, then map labels. Localized `[Gmail]` folder names; use SPECIAL-USE. POP fetching and Gmailify are being retired; IMAP is not. | M4 (app password), M5 (OAuth) |
| 2 | **Google Workspace** | Same as Gmail | Same scope. Admins can block app passwords and third-party apps, or allowlist our client ID. | Possibly an admin allowlisting the app | Same bandwidth limits; admin-set limits may be tighter | M5 |
| 3 | **iCloud Mail** | IMAP `imap.mail.me.com:993` | App-specific password only (needs two-factor auth). No OAuth for IMAP. ([Apple](https://support.apple.com/en-uz/102525)) | Create an app-specific password at account.apple.com | No POP. Connection cap reported around 15 to 20 (unofficial). Aliases (`@me.com`, `@mac.com`) share one mailbox. Hide My Email addresses appear as recipients. Verify CONDSTORE/QRESYNC in the M0 spike. | M4 |
| 4 | **Outlook.com / Hotmail / Live** | IMAP `outlook.office365.com:993` | OAuth only: basic auth and app passwords for IMAP were switched off for personal accounts in 2024 ([Microsoft](https://support.microsoft.com/office/outlook-and-other-apps-are-unable-to-connect-to-outlook-com-f4202ebf-89c6-4a8a-bec3-3d60cf7deaef)). Scope `https://outlook.office.com/IMAP.AccessAsUser.All` plus `offline_access`, via an Entra app registered for personal and work accounts. | Nothing | Throttling is opaque (third parties cite about 20 concurrent connections per mailbox). Large folders are slow to `SELECT`. Folder names come back localized. This is the strongest reason OAuth cannot wait past M5. | M5 |
| 5 | **Microsoft 365 / Exchange Online** | Same IMAP endpoint; Microsoft Graph as a fallback | Same scope, from the same Entra app. Tenants may require admin consent or have IMAP turned off per mailbox. | Possibly admin consent, or the admin enabling IMAP | Admin-disabled IMAP is common in businesses; Graph `Mail.Read` is the escape hatch (1.x). Exchange `UIDVALIDITY` changes after mailbox moves. | M5 (Graph in 1.x) |
| 6 | **Yahoo Mail** | IMAP `imap.mail.yahoo.com:993` | OAuth (`mail-r` read-only) only after Yahoo approves a Mail API access request; app passwords otherwise ([Nylas guide](https://developer.nylas.com/docs/provider-guides/yahoo-authentication/)). Yahoo has announced the end of basic-auth IMAP ([Yahoo](https://help.yahoo.com/kb/SLN36636.html)). | Generate an app password under Account security | Aggressive connection limits and silent disconnects on long sessions; keep sessions short and re-`SELECT`. | M4 (app password), M5 (OAuth once approved) |
| 7 | **QQ Mail** (Tencent) | IMAP `imap.qq.com:993` | Authorization code (授权码), not the account password | Turn on IMAP/SMTP in webmail settings, then generate the code (shown once). Changing the QQ password revokes every code. | Chinese charsets (GB2312, GBK, GB18030). Limits undocumented; start conservative. | M4 |
| 8 | **NetEase 163 / 126 / yeah.net** | IMAP `imap.163.com:993` (and `imap.126.com`, `imap.yeah.net`) | Client authorization code | Enable IMAP, generate the code | Refuses `SELECT` with "Unsafe Login" unless the client sends an RFC 2971 `ID` command first, despite the RFC forbidding that ([Mozilla bug](https://bugzilla.mozilla.org/show_bug.cgi?id=1112549)). We always send `ID` with name, version, vendor, and support address. | M4 |
| 9 | **AOL Mail** | IMAP `imap.aol.com:993` (Yahoo infrastructure) | Same as Yahoo: app password, OAuth after approval | Generate an app password | Same behavior as Yahoo. Former Verizon.net mailboxes live here. | M4, M5 |
| 10 | **Proton Mail** | No direct IMAP. Proton Mail Bridge exposes IMAP on `127.0.0.1` (paid plans only, [Proton](https://proton.me/support/imap-smtp-and-pop3-setup)) | Bridge-generated password; Bridge uses a self-signed certificate | Install and sign in to Bridge, copy its IMAP password | We trust Bridge's certificate only for `127.0.0.1` after the person confirms its fingerprint. Bridge's first sync is slow; we wait for it. Free accounts: import from Proton's export tool (`.eml` plus JSON) instead. Sandbox: localhost needs only `network.client`. | M6 (Bridge), Import (free) |
| 11 | **Yandex Mail** | IMAP `imap.yandex.com:993` | App password, or OAuth (XOAUTH2) with a registered Yandex app ([Yandex](https://www.yandex.com/support/mail/mail-clients/others.html)) | Turn on IMAP and the "app passwords and OAuth tokens" switch, then create an app password | Cyrillic charsets (KOI8-R, Windows-1251). Possible sanctions and payment issues for registering a developer app; app password is the dependable path. | M4, M5 optional |
| 12 | **Mail.ru** (VK) | IMAP `imap.mail.ru:993` | "Password for external applications"; OAuth exists but is thinly documented | Create the external-app password at id.mail.ru | Blocks plain passwords. Same charset notes as Yandex. | M4 |
| 13 | **GMX** (gmx.net, gmx.com) | IMAP `imap.gmx.net:993` / `imap.gmx.com:993` | Password, or an app-specific password when two-factor is on; OAuth reportedly exists but is undocumented | Turn on POP3/IMAP access in settings (off by default) | Same platform as WEB.DE and mail.com (United Internet); one profile covers all three. Turning two-factor off is reported to revoke app passwords. | M4 |
| 14 | **WEB.DE** | IMAP `imap.web.de:993` | Same as GMX | Turn on IMAP access in settings | Same as GMX | M4 |
| 15 | **Zoho Mail** | IMAP `imap.zoho.com:993` (regional hosts `.eu`, `.in`, `.com.au`, `.jp`) | App-specific password, or OAuth with a Zoho API client | Paid plan: IMAP is reported removed from free plans ([Zoho community](https://help.zoho.com/portal/pt/community/topic/no-more-imap-pop-smtp-on-free-plans-even-on-referrals-with-no-notice?page=1)). Enable IMAP in settings. | Data-center region decides the host; detect from the address or ask. Free accounts: import only. | M4, M5 optional |
| 16 | **Naver Mail** | IMAP `imap.naver.com:993` | Password, or an app password when two-step verification is on | Turn on IMAP in Naver Mail settings | Korean charsets (EUC-KR, CP949). Overseas logins can trigger blocks. | M4 |
| 17 | **Comcast / Xfinity** | IMAP `imap.comcast.net:993` | Password, or an app password with two-step verification | Turn on "Third Party Access Security" in Xfinity's settings ([Xfinity forum](https://forums.xfinity.com/conversations/email/imap-password-on-3rd-party-apps/69e395f58d70f67d063153ec)) | Users report repeated re-prompts; surface auth failures clearly instead of retrying. | M4 |
| 18 | **AT&T Mail** (att.net, sbcglobal.net, and other legacy domains) | IMAP `imap.mail.att.net:993` (Yahoo infrastructure) | "Secure mail key" (AT&T's app password) | Create a secure mail key in AT&T's profile | Behaves like Yahoo. Many legacy domains map to one host. | M4 |
| 19 | **T-Online** (Telekom) | IMAP `secureimap.t-online.de:993` | A separate "password for email programs" set in the E-Mail Center | Set that password | Unencrypted access already removed. | M4 |
| 20 | **Orange** (orange.fr, wanadoo.fr) | IMAP `imap.orange.fr:993` | Application password (about 20 to 23 characters) for non-Orange clients | Turn on IMAP in webmail settings, create an application password | Settings live in webmail, not the account security page. | M4 |
| + | **Fastmail** | JMAP `api.fastmail.com/jmap/session`; IMAP `imap.fastmail.com:993` | JMAP API token (read-only mail scope), or OAuth for registered apps; app passwords for IMAP ([Fastmail](https://fastmail.com/dev/)) | Create a read-only API token | Reference JMAP implementation; push via EventSource. Also our best-behaved IMAP server for tests. | M6 (JMAP), M4 (IMAP) |
| + | **Tuta** | None. No IMAP, no bridge | n/a | Export from Tuta's desktop app | Import only, from its `.eml`/mbox export | Import |

## What Generic IMAP Gets From This

Supporting these twenty forces every piece generic IMAP needs, so "any other IMAP server" falls out as a first-class account type:

- **Discovery:** a bundled provider database (hosts, ports, auth methods, required setup steps, help links) keyed by domain, then Mozilla's ISPDB autoconfig, then `autoconfig.<domain>` and `/.well-known/autoconfig`, then RFC 6186 SRV records (`_imaps._tcp`), then MX lookup to spot hosted Google and Microsoft domains, then manual entry.
- **Auth:** `AUTHENTICATE PLAIN`, `LOGIN`, `XOAUTH2`, and `OAUTHBEARER` (RFC 7628). SCRAM-SHA-256 later if a server asks for it.
- **TLS:** implicit TLS on 993 by default; STARTTLS on 143 only if the server requires it, and never plaintext. A per-account, fingerprint-confirmed certificate exception for self-hosted servers and Bridge.
- **Capabilities used when present, with fallbacks when not:** `ID`, `ENABLE`, `CONDSTORE`/`QRESYNC` (RFC 7162), `UIDPLUS`, `ESEARCH`, `SPECIAL-USE`/`LIST-EXTENDED`/`LIST-STATUS`, `COMPRESS=DEFLATE`, `IDLE`, `LITERAL+`, `UTF8=ACCEPT`, `OBJECTID` (RFC 8474), `NAMESPACE`, `BINARY`.
- **Folder names:** modified UTF-7 (RFC 3501) and UTF-8 (RFC 6855), any hierarchy delimiter, namespaces, `\Noselect` parents.
- This also covers self-hosted Dovecot, Cyrus, Stalwart, Exchange on-premises, and hosts such as Posteo, mailbox.org, Libero, Seznam, Rediffmail, and Daum, each of which only needs a database row.

The IETF draft [OAuth Profile for Open Public Clients](https://datatracker.ietf.org/doc/draft-ietf-mailmaint-oauth-public/) (revision 06, September 2026) would let a mail client register itself dynamically with any provider that adopts it. We implement it behind a flag once the draft settles, which removes per-provider client registration for those providers.

## Capability Table (filled in by the M0 spikes)

Observed live, not taken from documentation. `?` means not yet checked.

| Provider | CONDSTORE | QRESYNC | OBJECTID | COMPRESS | IDLE | SPECIAL-USE | Max connections seen | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Gmail | ? | ? | ? | ? | ? | ? | ? | |
| iCloud | ? | ? | ? | ? | ? | ? | ? | |
| Outlook.com | ? | ? | ? | ? | ? | ? | ? | |
| Yahoo / AOL | ? | ? | ? | ? | ? | ? | ? | |
| QQ | ? | ? | ? | ? | ? | ? | ? | |
| 163 | ? | ? | ? | ? | ? | ? | ? | |
| Yandex | ? | ? | ? | ? | ? | ? | ? | |
| Mail.ru | ? | ? | ? | ? | ? | ? | ? | |
| GMX / WEB.DE | ? | ? | ? | ? | ? | ? | ? | |
| Zoho | ? | ? | ? | ? | ? | ? | ? | |
| Naver | ? | ? | ? | ? | ? | ? | ? | |
| Xfinity | ? | ? | ? | ? | ? | ? | ? | |
| T-Online | ? | ? | ? | ? | ? | ? | ? | |
| Orange | ? | ? | ? | ? | ? | ? | ? | |
| Proton Bridge | ? | ? | ? | ? | ? | ? | ? | |
| Fastmail (IMAP) | ? | ? | ? | ? | ? | ? | ? | |
| Dovecot (test server) | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | 1 | Local brew 2.4.5 build; extensions absent from this build, not from Dovecot generally. [Spike](spikes/imap-client.md) |
| GreenMail (test server) | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | 1 | Local 2.1.3 standalone; no RFC 2971 ID (tagged BAD, connection survives). [Spike](spikes/imap-client.md) |
| Stalwart (test server) | ? | ? | ? | ? | ? | ? | ? | Bring-up parked: released 1.1.1 does not serve the API its own current docs and CLI describe. [Spike](spikes/imap-client.md) |
