import Foundation
import MusicFreePluginAPI
import ChineseMusicCatalogSupport

public struct QQMusicLyricsPlugin: LyricsPlugin {
    private let client: ChineseMusicCatalogClient
    public static var descriptor: PluginDescriptor { ChineseMusicService.qqMusic.descriptor(kind: .lyrics) }
    public init(configuration: ChineseMusicConfiguration = .anonymous, session: URLSession? = nil) {
        client = .init(service: .qqMusic, configuration: configuration, session: session)
    }
    public func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] {
        try await client.lyrics(for: query, context: context)
    }
}
