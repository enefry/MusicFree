import Foundation

public enum PluginOnlineCapability: String, Codable, Hashable, Sendable { case browse, search, download, playbackAccess, refresh }
public struct PluginSourceItem: Sendable {
    public let objectID: String
    public let title: String
    public let artist: String?
    public let isContainer: Bool
    public let durationSeconds: Double?
    public init(objectID: String, title: String, artist: String? = nil, isContainer: Bool = false, durationSeconds: Double? = nil) {
        self.objectID = objectID; self.title = title; self.artist = artist; self.isContainer = isContainer
        self.durationSeconds = durationSeconds
    }
}
public struct PluginSourcePage: Sendable {
    public let items: [PluginSourceItem]
    public let nextCursor: String?
    public init(items: [PluginSourceItem], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}
/// Transient access; never Codable or stored in preferences/history.
public struct PluginSourceAccess: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let expiresAt: Date?
    public let suggestedFileName: String?
    public init(url: URL, headers: [String: String] = [:], expiresAt: Date? = nil, suggestedFileName: String? = nil) {
        self.url = url; self.headers = headers; self.expiresAt = expiresAt
        self.suggestedFileName = suggestedFileName
    }
}
public protocol OnlineSourcePlugin: PluginInstance {}
public protocol BrowsingSourcePlugin: OnlineSourcePlugin {
    func browse(parentID: String?, cursor: String?, context: PluginOperationContext) async throws -> PluginSourcePage
}
public protocol SearchingSourcePlugin: OnlineSourcePlugin {
    func search(_ text: String, cursor: String?, context: PluginOperationContext) async throws -> PluginSourcePage
}
public protocol PlaybackSourcePlugin: OnlineSourcePlugin {
    func playbackAccess(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess
}
public protocol DownloadSourcePlugin: OnlineSourcePlugin {
    func downloadAccess(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess
}
public protocol RefreshingSourcePlugin: OnlineSourcePlugin {
    func refresh(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess
}
public typealias OnlineSourcePluginFactory = @Sendable (PluginLoadContext) async throws -> any OnlineSourcePlugin
