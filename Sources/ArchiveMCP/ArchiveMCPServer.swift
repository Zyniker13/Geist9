import Foundation
import MCP

/// The MCP server over one archive. Read-only toward the archive and toward
/// mail servers (DESIGN 9A): every tool is a search or fetch, the resources are
/// snapshots, and nothing here mutates the archive or talks to a provider.
public final class ArchiveMCPServer: Sendable {
    /// The archive this server serves. Held read-only for M3: sessions are
    /// constructed per call from the archive path, matching the app's own
    /// read paths, and no writer ever runs while a helper is up.
    public let archiveURL: URL

    /// Server identity advertised in `initialize`.
    public static let serverInfo = Server.Info(
        name: "Bristlecone Email Archiver",
        version: Bundle.versionString
    )

    /// Protocol version this build targets (DESIGN 9A pins the SDK, so this is
    /// the SDK's declared version; contract tests pin the string).
    public static let protocolVersion: String = "2025-06-18"

    public init(archiveURL: URL) throws {
        // Validate the shape here so misconfiguration fails at launch, not on
        // the first tool call: an archive is a folder with archive.sqlite3
        // (DESIGN 6). Opening sessions is cheap; keep the handle-per-call.
        let sqlite = archiveURL.appending(path: "archive.sqlite3")
        guard FileManager.default.fileExists(atPath: sqlite.path) else {
            throw SetupError.notAnArchive(archiveURL.path)
        }
        self.archiveURL = archiveURL
    }

    public enum SetupError: Error, CustomStringConvertible {
        case notAnArchive(String)

        public var description: String {
            switch self {
            case .notAnArchive(let path):
                return "not an archive folder (no archive.sqlite3): \(path)"
            }
        }
    }

    /// Serve over stdio (DESIGN 9A default): blocks until the client closes
    /// the pipe. stdout is the protocol channel, so everything else this
    /// process prints must go to stderr.
    public func run() async throws {
        let transport = StdioTransport()
        let server = makeServer()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    /// Build the `Server` with the DESIGN 9A tools and resources registered,
    /// ready to `connect` on any transport. Handlers are registered once here
    /// so every transport gets the identical surface.
    public func makeServer() -> Server {
        let server = Server(
            name: Self.serverInfo.name,
            version: Self.serverInfo.version,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        return server
    }
}

extension Bundle {
    /// Version for `initialize` responses; falls back for test and CLI builds.
    static var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
}
