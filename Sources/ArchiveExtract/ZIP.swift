// ZIP container reader for attachment extraction (decision 0036). The reader
// parses the central directory, verifies CRC-32 on every entry it inflates,
// and enforces hard allocation limits against zip bombs. It is deliberately
// strict: a wrong CRC or an unsupported layout must never hand the index
// silently-wrong bytes.

import CZlib
import Foundation

/// Errors the ZIP reader reports instead of returning wrong bytes.
public enum ZIPError: Error, Equatable {
    /// The data has no end-of-central-directory record: not a ZIP archive.
    case notAZip
    /// An end-of-central-directory record is present but its declared layout
    /// runs past the end of the data, or entries point outside the archive.
    case truncated
    /// An entry inflated fine but its CRC-32 does not match the recorded
    /// checksum. The `name` is the entry name as decoded.
    case corruptCRC(name: String)
    /// Layout features this reader will not interpret: ZIP64 archives,
    /// multi-disk archives, encrypted entries.
    case unsupported
    /// A limit from `ZIP.Limits` was exceeded (entry count or inflated size).
    case limitExceeded
}

/// One entry of a ZIP archive as handed to container extractors.
public struct ZIPEntry {
    /// The entry name, decoded per the ZIP name rules (UTF-8 when the
    /// general-purpose bit 11 is set, CP437 otherwise).
    public let name: String
    /// True when the entry is a directory (name ends with "/").
    public let isDirectory: Bool
    /// The inflated entry contents, or nil for directories and for entries
    /// skipped because their compression method is not supported. Skipped
    /// entries still appear in the list with their name.
    public let data: Data?
}

/// Reader for ZIP archives, the container format of .docx/.xlsx/.pptx,
/// OpenDocument, and iWork attachments, and of .zip attachments themselves.
///
/// All metadata is read from the central directory, which is the record
/// streamers write last: streamed writers set general-purpose bit 3 (data
/// descriptors) and leave the local header's CRC and sizes as zeros.
/// Implemented tolerances: self-extracting prefix bytes before the first
/// local header (offsets are rebased by the prefix length); trailing comment;
/// entries whose compression method is not stored or deflate (kept, but with
/// no data).
///
/// Rejected outright (`ZIPError.unsupported`): ZIP64 archives (sentinel
/// values in the end-of-central-directory record), multi-disk archives, and
/// encrypted entries — a misparse could hand back bytes from the wrong
/// offsets, so the reader refuses rather than guess.
public enum ZIP {
    /// Allocation limits guarding against zip bombs and hostile attachments.
    public struct Limits {
        /// Cap on the sum of inflated entry sizes across the whole archive.
        public let totalInflatedBytes: Int
        /// Cap on the inflated size of a single entry.
        public let perEntryInflatedBytes: Int
        /// Cap on the number of entries.
        public let entryCount: Int

        public init(
            totalInflatedBytes: Int = 512_000_000,
            perEntryInflatedBytes: Int = 256_000_000,
            entryCount: Int = 10_000
        ) {
            self.totalInflatedBytes = totalInflatedBytes
            self.perEntryInflatedBytes = perEntryInflatedBytes
            self.entryCount = entryCount
        }
    }

    /// Reads every entry of the archive.
    ///
    /// Verifies CRC-32 per entry against the central directory and throws
    /// `ZIPError.corruptCRC(name:)` on mismatch; never silently yields
    /// damaged contents.
    public static func open(_ data: Data, limits: Limits = .init()) throws -> [ZIPEntry] {
        let bytes = [UInt8](data)

        // End-of-central-directory scan: the signature can sit anywhere in
        // the last 22 + 65535 bytes, so scan that window backwards and take
        // the last candidate whose declared layout is consistent.
        let window = min(bytes.count, 22 + 65_535 + 4)
        guard window >= 4 else { throw ZIPError.notAZip }

        var parsed: Parsed?
        var sawSignature = false
        var start = bytes.count - 4
        let lowest = bytes.count - window
        while start >= lowest {
            if bytes[start] == 0x50, bytes[start + 1] == 0x4B,
               bytes[start + 2] == 0x05, bytes[start + 3] == 0x06 {
                sawSignature = true
                if let candidate = try parseArchive(bytes, endRecordAt: start, limits: limits) {
                    parsed = candidate
                    break
                }
            }
            start -= 1
        }

        guard let parsed else {
            throw sawSignature ? ZIPError.truncated : ZIPError.notAZip
        }

        // Reject declared totals before touching any payload.
        var claimedTotal = 0
        for entry in parsed.entries where entry.canExtract {
            claimedTotal += Int(entry.inflatedSize)
        }
        if claimedTotal > limits.totalInflatedBytes { throw ZIPError.limitExceeded }

        var results: [ZIPEntry] = []
        results.reserveCapacity(parsed.entries.count)
        var totalInflated = 0
        for entry in parsed.entries {
            let name = decodeName(entry.nameBytes, flags: entry.flags)
            guard !name.hasSuffix("/") else {
                results.append(ZIPEntry(name: name, isDirectory: true, data: nil))
                continue
            }
            guard entry.canExtract else {
                results.append(ZIPEntry(name: name, isDirectory: false, data: nil))
                continue
            }
            let payload = try entryPayload(entry, bytes: bytes, prefix: parsed.prefix)
            let inflated: [UInt8]
            if entry.method == 8 {
                inflated = try runInflate(
                    payload, expected: Int(entry.inflatedSize), limits: limits,
                    alreadyInflated: totalInflated
                )
            } else {
                inflated = payload
                if totalInflated + inflated.count > limits.totalInflatedBytes {
                    throw ZIPError.limitExceeded
                }
            }
            totalInflated += inflated.count
            if crc32Of(inflated) != entry.crc {
                throw ZIPError.corruptCRC(name: name)
            }
            results.append(ZIPEntry(name: name, isDirectory: false, data: Data(inflated)))
        }
        return results
    }

    // MARK: - Parsing

    private struct Parsed {
        /// Byte offset added to every declared offset (self-extracting junk
        /// before the archive proper).
        var prefix: Int
        var entries: [DirectoryEntry]
    }

    private struct DirectoryEntry {
        var nameBytes: [UInt8]
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var inflatedSize: UInt32
        var compressedSize: UInt32
        var localOffset: UInt32

        /// True when this reader will produce data for the entry: not a
        /// directory, not encrypted, method stored or deflate.
        var canExtract: Bool {
            method == 0 || method == 8
        }
    }

    /// Parses the end record and central directory at `endRecordAt`. Returns
    /// nil when the candidate is inconsistent (caller tries an earlier
    /// signature occurrence); throws for unambiguous rejections.
    private static func parseArchive(
        _ bytes: [UInt8], endRecordAt: Int, limits: Limits
    ) throws -> Parsed? {
        guard endRecordAt + 22 <= bytes.count else { return nil }
        func u16(_ offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }

        // Fixed end-record fields: sig(4) disk(2) cdDisk(2) countDisk(2)
        // countTotal(2) cdSize(4) cdOffset(4) commentLen(2).
        guard
            let countDisk = u16(endRecordAt + 8),
            let countTotal = u16(endRecordAt + 10),
            let cdSize = u32(endRecordAt + 12),
            let cdOffset = u32(endRecordAt + 16),
            let commentLen = u16(endRecordAt + 20),
            endRecordAt + 22 + Int(commentLen) <= bytes.count
        else {
            return nil
        }

        // Sentinel values mean ZIP64; refuse rather than misparse.
        if countTotal == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ZIPError.unsupported
        }
        if u16(endRecordAt + 4) != 0 || u16(endRecordAt + 6) != 0 || countDisk != countTotal {
            throw ZIPError.unsupported
        }
        if Int(countTotal) > limits.entryCount { throw ZIPError.limitExceeded }

        // The central directory ends right before the end record; its start
        // is derived, and the declared offset gives the prefix length.
        let cdEnd = endRecordAt
        let cdStart = cdEnd - Int(cdSize)
        guard cdStart >= 0, Int(cdOffset) <= cdStart else {
            return nil
        }
        let prefix = cdStart - Int(cdOffset)

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(Int(countTotal))
        var cursor = cdStart
        for _ in 0..<Int(countTotal) {
            guard cursor + 46 <= cdEnd, u32(cursor) == 0x0201_4B50,
                let flags = u16(cursor + 8),
                let method = u16(cursor + 10),
                let crc = u32(cursor + 16),
                let compressedSize = u32(cursor + 20),
                let inflatedSize = u32(cursor + 24),
                let nameLen = u16(cursor + 28),
                let extraLen = u16(cursor + 30),
                let commentLen = u16(cursor + 32),
                let localOffset = u32(cursor + 42),
                cursor + 46 + Int(nameLen) + Int(extraLen) + Int(commentLen) <= cdEnd
            else {
                return nil
            }
            entries.append(
                DirectoryEntry(
                    nameBytes: Array(bytes[(cursor + 46)..<(cursor + 46 + Int(nameLen))]),
                    flags: flags,
                    method: method,
                    crc: crc,
                    inflatedSize: inflatedSize,
                    compressedSize: compressedSize,
                    localOffset: localOffset
                )
            )
            cursor += 46 + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }
        return Parsed(prefix: prefix, entries: entries)
    }

    /// Locates the entry payload in the archive, rebasing the declared local
    /// header offset by the prefix length. Encrypted entries are rejected
    /// here, before any byte is touched.
    private static func entryPayload(
        _ entry: DirectoryEntry, bytes: [UInt8], prefix: Int
    ) throws -> [UInt8] {
        if entry.flags & 0x0001 != 0 { throw ZIPError.unsupported }
        let header = Int(entry.localOffset) + prefix
        guard header >= 0, header + 30 <= bytes.count,
            bytes[header] == 0x50, bytes[header + 1] == 0x4B,
            bytes[header + 2] == 0x03, bytes[header + 3] == 0x04
        else {
            throw ZIPError.truncated
        }
        func u16(_ offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        guard
            let nameLen = u16(header + 26),
            let extraLen = u16(header + 28)
        else {
            throw ZIPError.truncated
        }
        let dataStart = header + 30 + Int(nameLen) + Int(extraLen)
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= bytes.count else {
            throw ZIPError.truncated
        }
        return Array(bytes[dataStart..<dataEnd])
    }

    /// Raw-deflate (windowBits -15) via zlib, with hard output caps. The
    /// stream must consume exactly the declared compressed bytes and produce
    /// exactly the declared inflated size.
    private static func runInflate(
        _ input: [UInt8], expected: Int, limits: Limits, alreadyInflated: Int
    ) throws -> [UInt8] {
        if expected > limits.perEntryInflatedBytes { throw ZIPError.limitExceeded }
        var stream = z_stream()
        guard inflateInit2_(&stream, Int32(-15), ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            == Z_OK
        else { throw ZIPError.unsupported }
        defer { inflateEnd(&stream) }

        enum Outcome {
            case done
            case overLimit
            case malformed
        }
        var output = [UInt8]()
        output.reserveCapacity(min(expected, limits.perEntryInflatedBytes))
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var outcome = Outcome.malformed
        input.withUnsafeBufferPointer { inBuf in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBuf.baseAddress)
            stream.avail_in = UInt32(input.count)
            while true {
                var produced = 0
                var code: Int32 = Z_OK
                chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(outBuf.count)
                    code = inflate(&stream, Int32(Z_NO_FLUSH))
                    produced = outBuf.count - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(contentsOf: chunk[0..<produced])
                    #if DEBUG
                    #endif
                    if output.count > limits.perEntryInflatedBytes
                        || alreadyInflated + output.count > limits.totalInflatedBytes {
                        outcome = .overLimit
                        return
                    }
                } else {
                    #if DEBUG
                    #endif
                }
                if code == Z_STREAM_END {
                    outcome = stream.avail_in == 0 ? .done : .malformed
                    return
                }
                if code != Z_OK || produced == 0 { return }
            }
        }
        switch outcome {
        case .overLimit:
            throw ZIPError.limitExceeded
        case .malformed:
            throw ZIPError.truncated
        case .done:
            break
        }
        guard output.count == expected else { throw ZIPError.truncated }
        return output
    }

    // MARK: - Names

    /// UTF-8 when general-purpose bit 11 is set, CP437 otherwise (APPNOTE:
    /// unflagged names are "encoded in CP437"). Names are metadata, not
    /// stored content, so lossy mapping is acceptable here.
    private static func decodeName(_ raw: [UInt8], flags: UInt16) -> String {
        if flags & 0x0800 != 0 {
            return String(decoding: raw, as: UTF8.self)
        }
        var scalars = [Unicode.Scalar]()
        scalars.reserveCapacity(raw.count)
        for byte in raw {
            if byte < 0x80 {
                scalars.append(Unicode.Scalar(byte))
            } else {
                scalars.append(Unicode.Scalar(cp437High[Int(byte) - 0x80])!)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Unicode scalar values for CP437 bytes 0x80...0xFF.
    private static let cp437High: [UInt32] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
        0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
        0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
        0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
        0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
        0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
        0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
        0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
        0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
    ]

    // MARK: - CRC-32 (zlib)

    private static func crc32Of(_ bytes: [UInt8]) -> UInt32 {
        guard !bytes.isEmpty else { return UInt32(truncatingIfNeeded: crc32(0, nil, 0)) }
        var crc: uLong = crc32(0, nil, 0)
        bytes.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                crc = crc32(crc, base, uInt(bytes.count))
            }
        }
        return UInt32(truncatingIfNeeded: crc)
    }
}
