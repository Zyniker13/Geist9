// The archive manifest (DESIGN 6): format version, creation date, app version,
// and encryption info. Written once at archive creation; the format version is
// how future releases detect archives they cannot open.

import Foundation

public struct ArchiveManifest: Codable, Sendable, Equatable {
    /// The archive format this repository documents (docs/ARCHIVE-FORMAT.md).
    /// Bump only when the on-disk contract changes, with a migration note.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// UTC, ISO 8601.
    public var createdAt: String
    public var appVersion: String
    public var encryption: EncryptionInfo

    public struct EncryptionInfo: Codable, Sendable, Equatable {
        /// 1.0 archives are unencrypted (protected by FileVault, DESIGN 10).
        public var enabled: Bool
        /// Reserved for the 1.1 sealed-envelope scheme; nil until then.
        public var scheme: String?

        public init(enabled: Bool, scheme: String? = nil) {
            self.enabled = enabled
            self.scheme = scheme
        }
    }

    public init(createdAt: Date, appVersion: String, encryption: EncryptionInfo = EncryptionInfo(enabled: false)) {
        self.formatVersion = Self.currentFormatVersion
        self.createdAt = Timestamp.string(createdAt)
        self.appVersion = appVersion
        self.encryption = encryption
    }

    enum DecodingError: Error {
        case unsupportedFormatVersion(Int)
        case malformed(String)
    }

    /// Reads and validates manifest.json. An archive whose format is newer than
    /// this build understands must refuse to open rather than guess.
    public static func read(from url: URL) throws -> ArchiveManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(ArchiveManifest.self, from: data) else {
            throw ArchiveError.malformedManifest
        }
        guard manifest.formatVersion >= 1, manifest.formatVersion <= Self.currentFormatVersion else {
            throw ArchiveError.unsupportedFormatVersion(manifest.formatVersion)
        }
        return manifest
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try AtomicWrite.write(data, to: url)
    }
}

/// ISO 8601 UTC at seconds precision, fixed width, so SQLite TEXT comparisons
/// sort chronologically and third-party tools can read the index directly.
public enum Timestamp {
    public static func string(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    public static func date(_ string: String) -> Date? {
        // Fixed format: 2024-03-05T14:23:01Z
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges == 7 else {
            return nil
        }
        func group(_ i: Int) -> Int? {
            guard let r = Range(match.range(at: i), in: string) else { return nil }
            return Int(string[r])
        }
        guard let year = group(1), let month = group(2), let day = group(3),
              let hour = group(4), let minute = group(5), let second = group(6),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))
    }
}
