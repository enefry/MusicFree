import AVFAudio
import Foundation
import AVFoundation
import Testing
import MusicDomain
import LibraryAPI
import MediaSourceAPI
import SettingsAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
@testable import MusicFreePluginHostBridge
import MusicFreePluginAudio

private struct EmptyFactory: OnlineSourceFactory {
    func makeSource(for configuration: OnlineSourceConfiguration) throws -> (any OnlineSource)? { nil }
}
#if DEBUG
private func references() -> PluginRuntime {
    .init(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/fixture.wav")).registrations))
}
#endif
private func enabled(_ id: PluginID) -> PluginPreference { .init(pluginID: id, isEnabled: true, isLoadAllowed: true) }

#if DEBUG
@Test @MainActor func pcmControllerClosesOldGatesAndRetriesAfterOutputStops() async throws {
    let runtime = references()
    let id = ReferencePluginRegistrationProvider.pcmID
    var running = false
    var installed: [PluginDSPFactorySpec] = []
    let controller = PluginPCMHostController(runtime: runtime, excluding: []) { specifications in
        if running { throw PluginError.unavailable }
        installed = specifications
    }
    defer { controller.unload() }
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: false)
    await controller.apply()
    let old = try #require(installed.first)
    #expect(old.gate.isAllowed)
    running = true
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        configuration: ["gain": .number(0.25)])], applicationPrivacyAccepted: false)
    await controller.apply()
    #expect(!old.gate.isAllowed)
    #expect(installed.first?.configuration.values["gain"] == nil)
    let (stream, continuation) = AsyncStream<Bool>.makeStream()
    controller.observe(stream)
    running = false
    continuation.yield(false)
    for _ in 0..<100 where installed.first?.configuration.values["gain"] != .number(0.25) { await Task.yield() }
    #expect(installed.first?.configuration.values["gain"] == .number(0.25))
    let current = try #require(installed.first)
    #expect(current.gate.isAllowed)
    await runtime.apply(preferences: [], applicationPrivacyAccepted: false)
    await controller.apply()
    #expect(!current.gate.isAllowed)
    #expect(installed.isEmpty)
    continuation.finish()
}
#endif

@Test func sourceSchemaIsIndependentFromPluginGlobalPreferences() throws {
    let descriptor = PluginDescriptor(id: .init(rawValue: "schema.source"), name: "Source", kinds: [.onlineSource],
        sourceConfiguration: .init(fields: [.init(id: "account", title: "Account", kind: .text, required: true)]), onlineProviderID: "schema.source")
    try descriptor.configuration.validate([:], credentialRecordID: nil)
    #expect(throws: PluginError.invalidConfiguration) { try descriptor.sourceConfiguration.validate([:], credentialRecordID: nil) }
    try descriptor.sourceConfiguration.validate(["account": .text("account-a")], credentialRecordID: nil)
}

#if DEBUG
@Test func referenceLyricsRunsThroughHostProviderAndPreservesTranslation() async throws {
    let runtime = references(); let id = ReferencePluginRegistrationProvider.lyricsID
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: false)
    let adapter = PluginLyricsProviderAdapter(pluginID: id, runtime: runtime)
    let lyrics = try #require(try await adapter.fetchLyrics(for: .init(itemID: .init(sourceID: .init(rawValue: "test"), externalID: "test-track"),
        title: "MusicFree Reference Tone", artistName: "MusicFree", durationSeconds: 1)))
    #expect(lyrics.timedLines.first?.text == "Reference tone\n参考音调")
    #expect(lyrics.timedLines.first?.words.first?.durationMilliseconds == 1000)
    #expect(try JSONDecoder().decode(TrackLyrics.self, from: JSONEncoder().encode(lyrics)) == lyrics)
    #expect(try await adapter.fetchLyrics(for: .init(itemID: .init(sourceID: .init(rawValue: "test"), externalID: "other"), title: "Other", artistName: "Other")) == nil)
}
#endif
#if DEBUG
@Test func metadataPatchFiltersUnrequestedValuesAndRetainsMatchingEvidence() async throws {
    let runtime = references(); let id = ReferencePluginRegistrationProvider.metadataID
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: false)
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let query = MetadataEnrichmentQuery(itemID: .init(sourceID: .init(rawValue: "test"), externalID: "test-track"), title: "MusicFree Reference Tone",
        artistName: "MusicFree", durationSeconds: 1, missingFields: [.year])
    let candidate = try #require(try await adapter.search(query).first)
    #expect(candidate.year == 2026)
    #expect(candidate.artistName == "MusicFree")
    #expect(candidate.albumName == "Plugin Reference")
    #expect(candidate.genreName == nil)
}
#endif
#if DEBUG
@Test func sourceInstancesPreserveStableIdentityAndRevokeIndependently() async throws {
    let runtime = references(); let id = ReferencePluginRegistrationProvider.sourceID
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: true)
    await runtime.setAllowedSourceInstances([id: ["account-a", "account-b"]])
    let factory = CompositeOnlineSourceFactory(legacy: EmptyFactory(), runtime: runtime, downloadRoot: URL(fileURLWithPath: "/unused"))
    let first = try #require(try factory.makeSource(for: .init(sourceID: .init(rawValue: "account-a"),
        providerKind: .init(rawValue: "reference.source"), displayName: "A", privacyPolicyVersion: "1", isEnabled: true)) as? any CatalogBrowsingSource)
    let second = try #require(try factory.makeSource(for: .init(sourceID: .init(rawValue: "account-b"),
        providerKind: .init(rawValue: "reference.source"), displayName: "B", privacyPolicyVersion: "1", isEnabled: true)) as? any CatalogBrowsingSource)
    #expect(try await first.browse(.init()).items.first?.id.sourceID.rawValue == "account-a")
    #expect(try await second.browse(.init()).items.first?.id.sourceID.rawValue == "account-b")
    await runtime.setAllowedSourceInstances([id: ["account-b"]])
    await #expect(throws: PluginError.permissionRequired) { try await first.browse(.init()) }
    #expect(try await second.browse(.init()).items.count == 1)
    #expect(!first.onlineCapabilities.contains(.onlinePlayback)); #expect(first.onlineCapabilities.contains(.downloading))
    #expect(!(first is any PlaybackSource))
    #expect(throws: PluginError.unavailable) {
        try factory.makeSource(for: .init(sourceID: .init(rawValue: "unknown"), providerKind: .init(rawValue: "unknown"), displayName: "Unknown"))
    }
}
#endif

private struct PlaybackOnly: PlaybackSourcePlugin {
    func playbackAccess(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess {
        .init(url: URL(string: "https://fixture.example/tone.wav")!, headers: ["Authorization": "ephemeral"])
    }
}
@Test func playbackOnlyDoesNotRequireDownloadProtocol() async throws {
    let id = PluginID(rawValue: "fixture.playback-only")
    let descriptor = PluginDescriptor(id: id, name: "Playback Only", kinds: [.onlineSource], permissions: [.network],
        onlineProviderID: id.rawValue, onlineCapabilities: [.playbackAccess])
    let runtime = PluginRuntime(registry: PluginRegistry([.init(descriptor: descriptor, onlineSource: { _ in PlaybackOnly() })]))
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        grantedPermissions: [.network], acceptedPolicyVersion: "1")], applicationPrivacyAccepted: true)
    await runtime.setAllowedSourceInstances([id: ["playback-account"]])
    let factory = CompositeOnlineSourceFactory(legacy: EmptyFactory(), runtime: runtime, downloadRoot: URL(fileURLWithPath: "/unused"))
    let source = try #require(try factory.makeSource(for: .init(sourceID: .init(rawValue: "playback-account"),
        providerKind: .init(rawValue: id.rawValue), displayName: "Playback", privacyPolicyVersion: "1", isEnabled: true)))
    #expect(!(source is any DownloadSource))
    let playback = try #require(source as? any PlaybackSource)
    let access = try await playback.playbackAccess(for: .init(sourceID: source.descriptor.sourceID, externalID: "tone"), purpose: .audition)
    if case .http(let request, _) = access {
        #expect(request.headers["Authorization"] == "ephemeral")
    } else { Issue.record("Expected ephemeral playback request") }
}
#if DEBUG
@Test func referenceDownloadProducesActualDecodableMedia() async throws {
    var projectRoot = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { projectRoot.deleteLastPathComponent() }
    let root = projectRoot.appendingPathComponent(".noindex/PluginSystem/fixtures")
    let media = root.appendingPathComponent("reference-tone.wav")
    let existed = FileManager.default.fileExists(atPath: media.path)
    try PluginReferenceMedia.create(at: media)
    defer { if !existed { try? FileManager.default.removeItem(at: media) } }
    let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: media).registrations))
    let id = ReferencePluginRegistrationProvider.sourceID
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: true)
    await runtime.setAllowedSourceInstances([id: ["download-account"]])
    let factory = CompositeOnlineSourceFactory(legacy: EmptyFactory(), runtime: runtime, downloadRoot: root.appendingPathComponent("downloads"))
    let source = try #require(try factory.makeSource(for: .init(sourceID: .init(rawValue: "download-account"),
        providerKind: .init(rawValue: "reference.source"), displayName: "Download", privacyPolicyVersion: "1", isEnabled: true)) as? any DownloadSource)
    let receipt = try await source.download(.init(sourceID: source.descriptor.sourceID, externalID: "tone"), options: .init())
    defer { try? FileManager.default.removeItem(at: receipt.fileURL.deletingLastPathComponent()) }
    #expect(receipt.fileURL.pathExtension == "wav")
    let file = try AVAudioFile(forReading: receipt.fileURL)
    #expect(file.length == 48000); #expect(file.fileFormat.sampleRate == 48000)
    #expect(receipt.byteCount == 96044)
}
#endif
@Test func oldSettingsDecodeAndUnknownPluginPreferencesRoundTrip() throws {
    let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(old.pluginPreferences.isEmpty)
    let settings = old.settingPluginPreferences([.init(pluginID: .init(rawValue: "missing.plugin"), isVisible: false)])
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    let provider = OnlineProviderKind(rawValue: "future.provider")
    #expect(try JSONDecoder().decode(OnlineProviderKind.self, from: JSONEncoder().encode(provider)) == provider)
    #expect(String(data: try JSONEncoder().encode(OnlineProviderKind.dsAudio), encoding: .utf8) == "\"dsAudio\"")
}

@MainActor private final class GraphMountState {
    let engine = AVAudioEngine()
    var running = false
    var installed: AVAudioNode?
    var changes = 0
    func install(_ node: AVAudioNode?) throws {
        guard !running else { throw PluginError.staleOperation }
        if let installed { engine.disconnectNodeOutput(installed); engine.detach(installed) }
        if let node {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        }
        installed = node; changes += 1
    }
}
#if DEBUG
@Test @MainActor func graphChangeDefersMountWhileOutputRuns() async throws {
    let runtime = references()
    let id = ReferencePluginRegistrationProvider.dspID
    let state = GraphMountState()
    let controller = PluginAudioHostController(runtime: runtime,
        factories: PluginAudioHostController.referenceFactories) { try state.install($0) }
    defer { controller.unload() }
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        configuration: ["gain": .number(0.5)])], applicationPrivacyAccepted: false)
    await controller.apply()
    let old = try #require(state.installed as? AVAudioUnitEQ)
    state.running = true
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        configuration: ["gain": .number(0.75)])], applicationPrivacyAccepted: false)
    await controller.apply()
    #expect(state.changes == 1)
    #expect(old.bypass)
    state.running = false
    let (stream, continuation) = AsyncStream<Int>.makeStream()
    controller.observe(stream); continuation.yield(1)
    for _ in 0..<100 where state.changes == 1 { await Task.yield() }
    #expect(state.changes == 2)
    #expect(state.installed !== old)
    continuation.finish()
}
#endif

private actor SuspendedAuthorization {
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls = 0
    private var released = false
    var isWaiting: Bool { continuation != nil }
    func validate(_ id: PluginID) async throws {
        calls += 1
        guard calls == 1 else { return }
        if !released { await withCheckedContinuation { continuation = $0 } }
        throw PluginError.permissionRequired
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
#if DEBUG
@Test @MainActor func stalePCMFailureCannotClearNewerInstallation() async throws {
    let runtime = references(), gate = SuspendedAuthorization()
    let id = ReferencePluginRegistrationProvider.pcmID
    var installed: [PluginDSPFactorySpec] = []
    let controller = PluginPCMHostController(runtime: runtime, excluding: [], install: { installed = $0 },
        authorizeDSP: { try await gate.validate($0) })
    defer { controller.unload() }
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: false)
    let old = Task { await controller.apply() }
    defer { old.cancel(); Task { await gate.release() } }
    for _ in 0..<100 { if await gate.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.isWaiting)
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        configuration: ["gain": .number(0.25)])], applicationPrivacyAccepted: false)
    await controller.apply()
    let current = try #require(installed.first)
    await gate.release(); await old.value
    #expect(installed.first?.configuration.values["gain"] == .number(0.25))
    #expect(current.gate.isAllowed)
}
#endif
#if DEBUG
@Test @MainActor func staleGraphFailureCannotUnloadNewerEffect() async throws {
    let runtime = references(), gate = SuspendedAuthorization(), state = GraphMountState()
    let id = ReferencePluginRegistrationProvider.dspID
    let controller = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories,
        install: { try state.install($0) }, authorizeDSP: { try await gate.validate($0) })
    defer { controller.unload() }
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: false)
    let old = Task { await controller.apply() }
    defer { old.cancel(); Task { await gate.release() } }
    for _ in 0..<100 { if await gate.isWaiting { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.isWaiting)
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        configuration: ["gain": .number(0.25)])], applicationPrivacyAccepted: false)
    await controller.apply()
    let current = try #require(state.installed)
    await gate.release(); await old.value
    #expect(state.installed === current)
    #expect(state.changes == 1)
}
#endif
#if DEBUG
@Test @MainActor func failedPCMStatusDoesNotOverrideRevokedPreference() async throws {
    let runtime = references(), id = ReferencePluginRegistrationProvider.pcmID
    var installed: [PluginDSPFactorySpec] = []
    let controller = PluginPCMHostController(runtime: runtime, excluding: []) { installed = $0 }
    defer { controller.unload() }
    await runtime.apply(preferences: [enabled(id)], applicationPrivacyAccepted: false)
    await controller.apply()
    try #require(installed.first).gate.markFailed()
    await runtime.apply(preferences: [], applicationPrivacyAccepted: false)
    let service = PluginHostService(runtime: runtime, pcm: [controller])
    let snapshot = await service.snapshots().first { $0.id == id }
    #expect(snapshot?.state == .disabled)
}
#endif
#if DEBUG
@Test @MainActor func graphFactoryReceivesDescriptorSchemaVersion() async throws {
    let id = ReferencePluginRegistrationProvider.dspID
    let reference = ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/fixture.wav")).registrations
        .first { $0.descriptor.id == id }!
    let descriptor = PluginDescriptor(id: id, name: "Versioned gain", kinds: [.dsp],
        configuration: .init(version: 2, fields: reference.descriptor.configuration.fields))
    let runtime = PluginRuntime(registry: PluginRegistry([.init(descriptor: descriptor, dsp: reference.dsp)]))
    let state = GraphMountState()
    let controller = PluginAudioHostController(runtime: runtime, factories: [id: { configuration in
        guard configuration.schemaVersion == 2 else { throw PluginError.incompatible }
        return ReferenceAppleGainEffect(gainDecibels: -6)
    }]) { try state.install($0) }
    defer { controller.unload() }
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true, schemaVersion: 2)], applicationPrivacyAccepted: false)
    await controller.apply()
    #expect(state.installed != nil)
}
#endif

#if DEBUG
@Test @MainActor func revertingPendingGraphChangeRestoresAnalysisWithoutRemount() async throws {
    let runtime = references(), state = GraphMountState()
    let id = ReferencePluginRegistrationProvider.dspID
    let controller = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories) { try state.install($0) }
    defer { state.engine.stop(); state.running = false; controller.unload() }
    func preference(_ gain: Double) -> PluginPreference {
        .init(pluginID: id, isEnabled: true, isLoadAllowed: true, configuration: ["gain": .number(gain)])
    }
    await runtime.apply(preferences: [preference(0.5)], applicationPrivacyAccepted: false)
    await controller.apply()
    let original = try #require(state.installed)
    state.running = true
    await runtime.apply(preferences: [preference(0.25)], applicationPrivacyAccepted: false)
    await controller.apply()
    await runtime.apply(preferences: [preference(0.5)], applicationPrivacyAccepted: false)
    await controller.apply()
    #expect(state.installed === original)
    #expect(state.changes == 1)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    let player = AVAudioPlayerNode(); state.engine.attach(player)
    state.engine.connect(player, to: original, format: format)
    try state.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
    input.frameLength = 8192
    let planes = try #require(input.floatChannelData)
    for channel in 0..<2 { for frame in 0..<8192 { planes[channel][frame] = 1 } }
    player.scheduleBuffer(input, completionHandler: nil); try state.engine.start(); player.play()
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    for _ in 0..<8 { _ = try state.engine.renderOffline(1024, to: output) }
    var analysis: PluginPCMAnalysisSnapshot?
    let stream = controller.analysisUpdates()
    let collector = Task { for await sample in stream { analysis = sample; break } }
    defer { collector.cancel() }
    for _ in 0..<100 where analysis == nil { try await Task.sleep(for: .milliseconds(5)) }
    #expect(analysis != nil)
    #expect((analysis?.peak ?? 0) > 0.4)
}
#endif

#if DEBUG
@Test @MainActor func staleRevocationRestoresCurrentPCMWithoutRevivingFailure() async throws {
    let runtime = references(), id = ReferencePluginRegistrationProvider.pcmID
    var installed: [PluginDSPFactorySpec] = []
    var installations = 0
    let controller = PluginPCMHostController(runtime: runtime, excluding: []) {
        installed = $0; installations += 1
    }
    defer { controller.unload() }
    let current = enabled(id)
    await runtime.apply(preferences: [current], applicationPrivacyAccepted: false)
    await controller.apply()
    let specification = try #require(installed.first)
    controller.revokeChangedPreferences([])
    #expect(!specification.gate.isAllowed)
    await controller.apply()
    #expect(specification.gate.isAllowed)
    #expect(installations == 1)
    specification.gate.markFailed()
    controller.revokeChangedPreferences([])
    await controller.apply()
    #expect(!specification.gate.isAllowed)
    #expect(specification.gate.hasFailed)
    #expect(installations == 1)
}
#endif
