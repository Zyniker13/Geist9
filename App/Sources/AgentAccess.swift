// Agent access (DESIGN 9A): the app-side half of the MCP helper's access
// policy. Settings writes one policy file that the helper reads at startup
// (by default at the standard location this app writes; clients that name
// an explicit BRISTLECONE_ACCESS_POLICY override it, decision 0054), plus
// a JSONL activity log the helper appends to and this pane reads back. The
// app never opens the archive for agents and never runs the helper itself
// — the policy file is the whole channel.

import ArchiveCore
import Foundation

/// The person's choices for agent access, persisted as the JSON the helper
/// already decodes (`AccessPolicy`, decision 0053). One file serves every
/// MCP client: the person excludes accounts, folders and labels once, and
/// each client's configuration points at the same file.
struct AgentAccess {
    // Where Settings keeps the policy and the helper writes its log. The
    // folder is the app's own Application Support directory, created on
    // first use; nothing here touches the home folder's Mail data.
    static let folderName = "Agents"
    static let policyFileName = "policy.json"
    static let logFileName = "activity.jsonl"

    /// The policy exactly as the helper sees it, including `enabled`.
    var policy: AccessPolicy = .default

    /// Reads the stored policy; a missing or unreadable file answers nil
    /// so Settings starts from the switch-off state and the person sees
    /// "not configured" rather than a silently permissive helper.
    static func load() -> AgentAccess? {
        guard let url = policyURL, let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode(AccessPolicy.self, from: data)
        else { return nil }
        return AgentAccess(policy: policy)
    }

    /// Writes the policy file the helper reads. The helper re-reads it only
    /// at startup, so a change takes effect the next time a client connects
    /// — Settings says so.
    func save() throws {
        let url = try Self.requirePolicyURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: url, options: [.atomic])
    }

    // MARK: Activity log

    /// One appended line from the helper's activity log (the exact record
    /// shape lives in ArchiveMCP/AccessControl.swift; the app reads it
    /// read-only and must stay decoupled from the MCP SDK).
    struct LogLine: Identifiable, Equatable {
        let time: Date
        let tool: String
        let query: String?
        let resultCount: Int?
        var id: String { "\(time.timeIntervalSince1970)-\(tool)-\(query ?? "")" }
    }

    /// The newest entries first, bounded so a long-lived archive cannot
    /// balloon the pane. nil when the log does not exist yet (no agent has
    /// connected).
    static func readActivity(limit: Int = 200) -> [LogLine]? {
        guard let url = activityURL, let data = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: "\n").suffix(limit).compactMap { line -> LogLine? in
            struct Raw: Decodable {
                var time: Date
                var tool: String
                var query: String?
                var resultCount: Int?
            }
            guard let raw = try? decoder.decode(Raw.self, from: Data(line.utf8)) else { return nil }
            return LogLine(time: raw.time, tool: raw.tool, query: raw.query, resultCount: raw.resultCount)
        }
        return lines.reversed()
    }

    /// Clears the log. The helper keeps appending afterwards; the file is
    /// diagnostic, not the archive.
    static func clearActivity() throws {
        guard let url = activityURL else { return }
        try "".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Paths and client configuration

    /// The path the helper reads the policy from; goes into the client
    /// configuration snippet verbatim.
    static var policyPath: String? { policyURL?.path }

    static var policyURL: URL? {
        folder()?.appendingPathComponent(policyFileName)
    }

    static var activityURL: URL? {
        folder()?.appendingPathComponent(logFileName)
    }

    private static func folder() -> URL? {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = support.appendingPathComponent("Bristlecone", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func requirePolicyURL() throws -> URL {
        guard let url = policyURL else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "no Application Support directory",
            ])
        }
        return url
    }

    // MARK: Copyable client configuration

    /// The JSON a person pastes into an MCP client's mcpServers map
    /// (DESIGN 9A): launch the helper from the app bundle, hand it the
    /// archive and the policy. The archive path comes from the archive the
    /// person has open in the app; the helper path from where the app is
    /// actually installed. Values are JSON-escaped, so spaces in archive
    /// names survive the paste.
    func clientConfiguration(archivePath: String) -> String? {
        guard let policy = Self.policyPath else { return nil }
        let helper = Bundle.main.bundlePath + "/Contents/Helpers/email-archiver-mcp"
        let jsonEscape: (String) -> String = { text in
            let data = (try? JSONEncoder().encode([text])) ?? Data("[]".utf8)
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? "\"\""
        }
        return """
        {
          "mcpServers": {
            "email-archiver": {
              "command": \(jsonEscape(helper)),
              "env": {
                "ARCHIVE_PATH": \(jsonEscape(archivePath)),
                "BRISTLECONE_ACCESS_POLICY": \(jsonEscape(policy))
              }
            }
          }
        }
        """
    }
}
