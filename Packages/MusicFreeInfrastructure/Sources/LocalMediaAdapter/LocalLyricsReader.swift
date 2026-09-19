import Foundation
import MediaSourceAPI
import MusicDomain

/// Reads a same-name sidecar without retaining the source URL in the library.
/// The caller is responsible for holding any security-scoped access required
/// by the source while this function runs.
enum LocalLyricsReader {
  static let maximumByteCount = 2 * 1024 * 1024
  private static let supportedExtensions = ["lrc", "srt"]

  static func readSidecar(for mediaURL: URL) throws -> String? {
    for fileExtension in supportedExtensions {
      let exactSidecar = mediaURL
        .deletingPathExtension()
        .appendingPathExtension(fileExtension)
      do {
        if let lyrics = try readCandidate(at: exactSidecar) {
          return normalizedLyrics(lyrics, fileExtension: fileExtension)
        }
      } catch {
        // A security-scoped file may allow the exact sibling path while denying
        // directory enumeration. Keep the case-insensitive fallback available.
      }
    }

    let directory = mediaURL.deletingLastPathComponent()
    let baseName = mediaURL.deletingPathExtension().lastPathComponent
    let candidates = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.path < $1.path }

    guard let sidecar = candidates.first(where: { candidate in
      candidate.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(baseName) == .orderedSame
        && supportedExtensions.contains(candidate.pathExtension.lowercased())
    }) else {
      return nil
    }

    guard let lyrics = try readCandidate(at: sidecar) else { return nil }
    return normalizedLyrics(lyrics, fileExtension: sidecar.pathExtension)
  }

  private static func normalizedLyrics(_ text: String, fileExtension: String) -> String {
    guard fileExtension.caseInsensitiveCompare("srt") == .orderedSame else { return text }
    return convertSRTToLRC(text)
  }

  private static func convertSRTToLRC(_ text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    return normalized.components(separatedBy: "\n\n").compactMap { block in
      let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
      guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
            let start = lines[timingIndex].components(separatedBy: "-->").first,
            let timestamp = lrcTimestamp(start),
            timingIndex + 1 < lines.count
      else { return nil }
      let lyric = lines[(timingIndex + 1)...]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      return lyric.isEmpty ? nil : "[\(timestamp)]\(lyric)"
    }.joined(separator: "\n")
  }

  private static func lrcTimestamp(_ value: String) -> String? {
    let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
      .split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let hours = Int(parts[0]),
          let minutes = Int(parts[1]),
          hours >= 0,
          (0...59).contains(minutes)
    else { return nil }
    let secondsParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
    guard secondsParts.count == 2,
          let seconds = Int(secondsParts[0]),
          (0...59).contains(seconds),
          !secondsParts[1].isEmpty,
          secondsParts[1].allSatisfy(\.isNumber)
    else { return nil }
    let milliseconds = String(secondsParts[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
    return String(format: "%02d:%02d.%@", hours * 60 + minutes, seconds, milliseconds)
  }

  private static func readCandidate(at sidecar: URL) throws -> String? {
    let values = try sidecar.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true,
          values.isSymbolicLink != true,
          let fileSize = values.fileSize,
          fileSize <= maximumByteCount
    else {
      return nil
    }
    // The file may grow after the resource-value check. Read at most one byte
    // beyond the limit so a raced replacement cannot allocate unbounded data.
    guard let data = try readData(at: sidecar, maximumByteCount: maximumByteCount) else {
      return nil
    }
    return MetadataTextRepair.decode(data)
  }

  private static func readData(at url: URL, maximumByteCount: Int) throws -> Data? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var data = Data()
    while true {
      let remaining = maximumByteCount - data.count
      let readCount = remaining == 0 ? 1 : remaining + 1
      guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
        return data
      }
      guard chunk.count <= remaining else {
        return nil
      }
      data.append(chunk)
    }
  }
}
