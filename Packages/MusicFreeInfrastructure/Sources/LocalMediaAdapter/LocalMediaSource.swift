import Foundation
import MediaSourceAPI
import MusicDomain

/// The built-in source for files copied into the application's managed store.
@available(macOS 13.0, iOS 16.0, *)
public final class LocalMediaSource: MediaSource, @unchecked Sendable {
  public static let sourceID = MediaSourceID.local
  public static let defaultDescriptor = MediaSourceDescriptor(
    sourceID: .local,
    kind: .local,
    displayName: "Local Media",
    isReadOnly: false
  )
  public static let defaultCapabilities: MediaSourceCapabilities = [
    .managedRemoval,
    .artwork,
    .metadataReading,
  ]

  public let descriptor: MediaSourceDescriptor
  public let capabilities: MediaSourceCapabilities

  private let store: ManagedMediaStore
  private let probeReader: any MediaProbing
  private let metadataReader: any MetadataReading

  public init(
    configuration: LocalMediaConfiguration,
    probe: any MediaProbing,
    metadataReader: any MetadataReading,
    descriptor: MediaSourceDescriptor = LocalMediaSource.defaultDescriptor
  ) throws {
    guard descriptor.sourceID == .local, descriptor.kind == .local else {
      throw LocalMediaError.invalidConfiguration(.rootMustBeFileURL)
    }
    self.descriptor = descriptor
    self.capabilities = Self.defaultCapabilities
    self.store = try ManagedMediaStore(configuration: configuration)
    self.probeReader = probe
    self.metadataReader = metadataReader
  }

  public func resolve(_ itemID: MediaItemID) async throws -> PlaybackResource {
    guard itemID.sourceID == Self.sourceID else {
      throw MediaSourceError.sourceNotFound(itemID.sourceID)
    }
    do {
      return .localFile(try await store.mediaURL(forExternalID: itemID.externalID))
    } catch {
      throw Self.mapSourceError(error)
    }
  }

  public func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? {
    do {
      guard let url = try await store.artworkURL(for: artworkID) else { return nil }
      return .localFile(url)
    } catch {
      throw Self.mapSourceError(error)
    }
  }

  /// Probes a managed item through the injected decoder boundary.
  public func probe(_ itemID: MediaItemID) async throws -> MediaProbeResult {
    do {
      let resource = try await resolve(itemID)
      return try await probeReader.probe(resource).validated()
    } catch {
      throw Self.mapSourceError(error)
    }
  }

  /// Reads normalized raw metadata from a managed item through the injected reader boundary.
  public func metadata(for itemID: MediaItemID) async throws -> RawMediaMetadata {
    do {
      let resource = try await resolve(itemID)
      return try await metadataReader.readMetadata(from: resource)
    } catch {
      throw Self.mapSourceError(error)
    }
  }

  private static func mapSourceError(_ error: Error) -> Error {
    if let error = error as? MediaSourceError {
      return error
    }
    if let error = error as? LocalMediaError {
      switch error {
      case .itemNotFound, .invalidItemID, .rootContainmentViolation, .invalidRelativePath:
        return MediaSourceError.invalidResource
      case .probeFailed:
        return MediaSourceError.probeFailed(.readFailed)
      case .inaccessibleInput, .securityScopeUnavailable, .enumerationFailed,
        .bookmarkResolutionFailed:
        return MediaSourceError.sourceUnavailable(.local)
      case .cancelled:
        return MediaSourceError.cancelled
      default:
        return MediaSourceError.sourceUnavailable(.local)
      }
    }
    if let error = error as? MediaProbeError {
      return MediaSourceError.probeFailed(error)
    }
    if error is CancellationError {
      return MediaSourceError.cancelled
    }
    return MediaSourceError.sourceUnavailable(.local)
  }
}
