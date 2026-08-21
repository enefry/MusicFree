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

  private let importCoordinator: ImportCoordinator
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
    let importCoordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    self.importCoordinator = importCoordinator
    self.store = importCoordinator.store
    self.probeReader = probe
    self.metadataReader = metadataReader
  }

  public func resolve(_ assetID: MediaItemID) async throws -> PlaybackResource {
    guard assetID.sourceID == Self.sourceID else {
      throw MediaSourceError.sourceNotFound(assetID.sourceID)
    }
    do {
      return .localFile(try await store.mediaURL(forExternalID: assetID.externalID))
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

  /// Stores user-selected artwork in the same managed artwork root used by
  /// imported embedded covers. The library transaction still owns the public
  /// reference; this method only writes the bytes.
  public func writeArtwork(_ data: Data, artworkID: ArtworkID) async throws -> Bool {
    let acquiredImport = await importCoordinator.maintenanceGate.enterImport()
    guard acquiredImport else { throw MediaSourceError.cancelled }
    do {
      let wasCreated = try await store.writeArtwork(data, artworkID: artworkID).wasCreated
      await importCoordinator.maintenanceGate.leaveImport()
      return wasCreated
    } catch {
      await importCoordinator.maintenanceGate.leaveImport()
      throw Self.mapSourceError(error)
    }
  }

  /// Starts a content-addressed artwork write and keeps its file reserved
  /// until the owning library transaction reports its result.
  public func beginArtworkWrite(
    _ data: Data,
    artworkID: ArtworkID
  ) async throws -> ArtworkWriteReceipt {
    let acquiredImport = await importCoordinator.maintenanceGate.enterImport()
    guard acquiredImport else { throw MediaSourceError.cancelled }
    do {
      let location = try await store.beginImportedArtworkWrite(data, artworkID: artworkID)
      return ArtworkWriteReceipt(wasCreated: location.wasCreated) {
        [store, importCoordinator] committed in
        await store.finishImportedArtworkWrite(artworkID, committed: committed)
        await importCoordinator.maintenanceGate.leaveImport()
      }
    } catch {
      await importCoordinator.maintenanceGate.leaveImport()
      throw Self.mapSourceError(error)
    }
  }

  /// Removes an artwork file only when the caller has established that it
  /// created the file and no committed library transaction owns it yet.
  public func removeArtwork(_ artworkID: ArtworkID) async {
    await store.removeArtwork(artworkID)
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
