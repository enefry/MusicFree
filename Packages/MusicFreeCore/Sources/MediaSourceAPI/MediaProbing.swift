import Foundation
import MusicDomain

/// One audio track reported by a probe. Unknown technical values remain nil.
public struct ProbedAudioTrack: Codable, Equatable, Sendable {
  public let index: Int
  public let stableID: String?
  public let codec: String?
  public let sampleRate: Double?
  public let channelCount: Int?
  public let bitDepth: Int?
  /// Bit rate in bits per second, when the probe reports it.
  public let bitRate: Int?
  public let language: String?
  public let title: String?
  public let isDefault: Bool
  public let isDecodable: Bool

  public init(
    index: Int,
    stableID: String? = nil,
    codec: String? = nil,
    sampleRate: Double? = nil,
    channelCount: Int? = nil,
    bitDepth: Int? = nil,
    bitRate: Int? = nil,
    language: String? = nil,
    title: String? = nil,
    isDefault: Bool = false,
    isDecodable: Bool = true
  ) {
    self.index = index
    self.stableID = Self.trimmed(stableID)
    self.codec = Self.trimmed(codec)
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.bitDepth = bitDepth
    self.bitRate = bitRate
    self.language = Self.trimmed(language)
    self.title = Self.repaired(title)
    self.isDefault = isDefault
    self.isDecodable = isDecodable
  }

  private enum CodingKeys: String, CodingKey {
    case index
    case stableID
    case codec
    case sampleRate
    case channelCount
    case bitDepth
    case bitRate
    case language
    case title
    case isDefault
    case isDecodable
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let index = try container.decode(Int.self, forKey: .index)
    let sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate)
    let channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
    let bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
    let bitRate = try container.decodeIfPresent(Int.self, forKey: .bitRate)
    guard index >= 0,
          sampleRate == nil || (sampleRate!.isFinite && sampleRate! > 0),
          channelCount == nil || channelCount! > 0,
          bitDepth == nil || bitDepth! > 0,
          bitRate == nil || bitRate! > 0
    else {
      throw musicSourceDecodingFailure(decoder, field: "ProbedAudioTrack")
    }

    self.init(
      index: index,
      stableID: try container.decodeIfPresent(String.self, forKey: .stableID),
      codec: try container.decodeIfPresent(String.self, forKey: .codec),
      sampleRate: sampleRate,
      channelCount: channelCount,
      bitDepth: bitDepth,
      bitRate: bitRate,
      language: try container.decodeIfPresent(String.self, forKey: .language),
      title: try container.decodeIfPresent(String.self, forKey: .title),
      isDefault: try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
      isDecodable: try container.decodeIfPresent(Bool.self, forKey: .isDecodable) ?? true
    )
  }

  private static func trimmed(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func repaired(_ value: String?) -> String? {
    trimmed(MetadataTextRepair.repair(value ?? ""))
  }
}

private func musicSourceDecodingFailure(_ decoder: Decoder, field: String) -> DecodingError {
  DecodingError.dataCorrupted(
    .init(
      codingPath: decoder.codingPath,
      debugDescription: "Invalid MediaSourceAPI value for \(field)"
    )
  )
}

/// Probe output before it is normalized into MusicDomain technical values.
public struct MediaProbeResult: Codable, Equatable, Sendable {
  public let audioTracks: [ProbedAudioTrack]
  public let container: String?
  public let duration: Duration?
  public let hasVideoTrack: Bool

  public init(
    audioTracks: [ProbedAudioTrack],
    container: String? = nil,
    duration: Duration? = nil,
    hasVideoTrack: Bool = false
  ) {
    self.audioTracks = audioTracks
    self.container = container
    self.duration = duration
    self.hasVideoTrack = hasVideoTrack
  }

  public var decodableAudioTracks: [ProbedAudioTrack] {
    audioTracks.filter(\.isDecodable)
  }

  public var isPlayable: Bool {
    !decodableAudioTracks.isEmpty
  }

  /// Adapters use this boundary to turn an empty or undecodable probe into a
  /// classified failure before a library transaction is attempted.
  public func validated() throws -> Self {
    guard isPlayable else {
      throw MediaSourceError.probeFailed(.noDecodableAudioTrack)
    }
    return self
  }
}

/// Probes a resolved short-lived resource without exposing a concrete decoder.
public protocol MediaProbing: Sendable {
  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult
}
