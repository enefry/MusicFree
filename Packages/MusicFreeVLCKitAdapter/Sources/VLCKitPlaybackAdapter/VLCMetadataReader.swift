import Foundation
import MediaSourceAPI

#if canImport(VLCKit)
import VLCKit
#if canImport(UIKit)
import UIKit
#endif
#endif

/// Reads format-neutral metadata from the same VLCKit parser boundary used by
/// the probe. The returned value remains ephemeral and is not persisted here.
public final class VLCMetadataReader: @unchecked Sendable, MetadataReading {
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

  public func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata {
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

      let metadata = media.metaData
      let vlcDuration = duration(from: media.length)
      let reliableDuration = await VLCMediaDurationReader.reliableDuration(
        for: resource,
        fallback: vlcDuration
      )
      return RawMediaMetadata(
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album,
        albumArtist: metadata.albumArtist,
        genre: metadata.genre,
        comment: metadata.metaDescription,
        lyrics: firstExtraValue(
          from: metadata,
          keys: ["lyrics", "LYRICS", "unsyncedlyrics", "UNSYNCEDLYRICS"]
        ),
        trackNumber: metadata.trackNumber == 0 ? nil : Int(metadata.trackNumber),
        discNumber: metadata.discNumber == 0 ? nil : Int(metadata.discNumber),
        year: parseYear(metadata.date),
        duration: reliableDuration,
        artworks: artworkValues(from: metadata)
      )
    } catch let error as MediaSourceError {
      throw error
    } catch {
      throw mapMetadataError(error)
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

  private func mapMetadataError(_ error: Error) -> Error {
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

#if canImport(VLCKit)
  private func duration(from time: VLCTime?) -> Duration? {
    guard let milliseconds = time?.value?.int64Value, milliseconds >= 0 else {
      return nil
    }
    return .milliseconds(milliseconds)
  }

  private func parseYear(_ value: String?) -> Int? {
    guard let value else {
      return nil
    }
    let digits = value.filter(\.isNumber)
    guard digits.count >= 4, let year = Int(digits.prefix(4)), (1...9_999).contains(year) else {
      return nil
    }
    return year
  }

  private func firstExtraValue(from metadata: VLCMedia.MetaData, keys: [String]) -> String? {
    for key in keys {
      if let value = metadata.extraValue(forKey: key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
      }
    }
    return nil
  }

  private func artworkValues(from metadata: VLCMedia.MetaData) -> [RawArtwork] {
#if canImport(UIKit)
    guard let image = metadata.artwork,
          let data = image.pngData()
    else {
      return []
    }
    return [
      RawArtwork(
        data: data,
        mimeType: "image/png",
        pixelWidth: Int(image.size.width),
        pixelHeight: Int(image.size.height)
      )
    ]
#else
    _ = metadata
    return []
#endif
  }
#endif
}
