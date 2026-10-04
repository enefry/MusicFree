import Foundation

public extension MetadataServerLyricsConfiguration {
    /// Derive the lyrics service from the same optional host configuration as the legacy provider.
    static func from(bundle: Bundle = .main) -> Self? {
        guard let value = bundle.object(forInfoDictionaryKey: "MetadataServerBaseURL") as? String,
              var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var path = components.path.split(separator: "/").map(String.init)
        guard path.last == "metadata" else { return nil }
        path[path.count - 1] = "lyrics"
        components.path = "/" + path.joined(separator: "/")
        guard let url = components.url else { return nil }
        let timeoutValue = bundle.object(forInfoDictionaryKey: "MetadataServerRequestTimeout")
        let timeout = (timeoutValue as? NSNumber)?.doubleValue ?? (timeoutValue as? String).flatMap(Double.init) ?? 45
        return Self(baseURL: url, requestTimeout: timeout)
    }
}
