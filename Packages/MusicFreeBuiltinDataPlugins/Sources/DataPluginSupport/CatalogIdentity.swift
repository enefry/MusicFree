import Foundation
import CryptoKit

/// Stable candidate identity without importing the library's content model.
public enum MusicContentIdentity {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
