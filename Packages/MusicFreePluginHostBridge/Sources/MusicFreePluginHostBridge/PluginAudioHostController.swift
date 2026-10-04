import Foundation
import AVFAudio
import MusicFreePluginAPI
import MusicFreePluginAppleAudioAPI
import MusicFreePluginRuntime
import MusicFreePluginAudio

/// Each playback/audition graph owns an ordered chain of independent effects.
@MainActor public final class PluginAudioHostController {
    private struct Entry {
        let id: PluginID
        var preference: PluginPreference
        let effect: any PluginAppleAudioEffect
    }
    private let runtime: PluginRuntime
    private let factories: [PluginID: AppleAudioDSPPluginFactory]
    private let install: @MainActor ([AVAudioNode]) throws -> Void
    private let authorizeDSP: @Sendable (PluginID) async throws -> Void
    private var active: [Entry] = []
    private var pending: [Entry]?
    private var tappedNode: AVAudioNode?
    private var observation: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0
    private let analysis = PluginAnalysisQueue()
    private var graphGeneration: UInt64 = 0
    public private(set) var failedPluginIDs: Set<PluginID> = []

    public convenience init(runtime: PluginRuntime, factories: [PluginID: AppleAudioDSPPluginFactory],
                            installChain: @escaping @MainActor ([AVAudioNode]) throws -> Void) {
        self.init(runtime: runtime, factories: factories, installChain: installChain,
                  authorizeDSP: { _ = try await runtime.dspConfiguration(pluginID: $0) })
    }
    public convenience init(runtime: PluginRuntime, factories: [PluginID: AppleAudioDSPPluginFactory],
                            install: @escaping @MainActor (AVAudioNode?) throws -> Void) {
        self.init(runtime: runtime, factories: factories, install: install,
                  authorizeDSP: { _ = try await runtime.dspConfiguration(pluginID: $0) })
    }
    convenience init(runtime: PluginRuntime, factories: [PluginID: AppleAudioDSPPluginFactory],
                     install: @escaping @MainActor (AVAudioNode?) throws -> Void,
                     authorizeDSP: @escaping @Sendable (PluginID) async throws -> Void) {
        self.init(runtime: runtime, factories: factories, installChain: { nodes in
            guard nodes.count <= 1 else { throw PluginError.unsupportedCapability }
            try install(nodes.first)
        }, authorizeDSP: authorizeDSP)
    }
    private init(runtime: PluginRuntime, factories: [PluginID: AppleAudioDSPPluginFactory],
                 installChain: @escaping @MainActor ([AVAudioNode]) throws -> Void,
                 authorizeDSP: @escaping @Sendable (PluginID) async throws -> Void) {
        self.runtime = runtime; self.factories = factories; install = installChain
        self.authorizeDSP = authorizeDSP
    }
    public func apply() async {
        requestGeneration &+= 1; let request = requestGeneration
        let snapshots = await runtime.snapshots()
        guard request == requestGeneration else { return }
        let candidates = snapshots.filter { snapshot in
            let postMix = snapshot.descriptor.dspPlacements == nil ? factories[snapshot.id] != nil
                : (try? snapshot.descriptor.resolvedDSPPlacement(snapshot.preference.dspPlacement)) == .postMix
            return postMix && snapshot.descriptor.kinds.contains(.dsp) && snapshot.preference.isEnabled && snapshot.preference.isLoadAllowed
                && [.registered, .ready, .running].contains(snapshot.state)
        }
        failedPluginIDs = []
        var next: [Entry] = []
        for candidate in candidates {
            guard let factory = factories[candidate.id] else { failedPluginIDs.insert(candidate.id); continue }
            var operational = candidate.preference; operational.isVisible = true
            if let previous = active.first(where: { $0.id == candidate.id }) {
                var old = previous.preference; old.isVisible = true
                if old == operational { next.append(previous); continue }
            }
            do {
                try await authorizeDSP(candidate.id)
                guard request == requestGeneration else { return }
                let configuration = PluginInstanceConfiguration(values: candidate.preference.configuration,
                    credentialRecordID: candidate.preference.credentialRecordID,
                    acceptedPolicyVersion: candidate.preference.acceptedPolicyVersion,
                    schemaVersion: candidate.preference.schemaVersion,
                    dspPlacement: try candidate.descriptor.resolvedDSPPlacement(candidate.preference.dspPlacement))
                let effect: any PluginAppleAudioEffect
                if let previous = active.first(where: { $0.id == candidate.id }),
                   Self.differsOnlyInParameters(previous.preference, candidate.preference),
                   try previous.effect.update(configuration: configuration) {
                    effect = previous.effect
                } else { effect = try factory(configuration) }
                guard effect.behavior.scope == .postMix, effect.behavior.latencyFrames == 0,
                      effect.behavior.tailFrames == 0 else { throw PluginError.unsupportedCapability }
                next.append(.init(id: candidate.id, preference: candidate.preference, effect: effect))
            } catch {
                guard request == requestGeneration else { return }
                failedPluginIDs.insert(candidate.id)
            }
        }
        guard request == requestGeneration else { return }
        for previous in active where !next.contains(where: { $0.effect === previous.effect }) { previous.effect.setBypassed(true) }
        pending = next
        applyPending()
    }
    private static func differsOnlyInParameters(_ old: PluginPreference, _ new: PluginPreference) -> Bool {
        var previous = old
        previous.configuration = new.configuration; previous.isVisible = new.isVisible
        return previous == new
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
        guard let next = pending else { return }
        let sameNodes = next.count == active.count && zip(next, active).allSatisfy { $0.effect.node === $1.effect.node }
        if sameNodes {
            active = next; pending = nil
            for entry in active { entry.effect.setBypassed(false) }
            installAnalysisTapIfNeeded()
            return
        }
        // Remove taps before the engine detaches any node. A running engine
        // defers topology changes; removed/revoked effects are already bypassed.
        tappedNode?.removeTap(onBus: 0); tappedNode = nil
        do {
            try install(next.map { $0.effect.node })
            for previous in active where !next.contains(where: { $0.effect === previous.effect }) { previous.effect.reset(.stop) }
            active = next; pending = nil; graphGeneration &+= 1
            for entry in active { entry.effect.setBypassed(false) }
            installAnalysisTapIfNeeded()
        } catch { /* Playback snapshots retry after pause/stop. */ }
    }
    private func installAnalysisTapIfNeeded() {
        guard tappedNode == nil, let effect = active.last?.effect, effect.node.engine != nil else { return }
        effect.node.installTap(onBus: 0, bufferSize: 1024, format: nil,
            block: Self.makeAnalysisTap(queue: analysis, generation: graphGeneration))
        tappedNode = effect.node
    }
    public func unload() {
        requestGeneration &+= 1
        for entry in active { entry.effect.setBypassed(true) }
        pending = []; applyPending()
    }
    public func revokeChangedPreferences(_ preferences: [PluginPreference]) {
        for entry in active {
            var previous = entry.preference; previous.isVisible = true
            var updated = preferences.first { $0.pluginID == entry.id } ?? .init(pluginID: entry.id)
            updated.isVisible = true
            if previous != updated { entry.effect.setBypassed(true) }
        }
    }
    deinit { observation?.cancel() }
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
