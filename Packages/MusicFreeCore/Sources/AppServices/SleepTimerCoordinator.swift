import Foundation
import PlaybackAPI
import SettingsAPI

public enum SleepTimerSource: Equatable, Hashable, Sendable {
    case oneTime
    case automatic(scheduleIDs: [UUID])
}

public struct SleepTimerSnapshot: Equatable, Hashable, Sendable {
    public let startedAt: Date?
    public let deadline: Date?
    public let durationMinutes: Int?
    public let source: SleepTimerSource?

    public init(
        startedAt: Date? = nil,
        deadline: Date? = nil,
        durationMinutes: Int? = nil,
        source: SleepTimerSource? = nil
    ) {
        self.startedAt = startedAt
        self.deadline = deadline
        self.durationMinutes = durationMinutes
        self.source = source
    }

    public static let inactive = Self()

    public var isActive: Bool {
        deadline != nil
    }
}

@MainActor
public protocol SleepTimerServing: AnyObject {
    var snapshot: SleepTimerSnapshot { get }
    func makeSnapshotStream() -> AsyncStream<SleepTimerSnapshot>
    func startOneTime(durationMinutes: Int)
    func cancel()
}

@MainActor
final class SleepTimerCoordinator: SleepTimerServing {
    private let playback: any PlaybackServing
    private let clock: any AppClock
    private let calendar: Calendar

    private var preferences: SleepTimerPreferences = .defaults
    private var snapshotValue: SleepTimerSnapshot = .inactive
    private var playbackPhase: PlaybackPhase?
    private var timerID: UUID?
    private var timerTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SleepTimerSnapshot>.Continuation] = [:]

    init(playback: any PlaybackServing, clock: any AppClock, calendar: Calendar) {
        self.playback = playback
        self.clock = clock
        self.calendar = calendar
    }

    var snapshot: SleepTimerSnapshot {
        snapshotValue
    }

    func makeSnapshotStream() -> AsyncStream<SleepTimerSnapshot> {
        let subscriptionID = UUID()
        return AsyncStream { continuation in
            continuations[subscriptionID] = continuation
            continuation.yield(snapshotValue)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: subscriptionID)
                }
            }
        }
    }

    func start(preferences: SleepTimerPreferences) {
        self.preferences = preferences
        guard playbackTask == nil else { return }

        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = playback.makeSnapshotStream()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await handlePlaybackSnapshot(snapshot)
            }
        }
    }

    func update(preferences: SleepTimerPreferences) async {
        guard self.preferences != preferences else { return }
        self.preferences = preferences
        guard playback.snapshot.phase == .playing else { return }

        switch snapshotValue.source {
        case .oneTime:
            return
        case .automatic, nil:
            let now = await clock.now()
            activateAutomaticTimerIfNeeded(at: now)
        }
    }

    func startOneTime(durationMinutes: Int) {
        guard (SleepTimerSchedule.minimumDurationMinutes...SleepTimerSchedule.maximumDurationMinutes)
            .contains(durationMinutes)
        else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            activate(
                durationMinutes: durationMinutes,
                source: .oneTime,
                startedAt: await clock.now()
            )
        }
    }

    func cancel() {
        cancelTimer(publish: true)
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        cancelTimer(publish: false)
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func handlePlaybackSnapshot(_ snapshot: PlaybackSessionSnapshot) async {
        let enteredPlaying = snapshot.phase == .playing && playbackPhase != .playing
        playbackPhase = snapshot.phase
        guard enteredPlaying, !snapshotValue.isActive else { return }
        let now = await clock.now()
        activateAutomaticTimerIfNeeded(at: now)
    }

    private func activateAutomaticTimerIfNeeded(at date: Date) {
        let activeSchedules = preferences.activeSchedules(at: date, calendar: calendar)
        guard let durationMinutes = activeSchedules.map(\.durationMinutes).min() else {
            if case .automatic = snapshotValue.source {
                cancelTimer(publish: true)
            }
            return
        }
        let selectedIDs = activeSchedules
            .filter { $0.durationMinutes == durationMinutes }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        activate(
            durationMinutes: durationMinutes,
            source: .automatic(scheduleIDs: selectedIDs),
            startedAt: date
        )
    }

    private func activate(
        durationMinutes: Int,
        source: SleepTimerSource,
        startedAt: Date
    ) {
        timerTask?.cancel()
        let timerID = UUID()
        let duration = Duration.seconds(durationMinutes * 60)
        self.timerID = timerID
        snapshotValue = SleepTimerSnapshot(
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            durationMinutes: durationMinutes,
            source: source
        )
        publishSnapshot()

        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(for: duration)
                guard !Task.isCancelled, self.timerID == timerID else { return }
                self.timerID = nil
                self.timerTask = nil
                self.snapshotValue = .inactive
                self.publishSnapshot()

                let phase = playback.snapshot.phase
                if phase == .playing || phase == .buffering || phase == .preparing {
                    await playback.send(.pause)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.timerID == timerID else { return }
                self.timerID = nil
                self.timerTask = nil
                self.snapshotValue = .inactive
                self.publishSnapshot()
            }
        }
    }

    private func cancelTimer(publish: Bool) {
        timerID = nil
        timerTask?.cancel()
        timerTask = nil
        snapshotValue = .inactive
        if publish {
            publishSnapshot()
        }
    }

    private func publishSnapshot() {
        for continuation in continuations.values {
            continuation.yield(snapshotValue)
        }
    }

    deinit {
        playbackTask?.cancel()
        timerTask?.cancel()
    }
}
