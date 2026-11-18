# 0005: How the App Talks to 1Password

**Date:** 2026-11-17
**Status:** accepted

## Context

Credentials can live in a dedicated 1Password vault (DESIGN 4). There are three possible routes: the official 1Password SDK with desktop app integration through a helper, the `op` CLI with desktop app integration, and service account tokens.

## Decision

**Use `op` CLI (v2+) with desktop app integration for interactive use, and service account tokens for unattended Macs.**

### Rationale

1. **`op` CLI v2.42.0 is available** and supports both interactive (desktop app) and unattended (service account token) modes.
2. **No SDK required.** The official 1Password SDK requires Apple Developer signing and introduces a binary dependency. The `op` CLI is a standalone binary that the app spawns as a subprocess.
3. **Service account tokens** allow unattended operation on headless Macs or CI machines where the 1Password desktop app is not available.
4. **Security model matches requirements.** The app process spawns `op`, retrieves credentials, and exits. No persistent 1Password session, nothing from 1Password reaches disk.

### Implementation

```swift
func fetchCredential(from item: String, vault: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/op")
    process.arguments = ["item", "get", item, "--vault", vault, "--format", "json"]
    
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    
    try process.run()
    process.waitUntilExit()
    
    guard process.terminationStatus == 0 else {
        throw CredentialError.failedToRetrieve
    }
    
    let data = try output.fileHandleForReading.readToEnd()
    let json = try JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
    return json?["fields"]?[0]["value"] as? String ?? ""
}
```

For service account tokens:
```bash
OP_SERVICEACCOUNT_TOKEN=<token> op item get <item-uuid> --vault <vault> --format json
```

### Consequences

- **`op` CLI is an external dependency.** It must be installed on the user's Mac. The app should check for it at launch and provide a helpful error message if missing.
- **Interactive mode requires 1Password desktop app.** The user must have 1Password installed and unlocked. For unattended use, a service account token is needed.
- **Service account tokens are scoped.** They can be limited to specific vaults and items, reducing the blast radius if a token is compromised.
- **No 1Password SDK signing required.** This avoids the Apple Developer account dependency for the 1Password feature.
- **The app process never holds credentials longer than needed.** Credentials are fetched on-demand and not cached in memory.
