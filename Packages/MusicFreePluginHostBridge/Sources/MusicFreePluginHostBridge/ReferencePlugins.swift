import Foundation
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
import MusicFreePluginRuntime
import MusicFreePluginAudio

#if DEBUG
public struct ReferencePluginRegistrationProvider: BuiltInPluginRegistrationProvider {
    public static let lyricsID = PluginID(rawValue: "reference.lyrics")
    public static let metadataID = PluginID(rawValue: "reference.metadata")
    public static let sourceID = PluginID(rawValue: "reference.source")
    public static let dspID = PluginID(rawValue: "reference.gain")
    public static let pcmID = PluginID(rawValue: "reference.pcmGain")
    public static let fixtureTrack = PluginTrackQuery(title: "MusicFree Reference Tone", artist: "MusicFree", album: "Plugin Reference", durationSeconds: 1)
    private let mediaURL: URL
    public init(mediaURL: URL) { self.mediaURL = mediaURL }
    public var registrations: [BuiltInPluginRegistration] {
        [
            .init(descriptor: .init(id: Self.lyricsID, name: "Reference Lyrics", kinds: [.lyrics]), lyrics: { _ in ReferenceLyrics() }),
            .init(descriptor: .init(id: Self.metadataID, name: "Reference Metadata", kinds: [.metadata]), metadata: { _ in ReferenceMetadata() }),
            .init(descriptor: .init(id: Self.sourceID, name: "Reference Source", kinds: [.onlineSource],
                sourceConfiguration: .init(fields: [.init(id: "collection", title: "Collection", kind: .text)]),
                onlineProviderID: "reference.source", onlineCapabilities: [.browse, .search, .download]),
                onlineSource: { _ in ReferenceSource(mediaURL: mediaURL) }),
            .init(descriptor: .init(id: Self.pcmID, name: "Reference PCM Gain", kinds: [.dsp],
                configuration: .init(fields: [.init(id: "gain", title: "Gain (0–4)", kind: .number, minimumNumber: 0, maximumNumber: 4)]),
                dspPlacements: .init(supported: [.perTrack], defaultPlacement: .perTrack)), dsp: { config in
                    let gain: Float
                    if case .number(let value) = config.values["gain"] { gain = Float(value) } else { gain = 1 }
                    return try ReferenceGainProcessor(gain: gain)
                }),
            .init(descriptor: .init(id: Self.dspID, name: "Reference Gain", kinds: [.dsp],
                configuration: .init(fields: [.init(id: "gain", title: "Gain (0–4)", kind: .number, minimumNumber: 0, maximumNumber: 4)]),
                dspPlacements: .init(supported: [.perTrack, .postMix], defaultPlacement: .postMix)), dsp: { config in
                    let gain: Float
                    if case .number(let value) = config.values["gain"] { gain = Float(value) } else { gain = 1 }
                    return try ReferenceGainProcessor(gain: gain, scope: config.dspPlacement == .postMix ? .postMix : .perTrack)
                })
        ]
    }
}
private struct ReferenceLyrics: LyricsPlugin {
    func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] {
        guard query.matches(ReferencePluginRegistrationProvider.fixtureTrack) else { return [] }
        return [.init(id: "reference-tone", track: ReferencePluginRegistrationProvider.fixtureTrack,
            rawText: "[00:00.00]Reference tone", lines: [.init(startMilliseconds: 0, text: "Reference tone", translation: "参考音调",
                words: [.init(startMilliseconds: 0, durationMilliseconds: 1000, text: "Reference tone")])])]
    }
}
private struct ReferenceMetadata: MetadataPlugin {
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        guard query.matches(ReferencePluginRegistrationProvider.fixtureTrack) else { return [] }
        return [.init(id: "reference-tone", track: ReferencePluginRegistrationProvider.fixtureTrack,
            patch: .init(text: [.album: "Plugin Reference", .artist: "MusicFree", .genre: "Test Tone"], numbers: [.year: 2026, .trackNumber: 1]))]
    }
}
private struct ReferenceSource: BrowsingSourcePlugin, SearchingSourcePlugin, DownloadSourcePlugin {
    let mediaURL: URL
    private var item: PluginSourceItem { .init(objectID: "tone", title: ReferencePluginRegistrationProvider.fixtureTrack.title, artist: "MusicFree", durationSeconds: 1) }
    func browse(parentID: String?, cursor: String?, context: PluginOperationContext) async throws -> PluginSourcePage {
        .init(items: parentID == nil && cursor == nil ? [item] : [])
    }
    func search(_ text: String, cursor: String?, context: PluginOperationContext) async throws -> PluginSourcePage {
        .init(items: cursor == nil && item.title.localizedCaseInsensitiveContains(text) ? [item] : [])
    }
    func downloadAccess(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess {
        guard objectID == "tone" else { throw PluginError.invalidConfiguration }
        return .init(url: mediaURL)
    }
}

public enum PluginReferenceMedia {
    /// Stable host-owned fixture. No request, account or private catalog dependency.
    public static func create(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); word(UInt32(36 + 48000 * 2)); data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(48000)); word(UInt32(96000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(48000 * 2))
        for frame in 0..<48000 { word(Int16(sin(Double(frame) * 2 * .pi * 440 / 48000) * 3276)) }
        try data.write(to: url, options: .atomic)
    }
}
#endif
