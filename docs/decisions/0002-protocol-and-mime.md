# 0002: IMAP Library and MIME Parser

Status: Accepted, 2026-11-16

## Context

IMAP parsing is hard to get right and a security boundary; MIME in real mail breaks every rule.

## Decision

Use Apple's swift-nio-imap (Apache-2.0) for the IMAP protocol layer and write our own sync engine on top. Write our own streaming MIME parser in Swift, corpus-tested and fuzzed, with charset decoding through Foundation and ICU. Write our own small JMAP client over URLSession.

## Consequences

The protocol layer is maintained and fuzzed upstream and builds on Linux. The MIME parser is ours to fix quickly, and the original bytes are always kept, so a parser bug never loses mail.
