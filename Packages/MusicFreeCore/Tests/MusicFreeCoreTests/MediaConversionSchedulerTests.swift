import AppServices
import Foundation
import MediaSourceAPI
import Testing

@Suite struct MediaConversionSchedulerTests {
    @Test func limitsConcurrentOperations() async throws {
        let scheduler = MediaConversionScheduler(maximumConcurrency: .two)
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
