import Foundation
import PlaybackAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
import MusicFreePluginAudio

/// Applies factories only while output is stopped, and closes existing gates
/// immediately on configuration/permission change. Queued audio is not rewound.
@MainActor public final class PluginPCMHostController {
    private let runtime: PluginRuntime
    private let excluded: Set<PluginID>
    private let install: @MainActor ([PluginDSPFactorySpec]) throws -> Void
    private let authorizeDSP: @Sendable (PluginID) async throws -> Void
    private var operational: [PluginPreference] = []
    private var installed: [PluginDSPFactorySpec] = []
    private var pending: [PluginDSPFactorySpec]?
    private var revision: UInt64 = 0
    private var observation: Task<Void, Never>?
    public convenience init(runtime: PluginRuntime, excluding: Set<PluginID> = [], install: @escaping @MainActor ([PluginDSPFactorySpec]) throws -> Void) {
        self.init(runtime: runtime, excluding: excluding, install: install,
                  authorizeDSP: { _ = try await runtime.makeDSP(pluginID: $0) })
    }
    init(runtime: PluginRuntime, excluding: Set<PluginID>, install: @escaping @MainActor ([PluginDSPFactorySpec]) throws -> Void,
         authorizeDSP: @escaping @Sendable (PluginID) async throws -> Void) {
        self.runtime = runtime; self.excluded = excluding; self.install = install
        self.authorizeDSP = authorizeDSP
    }
    public func apply() async {
        revision &+= 1; let request = revision
        let snapshots = await runtime.snapshots()
        guard request == revision else { return }
        let candidates = snapshots.filter { snapshot in
            let perTrack = snapshot.descriptor.dspPlacements == nil ? !excluded.contains(snapshot.id)
                : (try? snapshot.descriptor.resolvedDSPPlacement(snapshot.preference.dspPlacement)) == .perTrack
            return perTrack && snapshot.descriptor.kinds.contains(.dsp)
            && snapshot.preference.isEnabled && snapshot.preference.isLoadAllowed
            && [.registered, .ready, .running].contains(snapshot.state) }
        let preferences = candidates.map { snapshot in var preference = snapshot.preference; preference.isVisible = true; return preference }
        guard preferences != operational else {
            if pending != nil { applyPending() }
            else { for spec in installed { spec.gate.setAllowed(true) } }
            return
        }
        for spec in installed + (pending ?? []) { spec.gate.setAllowed(false) }
        var specifications: [PluginDSPFactorySpec] = []
        for candidate in candidates {
            guard let factory = runtime.registry.registrations[candidate.id]?.dsp else { continue }
            let permitted = (try? await authorizeDSP(candidate.id)) != nil
            guard request == revision else { return }
            guard permitted else { continue }
            specifications.append(.init(pluginID: candidate.id, factory: factory,
                configuration: .init(values: candidate.preference.configuration,
                    credentialRecordID: candidate.preference.credentialRecordID,
                    acceptedPolicyVersion: candidate.preference.acceptedPolicyVersion,
                    schemaVersion: candidate.preference.schemaVersion,
                    dspPlacement: try? candidate.descriptor.resolvedDSPPlacement(candidate.preference.dspPlacement)),
                gate: PluginDSPPermissionGate()))
        }
        guard request == revision else { return }
        operational = preferences; pending = specifications
        applyPending()
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
        guard let specifications = pending else { return }
        do {
            try install(specifications)
            for spec in specifications { spec.gate.setAllowed(true) }
            installed = specifications; pending = nil
        } catch { /* A running engine defers the new factory until output stops. */ }
    }
    public var failedPluginIDs: Set<PluginID> { Set((installed + (pending ?? [])).filter { $0.gate.hasFailed }.map(\.pluginID)) }
    /// Close the old route before either host can enable a newly selected route.
    public func revokeChangedPreferences(_ preferences: [PluginPreference]) {
        for previous in operational {
            var updated = preferences.first { $0.pluginID == previous.pluginID } ?? .init(pluginID: previous.pluginID)
            updated.isVisible = true
            if previous != updated {
                for spec in installed + (pending ?? []) where spec.pluginID == previous.pluginID { spec.gate.setAllowed(false) }
            }
        }
    }
    public func unload() {
        revision &+= 1; observation?.cancel(); observation = nil
        for spec in installed + (pending ?? []) { spec.gate.setAllowed(false) }
        try? install([]); installed = []; pending = nil; operational = []
    }
    deinit { observation?.cancel() }
}
