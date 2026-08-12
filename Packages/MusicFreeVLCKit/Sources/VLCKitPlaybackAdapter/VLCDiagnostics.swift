import Foundation
import MediaSourceAPI

internal enum VLCDiagnostics {
  static func redacted(_ resource: PlaybackResource) -> String {
    switch resource {
    case .localFile:
      return "local_file"
    case .remote:
      return "remote_resource"
    }
  }

  static func redacted(_ options: VLCMediaOptionSet) -> String {
    "media_options(count: \(options.arguments.count), cookies: \(options.cookies.count))"
  }

  static func safeCode(_ value: String, fallback: String = "unknown") -> String {
    let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    return normalized.isEmpty ? fallback : String(normalized.prefix(64))
  }
}
