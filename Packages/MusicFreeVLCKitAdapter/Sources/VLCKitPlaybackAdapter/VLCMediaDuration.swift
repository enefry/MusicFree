import Foundation
import MediaSourceAPI

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Uses the system media container duration when available. Some VLCKit
/// parser results can expose a short, partial duration for otherwise valid
/// local files, which is unsafe for metadata matching.
internal enum VLCMediaDurationReader {
  static func reliableDuration(
    for resource: PlaybackResource,
    fallback: Duration?
  ) async -> Duration? {
#if canImport(AVFoundation)
    if case .localFile(let url) = resource {
      let asset = AVURLAsset(url: url)
      if let time = try? await asset.load(.duration) {
        let seconds = time.seconds
        if seconds.isFinite, seconds >= 0 {
          return .seconds(seconds)
        }
      }
    }
#else
    _ = resource
#endif
    return fallback
  }
}
