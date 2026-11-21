// The MCP server over one archive. Read-only toward the archive and toward
// mail servers (DESIGN 9A): every tool is a search or fetch, the resources are
// snapshots, and nothing here mutates the archive or talks to a provider.
//
// Access control (DESIGN 9A): the person's policy is resolved once, at
// startup, against this archive's index — excluded accounts, folders and
// labels become id sets, and every tool call and resource read filters and
// redacts through that one context. A policy file that cannot be read or
// decoded fails the launch: starting with a silently permissive filter is
// the one failure this server must never have. Names in a readable policy
// that match nothing in this archive stay silent by design and begin
// matching the moment they appear.

import ArchiveCore
import Foundation
import MCP

public final class ArchiveMCPServer: Sendable {
    /// The archive this server serves. Held read-only for M3: sessions are
    /// constructed per call from the archive path, matching the app's own
    /// read paths, and no writer ever runs while a helper is up.
    public let archiveURL: URL

    /// The opened archive, read-only for the whole life of the server.
    public let store: ArchiveStore

    /// Everything every handler enforces, resolved once against this
    /// archive: the visibility id sets, the redaction mode, the per-call
    /// budgets, the rate limiter, and the activity log.
    public let context: ToolContext

    /// Environment variable naming the access-policy JSON file. An absolute
    /// or `~`-expanded path; absent means the permissive default policy.
    public static let policyEnvironmentKey = "BRISTLECONE_ACCESS_POLICY"

    /// Environment variable overriding the activity log location. Default
    /// is `mcp-activity.jsonl` inside the archive folder.
    public static let activityLogEnvironmentKey = "BRISTLECONE_ACTIVITY_LOG"

    /// Server identity advertised in `initialize`.
    public static let serverInfo = Server.Info(
        name: "Bristlecone Email Archiver",
        version: Bundle.versionString
    )

    /// Protocol version this build targets (DESIGN 9A pins the SDK, so this is
    /// the SDK's declared version; contract tests pin the string).
    public static let protocolVersion: String = "2025-06-18"

    /// Opens the archive read-only and resolves the access policy against
    /// it. `policy` wins over the environment; a nil policy reads
    /// `BRISTLECONE_ACCESS_POLICY` and falls back to the permissive
    /// default, so an agent run with no configuration sees everything the
    /// owner sees minus junk and trash.
    public init(
        archiveURL: URL, policy: AccessPolicy? = nil,
        activityLogURL: URL? = nil
    ) throws {
        self.archiveURL = archiveURL
        // Validate the shape here so misconfiguration fails at launch, not on
        // the first tool call: openReadOnly refuses a folder without a
        // manifest (DESIGN 6) and opens the index read-only. Opening the
        // store once is enough; queries run on the same pool, which is safe
        // for concurrent readers, and no writer ever runs while a helper is
        // up (decision 0052: the helper never mutates the archive).
        guard let opened = try? ArchiveStore.openReadOnly(at: archiveURL) else {
            throw SetupError.notAnArchive(archiveURL.path)
        }
        self.store = opened

        let resolvedPolicy: AccessPolicy
        switch policy {
        case .some(let given):
            resolvedPolicy = given
        case .none:
            switch try Self.policyFromEnvironment() {
            case .some(let fromEnvironment):
                resolvedPolicy = fromEnvironment
            case .none:
                resolvedPolicy = .default
            }
        }

        let logURL = activityLogURL
            ?? Self.activityLogFromEnvironment()
            ?? archiveURL.appendingPathComponent("mcp-activity.jsonl")
        let visibility: MessageVisibility
        do {
            visibility = try opened.resolveVisibility(policy: resolvedPolicy)
        } catch {
            // Refuse to start when the policy cannot even be resolved
            // (a broken index): defaulting open here would be the worst
            // failure. Names that match nothing stay silent by design.
            throw SetupError.badPolicy(String(describing: error))
        }
        self.context = ToolContext(
            store: opened,
            access: AccessContext(
                visibility: visibility, policy: resolvedPolicy,
                activityLog: ActivityLog(fileURL: logURL)
            )
        )
    }

    /// Reads the policy file named by the environment, if any. A variable
    /// that is set but unreadable is an error, not a silent default: the
    /// owner asked for a restriction, and ignoring it would be the worst
    /// possible failure.
    static func policyFromEnvironment() throws -> AccessPolicy? {
        guard let raw = ProcessInfo.processInfo
            .environment[policyEnvironmentKey], !raw.isEmpty
        else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw SetupError.badPolicy(
                "\(policyEnvironmentKey) points at an unreadable file: \(raw)"
            )
        }
        do {
            return try JSONDecoder().decode(AccessPolicy.self, from: data)
        } catch {
            throw SetupError.badPolicy(
                "\(policyEnvironmentKey) is not a valid policy file: \(error)"
            )
        }
    }

    static func activityLogFromEnvironment() -> URL? {
        guard let raw = ProcessInfo.processInfo
            .environment[activityLogEnvironmentKey], !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    public enum SetupError: Error, CustomStringConvertible {
        case notAnArchive(String)
        case badPolicy(String)

        public var description: String {
            switch self {
            case .notAnArchive(let path):
                return "not an archive folder (no archive.sqlite3): \(path)"
            case .badPolicy(let why):
                return "access policy failed to resolve (refusing to start): \(why)"
            }
        }
    }

    /// Serve over stdio (DESIGN 9A default): blocks until the client closes
    /// the pipe. stdout is the protocol channel, so everything else this
    /// process prints must go to stderr.
    public func run() async throws {
        let transport = StdioTransport()
        let server = await makeServer()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    /// Build the `Server` with the DESIGN 9A tools and resources registered,
    /// ready to `connect` on any transport. Handlers are registered once here
    /// so every transport gets the identical surface, and all of them share
    /// the one resolved access context — there is no code path that reaches
    /// the archive without it.
    public func makeServer() async -> Server {
        let server = Server(
            name: Self.serverInfo.name,
            version: Self.serverInfo.version,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        let ctx = self.context
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(
                tools: ArchiveTools.definitions(),
                nextCursor: nil
            )
        }
        await server.withMethodHandler(CallTool.self) { params in
            try Self.toolErrorAsRPC {
                try ArchiveTools.call(
                    params.name,
                    arguments: params.arguments ?? [:],
                    ctx: ctx
                )
            }
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(
                templates: ArchiveResources.templates(),
                nextCursor: nil
            )
        }
        await server.withMethodHandler(ListResources.self) { params in
            try Self.toolErrorAsRPC {
                try ArchiveResources.list(cursor: params.cursor, ctx: ctx)
            }
        }
        await server.withMethodHandler(ReadResource.self) { params in
            try Self.toolErrorAsRPC {
                try ArchiveResources.read(params.uri, ctx: ctx)
            }
        }
        return server
    }

    /// Map our tool errors onto JSON-RPC errors so callers read a sentence
    /// ("rate limit exceeded: …", "not found: …") instead of the SDK's
    /// opaque "Internal error" fallback. The codes are server-side ranges:
    /// -32602 for bad arguments, -32601 for unknown tools, -32000..-32002
    /// for the domain refusals.
    private static func toolErrorAsRPC<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ArchiveTools.ToolError {
            switch error {
            case .badArguments:
                throw MCPError.invalidParams(error.description)
            case .unknownTool:
                throw MCPError.methodNotFound(error.description)
            case .notFound:
                throw MCPError.serverError(code: -32002, message: error.description)
            case .rateLimited:
                throw MCPError.serverError(code: -32000, message: error.description)
            }
        }
    }
}

extension Bundle {
    /// Version for `initialize` responses; falls back for test and CLI builds.
    static var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
}
