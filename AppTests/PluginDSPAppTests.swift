import AVFAudio
import Foundation
import XCTest
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
import MusicFreePluginRuntime
import MusicFreePluginHostBridge
import MusicFreePluginAudio
import MusicDomain
import PreferencesPersistenceAdapter
import AppServices
import PlaybackAPI
import SettingsAPI
@testable import MusicFree
@testable import FFmpegPlaybackAdapter

@MainActor final class PluginDSPAppTests: XCTestCase {
    func testGraphAnalysisHasActualPlaybackProducer() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PluginAnalysisTests")
        let url = root.appendingPathComponent("tone.wav")
        try PluginReferenceMedia.create(at: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: root) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: url).registrations))
        let controller = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories,
            install: { node in try engine.setPostEqualizerEffect(node) })
        defer { controller.unload() }
        await runtime.apply(preferences: [.init(pluginID: ReferencePluginRegistrationProvider.dspID,
            isEnabled: true, isLoadAllowed: true, configuration: ["gain": .number(0.5)])], applicationPrivacyAccepted: false)
        await controller.apply()
        var received: PluginPCMAnalysisSnapshot?
        let observer = Task { @MainActor in
            for await value in controller.analysisUpdates() { received = value; break }
        }
        defer { observer.cancel() }
        try await engine.prepare(PlaybackItem(itemID: .init(sourceID: .local, externalID: "analysis-tone"),
            resource: .localFile(url), displaySnapshot: .init(title: "Tone")), startAt: nil)
        engine.audioEngine.stop()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.play()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        for _ in 0..<60 {
            XCTAssertEqual(try engine.audioEngine.renderOffline(512, to: buffer), .success)
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<20 where received == nil { try await Task.sleep(for: .milliseconds(100)) }
        let sample = try XCTUnwrap(received)
        XCTAssertGreaterThan(sample.peak, 0.01)
        XCTAssertGreaterThan(sample.rms, 0)
        XCTAssertGreaterThan(sample.frameCount, 0)
    }
    func testSelectedPlacementProcessesFFmpegOutputExactlyOnce() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PluginDSPTests")
        let url = root.appendingPathComponent("tone.wav")
        try PluginReferenceMedia.create(at: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: root) }
        func renderPeak(enabled: Bool, placement: PluginDSPPlacement = .postMix, crossfade: Bool = false) async throws -> Float {
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: url).registrations))
        let controller = PluginPCMHostController(runtime: runtime, excluding: Set(PluginAudioHostController.referenceFactories.keys)) { specs in
            let factory: FFmpegPCMProcessorFactory = { format in try PluginFFmpegPCMAdapter(format: format, specifications: specs) }
            try engine.setPCMProcessorFactory(specs.isEmpty ? nil : factory, preservesTiming: true)
        }
        let graph = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories) {
            try engine.setPostEqualizerEffect($0)
        }
        defer { controller.unload(); graph.unload() }
        await runtime.apply(preferences: [.init(pluginID: ReferencePluginRegistrationProvider.dspID,
            isEnabled: enabled, isLoadAllowed: true, configuration: ["gain": .number(0.5)], dspPlacement: placement)], applicationPrivacyAccepted: false)
        await graph.apply(); await controller.apply()
        try await engine.prepare(PlaybackItem(itemID: .init(sourceID: .local, externalID: "plugin-tone"),
            resource: .localFile(url), displaySnapshot: .init(title: "Tone")), startAt: nil)
        if crossfade {
            try engine.apply(.init(transition: .init(mode: .crossfade, crossfadeDuration: .milliseconds(100))))
        }
        engine.audioEngine.stop()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        var handoffs: [LogicalPlaybackCommit] = []
        let observer = Task { for await handoff in engine.makeTransitionStream() { handoffs.append(handoff) } }
        defer { observer.cancel() }
        if crossfade {
            let next = PlaybackItem(itemID: .init(sourceID: .local, externalID: "plugin-next-tone"),
                resource: .localFile(url), displaySnapshot: .init(title: "Next Tone"))
            try await engine.prepareNext(next, ticket: .init(sessionID: UUID(), intent: 1, queueRevision: 1,
                generation: engine.state.generation, currentItemID: engine.state.itemID!, nextEntryID: UUID()))
        }
        try engine.play()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var peak: Float = 0
        for _ in 0..<(crossfade ? 210 : 60) {
            XCTAssertEqual(try engine.audioEngine.renderOffline(512, to: buffer), .success)
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][frame])) }
            try await Task.sleep(for: .milliseconds(1))
            if engine.state.phase == .stopped { break }
        }
        if crossfade { XCTAssertEqual(handoffs.count, 1) }
        return peak
        }
        let baseline = try await renderPeak(enabled: false)
        let perTrack = try await renderPeak(enabled: true, placement: .perTrack)
        let postMix = try await renderPeak(enabled: true, placement: .postMix)
        XCTAssertGreaterThan(baseline, 0.05)
        XCTAssertEqual(perTrack / baseline, 0.5, accuracy: 0.01)
        XCTAssertEqual(postMix / baseline, 0.5, accuracy: 0.01)
        let mixedBaseline = try await renderPeak(enabled: false, crossfade: true)
        let mixedPerTrack = try await renderPeak(enabled: true, placement: .perTrack, crossfade: true)
        let mixedPostMix = try await renderPeak(enabled: true, placement: .postMix, crossfade: true)
        XCTAssertEqual(mixedPerTrack / mixedBaseline, 0.5, accuracy: 0.01)
        XCTAssertEqual(mixedPostMix / mixedBaseline, 0.5, accuracy: 0.01)
    }
    func testPlacementSwitchUsesStoppedEngineHooks() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PluginPlacementTests")
        let url = root.appendingPathComponent("tone.wav")
        try PluginReferenceMedia.create(at: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: root) }
        let engine = FFmpegPlaybackEngine()
        let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: url).registrations))
        let graph = PluginAudioHostController(runtime: runtime, factories: PluginAudioHostController.referenceFactories) {
            try engine.setPostEqualizerEffect($0)
        }
        var mounted: [PluginDSPFactorySpec] = []
        let pcm = PluginPCMHostController(runtime: runtime) { specifications in
            let factory: FFmpegPCMProcessorFactory = { try PluginFFmpegPCMAdapter(format: $0, specifications: specifications) }
            try engine.setPCMProcessorFactory(specifications.isEmpty ? nil : factory, preservesTiming: true)
            mounted = specifications
        }
        // The engine event stream has one consumer; production uses the
        // coordinator's broadcast snapshots. Fan out here to exercise both hosts.
        let (graphEvents, graphContinuation) = AsyncStream<Void>.makeStream()
        let (pcmEvents, pcmContinuation) = AsyncStream<Void>.makeStream()
        let events = engine.makeEventStream()
        let observer = Task {
            for await _ in events { graphContinuation.yield(()); pcmContinuation.yield(()) }
        }
        graph.observe(graphEvents); pcm.observe(pcmEvents)
        defer { observer.cancel(); graphContinuation.finish(); pcmContinuation.finish() }
        defer { engine.hardStop(); graph.unload(); pcm.unload(); engine.dispose() }
        let service = PluginHostService(runtime: runtime, audio: [graph], pcm: [pcm])
        func settings(_ placement: PluginDSPPlacement) -> AppSettings {
            .init(pluginPreferences: [.init(pluginID: ReferencePluginRegistrationProvider.dspID,
                isEnabled: true, isLoadAllowed: true, configuration: ["gain": .number(0.5)], dspPlacement: placement)])
        }
        await service.apply(settings(.postMix))
        try await engine.prepare(.init(itemID: .init(sourceID: .local, externalID: "placement-tone"),
            resource: .localFile(url), displaySnapshot: .init(title: "Tone")), startAt: nil)
        try engine.play()
        let oldNode = try XCTUnwrap(engine.audioEngine.attachedNodes.compactMap { $0 as? AVAudioUnitEQ }.first { $0.bands.isEmpty })
        await service.apply(settings(.perTrack))
        XCTAssertTrue(engine.audioEngine.isRunning); XCTAssertTrue(oldNode.bypass); XCTAssertTrue(mounted.isEmpty)
        engine.hardPause()
        for _ in 0..<100 where mounted.isEmpty || oldNode.engine != nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(oldNode.engine)
        let oldSpec = try XCTUnwrap(mounted.first)
        XCTAssertTrue(oldSpec.gate.isAllowed)
        try engine.play()
        await service.apply(settings(.postMix))
        XCTAssertTrue(engine.audioEngine.isRunning); XCTAssertFalse(oldSpec.gate.isAllowed)
        engine.hardPause()
        for _ in 0..<100 where !mounted.isEmpty || engine.audioEngine.attachedNodes.filter({ $0 is AVAudioUnitEQ }).count != 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(mounted.isEmpty)
        XCTAssertEqual(engine.audioEngine.attachedNodes.filter { $0 is AVAudioUnitEQ }.count, 2)
        try engine.play(); XCTAssertTrue(engine.audioEngine.isRunning)
    }
    func testEachTransitionAndAuditionLaneOwnsStatefulProcessor() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let gate = PluginDSPPermissionGate(); gate.setAllowed(true)
        let spec = PluginDSPFactorySpec(pluginID: .init(rawValue: "stateful"), factory: { _ in LaneCounterProcessor() },
            configuration: .init(dspPlacement: .perTrack), gate: gate)
        let lanes = try (0..<4).map { _ in try PluginFFmpegPCMAdapter(format: format, specifications: [spec]) }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)); buffer.frameLength = 4096
        func process(_ lane: PluginFFmpegPCMAdapter) throws -> Float {
            try lane.process(buffer); return buffer.floatChannelData![0][0]
        }
        for lane in lanes { XCTAssertEqual(try process(lane), 1) }
        XCTAssertEqual(try process(lanes[0]), 2)
        lanes[0].reset()
        XCTAssertEqual(try process(lanes[0]), 1)
        for lane in lanes.dropFirst() { XCTAssertEqual(try process(lane), 2) }
    }
    func testPCMAdapterOwnsIndependentChainsAndBypassesImmediately() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let gate = PluginDSPPermissionGate()
        let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/unused")).registrations))
        let registration = try XCTUnwrap(runtime.registry.registrations[ReferencePluginRegistrationProvider.pcmID])
        let spec = PluginDSPFactorySpec(pluginID: registration.descriptor.id, factory: try XCTUnwrap(registration.dsp),
            configuration: .init(values: ["gain": .number(0.5)]), gate: gate)
        let first = try PluginFFmpegPCMAdapter(format: format, specifications: [spec])
        let second = try PluginFFmpegPCMAdapter(format: format, specifications: [spec])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        buffer.frameLength = 4096
        func process(_ processor: PluginFFmpegPCMAdapter) throws -> Float {
            for channel in 0..<2 { for frame in 0..<4096 { buffer.floatChannelData![channel][frame] = 1 } }
            try processor.process(buffer)
            return buffer.floatChannelData![0][0]
        }
        gate.setAllowed(true)
        XCTAssertEqual(try process(first), 0.5)
        XCTAssertEqual(try process(second), 0.5)
        first.reset()
        gate.setAllowed(false)
        XCTAssertEqual(try process(first), 1)
        XCTAssertEqual(try process(second), 1)
    }
    func testGraphEffectRevocationWhilePlayingDefersDetachUntilPause() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PluginDeferredRevocationTests")
        let url = root.appendingPathComponent("tone.wav")
        try PluginReferenceMedia.create(at: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: root) }
        let engine = FFmpegPlaybackEngine()
        let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: url).registrations))
        let controller = PluginAudioHostController(runtime: runtime,
            factories: PluginAudioHostController.referenceFactories,
            install: { node in try engine.setPostEqualizerEffect(node) })
        controller.observe(engine.makeEventStream())
        defer { engine.hardStop(); controller.unload(); engine.dispose() }
        await runtime.apply(preferences: [.init(pluginID: ReferencePluginRegistrationProvider.dspID,
            isEnabled: true, isLoadAllowed: true, configuration: ["gain": .number(0.5)])], applicationPrivacyAccepted: false)
        await controller.apply()
        try await engine.prepare(PlaybackItem(itemID: .init(sourceID: .local, externalID: "deferred-revocation"),
            resource: .localFile(url), displaySnapshot: .init(title: "Tone")), startAt: nil)
        try engine.play()
        await runtime.apply(preferences: [], applicationPrivacyAccepted: false)
        await controller.apply()
        XCTAssertTrue(engine.audioEngine.isRunning)
        XCTAssertEqual(engine.audioEngine.attachedNodes.filter { $0 is AVAudioUnitEQ }.count, 2)
        engine.hardPause()
        for _ in 0..<50 where engine.audioEngine.attachedNodes.filter({ $0 is AVAudioUnitEQ }).count != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.audioEngine.attachedNodes.filter { $0 is AVAudioUnitEQ }.count, 1)
        XCTAssertEqual(engine.state.phase, .paused)
        try engine.play()
        XCTAssertTrue(engine.audioEngine.isRunning)
    }
    func testGraphEffectCanEnableBeforePrepareAndUnloadOnRevocation() async throws {
        let engine = FFmpegPlaybackEngine()
        let runtime = PluginRuntime(registry: PluginRegistry(ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/unused")).registrations))
        let controller = PluginAudioHostController(runtime: runtime,
            factories: PluginAudioHostController.referenceFactories,
            install: { node in try engine.setPostEqualizerEffect(node) })
        defer { controller.unload(); engine.stop() }
        await runtime.apply(preferences: [.init(pluginID: ReferencePluginRegistrationProvider.dspID,
            isEnabled: true, isLoadAllowed: true, configuration: ["gain": .number(0.5)])], applicationPrivacyAccepted: false)
        await controller.apply()
        XCTAssertEqual(engine.audioEngine.attachedNodes.filter { $0 is AVAudioUnitEQ }.count, 2)
        await runtime.apply(preferences: [], applicationPrivacyAccepted: false)
        await controller.apply()
        XCTAssertEqual(engine.audioEngine.attachedNodes.filter { $0 is AVAudioUnitEQ }.count, 1)
    }
}

private struct LaneCounterProcessor: PluginDSPProcessor {
    let behavior = PluginDSPBehavior(scope: .perTrack)
    private var calls = 0
    mutating func prepare(format: PluginPCMFormat) throws {}
    mutating func process(_ buffer: PluginPCMBufferView) throws {
        calls += 1
        for channel in buffer.channels { for frame in 0..<buffer.frameCount { channel[frame] = Float(calls) } }
    }
    mutating func reset(_ reason: PluginDSPResetReason) { calls = 0 }
}

extension PluginDSPAppTests {
    func testRenderedEnvelopeProgressAndDeadlineReachSharedFileLog() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenderedEnvelopeDiagnosticsTests")
        let file = root.appendingPathComponent(MusicLogger.fileName)
        let previous = MusicLogger.fileLogStatus()
        MusicLogger.configureFileLogging(fileURL: file, enabled: true)
        defer {
            MusicLogger.configureFileLogging(fileURL: previous.fileURL ?? file, enabled: previous.isEnabled)
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("tone.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        func writeTone() throws {
            let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            tone.frameLength = 48000
            for channel in 0..<2 {
                for frame in 0..<48000 {
                    tone.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000) * 0.1)
                }
            }
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<8 { try output.write(from: tone) }
        }
        try writeTone()
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(.init(itemID: .init(sourceID: .local, externalID: "envelope-diagnostics"),
            resource: .localFile(url), displaySnapshot: .init(title: "Tone")), startAt: nil)
        try engine.apply(.init(transition: .init(fadeInDuration: .seconds(1), fadeOutDuration: .seconds(1))))
        engine.audioEngine.stop()
        // Match the bus and sample across a window longer than AVAudioEngine prefetch.
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        try engine.play()
        try await Task.sleep(for: .milliseconds(40))
        func renderPeaks() async throws -> [Float] {
            var peaks: [Float] = []
            for _ in 0..<4 {
                var peak: Float = 0
                for _ in 0..<24 {
                    if !engine.audioEngine.isRunning { break }
                    XCTAssertEqual(try engine.audioEngine.renderOffline(512, to: buffer), .success)
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
                }
                peaks.append(peak)
                try await Task.sleep(for: .milliseconds(15))
            }
            return peaks
        }
        let incoming = try await renderPeaks()
        XCTAssertGreaterThan(incoming[3], incoming[0] * 2)
        engine.pause()
        let outgoing = try await renderPeaks()
        XCTAssertGreaterThan(outgoing[0], outgoing[3] * 2)
        XCTAssertFalse(engine.audioEngine.isRunning)
        try engine.play()
        _ = try await renderPeaks()
        engine.pause()
        // No output callbacks: distinguish the wall deadline from rendered completion.
        await engine.waitForSoftStop()
        XCTAssertFalse(engine.audioEngine.isRunning)
        await MusicLogger.flushFileLog()
        let content = try String(contentsOf: try XCTUnwrap(MusicLogger.fileLogStatus().fileURL), encoding: .utf8)
        XCTAssertTrue(content.contains("[ffmpeg-envelope] event=render-progress"))
        XCTAssertTrue(content.contains("[ffmpeg-envelope] event=render-complete"))
        XCTAssertTrue(content.contains("event=fade-complete-pause"))
        XCTAssertTrue(content.contains("event=fade-deadline-pause"))
        XCTAssertTrue(content.contains("event=play-started"))
        XCTAssertTrue(content.contains("gain=0.0 rampFrame=3840 rampFrames=3840"))
        XCTAssertTrue(content.contains("gain=1.0 rampFrame=48000 rampFrames=48000"))
    }

    func testPlaybackEffectDiagnosticsReachSharedFileLog() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackEffectDiagnosticsTests")
        let file = root.appendingPathComponent(MusicLogger.fileName)
        let previous = MusicLogger.fileLogStatus()
        MusicLogger.configureFileLogging(fileURL: file, enabled: true)
        defer {
            MusicLogger.configureFileLogging(fileURL: previous.fileURL ?? file, enabled: previous.isEnabled)
            try? FileManager.default.removeItem(at: root)
        }
        let engine = FFmpegPlaybackEngine(equalizerManagedExternally: true)
        defer { engine.dispose() }
        let runtime = PluginRuntime(registry: PluginRegistry([PluginHostService.equalizerRegistration]))
        let graph = PluginAudioHostController(runtime: runtime, factories: PluginHostService.audioFactories,
            installChain: { try engine.setPostEqualizerEffects($0) })
        defer { graph.unload() }
        let pcm = PluginPCMHostController(runtime: runtime, excluding: Set(PluginHostService.audioFactories.keys)) { specs in
            let factory: FFmpegPCMProcessorFactory = { format in try PluginFFmpegPCMAdapter(format: format, specifications: specs) }
            try engine.setPCMProcessorFactory(specs.isEmpty ? nil : factory, preservesTiming: true)
        }
        defer { pcm.unload() }
        let plugins = PluginHostService(runtime: runtime, audio: [graph], pcm: [pcm])
        let suite = "MusicFree.PlaybackEffectDiagnostics.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let container = try AppServiceContainer(dependencies: .init(
            settingsRepository: UserDefaultsSettingsRepository(suiteName: suite), plugins: plugins, playbackEngine: engine))
        _ = try await container.settings.load()
        let eq = try EqualizerPreferences(isEnabled: true, preamp: .init(decibels: -6),
            bands: [.init(frequencyHz: 1_000, gain: .init(decibels: 3))])
        let settings = AppSettings(playbackPreferences: .init(equalizer: eq))
            .settingPluginPreferences([.init(pluginID: PluginHostService.equalizerRegistration.descriptor.id,
                isEnabled: true, isLoadAllowed: true,
                configuration: ["preamp": .number(-6), "1000": .number(3)], dspPlacement: .postMix)])
        try await container.settings.update(settings)
        let effective = try await container.settings.effective()
        try engine.apply(effective.effects)
        engine.pause()
        engine.stop()
        var perTrack = try XCTUnwrap(settings.pluginPreferences.first)
        perTrack.dspPlacement = .perTrack
        try await container.settings.update(settings.settingPluginPreferences([perTrack]))
        await MusicLogger.flushFileLog()
        let currentFile = try XCTUnwrap(MusicLogger.fileLogStatus().fileURL)
        let content = try String(contentsOf: currentFile, encoding: .utf8)
        XCTAssertTrue(content.contains("[playback-effects-settings] event=commit"))
        XCTAssertTrue(content.contains("eqEnabled=true eqEffective=true preamp=-6.0 bands=1000:3.0"))
        XCTAssertTrue(content.contains("[plugin-equalizer] event=apply"))
        XCTAssertTrue(content.contains("event=equalizer-applied plugin=builtin.dsp.equalizer attached=true bypass=false preamp=-6.0"))
        XCTAssertTrue(content.contains("1000:3.0"))
        XCTAssertTrue(content.contains("event=factories-installed active=1 plugins=builtin.dsp.equalizer gatesAllowed=true"))
        XCTAssertTrue(content.contains("external=true requested=true bypass=true"))
        XCTAssertTrue(content.contains("event=apply mode="))
        XCTAssertTrue(content.contains("event=pause mode="))
        XCTAssertTrue(content.contains("event=stop mode="))
        XCTAssertFalse(content.contains("credentialRecordID"))
    }

    func testBuiltinEqualizerProcessesEachSelectedNodeOnceAndSupportsGainChain() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BuiltinEQTests")
        let url = root.appendingPathComponent("tone.wav")
        try PluginReferenceMedia.create(at: url)
        defer { try? FileManager.default.removeItem(at: root) }
        func peak(eqEnabled: Bool, placement: PluginDSPPlacement, extraGain: Bool) async throws -> Float {
            let engine = FFmpegPlaybackEngine(equalizerManagedExternally: true)
            defer { engine.dispose() }
            let runtime = PluginRuntime(registry: PluginRegistry(
                ReferencePluginRegistrationProvider(mediaURL: url).registrations + [PluginHostService.equalizerRegistration]))
            let graph = PluginAudioHostController(runtime: runtime, factories: PluginHostService.audioFactories,
                installChain: { try engine.setPostEqualizerEffects($0) })
            let pcm = PluginPCMHostController(runtime: runtime, excluding: Set(PluginHostService.audioFactories.keys)) { specs in
                let factory: FFmpegPCMProcessorFactory = { format in try PluginFFmpegPCMAdapter(format: format, specifications: specs) }
                try engine.setPCMProcessorFactory(specs.isEmpty ? nil : factory, preservesTiming: true)
            }
            defer { graph.unload(); pcm.unload() }
            let id = PluginHostService.equalizerRegistration.descriptor.id
            await runtime.apply(preferences: [
                .init(pluginID: id, isEnabled: eqEnabled, isLoadAllowed: true, configuration: ["preamp": .number(-6)], dspPlacement: placement),
                .init(pluginID: ReferencePluginRegistrationProvider.dspID, isEnabled: extraGain, isLoadAllowed: true,
                    configuration: ["gain": .number(0.5)], dspPlacement: .postMix)
            ], applicationPrivacyAccepted: false)
            await graph.apply(); await pcm.apply()
            // The old engine API still accepts EQ intent; production external
            // management must bypass it so the same settings are not applied twice.
            let legacy = try XCTUnwrap(engine.equalizerDescriptor)
            try engine.apply(.init(equalizer: .init(preampDecibels: -6,
                bandGains: legacy.bands.map { .init(centerFrequencyHz: $0.centerFrequencyHz, gainDecibels: 0) })))
            XCTAssertTrue(engine.equalizerUnit.bypass)
            try await engine.prepare(.init(itemID: .init(sourceID: .local, externalID: "eq-tone"), resource: .localFile(url), displaySnapshot: .init(title: "Tone")), startAt: nil)
            engine.audioEngine.stop()
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
            try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            try engine.play()
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            var peak: Float = 0
            for _ in 0..<60 {
                XCTAssertEqual(try engine.audioEngine.renderOffline(512, to: buffer), .success)
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][frame])) }
                try await Task.sleep(for: .milliseconds(1))
            }
            return peak
        }
        let baseline = try await peak(eqEnabled: false, placement: .postMix, extraGain: false)
        XCTAssertGreaterThan(baseline, 0.05)
        let expected = Float(pow(10, -6.0 / 20))
        for placement in [PluginDSPPlacement.perTrack, .postMix] {
            let equalized = try await peak(eqEnabled: true, placement: placement, extraGain: false)
            let stacked = try await peak(eqEnabled: true, placement: placement, extraGain: true)
            XCTAssertEqual(equalized / baseline, expected, accuracy: 0.01)
            XCTAssertEqual(stacked / baseline, expected * 0.5, accuracy: 0.01)
        }
    }
}

extension PluginDSPAppTests {
    func testDeclickProcessesActualFFmpegOutputAndBypassesAtZeroStrength() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeclickPlaybackTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("left-impulses.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            pcm.frameLength = 48000
            let channels = try XCTUnwrap(pcm.floatChannelData)
            for frame in 0..<48000 {
                let tone = Float(0.15 * sin(2 * .pi * 440 * Double(frame) / 48000))
                channels[0][frame] = tone
                channels[1][frame] = tone
            }
            for frame in [4095, 8192, 12000, 16000, 20000, 24576] { channels[0][frame] += 0.7 }
            try file.write(from: pcm)
        }
        let registration = PluginHostService.declickRegistration
        func peaks(enabled: Bool, strength: Double) async throws -> [Float] {
            let engine = FFmpegPlaybackEngine(equalizerManagedExternally: true)
            defer { engine.dispose() }
            let runtime = PluginRuntime(registry: PluginRegistry([registration]))
            let controller = PluginPCMHostController(runtime: runtime) { specs in
                let factory: FFmpegPCMProcessorFactory = { try PluginFFmpegPCMAdapter(format: $0, specifications: specs) }
                try engine.setPCMProcessorFactory(specs.isEmpty ? nil : factory, preservesTiming: true)
            }
            defer { engine.hardStop(); controller.unload() }
            await runtime.apply(preferences: [.init(pluginID: registration.descriptor.id,
                isEnabled: enabled, isLoadAllowed: true, configuration: ["strengthPercent": .number(strength)])],
                applicationPrivacyAccepted: false)
            await controller.apply()
            try await engine.prepare(.init(itemID: .init(sourceID: .local, externalID: "declick-impulses"),
                resource: .localFile(url), displaySnapshot: .init(title: "Impulse fixture")), startAt: nil)
            engine.audioEngine.stop()
            try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            try engine.play()
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            var result: [Float] = [0, 0]
            for _ in 0..<60 {
                XCTAssertEqual(try engine.audioEngine.renderOffline(512, to: buffer), .success)
                let channels = try XCTUnwrap(buffer.floatChannelData)
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) { result[channel] = max(result[channel], abs(channels[channel][frame])) }
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(controller.failedPluginIDs.isEmpty)
            return result
        }
        let original = try await peaks(enabled: false, strength: 100)
        let processed = try await peaks(enabled: true, strength: 100)
        let bypass = try await peaks(enabled: true, strength: 0)
        XCTAssertGreaterThan(original[0], 0.5)
        XCTAssertLessThan(processed[0], 0.16)
        XCTAssertEqual(processed[1], original[1], accuracy: 0.001)
        XCTAssertEqual(bypass[0], original[0], accuracy: 0.001)
    }
}
