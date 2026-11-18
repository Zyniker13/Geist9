// Content addressing (DESIGN 6): every message is stored as
// messages/ab/cd/<sha256-hex>.eml where the name is the SHA-256 of the bytes.
// The hash is the message's storage identity across accounts and imports.

import Crypto
import Foundation

/// The SHA-256 of a stored message's original bytes.
public struct MessageHash: Hashable, Sendable, CustomStringConvertible {
    /// 32 raw bytes.
    public let bytes: Data

    public init?(hex: String) {
        guard hex.count == 64, let data = Data(hexString: hex) else { return nil }
        self.bytes = data
    }

    public init(bytes: Data) {
        precondition(bytes.count == 32, "MessageHash holds a full SHA-256 (32 bytes)")
        self.bytes = bytes
    }

    /// Lower-case hex, as used in file names.
    public var hex: String { bytes.hexEncodedString() }

    public var description: String { hex }

    /// First byte, for the `ab/` directory shard.
    var shard1: String { hex.prefix(2).lowercased() }
    /// Second byte, for the `cd/` directory shard.
    var shard2: String { hex.dropFirst(2).prefix(2).lowercased() }

    /// Storage path components relative to the archive's `messages/` directory.
    var relativePath: String { "\(shard1)/\(shard2)/\(hex).eml" }

    /// SHA-256 of the original bytes. The one place hashing happens.
    public static func sha256(_ data: Data) -> MessageHash {
        MessageHash(bytes: Data(SHA256.hash(data: data)))
    }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.hexValue(chars[index]),
                  let low = Self.hexValue(chars[index + 1]) else { return nil }
            bytes.append((high << 4) | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30          // 0-9
        case 0x61...0x66: return c - 0x61 + 10     // a-f
        case 0x41...0x46: return c - 0x41 + 10     // A-F
        default: return nil
        }
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
