import Foundation

/// A short-lived artwork value returned by a media source.
///
/// Consumers own the stream subscription. Dropping the stream or cancelling
/// its task must release the adapter's continuation and any underlying
/// resource.
public enum ArtworkResource: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case localFile(URL)
  case dataStream(AsyncThrowingStream<Data, Error>)

  public static func stream(_ stream: AsyncThrowingStream<Data, Error>) -> Self {
    .dataStream(stream)
  }

  public static func inMemory(_ data: Data) -> Self {
    .dataStream(
      AsyncThrowingStream<Data, Error> { continuation in
        continuation.yield(data)
        continuation.finish()
      }
    )
  }

  public var description: String {
    switch self {
    case .localFile:
      return "ArtworkResource(localFile: redacted)"
    case .dataStream:
      return "ArtworkResource(dataStream: ephemeral)"
    }
  }

  public var debugDescription: String {
    description
  }

  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}
