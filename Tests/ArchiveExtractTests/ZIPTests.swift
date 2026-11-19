import Foundation
import Testing

@testable import ArchiveExtract

/// Tests for the ZIP container reader (decision 0036). The container family of
/// extractors (.docx/.xlsx/.pptx, OpenDocument, iWork, .zip entry names) reads
/// attachments through this reader, so it must be strict: a wrong CRC or an
/// unsupported layout must never hand the index silently-wrong bytes.
///
/// Fixtures are built in-test by `ZIPBuilder` (stored entries) plus real,
/// precomputed raw-deflate streams (generated once with zlib, embedded as byte
/// arrays). The builder's CRC32 is a standard table implementation local to
/// this test target — the reader verifies CRCs against zlib's own.
@Suite
struct ZIPTests {
    // MARK: - Extraction

    @Test func readsStoredAndDeflatedEntries() throws {
        let zip = ZIPBuilder.make(entries: [
            .stored("readme.txt", Array("hello\n".utf8)),
            .deflated("report.txt", Self.reportDeflated, Self.reportRaw),
            .stored("data.bin", [0x00, 0xFF, 0x00, 0xFF]),
        ])
        let entries = try ZIP.open(Data(zip))
        #expect(entries.map(\.name) == ["readme.txt", "report.txt", "data.bin"])
        #expect(entries[0].data.map(Array.init) == Array("hello\n".utf8))
        #expect(entries[1].data.map(Array.init) == Self.reportRaw)
        #expect(entries[2].data.map(Array.init) == [0x00, 0xFF, 0x00, 0xFF])
        #expect(entries.allSatisfy { !$0.isDirectory })
    }

    @Test func readsDirectoryEntriesWithoutData() throws {
        let zip = ZIPBuilder.make(entries: [
            .stored("docs/", []),
            .stored("docs/readme.txt", Array("hi".utf8)),
        ])
        let entries = try ZIP.open(Data(zip))
        #expect(entries[0].name == "docs/")
        #expect(entries[0].isDirectory)
        #expect(entries[0].data == nil)
        #expect(entries[1].data.map(Array.init) == Array("hi".utf8))
    }

    // MARK: - Names

    @Test func decodesUTF8FlaggedNames() throws {
        // The name bytes are UTF-8 and the general-purpose bit 11 is set.
        let zip = ZIPBuilder.make(entries: [
            .stored("résumé.txt", Array("x".utf8), utf8Flag: true),
        ])
        let entries = try ZIP.open(Data(zip))
        #expect(entries.map(\.name) == ["résumé.txt"])
    }

    @Test func decodesUnflaggedNamesAsCP437() throws {
        // Without the UTF-8 flag, bytes >= 0x80 follow CP437: 0x82 = é.
        let nameBytes: [UInt8] = [0x63, 0x61, 0x66, 0x82, 0x2E, 0x74, 0x78, 0x74]
        let zip = ZIPBuilder.make(entries: [.stored(nameBytes: nameBytes, payload: Array("x".utf8))])
        let entries = try ZIP.open(Data(zip))
        #expect(entries.map(\.name) == ["café.txt"])
    }

    // MARK: - Rejection

    @Test func rejectsDataWithoutEOCD() {
        #expect(throws: ZIPError.notAZip) { try ZIP.open(Data([0x00, 0x01, 0x02])) }
        #expect(throws: ZIPError.notAZip) {
            // A JPEG-like magic is not a ZIP.
            try ZIP.open(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
        }
    }

    @Test func rejectsTruncatedArchive() throws {
        let zip = ZIPBuilder.make(entries: [.stored("a.txt", Array("hi".utf8))])
        #expect(throws: ZIPError.truncated) {
            try ZIP.open(Data(zip.dropLast(12)))
        }
    }

    @Test func rejectsWrongCRC() throws {
        // Flip one CRC byte on the deflated entry: the payload inflates fine
        // but the checksum no longer matches, which must be an error.
        let zip = ZIPBuilder.make(entries: [
            .deflated("report.txt", Self.reportDeflated, Self.reportRaw),
        ])
        var corrupt = zip
        let crcOffset = Self.centralDirectoryCRCOffset(in: corrupt)
        corrupt[crcOffset] ^= 0xFF
        #expect(throws: ZIPError.corruptCRC(name: "report.txt")) { try ZIP.open(Data(corrupt)) }
    }

    @Test func rejectsWrongCRCOnStoredEntry() throws {
        let zip = ZIPBuilder.make(entries: [
            .stored("readme.txt", Array("hello\n".utf8)),
        ])
        var corrupt = zip
        let crcOffset = Self.centralDirectoryCRCOffset(in: corrupt)
        corrupt[crcOffset] ^= 0xFF
        #expect(throws: ZIPError.corruptCRC(name: "readme.txt")) { try ZIP.open(Data(corrupt)) }
    }

    @Test func skipsUnsupportedMethodButKeepsName() throws {
        // Method 12 is bzip2; the reader cannot inflate it and must not
        // pretend it could. The entry keeps its name with no data so entry
        // names still join the index (decision 0036).
        let zip = ZIPBuilder.make(entries: [
            .raw("bzip2.bin", method: 12, payload: [0x42, 0x5A, 0x68]),
            .stored("readme.txt", Array("hi".utf8)),
        ])
        let entries = try ZIP.open(Data(zip))
        #expect(entries.map(\.name) == ["bzip2.bin", "readme.txt"])
        #expect(entries[0].data == nil)
        #expect(entries[1].data.map(Array.init) == Array("hi".utf8))
    }

    // MARK: - Tolerances

    @Test func usesCentralDirectorySizesWhenDataDescriptorFlagSet() throws {
        // Streamed writers set general-purpose bit 3 and leave the local
        // header's CRC and sizes as zeros; the central directory carries the
        // real values. The reader must trust the central directory.
        let zip = ZIPBuilder.make(entries: [
            .deflated("report.txt", Self.reportDeflated, Self.reportRaw, dataDescriptor: true),
        ])
        let entries = try ZIP.open(Data(zip))
        #expect(entries[0].data.map(Array.init) == Self.reportRaw)
    }

    @Test func toleratesPrefixJunk() throws {
        // Self-extracting archives carry bytes before the first local header;
        // the EOCD's declared offsets then need the prefix length added.
        var zip = Array(repeating: UInt8(0x5A), count: 16)
        zip += ZIPBuilder.make(entries: [
            .stored("readme.txt", Array("hi".utf8)),
            .deflated("report.txt", Self.reportDeflated, Self.reportRaw),
        ])
        let entries = try ZIP.open(Data(zip))
        #expect(entries.map(\.name) == ["readme.txt", "report.txt"])
        #expect(entries[1].data.map(Array.init) == Self.reportRaw)
    }

    // MARK: - Limits

    @Test func rejectsZIP64Offsets() throws {
        // A central-directory offset of 0xFFFFFFFF marks a ZIP64 archive;
        // this reader will not parse ZIP64, and must say so rather than
        // misparse the offsets (decision 0036).
        let zip = ZIPBuilder.make(entries: [.stored("a.txt", Array("hi".utf8))])
        var mutate = zip
        let cdOffsetIndex = mutate.count - 6 // EOCD: sig(4)…cdSize(4) cdOffset(4) comment(2)
        mutate.replaceSubrange(cdOffsetIndex..<cdOffsetIndex + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: ZIPError.unsupported) { try ZIP.open(Data(mutate)) }
    }

    @Test func enforcesTotalInflationLimit() throws {
        // A million zeros deflate to 985 bytes: a classic zip-bomb shape.
        // With the total-inflated cap set below the payload size, opening
        // must refuse rather than allocate.
        let zip = ZIPBuilder.make(entries: [
            .deflated("zeros.bin", Self.zerosDeflated, Self.zerosRaw),
        ])
        #expect(throws: ZIPError.limitExceeded) {
            try ZIP.open(Data(zip), limits: ZIP.Limits(totalInflatedBytes: 64_000))
        }
        // The default limit admits it comfortably.
        let entries = try ZIP.open(Data(zip))
        #expect(entries[0].data?.count == Self.zerosRaw.count)
    }

    @Test func enforcesPerEntryInflationLimit() throws {
        let zip = ZIPBuilder.make(entries: [
            .deflated("zeros.bin", Self.zerosDeflated, Self.zerosRaw),
        ])
        #expect(throws: ZIPError.limitExceeded) {
            try ZIP.open(
                Data(zip),
                limits: ZIP.Limits(totalInflatedBytes: 10_000_000, perEntryInflatedBytes: 64_000)
            )
        }
    }

    @Test func enforcesEntryCountLimit() throws {
        let entries = (0..<64).map { ZIPBuilder.Entry.stored("f\($0).txt", Array("x".utf8)) }
        let zip = ZIPBuilder.make(entries: entries)
        #expect(throws: ZIPError.limitExceeded) {
            try ZIP.open(Data(zip), limits: ZIP.Limits(entryCount: 32))
        }
    }

    // MARK: - Fixture bytes

    /// Raw-deflate stream (zlib, level 9) of `reportRaw`, generated once.
    static let reportRaw: [UInt8] = Array("Weekly status report\nAll action items are on track.\n".utf8)
    static let reportDeflated: [UInt8] = [11, 79, 77, 205, 206, 169, 84, 40, 46, 73, 44, 41, 45, 86, 40, 74, 45, 200, 47, 42, 225, 114, 204, 201, 81, 72, 76, 46, 201, 204, 207, 83, 200, 44, 73, 205, 45, 86, 72, 44, 74, 85, 0, 114, 74, 138, 18, 147, 179, 245, 184, 0]

    /// Raw-deflate stream (zlib, level 9) of a million zero bytes.
    static let zerosRaw: [UInt8] = Array(repeating: 0x00, count: 1_000_000)
    static let zerosDeflated: [UInt8] = [237, 193, 1, 1, 0, 0, 0, 130, 32, 255, 175, 110, 72, 64, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 175, 6]

    // MARK: - Test helpers

    /// Offset of the CRC-32 field of the first central-directory entry.
    private static func centralDirectoryCRCOffset(in zip: [UInt8]) -> Int {
        // Locate the EOCD signature by scanning backwards, then read cdSize
        // from the record itself; the first central entry starts at
        // eocdIndex - cdSize regardless of entry names or counts.
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocdIndex = -1
        if zip.count >= 4 {
            var start = zip.count - 4
            while start >= 0 {
                if zip[start] == eocdSig[0], zip[start + 1] == eocdSig[1],
                   zip[start + 2] == eocdSig[2], zip[start + 3] == eocdSig[3] {
                    eocdIndex = start
                    break
                }
                start -= 1
            }
        }
        precondition(eocdIndex >= 22, "fixture has no EOCD")
        func u32(_ o: Int) -> UInt32 {
            UInt32(zip[o]) | (UInt32(zip[o + 1]) << 8) | (UInt32(zip[o + 2]) << 16) | (UInt32(zip[o + 3]) << 24)
        }
        let cdSize = Int(u32(eocdIndex + 12))
        let cdStart = eocdIndex - cdSize
        precondition(cdStart >= 0, "EOCD cdSize exceeds fixture length")
        precondition(zip[cdStart] == 0x50 && zip[cdStart + 1] == 0x4B && zip[cdStart + 2] == 0x01,
                     "fixture has no central directory at the expected offset")
        return cdStart + 16 // CRC-32 sits 16 bytes into a central entry
    }
}

/// Minimal ZIP writer for test fixtures: stored entries, raw-deflate entries
/// whose bytes are precomputed, correct CRC-32 fields, and the few header
/// variations the reader must tolerate (UTF-8 name flag, data descriptors).
/// Shared across the ArchiveExtract test files (internal, not private).
enum ZIPBuilder {
    struct Entry {
        enum Kind {
            case stored(payload: [UInt8])
            case deflated(bytes: [UInt8]) // precomputed raw-deflate stream
            case raw(method: UInt16, payload: [UInt8])
        }

        let name: [UInt8]
        let utf8Flag: Bool
        let kind: Kind
        let crc: UInt32
        let inflatedSize: Int
        let dataDescriptor: Bool

        static func stored(
            _ name: String, _ payload: [UInt8], utf8Flag: Bool = false,
            declaredInflatedSize: Int? = nil
        ) -> Entry {
            Entry(
                name: Array(name.utf8), utf8Flag: utf8Flag, kind: .stored(payload: payload),
                crc: CRC32.checksum(payload), inflatedSize: declaredInflatedSize ?? payload.count,
                dataDescriptor: false
            )
        }

        static func stored(nameBytes: [UInt8], payload: [UInt8], utf8Flag: Bool = false) -> Entry {
            Entry(
                name: nameBytes, utf8Flag: utf8Flag, kind: .stored(payload: payload),
                crc: CRC32.checksum(payload), inflatedSize: payload.count, dataDescriptor: false
            )
        }

        static func deflated(
            _ name: String, _ deflated: [UInt8], _ inflated: [UInt8], dataDescriptor: Bool = false
        ) -> Entry {
            Entry(
                name: Array(name.utf8), utf8Flag: false, kind: .deflated(bytes: deflated),
                crc: CRC32.checksum(inflated), inflatedSize: inflated.count, dataDescriptor: dataDescriptor
            )
        }

        static func raw(_ name: String, method: UInt16, payload: [UInt8]) -> Entry {
            Entry(
                name: Array(name.utf8), utf8Flag: false,
                kind: .raw(method: method, payload: payload),
                crc: CRC32.checksum(payload), inflatedSize: payload.count, dataDescriptor: false
            )
        }
    }

    static func make(entries: [Entry]) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for entry in entries {
            let payload: [UInt8]
            let method: UInt16
            switch entry.kind {
            case let .stored(bytes):
                method = 0
                payload = bytes
            case let .deflated(bytes):
                method = 8
                payload = bytes
            case let .raw(methodValue, payloadBytes):
                method = methodValue
                payload = payloadBytes
            }
            let flags: UInt16 = (entry.utf8Flag ? 0x0800 : 0) | (entry.dataDescriptor ? 0x0008 : 0)
            let nameLen = UInt16(entry.name.count)
            let crcLE = uint32LE(entry.crc)
            let inflatedLE = uint32LE(UInt32(entry.inflatedSize))
            let storedLE = uint32LE(UInt32(payload.count))
            let offset = uint32LE(UInt32(out.count))

            // Local header. With a data descriptor the CRC and sizes here are
            // zeros and the real values live only in the central directory.
            out += [0x50, 0x4B, 0x03, 0x04]
            out += uint16LE(20) // version needed
            out += uint16LE(flags)
            out += uint16LE(method)
            out += uint16LE(0) // mod time
            out += uint16LE(0) // mod date
            out += entry.dataDescriptor ? [0, 0, 0, 0] : crcLE
            out += entry.dataDescriptor ? [0, 0, 0, 0] : storedLE
            out += entry.dataDescriptor ? [0, 0, 0, 0] : inflatedLE
            out += uint16LE(nameLen)
            out += uint16LE(0) // extra len
            out += entry.name
            out += payload

            // Data descriptor for streamed entries (optional 0x08074b50
            // prefix, then the real values).
            if entry.dataDescriptor {
                out += [0x50, 0x4B, 0x07, 0x08]
                out += crcLE
                out += storedLE
                out += inflatedLE
            }

            // Central directory entry.
            central += [0x50, 0x4B, 0x01, 0x02]
            central += uint16LE(20) // version made by
            central += uint16LE(20) // version needed
            central += uint16LE(flags)
            central += uint16LE(method)
            central += uint16LE(0) // mod time
            central += uint16LE(0) // mod date
            central += crcLE
            central += storedLE
            central += inflatedLE
            central += uint16LE(nameLen)
            central += uint16LE(0) // extra len
            central += uint16LE(0) // comment len
            central += uint16LE(0) // disk number start
            central += uint16LE(0) // internal attributes
            central += uint32LE(0) // external attributes
            central += offset
            central += entry.name
        }

        out += central
        // The CD starts exactly where the central bytes begin (the builder
        // emits no prefix); it must be recorded BEFORE the EOCD fields are
        // appended, or the offset would count the EOCD's own 16 leading bytes.
        let cdOffset = out.count - central.count
        out += [0x50, 0x4B, 0x05, 0x06] // EOCD
        out += uint16LE(0) // this disk
        out += uint16LE(0) // CD start disk
        out += uint16LE(UInt16(entries.count)) // entries on this disk
        out += uint16LE(UInt16(entries.count)) // entries total
        out += uint32LE(UInt32(central.count))
        out += uint32LE(UInt32(cdOffset)) // CD offset
        out += uint16LE(0) // comment len
        return out
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}

/// Standard CRC-32 (the same polynomial zlib uses), local to this test target
/// so fixtures carry correct checksums without depending on the reader.
private enum CRC32 {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        let table: [UInt32] = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
