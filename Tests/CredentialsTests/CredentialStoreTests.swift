import XCTest
@testable import Credentials

final class CredentialStoreTests: XCTestCase {
    func testPutGetRoundTrip() async throws {
        let store = InMemoryCredentialStore()
        try await store.put("account:a1:password", secret: Data("secret".utf8))
        let read = try await store.get("account:a1:password")
        XCTAssertEqual(read, Data("secret".utf8))
    }

    func testGetUnknownKeyThrowsNotFound() async throws {
        let store = InMemoryCredentialStore()
        do {
            _ = try await store.get("account:missing:password")
            XCTFail("expected notFound")
        } catch let error as CredentialError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testPutReplacesAndDeleteRemoves() async throws {
        let store = InMemoryCredentialStore()
        try await store.put("k", secret: Data("one".utf8))
        try await store.put("k", secret: Data("two".utf8))
        let afterSecondPut = try await store.get("k")
        XCTAssertEqual(afterSecondPut, Data("two".utf8))
        try await store.delete("k")
        try await store.delete("k") // removing an absent key is not an error
        do {
            _ = try await store.get("k")
            XCTFail("expected notFound after delete")
        } catch let error as CredentialError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testRotateReplacesOnlyExistingKeys() async throws {
        let store = InMemoryCredentialStore()
        try await store.put("k", secret: Data("old".utf8))
        try await store.rotate("k", to: Data("new".utf8))
        let afterRotate = try await store.get("k")
        XCTAssertEqual(afterRotate, Data("new".utf8))
        do {
            try await store.rotate("absent", to: Data("x".utf8))
            XCTFail("expected notFound")
        } catch let error as CredentialError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
