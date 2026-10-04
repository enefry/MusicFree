import AVFAudio
import Foundation
import XCTest
import MusicFreePluginAPI
import MusicFreePluginDSPAPI
import MusicFreePluginRuntime
import MusicFreePluginHostBridge
import MusicFreePluginAudio
import MusicDomain
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
