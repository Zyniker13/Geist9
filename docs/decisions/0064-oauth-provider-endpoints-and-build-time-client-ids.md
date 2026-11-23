# 0064 — OAuth provider endpoints, scopes, and build-time client IDs

## Context

M5's OAuth machinery (client, session, loopback receiver, sync driver,
local test server) is provider-agnostic; the provider database said
`supportsOAuth` per provider but carried no OAuth endpoints. ROADMAP M5
names Microsoft, Google, Yahoo/AOL, Yandex, Zoho, and Fastmail; DESIGN 4
("OAuth Flow") fixes the shape (PKCE, loopback or custom-scheme
redirect, refresh with rotation written back, read-only scopes where
offered) and says client IDs are injected at build time, never committed.
The endpoints themselves were not yet written down anywhere in code, and
they differ per provider.

## Decision

One `OAuthProviderConfig` per OAuth-capable provider
(`Sources/MailSync/OAuthProviders.swift`), keyed by the provider's
`ProviderProfile.id`:

- **Endpoints** are the providers' documented OAuth2 endpoints, spelled
  out (mail providers rarely publish discovery documents): Microsoft's
  Entra `common` tenant endpoints, Google's accounts endpoints with the
  RFC 7009 revocation endpoint, Yahoo/AOL's `api.login.{yahoo,aol}.com`
  triple, Yandex's `oauth.yandex.ru`, Zoho's `accounts.zoho.com`, and
  Fastmail's `api.fastmail.com`. Every endpoint is HTTPS.
- **Scopes** are read-only wherever a provider offers one: Yahoo/AOL
  `mail-r`, Zoho `ZohoMail.messages.READ`, Yandex `mail:imap_login`.
  Google (`https://mail.google.com/`) and Microsoft
  (`IMAP.AccessAsUser.All`) have no read-only IMAP scope; the privacy
  policy must say so (DESIGN 4). Microsoft's scope includes
  `offline_access` — without it Entra issues no refresh token and the
  whole refresh contract is dead.
- **Client IDs** are read from `BRISTLECONE_<PROVIDER>_CLIENT_ID` in the
  build environment at call time. An absent (or whitespace) value means
  the provider's OAuth entry point is off in that build; the app then
  offers the provider's non-OAuth path. Key names use the provider
  company (MICROSOFT for the `outlook` profile, GOOGLE for `gmail`),
  pinned by test.
- **Fastmail's** config is present but its OAuth is not exercised before
  M6, where the JMAP session scope is decided together with IMAP.
- **Microsoft revocation**: Entra exposes no per-token revocation
  endpoint for public clients, so `revocationEndpoint` is nil there;
  account removal drops only the local copy, and the person revokes the
  grant in their Microsoft account (the app's sign-out wording must not
  claim the server side was revoked).

## Consequences

- Adding a provider's OAuth is one table row in code plus a test line in
  the pinned key map; the authorize flow, session, and driver are
  unchanged.
- Tests can prove OAuth-off behavior by injecting an empty environment
  mapping; no real provider is ever contacted (TESTING.md).
- The `Done when` line "with a client ID present in the environment,
  Microsoft sign-in completes end to end" remains a maintainer-run check
  (STATUS.md "Needs the Maintainer"); the code path it will exercise is
  the same one the local test server covers.
- Zoho's regional hosts (`.eu`, `.in`, ...) are an IMAP-server concern
  (the profile's host), not an OAuth one: its OAuth endpoints are global
  and redirect per region.
