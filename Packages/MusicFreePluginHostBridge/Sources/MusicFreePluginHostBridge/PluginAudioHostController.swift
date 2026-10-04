import Foundation
import AVFAudio
import MusicFreePluginAPI
import MusicFreePluginAppleAudioAPI
import MusicFreePluginRuntime
import MusicFreePluginAudio

/// A separate controller for each formal/audition graph. The graph accepts only
/// a node; Runtime and plugin preferences never enter the playback package.
@MainActor public final class PluginAudioHostController {
    private let runtime: PluginRuntime
    private let factories: [PluginID: AppleAudioDSPPluginFactory]
    private let install: @MainActor (AVAudioNode?) throws -> Void
    private let authorizeDSP: @Sendable (PluginID) async throws -> Void
    private var active: (id: PluginID, preference: PluginPreference, effect: any PluginAppleAudioEffect)?
    private var pending: (id: PluginID, preference: PluginPreference, effect: any PluginAppleAudioEffect)?
    private var pendingRemoval = false
    private var hasActiveTap = false
    private var observation: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private let analysis = PluginAnalysisQueue()
    private var graphGeneration: UInt64 = 0
    public private(set) var failedPluginIDs: Set<PluginID> = []
    public convenience init(runtime: PluginRuntime, factories: [PluginID: AppleAudioDSPPluginFactory],
                install: @escaping @MainActor (AVAudioNode?) throws -> Void) {
        self.init(runtime: runtime, factories: factories, install: install,
                  authorizeDSP: { _ = try await runtime.dspConfiguration(pluginID: $0) })
    }
    init(runtime: PluginRuntime, factories: [PluginID: AppleAudioDSPPluginFactory],
         install: @escaping @MainActor (AVAudioNode?) throws -> Void,
         authorizeDSP: @escaping @Sendable (PluginID) async throws -> Void) {
        self.runtime = runtime; self.factories = factories; self.install = install
        self.authorizeDSP = authorizeDSP
    }
    public func apply() async {
        requestGeneration &+= 1
        let request = requestGeneration
        let snapshots = await runtime.snapshots()
        guard request == requestGeneration else { return }
        let candidates = snapshots.filter { snapshot in
            let postMix = snapshot.descriptor.dspPlacements == nil ? factories[snapshot.id] != nil
                : (try? snapshot.descriptor.resolvedDSPPlacement(snapshot.preference.dspPlacement)) == .postMix
            return postMix && snapshot.descriptor.kinds.contains(.dsp) && snapshot.preference.isEnabled && snapshot.preference.isLoadAllowed
                && [.registered, .ready, .running].contains(snapshot.state)
        }
        // The playback graph currently offers one bus-effect slot. Report any
        // unsupported backend or occupied slot instead of silently dropping it.
        let candidate = candidates.first { factories[$0.id] != nil }
        failedPluginIDs = Set(candidates.filter { $0.id != candidate?.id }.map(\.id))
        guard let candidate else { unload(); return }
        var operational = candidate.preference; operational.isVisible = true
        if var previous = active?.preference {
            previous.isVisible = true
            if active?.id == candidate.id && previous == operational {
                pending = nil; pendingRemoval = false; active?.effect.setBypassed(false)
                installAnalysisTapIfNeeded()
                return
            }
        }
        active?.effect.setBypassed(true)
        do {
            try await authorizeDSP(candidate.id)
            guard request == requestGeneration else { return }
            guard let factory = factories[candidate.id] else { throw PluginError.unavailable }
            let effect = try factory(.init(values: candidate.preference.configuration,
                credentialRecordID: candidate.preference.credentialRecordID,
                acceptedPolicyVersion: candidate.preference.acceptedPolicyVersion,
                schemaVersion: candidate.preference.schemaVersion,
                dspPlacement: try candidate.descriptor.resolvedDSPPlacement(candidate.preference.dspPlacement)))
            guard effect.behavior.scope == .postMix, effect.behavior.latencyFrames == 0,
                  effect.behavior.tailFrames == 0 else { throw PluginError.unsupportedCapability }
            active?.effect.setBypassed(true)
            pending = (candidate.id, candidate.preference, effect)
            pendingRemoval = false
            applyPending()
        } catch {
            guard request == requestGeneration else { return }
            failedPluginIDs.insert(candidate.id)
            unload()
        }
    }
    public func observe<Snapshot: Sendable>(_ stream: AsyncStream<Snapshot>) {
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self?.applyPending()
            }
        }
    }
    private func applyPending() {
        guard pending != nil || pendingRemoval else { return }
        // Taps must be removed before an installer detaches the previous node.
        // A running engine may defer installation after this safe bypass step.
        if hasActiveTap { active?.effect.node.removeTap(onBus: 0); hasActiveTap = false }
        do {
            try install(pending?.effect.node)
            active?.effect.reset(.stop)
            active = pending; pending = nil; pendingRemoval = false
            graphGeneration &+= 1
            if let effect = active?.effect {
                effect.setBypassed(false)
                installAnalysisTapIfNeeded()
            }
        } catch { /* Running output defers graph mutation until stopped. */ }
    }
    private func installAnalysisTapIfNeeded() {
        guard !hasActiveTap, let effect = active?.effect, effect.node.engine != nil else { return }
        effect.node.installTap(onBus: 0, bufferSize: 1024, format: nil,
            block: Self.makeAnalysisTap(queue: analysis, generation: graphGeneration))
        hasActiveTap = true
    }
    public func unload() {
        requestGeneration &+= 1
        active?.effect.setBypassed(true)
        pending = nil; pendingRemoval = true
        applyPending()
    }
    public func revokeChangedPreferences(_ preferences: [PluginPreference]) {
        guard let active else { return }
        var previous = active.preference; previous.isVisible = true
        var updated = preferences.first { $0.pluginID == active.id } ?? .init(pluginID: active.id)
        updated.isVisible = true
        if previous != updated { active.effect.setBypassed(true) }
    }
    deinit { observation?.cancel() }
    // SDK tap callbacks run on an audio-owned queue. Build this closure outside
    // MainActor so Swift does not insert an executor assertion in the callback.
    nonisolated private static func makeAnalysisTap(queue: PluginAnalysisQueue, generation: UInt64) -> AVAudioNodeTapBlock {
        { buffer, _ in queue.ingest(buffer, generation: generation) }
    }
    public func analysisUpdates() -> AsyncStream<PluginPCMAnalysisSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    if let value = self.analysis.latest(generation: self.graphGeneration) {
                        continuation.yield(.init(peak: value.peak, rms: value.rms, frameCount: value.frames))
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public static var referenceFactories: [PluginID: AppleAudioDSPPluginFactory] {
        [ReferencePluginRegistrationProvider.dspID: { configuration in
            let gain: Double
            if case .number(let value) = configuration.values["gain"] { gain = value } else { gain = 1 }
            guard gain.isFinite, (0...4).contains(gain) else { throw PluginError.invalidConfiguration }
            return ReferenceAppleGainEffect(gainDecibels: gain > 0 ? Float(20 * log10(gain)) : -96)
        }]
    }
}
