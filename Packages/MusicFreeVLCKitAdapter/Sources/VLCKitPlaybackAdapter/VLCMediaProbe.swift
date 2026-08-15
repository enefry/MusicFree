import Foundation
import MediaSourceAPI

#if canImport(VLCKit)
import VLCKit
#endif

/// A VLCKit-backed media probe. The probe reports only values exposed by the
/// parsed media object; it never infers format information from a filename.
public final class VLCMediaProbe: @unchecked Sendable, MediaProbing {
  private let configuration: VLCKitAdapterConfiguration

#if canImport(VLCKit)
  private let library: VLCLibrary
#endif

  public init(configuration: VLCKitAdapterConfiguration) throws {
    self.configuration = configuration
#if canImport(VLCKit)
    self.library = try VLCLibraryFactory.shared(configuration: configuration)
#else
    throw VLCKitAdapterError.binaryUnavailable
#endif
  }

  public func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
#if canImport(VLCKit)
    do {
      try Task.checkCancellation()
      let media = try VLCMediaFactory.makeMedia(
        for: resource,
        configuration: configuration
      )
      let parser = VLCMediaParser(
        library: library,
        timeout: Int32(timeoutMilliseconds)
      )
      let waiter = VLCMediaParseWaiter(
        parser: parser,
        media: media,
        timeoutMilliseconds: timeoutMilliseconds
      )
      _ = try await waiter.wait()
      try Task.checkCancellation()

      let tracks = media.audioTracks.enumerated().map { index, track in
        ProbedAudioTrack(
          index: index,
          codec: normalized(track.codecName()),
          sampleRate: track.audio.map { Double($0.rate) },
          channelCount: track.audio.map { Int($0.channelsNumber) },
          bitDepth: nil,
          bitRate: track.bitrate == 0 ? nil : Int(track.bitrate),
          language: normalized(track.language),
          title: normalized(track.trackDescription),
          isDecodable: true
        )
      }
      return try MediaProbeResult(
        audioTracks: tracks,
        container: nil,
        duration: duration(from: media.length),
        hasVideoTrack: media.tracksInformation.contains { $0.type.rawValue == 1 }
      ).validated()
    } catch let error as MediaSourceError {
      throw error
    } catch {
      throw mapProbeError(error)
    }
#else
    _ = resource
    throw VLCKitAdapterError.binaryUnavailable
#endif
  }

  private var timeoutMilliseconds: UInt64 {
    let components = configuration.parserTimeout.components
    let seconds = max(components.seconds, 0)
    let fractionalMilliseconds = max(components.attoseconds, 0) / 1_000_000_000_000_000
    return UInt64(seconds) * 1_000 + UInt64(fractionalMilliseconds)
  }

  private func mapProbeError(_ error: Error) -> Error {
    if error is CancellationError {
      return MediaSourceError.cancelled
    }
    if let adapterError = error as? VLCKitAdapterError {
      switch adapterError {
      case .cancelled:
        return MediaSourceError.cancelled
      case .invalidResource, .expiredResource:
        return MediaSourceError.invalidResource
      case .parserTimedOut:
        return MediaSourceError.probeFailed(.timedOut)
      case .binaryUnavailable, .parserFailed, .mediaCreationFailed,
        .engineFailure, .invalidConfiguration, .invalidOption,
        .unsupportedHeader, .invalidHeader:
        return MediaSourceError.probeFailed(.readFailed)
      }
    }
    return MediaSourceError.probeFailed(.readFailed)
  }

  private func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

#if canImport(VLCKit)
  private func duration(from time: VLCTime?) -> Duration? {
    guard let milliseconds = time?.value?.int64Value, milliseconds >= 0 else {
      return nil
    }
    return .milliseconds(milliseconds)
  }
#endif
}
