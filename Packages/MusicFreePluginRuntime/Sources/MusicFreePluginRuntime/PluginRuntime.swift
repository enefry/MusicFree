import Foundation
import MusicFreePluginAPI
import MusicFreePluginDSPAPI

public struct LoadedPluginInstances: Sendable {
    public var lyrics: (any LyricsPlugin)?
    public var metadata: (any MetadataPlugin)?
    public var onlineSource: (any OnlineSourcePlugin)?
    public init(lyrics: (any LyricsPlugin)? = nil, metadata: (any MetadataPlugin)? = nil,
                onlineSource: (any OnlineSourcePlugin)? = nil) {
        self.lyrics = lyrics; self.metadata = metadata; self.onlineSource = onlineSource
    }
    func shutdown() async {
        await lyrics?.shutdown(); await metadata?.shutdown(); await onlineSource?.shutdown()
    }
}

public actor PluginRuntime {
    public nonisolated let registry: PluginRegistry
    private let credentials: (any PluginCredentialAccess)?
    private var preferences: [PluginID: PluginPreference] = [:]
    private var applicationPrivacyAccepted = false
    private var allowedSourceInstances: [PluginID: Set<String>]?
    private struct Key: Hashable { let pluginID: PluginID; let instanceID: String; let kind: PluginKind }
    private struct Entry {
        var generation: UInt64
        var configuration: PluginInstanceConfiguration
        var loading: Task<LoadedPluginInstances, Error>?
        var loaded: LoadedPluginInstances?
        var state: PluginLifecycleState
        var operations: [UUID: @Sendable () -> Void] = [:]
    }
    private var entries: [Key: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    private var isStopped = false
    private var diagnostics: [PluginID: PluginError] = [:]
    public init(registry: PluginRegistry, credentials: (any PluginCredentialAccess)? = nil) {
        self.registry = registry; self.credentials = credentials
    }

    public func apply(preferences updated: [PluginPreference], applicationPrivacyAccepted: Bool,
                      allowedSourceInstances: [PluginID: Set<String>]? = nil) {
        // Publish all host authorization dimensions in one actor turn.
        if let allowedSourceInstances { setAllowedSourceInstances(allowedSourceInstances) }
        var next: [PluginID: PluginPreference] = [:]
        for preference in updated { next[preference.pluginID] = preference }
        for id in Array(diagnostics.keys) where preferences[id] != next[id] { diagnostics[id] = nil }
        for key in Array(entries.keys) {
            let old = preferences[key.pluginID] ?? PluginPreference(pluginID: key.pluginID)
            let new = next[key.pluginID] ?? PluginPreference(pluginID: key.pluginID)
            // Visibility alone must not unload an active capability.
            var oldOperational = old; oldOperational.isVisible = new.isVisible
            oldOperational.instances = new.instances
            let network = registry.descriptors[key.pluginID]?.permissions.contains(.network) == true
            if oldOperational != new || (network && self.applicationPrivacyAccepted != applicationPrivacyAccepted) {
                invalidate(key)
            } else if old.instances.first(where: { $0.instanceID == key.instanceID }) != new.instances.first(where: { $0.instanceID == key.instanceID }) {
                invalidate(key)
            }
        }
        self.preferences = next; self.applicationPrivacyAccepted = applicationPrivacyAccepted
    }

    public func snapshots() -> [PluginSnapshot] {
        var descriptors = registry.descriptors
        for id in preferences.keys where descriptors[id] == nil {
            descriptors[id] = PluginDescriptor(id: id, name: id.rawValue, kinds: [])
        }
        return descriptors.values.sorted { $0.id < $1.id }.map { descriptor in
            let preference = preferences[descriptor.id] ?? PluginPreference(pluginID: descriptor.id)
            let state: PluginLifecycleState
            if registry.descriptors[descriptor.id] == nil { state = .compiledOut }
            else if let unavailable = registry.unavailable[descriptor.id] { state = unavailable }
            else if isStopped { state = .unloaded }
            else if !preference.isEnabled { state = .disabled }
            else if !preference.isLoadAllowed { state = .loadBlocked }
            else if let error = diagnostics[descriptor.id] { state = error == .incompatible ? .incompatible : .failed }
            else if let error = authorizationError(descriptor.id) {
                switch error {
                case .permissionRequired: state = .permissionRequired
                case .incompatible: state = .incompatible
                default: state = .failed
                }
            }
            else {
                let states = entries.filter { $0.key.pluginID == descriptor.id }.map(\.value.state)
                state = [.failed, .loading, .running, .ready].first { states.contains($0) } ?? .registered
            }
            return PluginSnapshot(descriptor: descriptor, preference: preference, state: state,
                                  diagnostic: (diagnostics[descriptor.id] ?? authorizationError(descriptor.id)).map { String(describing: $0) })
        }
    }

    private func authorizationError(_ id: PluginID) -> PluginError? {
        do { _ = try permit(id, configuration: nil); return nil }
        catch { return (error as? PluginError) ?? .requestFailed(code: "authorization_failed") }
    }

    public func unload(pluginID: PluginID, instanceID: String? = nil) {
        for key in Array(entries.keys) where key.pluginID == pluginID && (instanceID == nil || key.instanceID == instanceID) {
            invalidate(key)
        }
    }

    public func setAllowedSourceInstances(_ allowed: [PluginID: Set<String>]) {
        for key in Array(entries.keys) where key.kind == .onlineSource {
            if allowed[key.pluginID]?.contains(key.instanceID) != true { invalidate(key) }
        }
        allowedSourceInstances = allowed
    }
    public func shutdown() {
        isStopped = true
        for key in Array(entries.keys) { invalidate(key) }
    }

    /// Each operation owns a lease; concurrent queries share the load, never a request generation.
    public func perform<Result: Sendable>(pluginID: PluginID, configuration: PluginInstanceConfiguration? = nil, kind: PluginKind? = nil,
        discardResult: (@Sendable (Result) async -> Void)? = nil,
        operation: @escaping @Sendable (LoadedPluginInstances, PluginOperationContext) async throws -> Result
    ) async throws -> Result {
        let preference = preferences[pluginID] ?? PluginPreference(pluginID: pluginID)
        let kinds = registry.descriptors[pluginID]?.kinds ?? []
        guard let requestedKind = kind ?? (kinds.count == 1 ? kinds.first : nil), kinds.contains(requestedKind), requestedKind != .dsp else {
            throw registry.registrations[pluginID] == nil ? PluginError.unavailable : PluginError.unsupportedCapability
        }
        var config = configuration ?? PluginInstanceConfiguration(values: preference.configuration,
            credentialRecordID: preference.credentialRecordID, schemaVersion: preference.schemaVersion)
        if let instance = preference.instances.first(where: { $0.instanceID == config.instanceID }) {
            config = PluginInstanceConfiguration(instanceID: config.instanceID, values: instance.values,
                credentialRecordID: config.credentialRecordID ?? instance.credentialRecordID,
                acceptedPolicyVersion: config.acceptedPolicyVersion ?? instance.acceptedPolicyVersion, schemaVersion: instance.schemaVersion)
        }
        let key = Key(pluginID: pluginID, instanceID: config.instanceID, kind: requestedKind)
        let (loaded, generation) = try await acquire(key, configuration: config)
        try Task.checkCancellation()
        let descriptor = try permit(pluginID, configuration: config, kind: requestedKind)
        let context = PluginOperationContext(pluginID: pluginID, instanceID: config.instanceID,
            generation: generation, permissions: descriptor.permissions, applicationPrivacyAccepted: applicationPrivacyAccepted)
        let task = Task { try Task.checkCancellation(); return try await operation(loaded, context) }
        guard entries[key]?.generation == generation else { task.cancel(); throw PluginError.staleOperation }
        entries[key]?.operations[context.operationID] = { task.cancel() }
        entries[key]?.state = .running
        defer {
            if entries[key]?.generation == generation {
                entries[key]?.operations[context.operationID] = nil
                let state: PluginLifecycleState = entries[key]?.operations.isEmpty == true ? .ready : .running
                entries[key]?.state = state
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            do {
                try Task.checkCancellation()
                guard !task.isCancelled else { throw CancellationError() }
                guard entries[key]?.generation == generation else { throw PluginError.staleOperation }
                _ = try permit(pluginID, configuration: config, kind: requestedKind)
                return result
            } catch {
                await discardResult?(result)
                throw error
            }
        } onCancel: { task.cancel() }
    }

    /// Explicit authorization operations can precede provider enablement.
    /// They obey load/policy/app gates and never instantiate the data factory.
    public func metadataAuthorization(pluginID: PluginID, requesting: Bool) async throws -> PluginMetadataAuthorizationStatus {
        _ = try permit(pluginID, configuration: nil, kind: .metadata, requiresEnabled: false)
        guard let registration = registry.registrations[pluginID], registration.descriptor.kinds.contains(.metadata),
              let handlers = registration.metadataAuthorization else { throw PluginError.unsupportedCapability }
        let expected = preferences[pluginID]
        let appConsent = applicationPrivacyAccepted
        let status = requesting ? await handlers.request() : await handlers.status()
        try Task.checkCancellation()
        _ = try permit(pluginID, configuration: nil, kind: .metadata, requiresEnabled: false)
        var previous = expected; previous?.isVisible = preferences[pluginID]?.isVisible ?? true
        guard previous == preferences[pluginID], appConsent == applicationPrivacyAccepted else { throw PluginError.staleOperation }
        return status
    }

    public func dspConfiguration(pluginID: PluginID, configuration: PluginInstanceConfiguration? = nil) throws -> PluginInstanceConfiguration {
        let preference = preferences[pluginID] ?? PluginPreference(pluginID: pluginID)
        let config = configuration ?? PluginInstanceConfiguration(values: preference.configuration, schemaVersion: preference.schemaVersion)
        let descriptor = try permit(pluginID, configuration: config, kind: .dsp)
        guard descriptor.kinds.contains(.dsp) else { throw PluginError.unsupportedCapability }
        let placement = try descriptor.resolvedDSPPlacement(preference.dspPlacement)
        guard config.dspPlacement == nil || config.dspPlacement == placement else { throw PluginError.unsupportedCapability }
        return .init(instanceID: config.instanceID, values: config.values,
            credentialRecordID: config.credentialRecordID ?? preference.credentialRecordID,
            acceptedPolicyVersion: config.acceptedPolicyVersion ?? preference.acceptedPolicyVersion,
            schemaVersion: config.schemaVersion, dspPlacement: placement)
    }

    public func makeDSP(pluginID: PluginID, configuration: PluginInstanceConfiguration? = nil) throws -> any PluginDSPProcessor {
        do {
            let config = try dspConfiguration(pluginID: pluginID, configuration: configuration)
            guard let factory = registry.registrations[pluginID]?.dsp else { throw PluginError.unsupportedCapability }
            let processor = try factory(config)
            if let placement = config.dspPlacement {
                guard processor.behavior.scope.rawValue == placement.rawValue else { throw PluginError.unsupportedCapability }
            }
            diagnostics[pluginID] = nil
            return processor
        } catch {
            diagnostics[pluginID] = (error as? PluginError) ?? .requestFailed(code: "dsp_factory_failed")
            throw error
        }
    }

    private func permit(_ id: PluginID, configuration: PluginInstanceConfiguration?, kind: PluginKind? = nil, requiresEnabled: Bool = true) throws -> PluginDescriptor {
        guard !isStopped else { throw PluginError.unavailable }
        guard let registration = registry.registrations[id] else { throw PluginError.unavailable }
        let descriptor = registration.descriptor
        let preference = preferences[id] ?? PluginPreference(pluginID: id)
        guard !requiresEnabled || preference.isEnabled else { throw PluginError.disabled }
        guard preference.isLoadAllowed else { throw PluginError.loadBlocked }
        if descriptor.kinds.contains(.dsp) || preference.dspPlacement != nil {
            _ = try descriptor.resolvedDSPPlacement(preference.dspPlacement)
        }
        guard descriptor.permissions.isSubset(of: preference.grantedPermissions),
              descriptor.permissions.isEmpty || preference.acceptedPolicyVersion == descriptor.policyVersion,
              !descriptor.permissions.contains(.network) || applicationPrivacyAccepted else { throw PluginError.permissionRequired }
        guard preference.schemaVersion == descriptor.configuration.version else { throw PluginError.incompatible }
        try descriptor.configuration.validate(preference.configuration, credentialRecordID: preference.credentialRecordID)
        if let configuration {
            if kind == .onlineSource, let allowedSourceInstances,
               allowedSourceInstances[id]?.contains(configuration.instanceID) != true { throw PluginError.permissionRequired }
            if kind == .onlineSource, descriptor.permissions.contains(.network) {
                guard configuration.acceptedPolicyVersion == descriptor.policyVersion else { throw PluginError.permissionRequired }
            }
            let schema = kind == .onlineSource ? descriptor.sourceConfiguration : descriptor.configuration
            guard configuration.schemaVersion == schema.version else { throw PluginError.incompatible }
            try schema.validate(configuration.values, credentialRecordID: configuration.credentialRecordID)
        }
        return descriptor
    }

    private func acquire(_ key: Key, configuration: PluginInstanceConfiguration) async throws -> (LoadedPluginInstances, UInt64) {
        _ = try permit(key.pluginID, configuration: configuration, kind: key.kind)
        if let entry = entries[key], entry.configuration != configuration { invalidate(key) }
        if let entry = entries[key], let loaded = entry.loaded { return (loaded, entry.generation) }
        if entries[key]?.loading == nil {
            guard let registration = registry.registrations[key.pluginID] else { throw PluginError.unavailable }
            nextGeneration &+= 1
            let generation = nextGeneration
            let context = PluginLoadContext(operation: PluginOperationContext(pluginID: key.pluginID,
                instanceID: key.instanceID, generation: generation, permissions: registration.descriptor.permissions,
                applicationPrivacyAccepted: applicationPrivacyAccepted), configuration: configuration,
                credentials: registration.descriptor.permissions.contains(.credentials) ? credentials.map {
                    ScopedPluginCredentials(base: $0, pluginID: key.pluginID, instanceID: key.instanceID,
                        recordID: configuration.credentialRecordID)
                } : nil)
            let task = Task<LoadedPluginInstances, Error> {
                var loaded = LoadedPluginInstances()
                do {
                    try Task.checkCancellation()
                    if key.kind == .lyrics, let factory = registration.lyrics { loaded.lyrics = try await factory(context); try Task.checkCancellation() }
                    if key.kind == .metadata, let factory = registration.metadata { loaded.metadata = try await factory(context); try Task.checkCancellation() }
                    if key.kind == .onlineSource, let factory = registration.onlineSource {
                        let source = try await factory(context)
                        loaded.onlineSource = source
                        try Task.checkCancellation()
                        let capabilities = registration.descriptor.onlineCapabilities
                        guard !capabilities.contains(.browse) || source is any BrowsingSourcePlugin,
                              !capabilities.contains(.search) || source is any SearchingSourcePlugin,
                              !capabilities.contains(.download) || source is any DownloadSourcePlugin,
                              !capabilities.contains(.playbackAccess) || source is any PlaybackSourcePlugin,
                              !capabilities.contains(.refresh) || source is any RefreshingSourcePlugin else { throw PluginError.invalidRegistration }
                    }
                    return loaded
                } catch { await loaded.shutdown(); throw error }
            }
            entries[key] = Entry(generation: generation, configuration: configuration, loading: task, state: .loading)
        }
        guard let entry = entries[key], let loading = entry.loading else { throw PluginError.staleOperation }
        do {
            let loaded = try await loading.value
            try Task.checkCancellation()
            _ = try permit(key.pluginID, configuration: configuration, kind: key.kind)
            guard entries[key]?.generation == entry.generation else { throw PluginError.staleOperation }
            if entries[key]?.loaded == nil { entries[key]?.loaded = loaded; entries[key]?.loading = nil; entries[key]?.state = .ready }
            diagnostics[key.pluginID] = nil
            return (loaded, entry.generation)
        } catch {
            if entries[key]?.generation == entry.generation, !(error is CancellationError) {
                entries[key]?.loading = nil; entries[key]?.state = .failed
                diagnostics[key.pluginID] = (error as? PluginError) ?? .requestFailed(code: "plugin_load_failed")
            }
            throw error
        }
    }

    private func invalidate(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.loading?.cancel(); for cancel in entry.operations.values { cancel() }
        if let loaded = entry.loaded { Task { await loaded.shutdown() } }
        else if let loading = entry.loading { Task { if let loaded = try? await loading.value { await loaded.shutdown() } } }
    }
}

private struct ScopedPluginCredentials: PluginCredentialAccess {
    let base: any PluginCredentialAccess
    let pluginID: PluginID
    let instanceID: String
    let recordID: String?
    func read(recordID: String, pluginID: PluginID, instanceID: String) async throws -> Data? {
        guard pluginID == self.pluginID, instanceID == self.instanceID, recordID == self.recordID else { throw PluginError.permissionRequired }
        return try await base.read(recordID: recordID, pluginID: pluginID, instanceID: instanceID)
    }
}
