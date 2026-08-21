import Foundation
import MusicDomain

struct VLCAudioStreamCandidate: Equatable, Sendable {
  let stableIDs: Set<String>
  let index: Int
  let language: String?
  let title: String?
  let codec: String?
  let channelCount: Int?
}

enum VLCAudioStreamMatcher {
  static func index(
    for selection: AudioStreamSelection,
    candidates: [VLCAudioStreamCandidate]
  ) -> Int? {
    if let streamID = selection.streamID?.rawValue,
       let exact = candidates.first(where: { $0.stableIDs.contains(streamID) })
    {
      return exact.index
    }

    let signature = selection.fallbackSignature
    let ranked = candidates.compactMap { candidate -> (Int, Int)? in
      var score = 0
      for (expected, actual, weight) in [
        (signature.language, candidate.language, 16),
        (signature.title, candidate.title, 8),
        (signature.codec, candidate.codec, 4),
      ] {
        guard let expected = normalized(expected) else { continue }
        guard expected == normalized(actual) else { return nil }
        score += weight
      }
      if let expectedChannels = signature.channelCount {
        guard candidate.channelCount == expectedChannels else { return nil }
        score += 2
      }
      if signature.indexHint == candidate.index { score += 1 }
      return (candidate.index, score)
    }
    return ranked.max { lhs, rhs in
      lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
    }?.0 ?? signature.indexHint.flatMap { hint in
      candidates.contains(where: { $0.index == hint }) ? hint : nil
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
  }
}
