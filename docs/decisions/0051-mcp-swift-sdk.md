# 0051 — MCP: use the official swift-sdk

## Context

M3 (Agent Access, DESIGN 9A) needs an MCP server exposing the search engine as
tools and resources, over stdio (default) and Streamable HTTP (opt-in,
loopback), with contract tests on Linux and macOS. Building the protocol layer
by hand means implementing JSON-RPC framing, lifecycle, capability negotiation,
and the tool/resource call shapes, then maintaining them against a spec that
still evolves. The official `modelcontextprotocol/swift-sdk` exists and is
actively maintained (its CI runs macOS and Linux, including conformance tests).

## Decision

Use `modelcontextprotocol/swift-sdk` (`MCP` product), pinned to the exact
version `0.12.1`, for the protocol and transport layers of `ArchiveMCP` and the
`MCPHelper` stdio executable. The DESIGN 9A parts that are ours — access
policy, redaction, untrusted-content wrapping, limits, activity log, tool
schemas — live in `ArchiveMCP` above the SDK.

License: MIT transitioning to Apache-2.0 (tag 0.12.1 carries the transition
notice); both are on the permitted list. Transitive dependencies at that pin:
swift-nio (Apache-2.0), swift-log (Apache-2.0), swift-system (Apache-2.0),
eventsource (MIT) — all permitted.

## Consequences

- One more dependency; upgrade deliberately (exact pin, never `from:`), with
  the tool-schema contract tests as the guard: an SDK bump that changes a
  tool's shape or a returned field breaks tests, not agents.
- The SDK is pre-1.0; if it breaks badly, the contract tests define the
  behavior we must keep, and the protocol layer is small enough to absorb.
- Linux support verified from the SDK's own CI (Linux job + static SDK build);
  our M3 contract tests will confirm it on our side.
- No write, no network tools will exist in the server regardless of what the
  SDK supports (DESIGN 9A read-only rule).
