import AVFoundation
import FFmpegAudioKit
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

@MainActor
@Suite(.serialized)
struct FFmpegSilenceSkippingTests {
    @Test(arguments: [false, true])
    func boundaryAnalysisUsesAllChannelsAndPreservesQuietMusic(_ compressed: Bool) throws {
        let url = try fixture(compressed: compressed)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try FFmpegAudioDecoder(localFileURL: url)
        let boundaries = try FFmpegSilenceBoundaries.analyze(decoder)
        #expect(abs(Double(boundaries.startFrame) / 48_000 - 0.38) < 0.01)
        #expect(abs(Double(try #require(boundaries.endFrame)) / 48_000 - 1.42) < 0.01)
        // The audible material lives only on the right channel, at -74 dB.
        // Its 400 ms internal silence must remain inside the playable range.
        #expect(Double(try #require(boundaries.endFrame) - boundaries.startFrame) / 48_000 > 1)
    }

    @Test func entirelySilentFilesStayPlayable() throws {
        let url = try fixture(silent: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let boundaries = try FFmpegSilenceBoundaries.analyze(FFmpegAudioDecoder(localFileURL: url))
        #expect(boundaries.startFrame == 0 && boundaries.endFrame == nil)
    }

    @Test func longBoundariesAndCancellation() throws {
        let url = try fixture(leading: 31, trailing: 32, sampleRate: 8000)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try FFmpegAudioDecoder(localFileURL: url)
        let boundaries = try FFmpegSilenceBoundaries.analyze(decoder)
        print("LONG_BOUNDARIES rate=\(decoder.format.sampleRate) duration=\(String(describing: decoder.duration)) start=\(boundaries.startFrame) end=\(String(describing: boundaries.endFrame))")
        #expect(abs(Double(boundaries.startFrame) / 8000 - 30.98) < 0.01)
        #expect(abs(Double(try #require(boundaries.endFrame)) / 8000 - 32.02) < 0.01)
        #expect(throws: CancellationError.self) {
            _ = try FFmpegSilenceBoundaries.analyze(decoder, isCancelled: { true })
        }
    }

    @Test(arguments: [false, true], [false, true])
    func actualMixerSkipsOnlyBoundaries(_ enabled: Bool, _ crossfade: Bool) async throws {
        let url = try fixture(amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let a = item(url, id: "silence-a"), b = item(url, id: "silence-b")
        try engine.apply(.init(transition: .init(mode: crossfade ? .crossfade : .gapless,
            crossfadeDuration: crossfade ? .milliseconds(100) : nil, skipBoundarySilence: enabled)))
        try await engine.prepare(a, startAt: nil)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        var commits: [LogicalPlaybackCommit] = [], retirements: [PlaybackTransitionRetirement] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        engine.setTransitionRetirementHandler { retirements.append($0) }
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        try engine.play()
        try await Task.sleep(for: .milliseconds(100))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        var internalSilence = 0, longestSilence = 0, heardAudio = false
        for _ in 0..<500 {
            guard engine.audioEngine.isRunning else { break }
            #expect(try engine.audioEngine.renderOffline(480, to: buffer) == .success)
            let data = try #require(buffer.floatChannelData)
            let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(data[1][$1])) }
            if peak > 0.01 {
                heardAudio = true
                longestSilence = max(longestSilence, internalSilence)
                internalSilence = 0
            } else if heardAudio { internalSilence += Int(buffer.frameLength) }
            try await Task.sleep(for: .milliseconds(1))
            if engine.state.phase == .stopped { break }
        }
        let retirement = try #require(retirements.first), commit = try #require(commits.first)
        let expectedLength: Int64 = enabled ? 49_920 : 96_000
        #expect(abs(retirement.renderFrame - expectedLength) <= 4)
        #expect(retirement.renderFrame - commit.renderFrame == (crossfade ? 4800 : 0))
        #expect(commits.count == 1 && retirements.count == 1)
        #expect(engine.state.itemID == b.itemID && engine.state.phase == .stopped)
        #expect(abs(seconds(retirement.playedDuration) - Double(expectedLength) / 48_000) < 0.001)
        #expect(longestSilence >= 18_000) // Preserve the musical pause.
        if enabled { #expect(longestSilence < 21_000) } // No one-second boundary gap.
        print("SILENCE_SKIP enabled=\(enabled) crossfade=\(crossfade) commit=\(commit.renderFrame) retirement=\(retirement.renderFrame) internalSilence=\(longestSilence)")
    }

    @Test func seekingIntoMusicalPauseKeepsRequestedPosition() async throws {
        let url = try fixture(amplitude: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.apply(.init(transition: .init(skipBoundarySilence: true)))
        try await engine.prepare(item(url, id: "silence-seek"), startAt: .milliseconds(800))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        try engine.play()
        try await Task.sleep(for: .milliseconds(100))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        for _ in 0..<8 {
            #expect(try engine.audioEngine.renderOffline(480, to: buffer) == .success)
        }
        engine.hardPause()
        #expect(engine.state.position >= .milliseconds(800) && engine.state.position < .milliseconds(1050))
    }

    private func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }

    private func item(_ url: URL, id: String) -> PlaybackItem {
        PlaybackItem(itemID: MediaItemID(sourceID: .local, externalID: id), resource: .localFile(url),
            displaySnapshot: PlaybackDisplaySnapshot(title: id, duration: .seconds(2)))
    }

    private func fixture(compressed: Bool = false, silent: Bool = false, amplitude: Float = 0.0002,
                         leading: Double = 0.4, trailing: Double = 0.6, sampleRate: Double = 48_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-boundaries-\(UUID().uuidString).\(compressed ? "m4a" : "wav")")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let settings: [String: Any] = compressed
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = Int((leading + 1 + trailing) * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            data[0][frame] = 0
            let time = Double(frame) / sampleRate - leading
            let audible = !silent && ((0..<0.3).contains(time) || (0.7..<1).contains(time))
            data[1][frame] = audible ? amplitude * Float(sin(Double(frame) * 2 * .pi / 48)) : 0
        }
        try file.write(from: buffer)
        return url
    }
}
