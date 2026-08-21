import Foundation
import MediaSourceAPI
import MusicDomain

#if canImport(VLCKit)
import VLCKit
#endif

internal struct VLCMediaCookie: Equatable, Sendable {
  let setCookieValue: String
  let host: String
  let path: String
}

internal struct VLCMediaOptionSet: Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let arguments: [String]
  let cookies: [VLCMediaCookie]

  var description: String {
    "VLCMediaOptionSet(redacted)"
  }

  var debugDescription: String {
    description
  }

  var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}

internal enum VLCMediaFactory {
  static func makeOptions(
    for resource: PlaybackResource,
    configuration: VLCKitAdapterConfiguration,
    now: Date = Date()
  ) throws -> VLCMediaOptionSet {
    var arguments: [String] = []
    var cookieValues: [VLCMediaCookie] = []

    switch resource {
    case .localFile(let url):
      guard url.isFileURL, !url.path.isEmpty else {
        throw VLCKitAdapterError.invalidResource
      }
    case .remote(let request):
      guard let scheme = request.url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            request.url.host?.isEmpty == false
      else {
        throw VLCKitAdapterError.invalidResource
      }
      guard !request.isExpired(at: now) else {
        throw VLCKitAdapterError.expiredResource
      }

      let host = request.url.host?.lowercased() ?? ""
      for headerName in request.headers.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
        guard let value = request.headers[headerName] else {
          continue
        }
        let normalizedName = try normalizedHeaderName(headerName)
        switch normalizedName {
        case "user-agent":
          arguments.append(try option(name: "http-user-agent", value: value))
        case "referer":
          arguments.append(try option(name: "http-referrer", value: value))
        case "cookie":
          cookieValues.append(contentsOf: try cookies(from: value, host: host))
        default:
          throw VLCKitAdapterError.unsupportedHeader(name: normalizedName)
        }
      }
    }

    for mediaOption in configuration.mediaOptions {
      switch mediaOption {
      case .networkCaching(let milliseconds):
        guard (0...600_000).contains(milliseconds) else {
          throw VLCKitAdapterError.invalidOption(field: "networkCaching")
        }
        arguments.append(":network-caching=\(milliseconds)")
      case .reconnect:
        arguments.append(":http-reconnect")
      case .continuousHTTP:
        arguments.append(":http-continuous")
      }
    }

    return VLCMediaOptionSet(arguments: arguments, cookies: cookieValues)
  }

#if canImport(VLCKit)
  static func makeMedia(
    for resource: PlaybackResource,
    configuration: VLCKitAdapterConfiguration,
    selection: PlaybackSelection = .wholeFile,
    initialPosition: Duration? = nil
  ) throws -> VLCMedia {
    let optionSet = try makeOptions(for: resource, configuration: configuration)
    let media: VLCMedia?
    switch resource {
    case .localFile(let url):
      media = VLCMedia(url: url)
    case .remote(let request):
      media = VLCMedia(url: request.url)
    }
    guard let media else {
      throw VLCKitAdapterError.mediaCreationFailed
    }

    for argument in optionSet.arguments {
      media.addOption(argument)
    }
    if let range = selection.range {
      media.addOption(":start-time=\(secondsString(initialPosition ?? range.start))")
      media.addOption(":stop-time=\(secondsString(range.end))")
    }
    for cookie in optionSet.cookies {
      guard media.storeCookie(cookie.setCookieValue, forHost: cookie.host, path: cookie.path) == 0 else {
        throw VLCKitAdapterError.engineFailure(code: "cookie_injection_failed")
      }
    }
    return media
  }

  private static func secondsString(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds)
      + Double(components.attoseconds) / 1_000_000_000_000_000_000
    return String(format: "%.6f", seconds)
  }
#endif

  private static func normalizedHeaderName(_ name: String) throws -> String {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty,
          normalized.allSatisfy({ isHeaderTokenCharacter($0) })
    else {
      throw VLCKitAdapterError.invalidHeader(name: "invalid")
    }
    return normalized
  }

  private static func option(name: String, value: String) throws -> String {
    guard isSafeHeaderValue(value, maximumLength: 2_048) else {
      throw VLCKitAdapterError.invalidHeader(name: name)
    }
    return ":\(name)=\(value)"
  }

  private static func cookies(from header: String, host: String) throws -> [VLCMediaCookie] {
    guard !host.isEmpty else {
      throw VLCKitAdapterError.invalidResource
    }
    var result: [VLCMediaCookie] = []
    for component in header.split(separator: ";", omittingEmptySubsequences: true) {
      let pair = component.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let separator = pair.firstIndex(of: "=") else {
        throw VLCKitAdapterError.invalidHeader(name: "cookie")
      }
      let name = String(pair[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty,
            name.allSatisfy({ isHeaderTokenCharacter($0) }),
            isSafeHeaderValue(value, maximumLength: 4_096)
      else {
        throw VLCKitAdapterError.invalidHeader(name: "cookie")
      }
      result.append(
        VLCMediaCookie(
          setCookieValue: "\(name)=\(value)",
          host: host,
          path: "/"
        )
      )
    }
    return result
  }

  private static func isSafeHeaderValue(_ value: String, maximumLength: Int) -> Bool {
    value.count <= maximumLength
      && !value.contains("\r")
      && !value.contains("\n")
      && !value.contains("\0")
  }

  private static func isHeaderTokenCharacter(_ character: Character) -> Bool {
    character.isASCII
      && (character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character))
  }
}
