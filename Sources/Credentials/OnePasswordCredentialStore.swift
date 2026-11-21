/// The 1Password backend (DESIGN 4, decision 0005).
///
/// The app spawns the `op` CLI (v2+) with a fixed argument list — never a
/// shell — and parses its JSON. Interactive use goes through the 1Password
/// desktop app; unattended Macs use a service account token passed as the
/// `OP_SERVICEACCOUNT_TOKEN` environment variable. Nothing from 1Password is
/// written to disk, logs, the index, or exports: the secret is read into
/// memory at the start of a sync and held only for that session.
///
/// Each mail account is one vault item tagged `email-archiver` with a
/// concealed `Secret` field (DESIGN 4). The app keeps the item's ID in its
/// non-secret account settings (the `op://` reference, by ID not title) and
/// hands it to this store; the store never searches by title.
import Foundation

/// What `op` failing means, classified at the runner boundary.
///
/// The `op` CLI signals outcomes through stderr text with no stable exit
/// code (1.3.x exits 1 for both a locked vault and a missing item), so the
/// runner — the only place that sees the CLI's output — classifies them
/// here. The store then maps kinds to `CredentialError` in one place and
/// never interprets raw CLI output itself.
public enum OpError: Error, Equatable, Sendable {
    /// `op` completed but reported that the requested item does not exist.
    /// The store maps this to `CredentialError.notFound`.
    case itemNotFound
}

/// The narrow surface of the `op` CLI the store needs. `ProcessOpRunner`
/// (Darwin) runs the real binary; tests use `FakeOpRunner` with the same
/// JSON shapes (TESTING, "Fake 1Password (ours)").
public protocol OpRunner: Sendable {
    /// Runs `op` with `arguments` and returns its stdout. Throws
    /// `OpError.itemNotFound` when the binary ran and reported the item
    /// missing; `CredentialError.unavailable` when the binary is missing,
    /// the vault is locked, or `op` exits non-zero for any other reason.
    func run(arguments: [String], environment: [String: String]) async throws -> Data
}

/// Runs the real `op` binary. The path is resolved once (an explicit path,
/// then the usual install locations, then `PATH`) so the argument list is
/// fixed and no shell is ever involved.
public struct ProcessOpRunner: OpRunner {
    public let opPath: String
    public let serviceAccountToken: String?

    public init(opPath: String? = nil, serviceAccountToken: String? = nil) {
        self.opPath = opPath ?? Self.defaultPath()
        self.serviceAccountToken = serviceAccountToken
    }

    /// The usual install locations, in order.
    public static func defaultPath() -> String {
        for candidate in ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "op" // last resort: rely on PATH
    }

    public func run(arguments: [String], environment: [String: String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        if let serviceAccountToken {
            env["OP_SERVICEACCOUNT_TOKEN"] = serviceAccountToken
        }
        process.environment = env

        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CredentialError.unavailable("could not run op at \(opPath)")
        }
        process.waitUntilExit()

        let stdout = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        if process.terminationStatus != 0 {
            let stderr = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
            let detail = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Never include the token or the secret in the error text.
            if Self.stdoutSaysItemMissing(detail) {
                throw OpError.itemNotFound
            }
            throw CredentialError.unavailable(detail.isEmpty ? "op exited \(process.terminationStatus)" : detail)
        }
        return stdout
    }

    /// `op` reports a missing item on stderr with no stable exit code
    /// (1.3.x exits 1 for both a locked vault and a missing item). Match the
    /// exact first line of its known missages so "vault locked" never
    /// classifies as notFound: a locked vault is `unavailable`, retryable
    /// once the person unlocks; a deleted item is genuinely gone.
    static func stdoutSaysItemMissing(_ text: String) -> Bool {
        let missing = [
            "no item found",          // current CLI: `item get <missing>`
            "item not found",
            "couldn't find the item", // older phrasing, kept for tolerance
        ]
        let line = text.lowercased()
            .components(separatedBy: .newlines).first ?? ""
        return missing.contains { line.hasPrefix($0) }
    }
}

/// The 1Password store. `itemID` resolves a store key to the vault item's ID
/// (the app's non-secret account settings hold the `op://` reference); a key
/// with no item is `notFound` for reads and creates the item on `put`.
public struct OnePasswordCredentialStore: CredentialStore {
    public let vault: String
    private let runner: OpRunner
    private let itemID: @Sendable (String) -> String?

    public init(
        vault: String,
        runner: OpRunner,
        itemID: @escaping @Sendable (String) -> String?
    ) {
        self.vault = vault
        self.runner = runner
        self.itemID = itemID
    }

    // MARK: - CredentialStore

    public func get(_ key: String) async throws -> Data {
        guard let id = itemID(key) else { throw CredentialError.notFound }
        let json = try await fetchItem(id: id)
        return try Self.secretField(from: json)
    }

    /// Creates the vault item for a new account and returns its ID, which
    /// the app records as the `op://` reference (by ID, not title).
    /// Onboarding (M4 task 4) calls this; `put` on a key with no item
    /// creates the same way but discards the ID.
    @discardableResult
    public func createItem(for key: String, secret: Data) async throws -> String {
        let title = "Bristlecone Email Archiver: \(key)"
        let fields = try Self.fieldsJSON(secret: secret)
        let data = try await run([
            "item", "create",
            "--vault", vault,
            "--category", "login",
            "--title", title,
            "--tags", "email-archiver",
            "--fields", fields,
            "--format", "json",
        ])
        let json = try Self.parseItem(data)
        return try Self.itemID(from: json)
    }

    public func put(_ key: String, secret: Data) async throws {
        if let id = itemID(key) {
            try await updateSecret(id: id, secret: secret)
            return
        }
        try await createItem(for: key, secret: secret)
    }

    public func delete(_ key: String) async throws {
        guard let id = itemID(key) else { return } // absent is not an error
        do {
            _ = try await run(["item", "delete", id, "--format", "json"])
        } catch let error as CredentialError where error == .notFound {
            // Already gone: removing an absent item is not an error, like
            // the Keychain and in-memory stores.
        }
    }

    public func rotate(_ key: String, to newSecret: Data) async throws {
        guard let id = itemID(key) else { throw CredentialError.notFound }
        try await updateSecret(id: id, secret: newSecret)
    }

    // MARK: - op JSON

    /// Runs `op` and translates the runner's classification into store
    /// errors: an item the vault no longer has is `notFound`; everything
    /// else (binary missing, vault locked, other failure) stays
    /// `unavailable`. Every operation reads and writes through this, so the
    /// CLI's output text is interpreted in exactly one place.
    private func run(_ arguments: [String]) async throws -> Data {
        do {
            return try await runner.run(arguments: arguments, environment: [:])
        } catch let error as OpError where error == .itemNotFound {
            throw CredentialError.notFound
        }
    }

    private func fetchItem(id: String) async throws -> [String: Any] {
        let data = try await run(["item", "get", id, "--format", "json"])
        return try Self.parseItem(data)
    }

    private func updateSecret(id: String, secret: Data) async throws {
        let fields = try Self.fieldsJSON(secret: secret)
        _ = try await run(["item", "edit", id, "--fields", fields, "--format", "json"])
    }

    /// The item's concealed `Secret` field value.
    static func secretField(from item: [String: Any]) throws -> Data {
        guard let fields = item["fields"] as? [[String: Any]] else {
            throw CredentialError.unavailable("op item response has no fields")
        }
        for field in fields where (field["label"] as? String) == "Secret" {
            guard let value = field["value"] as? String else {
                throw CredentialError.unavailable("Secret field has no value")
            }
            return Data(value.utf8)
        }
        throw CredentialError.notFound
    }

    /// The item's ID, which the app records as the `op://` reference.
    static func itemID(from item: [String: Any]) throws -> String {
        guard let id = item["id"] as? String, !id.isEmpty else {
            throw CredentialError.unavailable("op item response has no id")
        }
        return id
    }

    static func parseItem(_ data: Data) throws -> [String: Any] {
        guard let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.unavailable("op returned invalid JSON")
        }
        return item
    }

    /// The `--fields` JSON for an item whose only field the store manages is
    /// the concealed `Secret`. Onboarding (M4 task 4) enriches the item with
    /// the username, host, port, auth method and provider fields.
    static func fieldsJSON(secret: Data) throws -> String {
        let secretString = String(data: secret, encoding: .utf8) ?? ""
        let fields: [[String: String]] = [
            ["type": "CONCEALED", "label": "Secret", "value": secretString],
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
