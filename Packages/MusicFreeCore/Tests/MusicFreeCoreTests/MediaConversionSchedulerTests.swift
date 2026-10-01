import AppServices
import Foundation
import MediaSourceAPI
import Testing

@Suite(.timeLimit(.minutes(1))) struct MediaConversionSchedulerTests {
    @Test func limitsConcurrentOperations() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .two)
        await scheduler.updatePlaybackIsPlaying(true)
        let probe = ConversionConcurrencyProbe()

        try await withThrowingTaskGroup(of: MediaTranscodeResult.self) { group in
            for index in 0..<6 {
                group.addTask {
                    try await scheduler.schedule {
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(40))
                        await probe.leave()
                        return Self.result(index)
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await probe.maximumActiveCount == 2)
    }

    @Test func loweringLimitLetsRunningOperationsFinishBeforeStartingMore() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .three)
        await scheduler.updatePlaybackIsPlaying(true)
        let probe = ConversionConcurrencyProbe()
        let releaseFirstWave = AsyncGate()

        let tasks = (0..<4).map { index in
            Task {
                try await scheduler.schedule {
                    let active = await probe.enter()
                    if active <= 3 {
                        await releaseFirstWave.wait()
                    }
                    await probe.leave()
                    return Self.result(index)
                }
            }
        }

        await probe.waitUntilActive(3)
        await scheduler.updateMaximumConcurrency(.one)
        await releaseFirstWave.open()

        for task in tasks {
            _ = try await task.value
        }
        #expect(await probe.maximumActiveCount == 3)
        #expect(await probe.activeCountsAtEntry == [1, 2, 3, 1])
    }

    @Test func cancellingAWaitingOperationDoesNotConsumeCapacity() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .one)
        await scheduler.updatePlaybackIsPlaying(true)
        let probe = ConversionConcurrencyProbe()
        let releaseRunning = AsyncGate()

        let running = Task {
            try await scheduler.schedule {
                await probe.enter()
                await releaseRunning.wait()
                await probe.leave()
                return Self.result(0)
            }
        }
        await probe.waitUntilActive(1)

        let waiting = Task {
            try await scheduler.schedule {
                Issue.record("A cancelled waiter must not start")
                return Self.result(1)
            }
        }
        waiting.cancel()

        await releaseRunning.open()
        _ = try await running.value
        await #expect(throws: CancellationError.self) {
            _ = try await waiting.value
        }

        let final = try await scheduler.schedule { Self.result(2) }
        #expect(final.processedFrames == 2)
    }

    @Test func backgroundCapsAdmissionAndRestoresLatestForegroundSetting() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .three)
        await scheduler.updatePlaybackIsPlaying(true)
        let probe = ConversionConcurrencyProbe()
        let release = AsyncGate()
        await scheduler.updateApplicationInBackground(true)

        let tasks = (0..<6).map { index in
            Task {
                try await scheduler.schedule {
                    await probe.enter()
                    await release.wait()
                    await probe.leave()
                    return Self.result(index)
                }
            }
        }
        await probe.waitUntilActive(1)
        await scheduler.updateMaximumConcurrency(.four)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await probe.activeCount == 1)

        await scheduler.updateApplicationInBackground(false)
        await probe.waitUntilActive(4)
        await release.open()
        for task in tasks { _ = try await task.value }
        #expect(await probe.maximumActiveCount == 4)
    }

    @Test func alreadyRunningConversionsPauseAndContinueSeriallyInBackground() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .three)
        await scheduler.updatePlaybackIsPlaying(true)
        let started = ConversionConcurrencyProbe()
        let passedCheckpoint = ConversionConcurrencyProbe()
        let firstRelease = AsyncGate()
        let checkpointTrigger = AsyncGate()
        let secondRelease = AsyncGate()

        let first = Task {
            try await scheduler.schedule {
                await started.enter()
                await firstRelease.wait()
                return Self.result(0)
            }
        }
        await started.waitUntilActive(1)
        let second = Task {
            try await scheduler.schedule {
                await started.enter()
                await checkpointTrigger.wait()
                try await MediaConversionExecution.waitUntilRunnable()
                await passedCheckpoint.enter()
                await secondRelease.wait()
                return Self.result(1)
            }
        }
        await started.waitUntilActive(2)
        let third = Task {
            try await scheduler.schedule {
                await started.enter()
                await checkpointTrigger.wait()
                try await MediaConversionExecution.waitUntilRunnable()
                await passedCheckpoint.enter()
                return Self.result(2)
            }
        }
        await started.waitUntilActive(3)
        await scheduler.updateApplicationInBackground(true)
        await checkpointTrigger.open()
        try await Task.sleep(for: .milliseconds(40))
        #expect(await passedCheckpoint.activeCount == 0)

        await firstRelease.open()
        _ = try await first.value
        await passedCheckpoint.waitUntilActive(1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await passedCheckpoint.activeCount == 1)
        await secondRelease.open()
        _ = try await second.value
        _ = try await third.value
        #expect(await passedCheckpoint.activeCount == 2)
    }

    @Test func foregroundResumesPausedConversionBeforeBackgroundConversionFinishes() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .two)
        await scheduler.updatePlaybackIsPlaying(true)
        let started = ConversionConcurrencyProbe()
        let releaseFirst = AsyncGate()
        let checkpointTrigger = AsyncGate()
        let first = Task {
            try await scheduler.schedule {
                await started.enter()
                await releaseFirst.wait()
                return Self.result(0)
            }
        }
        await started.waitUntilActive(1)
        let second = Task {
            try await scheduler.schedule {
                await started.enter()
                await checkpointTrigger.wait()
                try await MediaConversionExecution.waitUntilRunnable()
                return Self.result(1)
            }
        }
        await started.waitUntilActive(2)
        await scheduler.updateApplicationInBackground(true)
        await checkpointTrigger.open()
        await scheduler.updateApplicationInBackground(false)
        #expect(try await second.value.processedFrames == 1)
        await releaseFirst.open()
        _ = try await first.value
    }

    @Test func cancellingBackgroundPausedConversionReleasesItsSlot() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .two)
        await scheduler.updatePlaybackIsPlaying(true)
        let started = ConversionConcurrencyProbe()
        let releaseFirst = AsyncGate()
        let checkpointTrigger = AsyncGate()
        let first = Task {
            try await scheduler.schedule {
                await started.enter()
                await releaseFirst.wait()
                return Self.result(0)
            }
        }
        await started.waitUntilActive(1)
        let second = Task {
            try await scheduler.schedule {
                await started.enter()
                await checkpointTrigger.wait()
                try await MediaConversionExecution.waitUntilRunnable()
                Issue.record("A cancelled paused conversion must not continue")
                return Self.result(1)
            }
        }
        await started.waitUntilActive(2)
        await scheduler.updateApplicationInBackground(true)
        await checkpointTrigger.open()
        try await Task.sleep(for: .milliseconds(40))
        second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await second.value }

        await scheduler.updateApplicationInBackground(false)
        let next = try await scheduler.schedule { Self.result(2) }
        #expect(next.processedFrames == 2)
        await releaseFirst.open()
        _ = try await first.value
    }

    @Test func idlePlaybackBlocksAdmissionDespiteLifecycleAndSettingsChanges() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .one)
        let started = ConversionConcurrencyProbe()
        let release = AsyncGate()
        let tasks = (0..<2).map { index in
            Task {
                try await scheduler.schedule {
                    await started.enter()
                    await release.wait()
                    return Self.result(index)
                }
            }
        }

        await scheduler.updateApplicationInBackground(true)
        await scheduler.updateMaximumConcurrency(.two)
        await scheduler.updateApplicationInBackground(false)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await started.activeCount == 0)

        await scheduler.updatePlaybackIsPlaying(true)
        await started.waitUntilActive(2)
        await release.open()
        for task in tasks { _ = try await task.value }
    }

    @Test func playbackPauseSuspendsAllWorkersAndResumeRespectsBackgroundLimit() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .two)
        await scheduler.updatePlaybackIsPlaying(true)
        let started = ConversionConcurrencyProbe()
        let passedCheckpoint = ConversionConcurrencyProbe()
        let checkpointTrigger = AsyncGate()
        let release = AsyncGate()
        let tasks = (0..<2).map { index in
            Task {
                try await scheduler.schedule {
                    await started.enter()
                    await checkpointTrigger.wait()
                    try await MediaConversionExecution.waitUntilRunnable()
                    await passedCheckpoint.enter()
                    await release.wait()
                    return Self.result(index)
                }
            }
        }
        await started.waitUntilActive(2)

        await scheduler.updatePlaybackIsPlaying(false)
        await checkpointTrigger.open()
        await scheduler.updateApplicationInBackground(true)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await passedCheckpoint.activeCount == 0)

        await scheduler.updatePlaybackIsPlaying(true)
        await passedCheckpoint.waitUntilActive(1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await passedCheckpoint.activeCount == 1)

        await scheduler.updateApplicationInBackground(false)
        await passedCheckpoint.waitUntilActive(2)
        #expect(await started.activeCount == 2)
        await release.open()
        for task in tasks { _ = try await task.value }
    }

    @Test func cancellingPlaybackPausedWorkerAndWaiterDoesNotLeakCapacity() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .one)
        await scheduler.updatePlaybackIsPlaying(true)
        let started = ConversionConcurrencyProbe()
        let checkpointTrigger = AsyncGate()
        let running = Task {
            try await scheduler.schedule {
                await started.enter()
                await checkpointTrigger.wait()
                try await MediaConversionExecution.waitUntilRunnable()
                Issue.record("A cancelled playback-paused conversion must not continue")
                return Self.result(0)
            }
        }
        await started.waitUntilActive(1)
        await scheduler.updatePlaybackIsPlaying(false)
        await checkpointTrigger.open()
        let waiting = Task {
            try await scheduler.schedule {
                Issue.record("A cancelled playback-paused waiter must not start")
                return Self.result(1)
            }
        }
        try await Task.sleep(for: .milliseconds(40))
        running.cancel()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await running.value }
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }

        await scheduler.updatePlaybackIsPlaying(true)
        #expect(try await scheduler.schedule { Self.result(2) }.processedFrames == 2)
    }

    private static func result(_ index: Int) -> MediaTranscodeResult {
        MediaTranscodeResult(
            outputURL: URL(fileURLWithPath: "/media-conversion-scheduler-\(index).m4a"),
            target: .alac,
            processedFrames: Int64(index),
            sampleRate: 44_100,
            channelCount: 2,
            bitDepth: 16
        )
    }
}

private actor ConversionConcurrencyProbe {
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var activeCountsAtEntry: [Int] = []
    private var activeWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    @discardableResult
    func enter() -> Int {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        activeCountsAtEntry.append(activeCount)
        resumeActiveWaiters()
        return activeCount
    }

    func leave() {
        activeCount -= 1
    }

    func waitUntilActive(_ count: Int) async {
        if activeCount >= count { return }
        await withCheckedContinuation { continuation in
            activeWaiters.append((count, continuation))
        }
    }

    private func resumeActiveWaiters() {
        let ready = activeWaiters.filter { activeCount >= $0.count }
        activeWaiters.removeAll { activeCount >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}
