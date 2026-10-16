import Foundation
import MusicFreePluginAPI
import MusicFreePluginRuntime
import LRCLIBLyricsPlugin
import MetadataServerLyricsPlugin
import MusicKitMetadataPlugin
import MusicBrainzMetadataPlugin
import MetadataServerMetadataPlugin
import DiscogsMetadataPlugin
import ChineseMusicCatalogSupport
import NetEaseLyricsPlugin
import NetEaseMetadataPlugin
import QQMusicLyricsPlugin
import QQMusicMetadataPlugin

/// Register factories only. Clients and sessions are created after runtime permission checks.
public struct BuiltinDataPluginRegistrationProvider: BuiltInPluginRegistrationProvider {
    public let registrations: [BuiltInPluginRegistration]
    public let unavailable: [PluginDescriptor]

    public init(bundle: Bundle = .main, includeLyrics: Bool = true, includeMetadataServer: Bool = true) {
        var entries: [BuiltInPluginRegistration] = [
            .init(descriptor: MusicKitMetadataPlugin.descriptor, metadata: { _ in MusicKitMetadataPlugin() },
                metadataAuthorization: .init(status: MusicKitMetadataPlugin.systemAuthorizationStatus, request: MusicKitMetadataPlugin.requestSystemAuthorization))
        ]
        var unavailable: [PluginDescriptor] = []
        entries += [
            .init(descriptor: NetEaseMetadataPlugin.descriptor,
                metadata: { context in NetEaseMetadataPlugin(configuration: try await ChineseMusicConfiguration.from(context)) },
                metadataAuthorization: .init(status: { .authorized })),
            .init(descriptor: QQMusicMetadataPlugin.descriptor,
                metadata: { context in QQMusicMetadataPlugin(configuration: try await ChineseMusicConfiguration.from(context)) },
                metadataAuthorization: .init(status: { .authorized }))
        ]
        if includeLyrics {
            entries += [
                .init(descriptor: NetEaseLyricsPlugin.descriptor,
                    lyrics: { context in NetEaseLyricsPlugin(configuration: try await ChineseMusicConfiguration.from(context)) }),
                .init(descriptor: QQMusicLyricsPlugin.descriptor,
                    lyrics: { context in QQMusicLyricsPlugin(configuration: try await ChineseMusicConfiguration.from(context)) })
            ]
        } else {
            unavailable += [NetEaseLyricsPlugin.descriptor, QQMusicLyricsPlugin.descriptor]
        }
        if let config = MusicBrainzAPIConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: MusicBrainzMetadataPlugin.descriptor,
                metadata: { _ in MusicBrainzMetadataPlugin(configuration: config) }, metadataAuthorization: .init(status: { .authorized })))
        } else { unavailable.append(MusicBrainzMetadataPlugin.descriptor) }
        if let config = DiscogsAPIConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: DiscogsMetadataPlugin.descriptor,
                metadata: { _ in DiscogsMetadataPlugin(configuration: config) }, metadataAuthorization: .init(status: { .authorized })))
        } else { unavailable.append(DiscogsMetadataPlugin.descriptor) }
        if includeMetadataServer, let config = MetadataServerConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: MetadataServerMetadataPlugin.descriptor,
                metadata: { _ in MetadataServerMetadataPlugin(configuration: config) }, metadataAuthorization: .init(status: { .authorized })))
        } else { unavailable.append(MetadataServerMetadataPlugin.descriptor) }
        if includeLyrics, let config = LRCLIBAPIConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: LRCLIBLyricsPlugin.descriptor,
                lyrics: { _ in LRCLIBLyricsPlugin(configuration: config) }))
        } else { unavailable.append(LRCLIBLyricsPlugin.descriptor) }
        if includeLyrics && includeMetadataServer, let config = MetadataServerLyricsConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: MetadataServerLyricsPlugin.descriptor,
                lyrics: { _ in MetadataServerLyricsPlugin(configuration: config) }))
        } else { unavailable.append(MetadataServerLyricsPlugin.descriptor) }
        self.registrations = entries
        self.unavailable = unavailable
    }
}
