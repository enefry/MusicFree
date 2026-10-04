import Foundation

public enum PluginMetadataField: String, Codable, Hashable, Sendable {
    case title, artist, albumArtist, album, genre, year, trackNumber, discNumber, artwork
}
/// Absent keys mean unchanged. There is deliberately no automatic clear operation.
public struct PluginMetadataPatch: Sendable {
    public let text: [PluginMetadataField: String]
    public let numbers: [PluginMetadataField: Int]
    public init(text: [PluginMetadataField: String] = [:], numbers: [PluginMetadataField: Int] = [:]) {
        self.text = text; self.numbers = numbers
    }
}
public struct PluginMetadataCandidate: Sendable {
    public let id: String
    public let track: PluginTrackQuery
    public let patch: PluginMetadataPatch
    public let artworkReference: String?
    public init(id: String, track: PluginTrackQuery, patch: PluginMetadataPatch, artworkReference: String? = nil) {
        self.id = id; self.track = track; self.patch = patch; self.artworkReference = artworkReference
    }
}
public enum PluginMetadataAuthorizationStatus: String, Sendable {
    case notDetermined, denied, restricted, authorized, unavailable
}
public protocol MetadataPlugin: PluginInstance {
    func authorizationStatus() async -> PluginMetadataAuthorizationStatus
    func requestAuthorization() async -> PluginMetadataAuthorizationStatus
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate]
    func artwork(reference: String, context: PluginOperationContext) async throws -> Data?
}
public extension MetadataPlugin {
    func authorizationStatus() async -> PluginMetadataAuthorizationStatus { .authorized }
    func requestAuthorization() async -> PluginMetadataAuthorizationStatus { await authorizationStatus() }
    func artwork(reference: String, context: PluginOperationContext) async throws -> Data? { nil }
}
public typealias MetadataPluginFactory = @Sendable (PluginLoadContext) async throws -> any MetadataPlugin
