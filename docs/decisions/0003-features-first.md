# 0003: Features First; App Store Only at Parity

Status: Accepted, 2026-11-16

## Context

The Mac App Store sandbox blocks some features this app wants: 1Password desktop integration, reading Apple Mail's folders directly, an MCP helper that any client can launch, and possibly others. The maintainer's rule: the App Store is a target if and only if it can be done without compromising any feature.

## Decision

The Developer ID edition is the product. It uses the hardened runtime and is notarized, but is not sandboxed where a feature needs otherwise. The code keeps a sandboxed build possible by putting each sandbox-sensitive capability behind a protocol. At M11 a parity review lists every difference; the App Store edition ships only if there are none. Otherwise a separate 'lite' edition may ship, at the maintainer's choice, or none.

## Consequences

No feature is cut or weakened for the App Store. The App Store edition may never ship.
