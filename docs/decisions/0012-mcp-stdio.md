# 0012 — MCP stdio transport

**Date:** 2026-11-17
**Status:** accepted

## Context

The app needs to expose the email archive to AI agents via the Model Context Protocol (MCP). MCP defines a stdio transport for local communication: the host process (the app) communicates with clients (AI agents) via JSON-RPC over stdin/stdout.

## Decision

**Implement MCP stdio transport in Swift using `Foundation.JSONEncoder`/`JSONDecoder` over `FileHandle.standardInput`/`FileHandle.standardOutput`.**

### Rationale

1. **stdio is the simplest MCP transport.** It requires no network stack, no ports, no security configuration. The host process just reads JSON-RPC messages from stdin and writes responses to stdout.
2. **Swift's Foundation provides everything needed.** `JSONEncoder`/`JSONDecoder` for serialization, `FileHandle` for I/O. No external dependencies.
3. **MCP is a JSON-RPC 2.0 protocol.** Messages are JSON objects with `jsonrpc`, `id`, `method`, and optional `params` or `result` fields. Standard JSON-RPC 2.0.
4. **No third-party MCP library needed.** The protocol is simple enough to implement directly. A Swift MCP library could be added later if needed.

### Implementation Sketch

```swift
import Foundation

class MCPStdioTransport {
    private let stdin = FileHandle.standardInput
    private let stdout = FileHandle.standardOutput
    
    func run() {
        let lineDecoder = InputStreamReader(handle: stdin)
        while let line = lineDecoder.nextLine() {
            guard let message = try? JSONDecoder().decode(Message.self, from: line.data(using: .utf8)!) else {
                continue
            }
            let response = handle(message)
            let encoded = try! JSONEncoder().encode(response)
            stdout.write(encoded + Data([10])) // newline-terminated
        }
    }
    
    private func handle(_ message: Message) -> Message {
        switch message.method {
        case "initialize":
            return initialize(message)
        case "tools/list":
            return toolsList(message)
        case "tools/call":
            return toolsCall(message)
        case "resources/list":
            return resourcesList(message)
        default:
            return errorResponse(id: message.id, code: -32601, message: "Method not found")
        }
    }
}

struct Message: Codable {
    let jsonrpc: String
    let id: Int?
    let method: String?
    let params: [String: Any]?
    let result: [String: Any]?
    let error: ErrorObject?
}
```

### Consequences

- **Stdio requires the host to be the stdin/stdout provider.** The app must be launched in a way that connects its stdin/stdout to the MCP client (e.g., `email-archiver mcp` subcommand).
- **No TLS, no authentication.** Stdio transport is inherently local (same machine), so this is acceptable. The app should document that the MCP endpoint should not be exposed to untrusted users.
- **Single-threaded message handling.** Messages are processed sequentially on the stdin loop. For long-running operations (e.g., searching a large archive), the response may be delayed. Consider async processing with buffered responses.
