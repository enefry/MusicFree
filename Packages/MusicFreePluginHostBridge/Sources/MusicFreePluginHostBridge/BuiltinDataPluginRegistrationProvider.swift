import Foundation
import MusicFreePluginAPI
import MusicFreePluginRuntime
import LRCLIBLyricsPlugin
import MetadataServerLyricsPlugin
import MusicKitMetadataPlugin
import MusicBrainzMetadataPlugin
import MetadataServerMetadataPlugin
import DiscogsMetadataPlugin

/// Register factories only. Clients and sessions are created after runtime permission checks.
public struct BuiltinDataPluginRegistrationProvider: BuiltInPluginRegistrationProvider {
    public let registrations: [BuiltInPluginRegistration]
    public let unavailable: [PluginDescriptor]

    public init(bundle: Bundle = .main, includeLyrics: Bool = true, includeMetadataServer: Bool = true) {
        var entries: [BuiltInPluginRegistration] = [
            .init(descriptor: MusicKitMetadataPlugin.descriptor, metadata: { _ in MusicKitMetadataPlugin() })
        ]
        var unavailable: [PluginDescriptor] = []
        if let config = MusicBrainzAPIConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: MusicBrainzMetadataPlugin.descriptor,
                metadata: { _ in MusicBrainzMetadataPlugin(configuration: config) }))
        } else { unavailable.append(MusicBrainzMetadataPlugin.descriptor) }
        if let config = DiscogsAPIConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: DiscogsMetadataPlugin.descriptor,
                metadata: { _ in DiscogsMetadataPlugin(configuration: config) }))
        } else { unavailable.append(DiscogsMetadataPlugin.descriptor) }
        if includeMetadataServer, let config = MetadataServerConfiguration.from(bundle: bundle) {
            entries.append(.init(descriptor: MetadataServerMetadataPlugin.descriptor,
                metadata: { _ in MetadataServerMetadataPlugin(configuration: config) }))
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
