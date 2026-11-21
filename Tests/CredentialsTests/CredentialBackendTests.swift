import Foundation
import Testing

@testable import Credentials

// MARK: - Fakes

/// An in-memory Keychain client with the same error surface as the real one:
/// `notFound` on a missing read, success on a missing delete.
final class FakeKeychainClient: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    private func key(service: String, account: String) -> String {
        service + "\u{1}" + account
    }

    nonisolated func read(service: String, account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = items[key(service: service, account: account)] else {
            throw CredentialError.notFound
        }
        return data
    }

    nonisolated func write(service: String, account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(service: service, account: account)] = secret
    }

    nonisolated func remove(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(service: service, account: account)] = nil
    }

    nonisolated func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }
}

/// A fake `op` CLI with the same JSON shapes as the real one: items carry an
/// `id` and a `fields` array; the store manages the concealed `Secret` field.
final class FakeOpRunner: OpRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: Any]] = [:]
    private var nextID = 1
    private var _invocations: [[String]] = []

    nonisolated var invocations: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    nonisolated func run(arguments: [String], environment: [String: String]) async throws -> Data {
        // The locked work happens in a synchronous helper: `NSLock.lock()` is
        // unavailable from asynchronous contexts in Swift 6 mode, and nothing
        // here actually suspends.
        try syncRun(arguments: arguments)
    }

    private func syncRun(arguments: [String]) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        _invocations.append(arguments)
        switch arguments.first {
        case "item":
            return try handleItem(arguments.dropFirst().map { $0 })
        default:
            throw CredentialError.unavailable("unexpected op arguments: \(arguments)")
        }
    }

    private func handleItem(_ args: [String]) throws -> Data {
        switch args.first {
        case "get":
            let id = args[1]
            guard let item = items[id] else {
                // The real runner classifies op's "no item found" stderr
                // into this kind; the fake honors the same contract.
                throw OpError.itemNotFound
            }
            return try Self.encode(item)
        case "create":
            let fields = try Self.fieldsArgument(args)
            let id = "item-\(nextID)"
            nextID += 1
            let item: [String: Any] = ["id": id, "fields": fields]
            items[id] = item
            return try Self.encode(item)
        case "edit":
            let id = args[1]
            guard var item = items[id] else {
                throw OpError.itemNotFound
            }
            item["fields"] = try Self.fieldsArgument(args)
            items[id] = item
            return try Self.encode(item)
        case "delete":
            let id = args[1]
            guard items.removeValue(forKey: id) != nil else {
                throw OpError.itemNotFound
            }
            return try Self.encode(["id": id])
        default:
            throw CredentialError.unavailable("unexpected item subcommand: \(args)")
        }
    }

    private static func fieldsArgument(_ args: [String]) throws -> [[String: Any]] {
        guard let index = args.firstIndex(of: "--fields"), index + 1 < args.count else {
            throw CredentialError.unavailable("missing --fields")
        }
        let data = Data(args[index + 1].utf8)
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CredentialError.unavailable("bad --fields JSON")
        }
        return fields
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - KeychainCredentialStore

@Suite("KeychainCredentialStore")
struct KeychainCredentialStoreTests {
    private func makeStore(client: FakeKeychainClient) -> KeychainCredentialStore {
        KeychainCredentialStore(service: "com.zyniker.bristlecone", client: client)
    }

    @Test func roundTrip() async throws {
        let client = FakeKeychainClient()
        let store = makeStore(client: client)
        try await store.put("account:acct-1:password", secret: Data("pw".utf8))
        let secret = try await store.get("account:acct-1:password")
        #expect(secret == Data("pw".utf8))
    }

    @Test func missingKeyIsNotFound() async {
        let store = makeStore(client: FakeKeychainClient())
        do {
            _ = try await store.get("account:acct-1:password")
            Issue.record("expected notFound")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func deleteRemovesTheItem() async throws {
        let client = FakeKeychainClient()
        let store = makeStore(client: client)
        try await store.put("account:acct-1:password", secret: Data("pw".utf8))
        try await store.delete("account:acct-1:password")
        do {
            _ = try await store.get("account:acct-1:password")
            Issue.record("expected notFound after delete")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        }
        #expect(await client.count() == 0)
    }

    @Test func rotateReplacesTheSecret() async throws {
        let client = FakeKeychainClient()
        let store = makeStore(client: client)
        try await store.put("account:acct-1:refresh", secret: Data("old".utf8))
        try await store.rotate("account:acct-1:refresh", to: Data("new".utf8))
        #expect(try await store.get("account:acct-1:refresh") == Data("new".utf8))
    }

    @Test func rotateOfMissingKeyIsNotFound() async {
        let store = makeStore(client: FakeKeychainClient())
        do {
            try await store.rotate("account:acct-1:refresh", to: Data("new".utf8))
            Issue.record("expected notFound")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - OnePasswordCredentialStore

@Suite("OnePasswordCredentialStore")
struct OnePasswordCredentialStoreTests {
    private func makeStore(
        runner: FakeOpRunner,
        itemIDs: [String: String] = [:]
    ) -> OnePasswordCredentialStore {
        OnePasswordCredentialStore(
            vault: "Bristlecone Email Archiver",
            runner: runner,
            itemID: { itemIDs[$0] }
        )
    }

    @Test func getReadsTheSecretField() async throws {
        let runner = FakeOpRunner()
        // Seed the item the way onboarding would have created it (the first
        // created item gets id "item-1"), then map the key to it.
        let seeder = makeStore(runner: runner)
        try await seeder.put("account:acct-1:password", secret: Data("s3cret".utf8))
        let store = makeStore(runner: runner, itemIDs: ["account:acct-1:password": "item-1"])
        let secret = try await store.get("account:acct-1:password")
        #expect(secret == Data("s3cret".utf8))
    }

    @Test func keyWithoutAnItemIsNotFound() async {
        let store = makeStore(runner: FakeOpRunner())
        do {
            _ = try await store.get("account:acct-1:password")
            Issue.record("expected notFound")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func putCreatesATaggedItem() async throws {
        let runner = FakeOpRunner()
        let store = makeStore(runner: runner)
        try await store.put("account:acct-1:password", secret: Data("s3cret".utf8))
        let createCall = try await runner.invocations.first { $0.contains("create") }
        #expect(createCall != nil)
        #expect(createCall?.contains("email-archiver") == true)
        #expect(createCall?.contains("Bristlecone Email Archiver") == true)
    }

    @Test func createItemReturnsTheIDForTheOpReference() async throws {
        let runner = FakeOpRunner()
        let store = makeStore(runner: runner)
        let id = try await store.createItem(for: "account:acct-1:password", secret: Data("s3cret".utf8))
        #expect(id == "item-1")
        // The app records this ID; reads then resolve through it.
        let mapped = makeStore(runner: runner, itemIDs: ["account:acct-1:password": id])
        #expect(try await mapped.get("account:acct-1:password") == Data("s3cret".utf8))
    }

    @Test func rotateUpdatesTheExistingItem() async throws {
        let runner = FakeOpRunner()
        // Seed the item (first created item gets id "item-1"), then rotate
        // through a store that knows the key's item ID.
        let seeder = makeStore(runner: runner)
        try await seeder.put("account:acct-1:refresh", secret: Data("old".utf8))
        let store = makeStore(runner: runner, itemIDs: ["account:acct-1:refresh": "item-1"])
        try await store.rotate("account:acct-1:refresh", to: Data("new".utf8))
        #expect(try await store.get("account:acct-1:refresh") == Data("new".utf8))
    }

    @Test func rotateOfMissingKeyIsNotFound() async {
        let store = makeStore(runner: FakeOpRunner())
        do {
            try await store.rotate("account:acct-1:refresh", to: Data("new".utf8))
            Issue.record("expected notFound")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func deleteRemovesTheItem() async throws {
        let runner = FakeOpRunner()
        let seeder = makeStore(runner: runner)
        try await seeder.put("account:acct-1:password", secret: Data("s3cret".utf8))
        let store = makeStore(runner: runner, itemIDs: ["account:acct-1:password": "item-1"])
        try await store.delete("account:acct-1:password")
        do {
            _ = try await store.get("account:acct-1:password")
            Issue.record("expected notFound after delete")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        }
    }

    @Test func deletingAnAlreadyDeletedItemIsNotAnError() async throws {
        let runner = FakeOpRunner()
        let seeder = makeStore(runner: runner)
        try await seeder.put("account:acct-1:password", secret: Data("s3cret".utf8))
        let store = makeStore(runner: runner, itemIDs: ["account:acct-1:password": "item-1"])
        try await store.delete("account:acct-1:password")
        try await store.delete("account:acct-1:password")
    }

    /// The runner classifies `op`'s stderr text once; the store trusts the
    /// kind and never interprets CLI output itself.
    @Test func runnerClassifiesMissingItemAsItemNotFound() {
        #expect(ProcessOpRunner.stdoutSaysItemMissing("no item found for blah"))
        #expect(ProcessOpRunner.stdoutSaysItemMissing("Item not found in vault"))
        #expect(ProcessOpRunner.stdoutSaysItemMissing("COULDN'T FIND THE ITEM"))
        // A locked vault exits non-zero with different text and must stay
        // `unavailable`, never collapse into notFound.
        #expect(!ProcessOpRunner.stdoutSaysItemMissing("vault is locked"))
        #expect(!ProcessOpRunner.stdoutSaysItemMissing(""))
        #expect(!ProcessOpRunner.stdoutSaysItemMissing("account is locked, unlock 1Password"))
    }

    /// After an item is deleted, `get` is `notFound` (the credential is
    /// gone), while a locked vault stays `unavailable` — the distinction
    /// onboarding needs to tell "rotate the password" from "unlock 1Password".
    @Test func getAfterDeleteIsNotFoundWhileLockedVaultStaysUnavailable() async {
        let store = OnePasswordCredentialStore(
            vault: "Bristlecone Email Archiver",
            runner: MissingItemOpRunner(),
            itemID: { _ in "item-gone" }
        )
        do {
            _ = try await store.get("account:acct-1:password")
            Issue.record("expected notFound")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func opFailureSurfacesAsUnavailable() async {
        let runner = FailingOpRunner()
        let store = OnePasswordCredentialStore(
            vault: "Bristlecone Email Archiver",
            runner: runner,
            itemID: { _ in "item-1" }
        )
        do {
            _ = try await store.get("account:acct-1:password")
            Issue.record("expected unavailable")
        } catch let error as CredentialError {
            #expect(error == .unavailable("op is locked"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

/// An `op` that always fails, as when the 1Password vault is locked.
struct FailingOpRunner: OpRunner {
    func run(arguments: [String], environment: [String: String]) async throws -> Data {
        throw CredentialError.unavailable("op is locked")
    }
}

/// An `op` whose vault answers every read with "the item does not exist" —
/// what the real CLI prints to stderr after an item was deleted elsewhere.
struct MissingItemOpRunner: OpRunner {
    func run(arguments: [String], environment: [String: String]) async throws -> Data {
        throw OpError.itemNotFound
    }
}

// MARK: - CredentialStoreMove

@Suite("CredentialStoreMove")
struct CredentialStoreMoveTests {
    struct FakeVerifier: SignInVerifier {
        let succeeds: Bool
        func canSignIn(accountKey: String, secret: Data) async throws -> Bool { succeeds }
    }

    @Test func moveCopiesAndDeletesTheOldCopy() async throws {
        let source = InMemoryCredentialStore()
        let destination = InMemoryCredentialStore()
        try await source.put("account:acct-1:password", secret: Data("pw".utf8))
        let move = CredentialStoreMove(verifier: FakeVerifier(succeeds: true))
        let result = try await move.move("account:acct-1:password", from: source, to: destination)
        #expect(result.oldCopyDeleted)
        #expect(try await destination.get("account:acct-1:password") == Data("pw".utf8))
        do {
            _ = try await source.get("account:acct-1:password")
            Issue.record("expected notFound in the source after a successful move")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        }
    }

    @Test func failedSignInKeepsTheOldCopy() async throws {
        let source = InMemoryCredentialStore()
        let destination = InMemoryCredentialStore()
        try await source.put("account:acct-1:password", secret: Data("pw".utf8))
        let move = CredentialStoreMove(verifier: FakeVerifier(succeeds: false))
        do {
            _ = try await move.move("account:acct-1:password", from: source, to: destination)
            Issue.record("expected the sign-in failure to surface")
        } catch {
            // The old copy must survive: the archive's secret is never lost.
            #expect(try await source.get("account:acct-1:password") == Data("pw".utf8))
        }
    }

    @Test func moveToADifferentKey() async throws {
        let source = InMemoryCredentialStore()
        let destination = InMemoryCredentialStore()
        try await source.put("account:acct-1:password", secret: Data("pw".utf8))
        let move = CredentialStoreMove(verifier: FakeVerifier(succeeds: true))
        _ = try await move.move(
            "account:acct-1:password",
            from: source,
            to: destination,
            newKey: "account:acct-1:password-v2"
        )
        #expect(try await destination.get("account:acct-1:password-v2") == Data("pw".utf8))
    }

    @Test func moveOfMissingKeyIsNotFound() async {
        let source = InMemoryCredentialStore()
        let destination = InMemoryCredentialStore()
        let move = CredentialStoreMove(verifier: FakeVerifier(succeeds: true))
        do {
            _ = try await move.move("account:acct-1:password", from: source, to: destination)
            Issue.record("expected notFound")
        } catch let error as CredentialError {
            #expect(error == .notFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
