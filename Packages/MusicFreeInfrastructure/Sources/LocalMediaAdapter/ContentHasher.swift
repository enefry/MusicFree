import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// A hashing dependency that keeps the importer testable without loading a file into memory.
public protocol LocalMediaHashing: Sendable {
  func hash(fileAt url: URL) async throws -> String
}

struct ContentHasher: LocalMediaHashing, Sendable {
  private let chunkSize: Int

  init(chunkSize: Int = 64 * 1024) {
    self.chunkSize = max(4 * 1024, chunkSize)
  }

  func hash(fileAt url: URL) async throws -> String {
    guard url.isFileURL else {
      throw LocalMediaError.hashingFailed
    }

#if canImport(CryptoKit)
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      var hasher = SHA256()
      while true {
        try Task.checkCancellation()
        guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else {
          break
        }
        hasher.update(data: data)
      }
      return Self.hex(hasher.finalize())
    } catch is CancellationError {
      throw LocalMediaError.cancelled
    } catch {
      throw LocalMediaError.hashingFailed
    }
#else
    throw LocalMediaError.hashingFailed
#endif
  }

  static func hash(data: Data) -> String {
#if canImport(CryptoKit)
    Self.hex(SHA256.hash(data: data))
#else
    ""
#endif
  }

#if canImport(CryptoKit)
  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
#endif
}
