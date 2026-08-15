import Foundation

/// One audio track reported by a probe. Unknown technical values remain nil.
public struct ProbedAudioTrack: Codable, Equatable, Sendable {
  public let index: Int
  public let codec: String?
  public let sampleRate: Double?
  public let channelCount: Int?
  public let bitDepth: Int?
  /// Bit rate in bits per second, when the probe reports it.
  public let bitRate: Int?
  public let language: String?
  public let title: String?
  public let isDecodable: Bool

  public init(
    index: Int,
    codec: String? = nil,
    sampleRate: Double? = nil,
    channelCount: Int? = nil,
    bitDepth: Int? = nil,
    bitRate: Int? = nil,
    language: String? = nil,
    title: String? = nil,
    isDecodable: Bool = true
  ) {
    self.index = index
    self.codec = codec
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.bitDepth = bitDepth
    self.bitRate = bitRate
    self.language = language
    self.title = title
    self.isDecodable = isDecodable
  }
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
