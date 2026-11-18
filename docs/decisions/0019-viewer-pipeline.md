# 0019 — Viewer rendering pipeline: sanitizer, lockdown layers, attachment scheme

Date: 2026-11-18

## Context

DESIGN 8 requires the message viewer to render email HTML without allowing
the message to fetch, execute, or phone home, while keeping a "load remote
content" escape hatch the person controls per message. Email HTML is hostile
input: script smuggle, attribute injection, entity-encoded `javascript:` URLs,
CSS fetches, SVG tricks, and tracker pixels are all ordinary mail content.
The viewer must also show inline attachments (`cid:` references) without any
other network path.

## Decision

The pipeline has four independent layers; the message is only ever safe
because all of them hold, and the first layer already strips everything
dangerous by itself.

1. **Sanitizer (MailMIME, cross-platform, pure Swift).** A tolerant
   byte-level HTML tokenizer rebuilds the message from an allow-list:
   tags not on the list are dropped (children kept) or, for script, style,
   iframe, object, applet, svg, math, template, and friends, swallowed with
   their content; attributes are per-tag allow-lists, so no event handler
   can ever pass; every URL is entity-decoded, stripped of control
   characters, scheme-checked, and re-escaped on output; inline `style`
   values are refused when they can fetch or escape (`url`, `@import`,
   `expression`, backslash escapes, `&`, `<`); comments, doctypes, meta,
   base, and link are dropped; unknown schemes fail closed. `cid:` and
   `data:image/` sources are kept; absolute http(s) sources are kept only
   when the caller says remote content is allowed, and are always reported
   in `remoteResources` so the interface can show what the message tried to
   load. The result carries `links` (decoded targets, for confirm-before-
   open), `hadActiveContent`, and `remoteResources`. The sanitizer is
   fuzz-tested against a hostile corpus in `MailMIMETests`.
2. **WebKit lockdown (ViewerKit, macOS).** The WKWebView runs with
   content JavaScript disabled (`allowsContentJavaScript = false` plus the
   legacy preference), a `WKContentRuleList` that blocks every `http(s)`,
   `ws(s)`, and `ftp` load (with `allow` rules ahead of the block rule for
   the hosts of a message the person granted), fullscreen and airplay off,
   and a navigation delegate that turns link activations into an
   `openLink` callback (the app confirms externally) and cancels every
   other navigation.
3. **Content-Security-Policy.** The rendered document injects
   `default-src 'none'; script-src 'none'; object-src 'none'; frame-src
   'none'; connect-src 'none'; form-action 'none'; base-uri 'none'` with
   `img-src` limited to the attachment scheme, `data:` (and http(s) only
   under a grant), and `style-src 'unsafe-inline'` for surviving inline
   styles.
4. **Attachment scheme.** A custom URL scheme (`x-bc-mail`) serves only
   attachment bytes looked up in the archive: the document base is
   `x-bc-mail://message/<rowid>/`, `cid:` sources are rewritten to that
   space, and the handler answers only known message/cid pairs with the
   stored bytes and their content type; everything else gets no data. The
   main document itself loads via `loadHTMLString`, so no file:// URL ever
   sees the message.

Plain-text messages render as escaped text in a `pre`; no sanitizer pass is
involved. Unknown or unparseable HTML falls out as inert text; the sanitizer
never throws.

## Consequences

- SVG and MathML subtrees are dropped entirely (their content can carry
  fetch and script tricks that the HTML allow-list cannot express); a
  mail whose body is only an SVG renders empty with the active-content
  notice. Acceptable for M1.
- Unknown benign tags lose their semantics but keep their text, matching
  what a strict reader does with mail it does not trust.
- The remote-content grant is per message, decided by the app, and changes
  require re-rendering the document (the app re-sanitizes and reloads).
- `WKContentRuleList` compilation is asynchronous; the viewer compiles the
  rule list once per process and loads documents only after it is added.
- The lockdown layers are covered by ViewerKit tests that run a local
  recording HTTP server and assert zero requests without a grant, exactly
  the granted hosts' requests with one, and no requests for script-driven
  fetches.
- WebKit specifics found while building this (all pinned by tests):
  - A rule list compiled with a `nil` store identifier crashes WebKit's
    content controller when added (`RuleListSmokeTests`); the cache always
    uses a named, content-derived identifier.
  - Content blocker rules have no plain `allow` action; grants use
    `ignore-previous-rules` ahead of the block rules.
  - A web process must exist before a rule list is added, so the viewer
    performs a warm-up load before arming the list.
  - WebKit's local-network protection stops loopback subresources from
    the message's custom scheme regardless of grants, so the grant-path
    network tests observe from an http origin served by the recording
    server. Real remote content lives on public hosts and is unaffected.

