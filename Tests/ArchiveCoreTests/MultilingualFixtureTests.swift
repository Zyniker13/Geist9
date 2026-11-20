// Multilingual end-to-end fixtures (ROADMAP M2 "Done when"): a Chinese, a
// Korean, a Russian, and a German fixture are each found by their own
// words, and a German compound is found by one of its parts through the
// trigram fallback. Every message is fake, example.com addresses only.

import XCTest
@testable import ArchiveCore

final class MultilingualFixtureTests: XCTestCase {
    private var tempDir: URL!
    private var store: ArchiveStore!
    private var ids: [String: Int64] = [:]

    private let alice = AccountIdentity(email: "alice@example.com", displayName: "Alice", providerKind: "import")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("geist9-multilingual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try ArchiveStore.create(at: tempDir.appendingPathComponent("Multi.emailarchive"), appVersion: "0.1.0")

        ids["zh"] = try ingest("""
        Message-ID: <zh-fixture@example.com>
        Date: Mon, 04 Mar 2024 09:20:00 +0000
        From: Li Wei <li.wei@example.com>
        To: alice@example.com
        Subject: 二月发票

        二月的发票已经收到，付款将在周五安排。
        """)
        ids["ko"] = try ingest("""
        Message-ID: <ko-fixture@example.com>
        Date: Tue, 05 Mar 2024 10:30:00 +0000
        From: Kim Minsu <kim.minsu@example.com>
        To: alice@example.com
        Subject: 3월 회의 안내

        다음 주 화요일에 회의가 있습니다. 회의실은 3층입니다.
        """)
        ids["ru"] = try ingest("""
        Message-ID: <ru-fixture@example.com>
        Date: Wed, 06 Mar 2024 11:40:00 +0000
        From: Ivan Petrov <ivan.petrov@example.com>
        To: alice@example.com
        Subject: переговоры с поставщиком

        переговоры с поставщиком прошли успешно, счёт согласован.
        """)
        ids["de"] = try ingest("""
        Message-ID: <de-fixture@example.com>
        Date: Thu, 07 Mar 2024 12:50:00 +0000
        From: Anna Schmidt <anna.schmidt@example.com>
        To: alice@example.com
        Subject: Schadensbericht zum Wasserrohrbruch

        Im Anhang finden Sie den Schadensbericht.
        """)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: helpers

    private func eml(_ raw: String) -> Data {
        // Multiline literals carry no trailing newline; real .eml files end
        // with one.
        Data((raw + "\n").utf8)
    }

    @discardableResult
    private func ingest(_ raw: String) throws -> Int64 {
        let data = eml(raw)
        let parsed = MailBridge.parse(for: data)
        let message = IngestedMessage(
            record: parsed.record,
            data: data,
            memberships: [Membership(mailbox: "INBOX")],
            labels: parsed.gmailLabels.map { LabelName(name: $0) },
            attachments: parsed.attachments,
            providerThreadID: parsed.gmailThreadID,
            searchText: parsed.searchText
        )
        switch try store.ingest(message, into: alice) {
        case .created(let id): return id
        case .duplicate(let id): return id
        }
    }

    private func idsMatching(_ query: String) throws -> Set<Int64> {
        Set(try store.search(query).hits.map(\.messageID))
    }

    private func assertFound(_ query: String, _ key: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try idsMatching(query)
        XCTAssertTrue(
            got.contains(ids[key]!),
            "\(query) must find the \(key) fixture (got \(got.count) hits)",
            file: file, line: line
        )
    }

    private func assertMisses(_ query: String, _ keys: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try idsMatching(query)
        for key in keys {
            XCTAssertFalse(
                got.contains(ids[key]!),
                "\(query) must not match the \(key) fixture",
                file: file, line: line
            )
        }
    }

    // MARK: the Done-when fixtures

    func testChineseFixtureFoundByItsOwnWords() throws {
        try assertFound("发票", "zh")
        try assertMisses("发票", ["ko", "ru", "de"])
    }

    func testKoreanFixtureFoundByItsOwnWords() throws {
        try assertFound("회의", "ko")
        try assertMisses("회의", ["zh", "ru", "de"])
    }

    func testRussianFixtureFoundByItsOwnWords() throws {
        try assertFound("переговоры", "ru")
        try assertMisses("переговоры", ["zh", "ko", "de"])
    }

    func testGermanFixtureFoundByItsOwnWords() throws {
        try assertFound("Schadensbericht", "de")
        try assertMisses("Schadensbericht", ["zh", "ko", "ru"])
    }

    /// A German compound found by one of its parts: the exact index holds
    /// the whole folded token, so "Schaden" alone misses it; the trigram
    /// fallback then matches the substring (DESIGN 6A, M2.1).
    func testGermanCompoundFoundByOneOfItsParts() throws {
        try assertFound("Schaden", "de")
        try assertMisses("Schaden", ["zh", "ko", "ru"])
        let hit = try XCTUnwrap(
            store.search("Schaden").hits.first { $0.messageID == ids["de"] }
        )
        XCTAssertTrue(hit.viaTrigram, "the compound part must be rescued by the trigram fallback")
    }
}
