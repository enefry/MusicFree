import Foundation
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

@available(macOS 13.0, iOS 16.0, *)
internal actor SettingsCoordinator: SettingsServing {
    private enum Mutation: Sendable {
        case save(AppSettings)
        case reset
    }

    private let repository: (any SettingsRepository)?
    private var cachedSettings: AppSettings?
    private var playbackCapabilities: PlaybackCapabilities
    private let equalizerDescriptor: EqualizerDescriptor?
    private var systemCapabilities: SystemIntegrationCapabilitySnapshot
    private var mutationTask: (id: UUID, task: Task<Void, Error>)?
    private var changeContinuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]
    private var effectiveContinuations:
        [UUID: AsyncStream<EffectivePlaybackSettings>.Continuation] = [:]

    init(
        repository: (any SettingsRepository)?,
        playbackCapabilities: PlaybackCapabilities,
        equalizerDescriptor: EqualizerDescriptor?,
        systemCapabilities: SystemIntegrationCapabilitySnapshot
    ) {
        self.repository = repository
        self.playbackCapabilities = playbackCapabilities
        self.equalizerDescriptor = equalizerDescriptor
        self.systemCapabilities = systemCapabilities
    }

    func load() async throws -> AppSettings {
        guard let repository else {
            throw AppServiceError.missingDependency("settingsRepository")
        }
        do {
            let settings = try await repository.load().validated()
            cachedSettings = settings
            return settings
        } catch {
            throw AppServiceError.mapped(error, operation: "settings.load")
        }
    }

    func update(_ settings: AppSettings) async throws {
        guard let repository else {
            throw AppServiceError.missingDependency("settingsRepository")
        }
        let validated: AppSettings
        do {
            validated = try settings.validated()
        } catch {
            throw AppServiceError.mapped(error, operation: "settings.validate")
        }

        do {
            try await enqueue(.save(validated), repository: repository)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppServiceError.mapped(error, operation: "settings.save")
        }
    }

    func reset() async throws {
        guard let repository else {
            throw AppServiceError.missingDependency("settingsRepository")
        }
        do {
            try await enqueue(.reset, repository: repository)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppServiceError.mapped(error, operation: "settings.reset")
        }
    }

    func effective() async throws -> EffectivePlaybackSettings {
        let settings = try await currentSettings()
        return makeEffective(for: settings)
    }

    func makeChangeStream() async -> AsyncStream<AppSettings> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AppSettings>.makeStream()
        install(continuation, for: id)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeSettingsSubscription(id)
            }
        }
        return stream
    }

    func makeEffectiveChangeStream() async -> AsyncStream<EffectivePlaybackSettings> {
        let id = UUID()
        let (stream, continuation) =
            AsyncStream<EffectivePlaybackSettings>.makeStream()
        installEffective(continuation, for: id)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeEffectiveSubscription(id)
            }
        }
        return stream
    }

    func updatePlaybackCapabilities(_ capabilities: PlaybackCapabilities) async {
        playbackCapabilities = capabilities
        if let cachedSettings {
            publishEffective(for: cachedSettings)
        }
    }

    func updateSystemCapabilities(_ capabilities: SystemIntegrationCapabilitySnapshot) async {
        systemCapabilities = capabilities
        if let cachedSettings {
            publishEffective(for: cachedSettings)
        }
    }

    func currentPlaybackCapabilities() -> PlaybackCapabilities {
        playbackCapabilities
    }

    func currentSystemCapabilities() -> SystemIntegrationCapabilitySnapshot {
        systemCapabilities
    }

    private func currentSettings() async throws -> AppSettings {
        if let cachedSettings { return cachedSettings }
        return try await load()
    }

    private func enqueue(
        _ mutation: Mutation,
        repository: any SettingsRepository
    ) async throws {
        let predecessor = mutationTask?.task
        let mutationID = UUID()
        let task = Task { [weak self] in
            if let predecessor {
                _ = await predecessor.result
            }
            try Task.checkCancellation()

            let committed: AppSettings
            switch mutation {
            case .save(let settings):
                try await repository.save(settings)
                committed = settings
            case .reset:
                try await repository.reset()
                committed = .defaults
            }

            guard let self else { throw CancellationError() }
            await self.commitMutation(committed)
        }
        mutationTask = (mutationID, task)

        do {
            try await task.value
            if mutationTask?.id == mutationID {
                mutationTask = nil
            }
        } catch {
            if mutationTask?.id == mutationID {
                mutationTask = nil
            }
            throw error
        }
    }

    private func commitMutation(_ settings: AppSettings) {
        cachedSettings = settings
        publish(settings)
        publishEffective(for: settings)
    }

    private func makeEffective(for settings: AppSettings) -> EffectivePlaybackSettings {
        let preferences = settings.playbackPreferences
        let rate: Float = playbackCapabilities.contains(.variableRate)
            ? Float(preferences.rate.value)
            : 1

        let equalizer: EqualizerConfiguration?
        if playbackCapabilities.contains(.equalizer),
           let equalizerDescriptor,
           preferences.equalizer.isEnabled {
            let savedBands = Dictionary(
                uniqueKeysWithValues: preferences.equalizer.bands.map {
                    ($0.frequencyHz, Float($0.gain.decibels))
                }
            )
            equalizer = EqualizerConfiguration(
                preampDecibels: Float(preferences.equalizer.preamp.decibels),
                bandGains: equalizerDescriptor.bands.map {
                    EqualizerBandGain(
                        centerFrequencyHz: $0.centerFrequencyHz,
                        gainDecibels: savedBands[Int($0.centerFrequencyHz.rounded())] ?? 0
                    )
                }
            )
        } else {
            equalizer = nil
        }

        let replayGainMode: PlaybackAPI.ReplayGainMode
        if playbackCapabilities.contains(.replayGain) {
            switch preferences.replayGain {
            case .off:
                replayGainMode = .disabled
            case .track:
                replayGainMode = .track
            case .album:
                replayGainMode = .album
            }
        } else {
            replayGainMode = .disabled
        }

        let transition: AudioTransitionConfiguration
        if preferences.transition.isCrossfadeEnabled,
           playbackCapabilities.contains(.crossfade),
           preferences.transition.crossfadeDuration > .zero {
            transition = AudioTransitionConfiguration(
                mode: .crossfade,
                crossfadeDuration: preferences.transition.crossfadeDuration
            )
        } else if preferences.transition.gaplessPlaybackEnabled,
                  playbackCapabilities.contains(.gapless) {
            transition = AudioTransitionConfiguration(mode: .gapless)
        } else {
            transition = .disabled
        }

        let effects = AudioEffectConfiguration(
            equalizer: equalizer,
            replayGain: ReplayGainConfiguration(mode: replayGainMode),
            transition: transition,
            rate: rate
        )
        return EffectivePlaybackSettings(
            settings: settings,
            effects: effects,
            playbackCapabilities: playbackCapabilities,
            equalizerDescriptor: equalizerDescriptor,
            systemCapabilities: systemCapabilities
        )
    }

    private func publish(_ settings: AppSettings) {
        for continuation in changeContinuations.values {
            continuation.yield(settings)
        }
    }

    private func publishEffective(for settings: AppSettings) {
        let effective = makeEffective(for: settings)
        for continuation in effectiveContinuations.values {
            continuation.yield(effective)
        }
    }

    private func install(
        _ continuation: AsyncStream<AppSettings>.Continuation,
        for id: UUID
    ) {
        changeContinuations[id] = continuation
    }

    private func installEffective(
        _ continuation: AsyncStream<EffectivePlaybackSettings>.Continuation,
        for id: UUID
    ) {
        effectiveContinuations[id] = continuation
    }

    private func removeSettingsSubscription(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    private func removeEffectiveSubscription(_ id: UUID) {
        effectiveContinuations.removeValue(forKey: id)
    }
}
