import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Stable identifiers shared by local-media import and metadata editing.
@available(macOS 13.0, iOS 16.0, *)
public enum MusicContentIdentity {
    public static func sha256Hex(_ data: Data) -> String {
#if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
#endif
    }

    public static func token(_ value: String) -> String {
        sha256Hex(Data(value.utf8))
    }

    /// Hashes an ordered list without allowing separators inside values to
    /// make two different lists share the same serialized input.
    public static func compositeToken(_ values: [String]) -> String {
        let serialized = values.reduce(into: "") { result, value in
            result += "\(value.utf8.count):\(value)"
        }
        return token(serialized)
    }
}
