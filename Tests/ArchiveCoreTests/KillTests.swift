// Crash-recovery tests: kill bench-search at durability boundaries and verify
// the batch-ingest durability contract (DESIGN 6): a crash anywhere leaves
// only complete files plus, at most, an unindexed set; no stored message bytes
// are ever lost or altered, and a resumed run converges the archive to exactly
// the input.
//
// Two kill mechanisms:
// - `--kill-after N`: SIGABRT after N messages, checked between batch flushes.
// - `--crash-stage <name>`: SIGABRT exactly at a batch-ingest stage boundary
//   (ArchiveStore.crashHook), the state a power loss would leave mid-flush.
//
// After a crash scrub may report unindexed files — that is the crash boundary
// the index transaction guards, not data loss. Loss means hashMismatches
// (bytes altered), missingFiles (indexed but gone), or corruptLayout.

import Foundation
import XCTest
@testable import ArchiveCore

final class KillTests: XCTestCase {
    private var archiveDir: URL!

    /// The bench-search executable, derived from this file's path so the test
    /// works from any working directory and on Linux CI. check.sh's `swift
    /// build` produces it before `swift test` runs. The classic `.build/debug`
    /// layout holds on Linux and native SwiftPM builds; the XCBuild layout
    /// `.build/out/Products/Debug` holds when the Xcode build system drives
    /// SwiftPM — try both.
    private static let benchSearch: URL = {
        let here = URL(fileURLWithPath: #filePath) // .../Tests/ArchiveCoreTests/KillTests.swift
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            root.appendingPathComponent(".build/debug/bench-search"),
            root.appendingPathComponent(".build/out/Products/Debug/bench-search"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return candidates[0]
    }()

    override func setUp() {
        archiveDir = nil
        super.setUp()
    }

    override func tearDown() {
        if let dir = archiveDir {
            try? FileManager.default.removeItem(at: dir)
        }
        archiveDir = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func makeTempArchive() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KillTest-\(UUID().uuidString)", isDirectory: true)
        // create() writes the manifest and the messages/ layout itself.
        _ = try ArchiveStore.create(at: dir, appVersion: "test")
        return dir
    }

    /// Runs bench-search and returns its exit status. For a SIGABRT death the
    /// status is the signal number (non-zero), which is all the tests assert.
    @discardableResult
    private func spawnBenchSearch(_ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = Self.benchSearch
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if !data.isEmpty {
            print(String(decoding: data, as: UTF8.self))
        }
        return process.terminationStatus
    }

    private func assertNoDataLoss(
        _ scrub: ScrubReport, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(scrub.hashMismatches.isEmpty, "hash mismatches: \(scrub.hashMismatches)", file: file, line: line)
        XCTAssertTrue(scrub.missingFiles.isEmpty, "missing files: \(scrub.missingFiles)", file: file, line: line)
        XCTAssertTrue(scrub.corruptLayout.isEmpty, "corrupt layout: \(scrub.corruptLayout)", file: file, line: line)
    }

    /// Opens the archive, asserts the post-crash / post-resume state, and lets
    /// the store close when the function returns — the test must not hold the
    /// database open across a child-process run.
    private func assertArchive(
        _ dir: URL, unindexed: Int, rows: Int, clean: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let store = try ArchiveStore.open(at: dir)
        let scrub = try store.scrub()
        assertNoDataLoss(scrub, file: file, line: line)
        XCTAssertEqual(scrub.isClean, clean, "unindexed files: \(scrub.unindexedFiles.count)", file: file, line: line)
        XCTAssertEqual(scrub.unindexedFiles.count, unindexed, "unindexed files", file: file, line: line)
        XCTAssertEqual(try store.countMessages(), rows, "indexed rows", file: file, line: line)
    }

    // MARK: - Crash between batches (kill point checked in the message loop)

    func testCrashBetweenBatchesThenResume() throws {
        archiveDir = try makeTempArchive()
        let count = 500

        // Kill after 100 messages: batch 1 (256) has not flushed yet, so the
        // archive is empty on disk.
        let crashExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42", "--kill-after", "100"
        ])
        XCTAssertNotEqual(crashExit, 0, "bench-search should have died at the kill point")

        try assertArchive(archiveDir, unindexed: 0, rows: 0, clean: true)

        // Resume with the same arguments: already-stored messages cost only a
        // hash lookup, so the run converges.
        let resumeExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(resumeExit, 0, "resumed ingest should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }

    // MARK: - Crash after durable file writes, before directory fsync

    func testCrashAfterFilesWrittenThenResume() throws {
        archiveDir = try makeTempArchive()
        let count = 500

        // First batch flush: 256 files are renamed into place, then the
        // process dies before the directories are flushed. No index row was
        // committed (the index never leads the files).
        let crashExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42", "--crash-stage", "files-written"
        ])
        XCTAssertNotEqual(crashExit, 0, "bench-search should have died at the files-written boundary")

        try assertArchive(archiveDir, unindexed: 256, rows: 0, clean: false)

        let resumeExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(resumeExit, 0, "resumed ingest should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }

    // MARK: - Crash after directory fsync, before the index transaction

    func testCrashAfterDirFsyncThenResume() throws {
        archiveDir = try makeTempArchive()
        let count = 500

        let crashExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42", "--crash-stage", "dir-fsync"
        ])
        XCTAssertNotEqual(crashExit, 0, "bench-search should have died at the dir-fsync boundary")

        try assertArchive(archiveDir, unindexed: 256, rows: 0, clean: false)

        let resumeExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(resumeExit, 0, "resumed ingest should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }

    // MARK: - Crash after the index transaction committed

    func testCrashAfterIndexCommitThenResume() throws {
        archiveDir = try makeTempArchive()
        let count = 500

        let crashExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42", "--crash-stage", "index-commit"
        ])
        XCTAssertNotEqual(crashExit, 0, "bench-search should have died at the index-commit boundary")

        try assertArchive(archiveDir, unindexed: 0, rows: 256, clean: true)

        let resumeExit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(resumeExit, 0, "resumed ingest should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }

    // MARK: - Multiple crash-resume cycles on one archive

    func testMultipleCrashResumeCycles() throws {
        archiveDir = try makeTempArchive()
        let count = 500

        // Cycle 1: die in the message loop before any flush.
        var exit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42", "--kill-after", "100"
        ])
        XCTAssertNotEqual(exit, 0)
        try assertArchive(archiveDir, unindexed: 0, rows: 0, clean: true)

        // Cycle 2: die mid-flush, leaving the first batch's files unindexed.
        exit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42", "--crash-stage", "files-written"
        ])
        XCTAssertNotEqual(exit, 0)
        try assertArchive(archiveDir, unindexed: 256, rows: 0, clean: false)

        // Cycle 3: die mid-loop after one full batch committed.
        exit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42", "--kill-after", "300"
        ])
        XCTAssertNotEqual(exit, 0)
        try assertArchive(archiveDir, unindexed: 0, rows: 256, clean: true)

        // Final resume to completion.
        exit = try spawnBenchSearch([
            "prepare", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(exit, 0, "resumed ingest should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }

    // MARK: - Crash during a real import (MailImporter → per-message ingest)
    //
    // ROADMAP M1: "Kill tests during import leave a valid archive that the
    // next run completes." Import ingests one message at a time, so a crash
    // after N counted file-write boundaries leaves N-1 rows committed and
    // exactly one unindexed file (message N's bytes, durable but unindexed).

    func testCrashDuringImportThenResume() throws {
        archiveDir = try makeTempArchive()
        let count = 300

        let crashExit = try spawnBenchSearch([
            "import", archiveDir.path, String(count), "42", "--kill-after", "100"
        ])
        XCTAssertNotEqual(crashExit, 0, "import should have died at the kill point")

        try assertArchive(archiveDir, unindexed: 1, rows: 99, clean: false)

        // Resume: the same deterministic source regenerates identical bytes,
        // so the 99 stored messages dedup and the run converges.
        let resumeExit = try spawnBenchSearch([
            "import", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(resumeExit, 0, "resumed import should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }

    func testCrashDuringImportAtFilesWrittenThenResume() throws {
        archiveDir = try makeTempArchive()
        let count = 300

        let crashExit = try spawnBenchSearch([
            "import", archiveDir.path, String(count), "42", "--crash-stage", "files-written"
        ])
        XCTAssertNotEqual(crashExit, 0, "import should have died at the files-written boundary")

        // The first message's bytes are on disk; nothing is indexed yet.
        try assertArchive(archiveDir, unindexed: 1, rows: 0, clean: false)

        let resumeExit = try spawnBenchSearch([
            "import", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(resumeExit, 0, "resumed import should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }

    func testCrashDuringImportAtIndexCommitThenResume() throws {
        archiveDir = try makeTempArchive()
        let count = 300

        let crashExit = try spawnBenchSearch([
            "import", archiveDir.path, String(count), "42", "--crash-stage", "index-commit"
        ])
        XCTAssertNotEqual(crashExit, 0, "import should have died at the index-commit boundary")

        // The first message committed completely; the second never started.
        try assertArchive(archiveDir, unindexed: 0, rows: 1, clean: true)

        let resumeExit = try spawnBenchSearch([
            "import", archiveDir.path, String(count), "42"
        ])
        XCTAssertEqual(resumeExit, 0, "resumed import should succeed")

        try assertArchive(archiveDir, unindexed: 0, rows: count, clean: true)
    }
}
