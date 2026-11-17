import XCTest
@testable import ArchiveCore

final class ArchiveFormatTests: XCTestCase {
    func testMessagePathShardsByHash() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(ArchiveFormat.messagePath(forSHA256: hex), "messages/ab/ab/\(hex).eml")
    }

    func testMessagePathRejectsBadHashes() {
        XCTAssertNil(ArchiveFormat.messagePath(forSHA256: "abc"))
        XCTAssertNil(ArchiveFormat.messagePath(forSHA256: String(repeating: "AB", count: 32)))
        XCTAssertNil(ArchiveFormat.messagePath(forSHA256: String(repeating: "../", count: 21) + "a"))
    }
}
