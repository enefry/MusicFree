import AVFoundation
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

@MainActor
@Suite(.serialized)
struct FFmpegRemoteControlLifecycleTests {
    @Test func preparationDoesNotStartSystemAudioOutput() async throws {
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }

        try await engine.prepare(makeItem(), startAt: nil)
        #expect(engine.state.phase == .preparing)
        #expect(!engine.audioEngine.isRunning)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!engine.audioEngine.isRunning)
    }

    @Test func pauseStopsOutputAndResumePreservesProgress() async throws {
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(makeItem(), startAt: nil)
        try engine.play()
        try await waitForProgress(engine, past: .milliseconds(250))

        engine.pause()
        let pausedPosition = engine.state.position
        #expect(engine.state.phase == .paused)
        #expect(!engine.audioEngine.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state.position == pausedPosition)
        #expect(!engine.audioEngine.isRunning)

        try engine.play()
        #expect(engine.audioEngine.isRunning)
        try await waitForProgress(engine, past: pausedPosition)
        #expect(engine.state.phase == .playing)
    }

    @Test func pausedSeekAndRouteRecoveryKeepOutputInactive() async throws {
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(makeItem(), startAt: nil)
        try engine.play()
        try await waitForProgress(engine, past: .milliseconds(250))
        engine.pause()

        try await engine.seek(to: .milliseconds(500))
        #expect(engine.state.phase == .paused)
        #expect(!engine.audioEngine.isRunning)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: engine.audioEngine
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state.phase == .paused)
        #expect(engine.state.position == .milliseconds(500))
        #expect(!engine.audioEngine.isRunning)

        try engine.play()
        try await waitForProgress(engine, past: .milliseconds(500))
        #expect(engine.audioEngine.isRunning)
    }

    @Test func naturalEndStopsOutputAndCanReplay() async throws {
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let range = PlaybackRange(start: .milliseconds(200), end: .milliseconds(550))
        try await engine.prepare(makeItem(range: range), startAt: nil)
        try engine.play()
        for _ in 0..<100 where engine.state.phase != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
        #expect(!engine.audioEngine.isRunning)

        try engine.play()
        #expect(engine.audioEngine.isRunning)
        #expect(engine.state.position == .zero)
        engine.stop()
        #expect(!engine.audioEngine.isRunning)
    }

    private func makeItem(range: PlaybackRange? = nil) -> PlaybackItem {
        PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "remote-control-lifecycle"),
            resource: .local(Bundle.module.bundleURL.appendingPathComponent("cue-seek-chirp.m4a")),
            selection: PlaybackSelection(range: range),
            displaySnapshot: PlaybackDisplaySnapshot(title: "Remote control lifecycle")
        )
    }

    private func waitForProgress(_ engine: FFmpegPlaybackEngine, past position: Duration) async throws {
        for _ in 0..<100 where engine.state.position <= position {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.state.position > position)
    }
}
