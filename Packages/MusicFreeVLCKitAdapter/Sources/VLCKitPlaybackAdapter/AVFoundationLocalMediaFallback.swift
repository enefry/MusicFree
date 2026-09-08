import Foundation
import MediaSourceAPI

#if canImport(AVFoundation)
import AVFoundation
import CoreMedia

/// Recovers local files that the asynchronous VLC preparser rejects even
/// though the system media stack can open and decode their audio tracks.
/// Remote resources intentionally remain on the VLCKit path because their
/// ephemeral headers cannot be reproduced by AVURLAsset.
internal enum AVFoundationLocalMediaFallback {
  static func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult? {
    guard case .localFile(let url) = resource else { return nil }
    try Task.checkCancellation()

    let asset = AVURLAsset(url: url)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard !audioTracks.isEmpty else { return nil }
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let duration = await duration(of: asset)

    var tracks: [ProbedAudioTrack] = []
    tracks.reserveCapacity(audioTracks.count)
    for (index, track) in audioTracks.enumerated() {
      try Task.checkCancellation()
      let descriptions = (try? await track.load(.formatDescriptions)) ?? []
      let description = descriptions.first
      let streamDescription = description.flatMap {
        CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
      }
      let estimatedDataRate = try? await track.load(.estimatedDataRate)
      let bitRate = estimatedDataRate.flatMap { value in
        value > 0 ? Int(value.rounded()) : nil
      }
      let bitDepth = streamDescription.flatMap { description in
        description.mBitsPerChannel > 0
          ? Int(description.mBitsPerChannel)
          : nil
      }

      tracks.append(ProbedAudioTrack(
        index: index,
        stableID: "avfoundation-track:\(index)",
        codec: description.flatMap {
          fourCharacterCode(CMFormatDescriptionGetMediaSubType($0))
        },
        sampleRate: streamDescription.flatMap {
          $0.mSampleRate > 0 ? $0.mSampleRate : nil
        },
        channelCount: streamDescription.flatMap {
          $0.mChannelsPerFrame > 0 ? Int($0.mChannelsPerFrame) : nil
        },
        bitDepth: bitDepth,
        bitRate: bitRate,
        language: nil,
        title: nil,
        isDefault: false,
        isDecodable: true
      ))
    }

    return MediaProbeResult(
      audioTracks: tracks,
      container: nil,
      duration: duration,
      hasVideoTrack: !videoTracks.isEmpty
    )
  }

  static func metadata(_ resource: PlaybackResource) async throws -> RawMediaMetadata? {
    guard case .localFile(let url) = resource else { return nil }
    try Task.checkCancellation()

    let asset = AVURLAsset(url: url)
    let metadata = (try? await asset.load(.commonMetadata)) ?? []
    let duration = await duration(of: asset)
    let creationDate = await stringValue(
      .commonIdentifierCreationDate,
      in: metadata
    )

    return RawMediaMetadata(
      title: await stringValue(.commonIdentifierTitle, in: metadata),
      artist: await stringValue(.commonIdentifierArtist, in: metadata),
      album: await stringValue(.commonIdentifierAlbumName, in: metadata),
      comment: await stringValue(.commonIdentifierDescription, in: metadata),
      year: parseYear(creationDate),
      duration: duration,
      artworks: await artworkValues(in: metadata)
    )
  }

  private static func duration(of asset: AVURLAsset) async -> Duration? {
    guard let time = try? await asset.load(.duration) else { return nil }
    let seconds = time.seconds
    guard seconds.isFinite, seconds >= 0 else { return nil }
    return .seconds(seconds)
  }

  private static func stringValue(
    _ identifier: AVMetadataIdentifier,
    in metadata: [AVMetadataItem]
  ) async -> String? {
    let matches = AVMetadataItem.metadataItems(
      from: metadata,
      filteredByIdentifier: identifier
    )
    for item in matches {
      if let value = try? await item.load(.stringValue) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  private static func artworkValues(
    in metadata: [AVMetadataItem]
  ) async -> [RawArtwork] {
    let matches = AVMetadataItem.metadataItems(
      from: metadata,
      filteredByIdentifier: .commonIdentifierArtwork
    )
    for item in matches {
      if let data = try? await item.load(.dataValue), !data.isEmpty {
        return [RawArtwork(data: data)]
      }
    }
    return []
  }

  private static func parseYear(_ value: String?) -> Int? {
    guard let value else { return nil }
    let digits = value.filter(\.isNumber)
    guard digits.count >= 4,
          let year = Int(digits.prefix(4)),
          (1...9_999).contains(year)
    else {
      return nil
    }
    return year
  }

  private static func fourCharacterCode(_ value: FourCharCode) -> String? {
    let bytes: [UInt8] = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    guard let text = String(bytes: bytes, encoding: .ascii) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
#endif
