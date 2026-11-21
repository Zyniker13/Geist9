/// Agent access (DESIGN 9A): a local, read-only MCP server over the same engine the
/// app uses (decision 0008). A stdio helper inside the app bundle by default, an
/// optional loopback-only HTTP transport; per-client exposure, redaction, limits, and
/// an activity log. Every returned body, subject, and attachment text is wrapped and
/// labelled as untrusted content, because email is the classic prompt-injection channel.
///
/// M3 work in progress: the stdio server skeleton (lifecycle + tool registry shape);
/// tool bodies, resources, access policy, redaction, limits, and the activity log land
/// next, each with contract tests.

import Foundation
import MCP

/// The stdio server assembly. `ArchiveMCPServer` owns the archive handle and
/// the tool implementations; this file wires it to the SDK's stdio transport.
public enum StdioMCPServer {
    public enum SetupError: Error, CustomStringConvertible {
        case missingArchivePath
        case archiveNotReadable(String)

        public var description: String {
            switch self {
            case .missingArchivePath:
                return "no archive: set ARCHIVE_PATH to the archive folder"
            case .archiveNotReadable(let path):
                return "archive not readable: \(path)"
            }
        }
    }

    /// Resolve the archive location the same way for every launch: the helper
    /// takes it from the environment (the app's client config sets it), with
    /// an optional explicit override for tests.
    public static func fromEnvironment(archivePath override: String? = nil) throws
        -> ArchiveMCPServer
    {
        let path: String
        if let override {
            path = override
        } else if let env =
            ProcessInfo.processInfo.environment["ARCHIVE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty
        {
            path = env
        } else {
            throw SetupError.missingArchivePath
        }
        let archiveURL = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.isReadableFile(atPath: archiveURL.path) else {
            throw SetupError.archiveNotReadable(archiveURL.path)
        }
        return try ArchiveMCPServer(archiveURL: archiveURL)
    }
}

extension Optional {
    fileprivate func unwrapOrThrow(_ error: @autoclosure () -> some Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
