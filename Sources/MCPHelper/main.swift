// stdio MCP helper (DESIGN 9A): what MCP clients launch. Reads the archive
// read-only, serves the DESIGN 9A tools over stdio, prints nothing else to
// stdout — diagnostics go to stderr, because stdout is the protocol channel.
import ArchiveMCP
import Foundation

do {
    let helper = try StdioMCPServer.fromEnvironment()
    try await helper.run()
} catch {
    // stderr only: stdout is the protocol channel (DESIGN 9A).
    // FileHandle.standardError rather than the C `stderr` global: Glibc's
    // stderr is shared mutable state, which Swift 6 language mode rejects
    // (the Linux build failed on exactly that).
    let message = "email-archiver-mcp: \(error)\n"
    FileHandle.standardError.write(message.data(using: .utf8) ?? Data())
    exit(1)
}
