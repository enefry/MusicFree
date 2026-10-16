import Foundation
import MusicFreePluginAPI
import ChineseMusicCatalogSupport

public struct QQMusicMetadataPlugin: MetadataPlugin {
    private let client: ChineseMusicCatalogClient
    public static var descriptor: PluginDescriptor { ChineseMusicService.qqMusic.descriptor(kind: .metadata) }
    public init(configuration: ChineseMusicConfiguration = .anonymous, session: URLSession? = nil) {
        client = .init(service: .qqMusic, configuration: configuration, session: session)
    }
    public func authorizationStatus() async -> PluginMetadataAuthorizationStatus { .authorized }
    public func requestAuthorization() async -> PluginMetadataAuthorizationStatus { .authorized }
    public func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        try await client.metadata(for: query, fields: fields, context: context)
    }
    public func artwork(reference: String, context: PluginOperationContext) async throws -> Data? {
        try await client.artwork(reference: reference, context: context)
    }
}
