import Foundation

/// A sensitive request used only for the lifetime of one remote playback
/// operation. It deliberately does not conform to Codable.
public struct RemotePlaybackRequest: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  /// Re-resolves the same item into a fresh request, e.g. after the signed URL
  /// expires mid-playback.
  public typealias Refresher = @Sendable () async throws -> RemotePlaybackRequest

  public let url: URL
  private let sensitiveHeaders: [String: String]
  public let expiresAt: Date?
  private let refresher: Refresher?

  public init(
    url: URL,
    headers: [String: String] = [:],
    expiresAt: Date? = nil,
    refresher: Refresher? = nil
  ) {
    self.url = url
    self.sensitiveHeaders = headers
    self.expiresAt = expiresAt
    self.refresher = refresher
  }

  public var canRefresh: Bool {
    refresher != nil
  }

  /// Returns a copy that can re-resolve itself through `refresher`.
  public func withRefresher(_ refresher: @escaping Refresher) -> Self {
    Self(url: url, headers: sensitiveHeaders, expiresAt: expiresAt, refresher: refresher)
  }

  /// Resolves a fresh request. The result keeps this request's refresher when
  /// the resolver did not attach one, so later expirations can refresh again.
  public func refreshed() async throws -> Self {
    guard let refresher else {
      throw CancellationError()
    }
    let next = try await refresher()
    return next.canRefresh ? next : next.withRefresher(refresher)
  }

  /// Returns a copy so callers cannot mutate the request after construction.
  public var headers: [String: String] {
    sensitiveHeaders
  }

  public var expirationDate: Date? {
    expiresAt
  }

  public func isExpired(at date: Date) -> Bool {
    guard let expiresAt else {
      return false
    }
    return date >= expiresAt
  }

  public var description: String {
    "RemotePlaybackRequest(redacted)"
  }

  public var debugDescription: String {
    description
  }

  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}

/// A resource resolved for one playback or probe operation.
///
/// The resource is intentionally not Codable and must never be placed in a
/// queue or persistence model. The remote request and its headers are also
/// redacted from textual and reflective representations.
public enum PlaybackResource: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case localFile(URL)
  case remote(RemotePlaybackRequest)

  public static func local(_ url: URL) -> Self {
    .localFile(url)
  }

  public var isEphemeral: Bool {
    true
  }

  public var description: String {
    switch self {
    case .localFile:
      return "PlaybackResource(localFile: redacted)"
    case .remote:
      return "PlaybackResource(remote: redacted)"
    }
  }

  public var debugDescription: String {
    description
  }

  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}
