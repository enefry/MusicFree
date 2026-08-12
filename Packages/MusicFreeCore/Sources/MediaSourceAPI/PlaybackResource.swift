import Foundation

/// A sensitive request used only for the lifetime of one remote playback
/// operation. It deliberately does not conform to Codable.
public struct RemotePlaybackRequest: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let url: URL
  private let sensitiveHeaders: [String: String]
  public let expiresAt: Date?

  public init(
    url: URL,
    headers: [String: String] = [:],
    expiresAt: Date? = nil
  ) {
    self.url = url
    self.sensitiveHeaders = headers
    self.expiresAt = expiresAt
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
