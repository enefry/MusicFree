import MusicDomain

/// Resolves a source instance by its stable source identifier.
public protocol MediaSourceResolving: Sendable {
  /// Unknown or unavailable source IDs must be reported as a classified
  /// MediaSourceError rather than returned as a placeholder source.
  func source(for sourceID: MediaSourceID) async throws -> any MediaSource
}
