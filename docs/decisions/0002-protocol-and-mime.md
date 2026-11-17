# 0002: IMAP Library and MIME Parser

Status: Accepted, 2026-11-16; confirmed by the M0 IMAP spike, 2026-11-17 ([spike result](../spikes/imap-client.md))

## Context

IMAP parsing is hard to get right and a security boundary; MIME in real mail breaks every rule.

## Decision

Use Apple's swift-nio-imap (Apache-2.0), pinned to an exact release (0.5.0 at the spike), for the IMAP protocol layer and write our own sync engine on top. Write our own streaming MIME parser in Swift, corpus-tested and fuzzed, with charset decoding through Foundation and ICU. Write our own small JMAP client over URLSession.

## Consequences

The protocol layer is maintained and fuzzed upstream and builds on Linux. The MIME parser is ours to fix quickly, and the original bytes are always kept, so a parser bug never loses mail.

Spike confirmations: connect, capability, login, ID, list, select, append, UID fetch (envelope, UID, RFC822.SIZE), UID SEARCH, BODY.PEEK[] streamed to disk, IDLE, and logout pass unchanged against GreenMail 2.1.3 and Dovecot 2.4.5. Two behaviors the sync engine must absorb: APPEND with CRLF (servers rewrite bare LF, and Restore must send what the server keeps byte-stable), and RFC 2971 ID sent once after login with a NO/BAD reply treated as "extension not supported". QRESYNC SELECT is written with the library's `QResyncParameter` but was not exercised live (neither test server offers it; Stalwart bring-up parked — see the spike).
