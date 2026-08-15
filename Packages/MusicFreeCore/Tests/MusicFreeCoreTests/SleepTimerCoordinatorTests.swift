@testable import AppServices
import Foundation
import PlaybackAPI
import SettingsAPI
import Testing

@MainActor
@Test("Overlapping automatic sleep schedules use the shortest timer and pause playback")
func automaticSleepTimerUsesShortestActiveSchedule() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let startDate = calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 14,
        hour: 23,
        minute: 45
    ))!
    let clock = SleepTimerTestClock(startDate: startDate)
    let playback = SleepTimerPlaybackSpy()
    let shorterID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let preferences = try SleepTimerPreferences(schedules: [
        SleepTimerSchedule(
            startMinute: 23 * 60,
            endMinute: 5 * 60,
            durationMinutes: 30
        ),
        SleepTimerSchedule(
            id: shorterID,
            startMinute: 23 * 60 + 30,
            endMinute: 1 * 60,
            durationMinutes: 20
        ),
    ])
    let coordinator = SleepTimerCoordinator(
        playback: playback,
        clock: clock,
        calendar: calendar
    )

    coordinator.start(preferences: preferences)
    playback.publish(phase: .playing)

    let didActivate = await waitForSleepTimerCondition {
        let pendingSleepCount = await clock.pendingSleepCount()
        return coordinator.snapshot.durationMinutes == 20
            && coordinator.snapshot.source == .automatic(scheduleIDs: [shorterID])
            && pendingSleepCount == 1
    }
    #expect(didActivate)

    await clock.advance(by: .seconds(20 * 60))

    let didExpire = await waitForSleepTimerCondition {
        playback.commands == [.pause]
            && playback.snapshot.phase == .paused
            && coordinator.snapshot == .inactive
    }
    #expect(didExpire)
    coordinator.stop()
}

@MainActor
@Test("A one-time sleep timer overrides an active automatic timer")
func oneTimeSleepTimerOverridesAutomaticTimer() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let startDate = calendar.date(from: DateComponents(
        year: 2026,
        month: 8,
        day: 14,
        hour: 23,
        minute: 45
    ))!
    let clock = SleepTimerTestClock(startDate: startDate)
    let playback = SleepTimerPlaybackSpy()
    let preferences = try SleepTimerPreferences(schedules: [
        SleepTimerSchedule(
            startMinute: 23 * 60,
            endMinute: 5 * 60,
            durationMinutes: 20
        ),
    ])
    let coordinator = SleepTimerCoordinator(
        playback: playback,
        clock: clock,
        calendar: calendar
    )

    coordinator.start(preferences: preferences)
    playback.publish(phase: .playing)
    let didActivateAutomatically = await waitForSleepTimerCondition {
        let pendingSleepCount = await clock.pendingSleepCount()
        return coordinator.snapshot.durationMinutes == 20
            && pendingSleepCount == 1
    }
    #expect(didActivateAutomatically)

    coordinator.startOneTime(durationMinutes: 35)
    let didOverride = await waitForSleepTimerCondition {
        let pendingSleepCount = await clock.pendingSleepCount()
        return coordinator.snapshot.durationMinutes == 35
            && coordinator.snapshot.source == .oneTime
            && pendingSleepCount == 1
    }
    #expect(didOverride)
    coordinator.stop()
}

@MainActor
private final class SleepTimerPlaybackSpy: PlaybackServing {
    private(set) var snapshot = PlaybackSessionSnapshot()
    private(set) var commands: [PlaybackSessionCommand] = []
    private var continuations: [UUID: AsyncStream<PlaybackSessionSnapshot>.Continuation] = [:]

    func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    func send(_ command: PlaybackSessionCommand) async {
        commands.append(command)
        if command == .pause {
            publish(phase: .paused)
        }
    }

    func execute(_ command: PlaybackSessionCommand) async throws {
        await send(command)
    }

    func publish(phase: PlaybackPhase) {
        snapshot = PlaybackSessionSnapshot(
            state: PlaybackState(
                phase: phase,
                generation: .initial
            )
        )
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}

private actor SleepTimerTestClock: AppClock {
    private struct PendingSleep {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var currentDate: Date
    private var pendingSleeps: [UUID: PendingSleep] = [:]

    init(startDate: Date) {
        currentDate = startDate
    }

    func now() -> Date {
        currentDate
    }

    func pendingSleepCount() -> Int {
        pendingSleeps.count
    }

    func advance(by duration: Duration) {
        currentDate = currentDate.addingTimeInterval(duration.timeInterval)
        let ready = pendingSleeps.filter { $0.value.deadline <= currentDate }
        for (id, pending) in ready {
            pendingSleeps.removeValue(forKey: id)
            pending.continuation.resume()
        }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let deadline = currentDate.addingTimeInterval(duration.timeInterval)
        guard deadline > currentDate else { return }
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pendingSleeps[id] = PendingSleep(
                        deadline: deadline,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelSleep(id) }
        }
    }

    private func cancelSleep(_ id: UUID) {
        guard let pending = pendingSleeps.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private func waitForSleepTimerCondition(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
