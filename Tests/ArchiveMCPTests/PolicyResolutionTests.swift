import XCTest
import ArchiveCore
@testable import ArchiveMCP

/// The policy resolution order (decision 0054): the client's explicit file
/// from the environment, then the app's standard policy location, then
/// none — which the server treats as the permissive default. These tests
/// pin the pure pieces; the end-to-end tests prove the real launch path.
final class PolicyResolutionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("policy-resolution-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    // MARK: - Which file one launch reads

    func testEnvironmentValueWinsOverTheStandardLocation() {
        let standard = URL(fileURLWithPath: "/support/Bristlecone/Agents/policy.json")
        XCTAssertEqual(
            ArchiveMCPServer.policyFilePath(
                envValue: "/elsewhere/policy.json", standardURL: standard),
            "/elsewhere/policy.json")
    }

    func testEnvironmentValueExpandsTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            ArchiveMCPServer.policyFilePath(envValue: "~/.config/p.json", standardURL: nil),
            home + "/.config/p.json")
    }

    func testBlankEnvironmentMeansUnset() {
        let standard = URL(fileURLWithPath: "/support/Bristlecone/Agents/policy.json")
        XCTAssertEqual(
            ArchiveMCPServer.policyFilePath(envValue: "  ", standardURL: standard),
            standard.path)
        XCTAssertEqual(
            ArchiveMCPServer.policyFilePath(envValue: "", standardURL: standard),
            standard.path)
    }

    func testNoEnvironmentUsesTheStandardLocation() {
        let standard = URL(fileURLWithPath: "/support/Bristlecone/Agents/policy.json")
        XCTAssertEqual(
            ArchiveMCPServer.policyFilePath(envValue: nil, standardURL: standard),
            standard.path)
    }

    func testNothingConfiguredMeansNoPath() {
        XCTAssertNil(ArchiveMCPServer.policyFilePath(envValue: nil, standardURL: nil))
    }

    func testStandardLocationLayoutMatchesTheApp() {
        // The app writes (App/Sources/AgentAccess.swift) into Application
        // Support/Bristlecone/Agents; the helper must read the same shape.
        let url = ArchiveMCPServer.standardPolicyURL(
            underApplicationSupport: URL(fileURLWithPath: "/support"))
        XCTAssertEqual(url.path, "/support/Bristlecone/Agents/policy.json")
    }

    // MARK: - Reading one policy file

    func testAbsentFileIsNilNotAnError() throws {
        XCTAssertNil(
            try ArchiveMCPServer.policyFile(
                at: tempDir.appendingPathComponent("no-such.json").path,
                named: "the test policy"))
    }

    func testValidFileDecodes() throws {
        let url = tempDir.appendingPathComponent("policy.json")
        try Data(#"{"enabled": false}"#.utf8).write(to: url)
        let policy = try XCTUnwrap(
            try ArchiveMCPServer.policyFile(at: url.path, named: "the test policy"))
        XCTAssertFalse(policy.enabled)
    }

    func testInvalidFileThrowsInsteadOfDefaulting() throws {
        let url = tempDir.appendingPathComponent("policy.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertThrowsError(
            try ArchiveMCPServer.policyFile(at: url.path, named: "the test policy")
        ) { error in
            let described = String(describing: error)
            XCTAssertTrue(
                described.contains("refusing to start"),
                "an invalid policy file must refuse, not default: \(described)")
        }
    }
}
