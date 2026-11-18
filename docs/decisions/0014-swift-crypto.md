# 0014 — SHA-256 via swift-crypto

**Date:** 2026-11-17
**Status:** accepted

## Context

DESIGN 6 stores every message content-addressed: `messages/ab/cd/<sha256-hex>.eml`.
The hash must be computed identically on macOS and Linux (the core builds and tests
on both), including inside the MCP helper. Darwin's CommonCrypto is not available on
Linux, and the `CryptoKit` module is Apple-only.

## Decision

Use [swift-crypto](https://github.com/apple/swift-crypto) 5.1.1 (exact pin) and its
`Crypto` module (`SHA256`) everywhere hashing is needed. swift-crypto is maintained
by Apple, is Apache-2.0-licensed, and provides the same API as CryptoKit, backed by
the system CommonCrypto/BoringSSL on macOS and Linux respectively. The dependency
was already in the package graph via swift-nio-ssl; pinning it makes the import
explicit.

## Consequences

- One hashing implementation, one code path, byte-identical results on both platforms.
- The same module is the natural candidate for the 1.1 encryption envelope
  (AES-256-GCM, HKDF), which keeps decision 0013's scope to the SQLite layer only.
