import AVFoundation
import Foundation
import MusicDomain
import MediaSourceAPI
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

@MainActor
@Suite(.serialized)
struct FFmpegPlaybackTransitionTests {
    @Test(arguments: [false, true], [false, true])
    func actualOfflineGraphHandoff(_ crossfade: Bool, _ useDSP: Bool) async throws {
        let aURL = try fixture("transition-a.wav", frequency: 330)
        let bURL = try fixture("transition-b.wav", frequency: 550)
        defer { try? FileManager.default.removeItem(at: aURL); try? FileManager.default.removeItem(at: bURL) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let counter = ProcessorCounter()
        if useDSP { try engine.setPCMProcessorFactory({ _ in counter.created(); return HalfGainProcessor(counter: counter) }, preservesTiming: true) }
        let a = item(aURL, id: "a"), b = item(bURL, id: "b")
        let commits = engine.makeTransitionStream()
        var received: [LogicalPlaybackCommit] = []
        var retired: [PlaybackTransitionRetirement] = []
        engine.setTransitionRetirementHandler { retired.append($0) }
        let observer = Task { for await commit in commits { received.append(commit) } }
        defer { observer.cancel() }
        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(
            mode: crossfade ? .crossfade : .gapless, crossfadeDuration: crossfade ? .milliseconds(100) : nil)))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        try await Task.sleep(for: .milliseconds(50))
        try engine.play()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var sum: Double = 0, peak: Float = 0, nonSilent = 0
        for _ in 0..<100 {
            let status = try engine.audioEngine.renderOffline(512, to: buffer)
            #expect(status == .success)
            if let data = buffer.floatChannelData {
                for i in 0..<Int(buffer.frameLength) {
                    let value = data[0][i]; sum += Double(value * value); peak = max(peak, abs(value))
                    if abs(value) > 0.001 { nonSilent += 1 }
                }
            }
            try await Task.sleep(for: .milliseconds(1))
            if engine.state.phase == .stopped { break }
        }
        #expect(sum > 10)
        #expect(nonSilent > 20000)
        #expect(peak <= (useDSP ? 0.251 : 0.501))
        #expect(received.count == 1)
        #expect(received.first?.ticket == ticket)
        #expect(received.first?.renderFrame == (crossfade ? 14400 : 19200))
        #expect(engine.state.itemID == b.itemID)
        #expect(retired.count == 1)
        #expect(retired.first?.renderFrame == 19200)
        #expect(retired.first?.playedDuration == .milliseconds(400))
        engine.hardStop()
        if useDSP {
            try await Task.sleep(for: .milliseconds(30))
            #expect(counter.counts.created == 2 && counter.counts.reset == 2)
        }
    }

    @Test func lowSampleRateLocalTracksCrossfadeWithoutSilence() async throws {
        let sampleRate = 8_000.0
        let aURL = try fixture("transition-low-rate-a.wav", frequency: 330, sampleRate: sampleRate)
        let bURL = try fixture("transition-low-rate-b.wav", frequency: 550, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: aURL); try? FileManager.default.removeItem(at: bURL) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let a = item(aURL, id: "low-rate-a"), b = item(bURL, id: "low-rate-b")
        let commits = engine.makeTransitionStream()
        var received: [LogicalPlaybackCommit] = []
        let observer = Task { for await commit in commits { received.append(commit) } }
        defer { observer.cancel() }

        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(
            mode: .crossfade, crossfadeDuration: .milliseconds(100))))
        let output = ContinuousOutputCapture()
        engine.audioEngine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 256,
            format: nil,
            block: makeContinuousOutputTap(output)
        )
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        try await Task.sleep(for: .milliseconds(50))
        try engine.play()
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            if engine.state.phase == .stopped { break }
        }

        let result = output.result
        print("low-rate crossfade signalFrames=\(result.signalFrames) longestInternalSilenceMs=\(result.longestInternalSilence * 1_000)")
        #expect(result.signalFrames > 1_000)
        #expect(result.longestInternalSilence < 0.01)
        #expect(received.count == 1)
        #expect(received.first?.ticket == ticket)
        #expect(received.first?.sampleRate == 48_000)
        #expect(received.first?.renderFrame == 14_400)
        #expect(engine.state.itemID == b.itemID && engine.state.phase == .stopped)
        engine.hardStop()
    }

    @Test(arguments: [false, true], [false, true])
    func consecutiveFormatChangesRebuildTheOutputChain(_ reversed: Bool, _ useEffect: Bool) async throws {
        var formats: [(Double, AVAudioChannelCount)] = [(8000, 1), (8000, 1), (16000, 1), (44100, 2), (96000, 2), (48000, 1)]
        if reversed { formats.reverse() }
        let urls = try formats.enumerated().map { index, format in
            try fixture("transition-reconfigure-\(reversed)-\(index).wav", frequency: 440,
                        sampleRate: format.0, channels: format.1)
        }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        // Keep this on the legacy feeder so EOF teardown still exercises
        // prepared-resource release across decoder format changes.
        try engine.setRate(1.5)
        if useEffect { try engine.setPostEqualizerEffect(AVAudioUnitEQ(numberOfBands: 0)) }
        for (index, url) in urls.enumerated() {
            print("format regression next sampleRate=\(formats[index].0) channels=\(formats[index].1) effect=\(useEffect)")
            try await engine.prepare(item(url, id: "format-\(index)"), startAt: nil)
            let output = FormatSwitchOutputCapture()
            engine.audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                                        block: makeFormatSwitchOutputTap(output))
            try engine.play()
            for _ in 0..<200 {
                try await Task.sleep(for: .milliseconds(10))
                if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            }
            engine.audioEngine.mainMixerNode.removeTap(onBus: 0)
            #expect(output.energy > 1)
            #expect(engine.state.phase == .stopped)
        }
    }

    @Test func softFadeAndHardControlDoNotRevive() async throws {
        let url = try fixture("transition-controls.wav", frequency: 440, duration: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(item(url, id: "controls"), startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(
            fadeInDuration: .milliseconds(80), fadeOutDuration: .milliseconds(120))))
        try engine.setVolume(0.4); try engine.setMuted(true); try engine.play()
        try await Task.sleep(for: .milliseconds(150))
        engine.pause()
        #expect(engine.state.phase == .paused)
        try engine.play() // a late fade completion must not pause the new intent
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.state.phase == .playing)
        #expect(engine.audioEngine.isRunning)
        #expect(engine.volume == 0.4 && engine.isMuted)
        engine.hardPause()
        #expect(!engine.audioEngine.isRunning)
        try engine.play(); engine.stop(); engine.hardStop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!engine.audioEngine.isRunning)
        #expect(engine.state.itemID == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func consecutiveSlotReusePreservesRetirements(_ crossfade: Bool, _ mixedFormats: Bool) async throws {
        let formats: [(Double, AVAudioChannelCount)] = mixedFormats
            ? [(8000, 1), (16000, 1), (44100, 2), (96000, 2)] : Array(repeating: (48000, 1), count: 4)
        let urls = try formats.enumerated().map { index, format in
            try fixture("transition-reuse-\(index).wav", frequency: Double(330 + index * 110),
                        sampleRate: format.0, channels: format.1)
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let items = urls.enumerated().map { item($0.element, id: "reuse-\($0.offset)") }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let counter = ProcessorCounter()
        try engine.setPCMProcessorFactory({ _ in counter.created(); return HalfGainProcessor(counter: counter) }, preservesTiming: true)
        try await engine.prepare(items[0], startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(
            mode: crossfade ? .crossfade : .gapless, crossfadeDuration: crossfade ? .milliseconds(100) : nil)))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        var commits: [LogicalPlaybackCommit] = [], retirements: [PlaybackTransitionRetirement] = []
        var preparations: [Task<Void, Error>] = []
        engine.setTransitionRetirementHandler { retirements.append($0) }
        func ticket() -> PlaybackTransitionTicket {
            PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
                generation: engine.state.generation, currentItemID: engine.state.itemID!, nextEntryID: UUID())
        }
        engine.setTransitionCommitHandler { commit in
            commits.append(commit)
            let nextIndex = commits.count + 1
            if nextIndex < items.count {
                let nextTicket = ticket()
                preparations.append(Task { try await engine.prepareNext(items[nextIndex], ticket: nextTicket) })
            }
        }
        try await engine.prepareNext(items[1], ticket: ticket())
        try engine.play()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        let output = ContinuousOutputCapture()
        for _ in 0..<350 {
            #expect(try engine.audioEngine.renderOffline(256, to: buffer) == .success)
            output.record(buffer)
            try await Task.sleep(for: .milliseconds(1))
            if engine.state.phase == .stopped { break }
        }
        for preparation in preparations { try await preparation.value }
        #expect(commits.map { $0.item.itemID } == Array(items.dropFirst()).map(\.itemID))
        #expect(retirements.count == 3)
        #expect(retirements.allSatisfy { $0.playedDuration == .milliseconds(400) && $0.reason == .ended })
        #expect(engine.state.itemID == items[3].itemID)
        #expect(output.result.signalFrames > 20_000)
        #expect(output.result.longestInternalSilence < 0.01)
        engine.hardStop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.counts.created == 4 && counter.counts.reset == 4)
        #expect(counter.counts.maximumLive <= 2)
    }

    @Test(arguments: [false, true], [3, 12])
    func compressedEOFSupportsFullTransitionWindow(_ crossfade: Bool, _ window: Int) async throws {
        let url = try fixture("transition-compressed.m4a", frequency: 440, duration: Double(2 * window + 1), sampleRate: 44100, channels: 2,
                              compressed: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let a = item(url, id: "compressed-a"), b = item(url, id: "compressed-b")
        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(
            mode: crossfade ? .crossfade : .gapless, crossfadeDuration: crossfade ? .seconds(window) : nil)))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        var commits: [LogicalPlaybackCommit] = [], retirements: [PlaybackTransitionRetirement] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        engine.setTransitionRetirementHandler { retirements.append($0) }
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        try engine.play()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let output = ContinuousOutputCapture()
        for _ in 0..<((4 * window + 3) * 100) {
            #expect(try engine.audioEngine.renderOffline(512, to: buffer) == .success)
            output.record(buffer)
            try await Task.sleep(for: .milliseconds(1))
            if engine.state.phase == .stopped { break }
        }
        #expect(engine.state.itemID == b.itemID && engine.state.phase == .stopped)
        #expect(commits.count == 1 && retirements.count == 1)
        let commit = try #require(commits.first), retirement = try #require(retirements.first)
        // Decoded EOF must retain the full selected window, including 12 seconds.
        #expect(abs(retirement.renderFrame - Int64((2 * window + 1) * 48_000)) <= 1)
        #expect(retirement.renderFrame - commit.renderFrame == (crossfade ? Int64(window * 48_000) : 0))
        #expect(output.result.signalFrames > 450_000)
        #expect(output.result.longestInternalSilence < 0.01)
        print("compressed EOF window=\(window) crossfade=\(crossfade) commit=\(commit.renderFrame) retirement=\(retirement.renderFrame) longestSilenceMs=\(output.result.longestInternalSilence * 1000)")
    }

    @Test(arguments: ["rate", "range", "format", "remote", "DSP-delay", "missing-file", "empty-file"])
    func unsupportedOrFailedNextLeavesCurrentPlayable(_ scenario: String) async throws {
        let url = try fixture("transition-fallback.wav", frequency: 440, duration: 2)
        // Mono/stereo rate changes are supported; a different multichannel
        // layout still requires a separate output configuration.
        let other = try fixture("transition-format.wav", frequency: 550, sampleRate: 44100, channels: 6)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: other) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let counter = ProcessorCounter()
        try engine.setPCMProcessorFactory({ _ in counter.created(); return HalfGainProcessor(counter: counter) },
                                          preservesTiming: scenario != "DSP-delay")
        var a = item(url, id: "fallback-a"), b = item(url, id: "fallback-b")
        if scenario == "range" {
            a = PlaybackItem(itemID: a.itemID, resource: a.resource,
                selection: PlaybackSelection(range: PlaybackRange(start: .zero, end: .seconds(1))), displaySnapshot: a.display)
        }
        if scenario == "format" { b = item(other, id: "fallback-b") }
        if scenario == "remote" {
            b = PlaybackItem(itemID: b.itemID, resource: .remote(RemotePlaybackRequest(url: URL(string: "https://example.invalid/audio.wav")!)), displaySnapshot: b.display)
        }
        if scenario == "missing-file" { b = item(url.deletingLastPathComponent().appendingPathComponent("missing-transition.wav"), id: "fallback-b") }
        if scenario == "empty-file" {
            let empty = try #require(Bundle.module.url(forResource: "tagged-metadata", withExtension: "flac"))
            b = item(empty, id: "fallback-b")
        }
        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(mode: .gapless)))
        if scenario == "rate" { try engine.setRate(2) }
        try engine.play()
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        await #expect(throws: (any Error).self) { try await engine.prepareNext(b, ticket: ticket) }
        engine.cancelNext()
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state.itemID == a.itemID)
        #expect(engine.state.phase == .playing)
        #expect(engine.audioEngine.isRunning)
        #expect(engine.state.position > .zero)
        if scenario == "empty-file" {
            // If B opened successfully but decoded no samples, its processor
            // must be released and A must remain the only live processor.
            #expect(counter.counts.created <= 2 && counter.counts.created - counter.counts.reset == 1)
        } else {
            #expect(counter.counts.created == 1) // rejection/cancellation must not rebuild A
        }
    }

    @Test(arguments: ["pause", "seek", "route"])
    func interruptedOverlapRetiresActualDurationWithoutRevivingOutgoing(_ control: String) async throws {
        let url = try fixture("transition-interrupt.wav", frequency: 440)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = item(url, id: "interrupt-a"), b = item(url, id: "interrupt-b")
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        var commits = 0, retired: [PlaybackTransitionRetirement] = []
        engine.setTransitionCommitHandler { _ in commits += 1 }
        engine.setTransitionRetirementHandler { retired.append($0) }
        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(mode: .crossfade, crossfadeDuration: .milliseconds(100))))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        try engine.play()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        for _ in 0..<15 { #expect(try engine.audioEngine.renderOffline(1024, to: buffer) == .success) }
        // Flush the render commit synchronously even if the polling task has
        // not delivered it yet, then cut the outgoing overlap immediately.
        switch control {
        case "seek": try await engine.seek(to: .milliseconds(50))
        case "route":
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine.audioEngine)
            try await Task.sleep(for: .milliseconds(30))
        default: engine.hardPause()
        }
        #expect(commits == 1)
        #expect(engine.state.itemID == b.itemID)
        #expect(engine.state.phase == (control == "pause" ? .paused : .playing))
        #expect(engine.audioEngine.isRunning == (control != "pause"))
        #expect(retired.count == 1)
        #expect(retired.first?.reason == .interrupted)
        let retirement = try #require(retired.first)
        // AVAudioEngine may pull source frames ahead of manual output frames.
        // Check the actual source-clock duration, bounded by the overlap.
        #expect(retirement.playedDuration > .milliseconds(300) && retirement.playedDuration < .milliseconds(400))
        #expect(retirement.playedDuration == .seconds(Double(retirement.renderFrame) / 48000))
        try await Task.sleep(for: .milliseconds(30))
        #expect(engine.state.itemID == b.itemID && commits == 1 && retired.count == 1)
    }

    @Test func variableRateSeekRestoresPlayerOutput() async throws {
        let url = try fixture("transition-rate-seek.wav", frequency: 440, duration: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(item(url, id: "rate-seek"), startAt: nil)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.play()
        try engine.setRate(1.5)
        try await engine.seek(to: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(80))
        #expect(engine.audioEngine.isRunning)
        #expect(try renderEnergy(engine, format: format, blocks: 40) > 1)
        #expect(engine.state.itemID?.externalID == "rate-seek")
    }

    @Test(arguments: [false, true], [Float(1), Float(1.5)])
    func zeroSeekAndReplayRewindDecoder(_ replay: Bool, _ rate: Float) async throws {
        let url = try fixture("transition-rewind-\(replay)-\(rate).wav", frequency: 440)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(item(url, id: "rewind"), startAt: nil)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.play()
        try engine.setRate(rate)
        // The short fixture fits in one ring, so the decoder has reached EOF
        // even while buffered audio remains available to render.
        try await Task.sleep(for: .milliseconds(60))
        _ = try renderEnergy(engine, format: format, blocks: replay ? 50 : 2)
        if replay {
            try await Task.sleep(for: .milliseconds(30))
            #expect(engine.state.phase == .stopped)
            try engine.play()
        } else {
            try await engine.seek(to: .zero)
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(try renderEnergy(engine, format: format, blocks: 10) > 1)
        #expect(engine.state.phase == .playing)
    }

    @Test(arguments: [false, true])
    func preparedNextDoesNotRebuildDuringSoftControl(_ stop: Bool) async throws {
        let url = try fixture("transition-soft-next-\(stop).wav", frequency: 440, duration: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let counter = ProcessorCounter()
        try engine.setPCMProcessorFactory({ _ in counter.created(); return HalfGainProcessor(counter: counter) }, preservesTiming: true)
        let a = item(url, id: "soft-a"), b = item(url, id: "soft-b")
        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(
            mode: .gapless, fadeOutDuration: .milliseconds(120))))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        try engine.play()
        _ = try renderEnergy(engine, format: format, blocks: 4)
        if stop { engine.stop() } else { engine.pause() }
        #expect(engine.audioEngine.isRunning)
        #expect(try renderEnergy(engine, format: format, blocks: 2) > 0.01)
        #expect(counter.counts.created == 2)
        try await Task.sleep(for: .milliseconds(450))
        #expect(!engine.audioEngine.isRunning)
        #expect(engine.state.phase == (stop ? .stopped : .paused))
    }

    @Test func restoringNormalRateReenablesTransitions() async throws {
        let url = try fixture("transition-restore-rate.wav", frequency: 440, duration: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let a = item(url, id: "restore-rate-a"), b = item(url, id: "restore-rate-b")
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(mode: .gapless), rate: 1.5))
        try await engine.prepare(a, startAt: nil)
        try engine.play()
        try await Task.sleep(for: .milliseconds(80))
        try engine.setRate(1)
        var commits: [LogicalPlaybackCommit] = []
        var retirements: [PlaybackTransitionRetirement] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        engine.setTransitionRetirementHandler { retirements.append($0) }
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        for _ in 0..<300 {
            if !commits.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(commits.count == 1 && commits.first?.ticket == ticket)
        #expect(engine.state.itemID == b.itemID && engine.audioEngine.isRunning)
        #expect(retirements.count == 1)
        #expect(retirements.first?.playedDuration ?? .zero >= .milliseconds(1990))
    }

    @Test func handoffRateSeekKeepsDecoderQueueOwnership() async throws {
        let aURL = try fixture("transition-queue-a.wav", frequency: 330)
        let bURL = try fixture("transition-queue-b.wav", frequency: 550, duration: 8)
        defer { try? FileManager.default.removeItem(at: aURL); try? FileManager.default.removeItem(at: bURL) }
        let engine = FFmpegPlaybackEngine()
        let barrier = ProcessorResetBarrier()
        defer { barrier.release(); engine.dispose() }
        try engine.setPCMProcessorFactory({ _ in
            let ordinal = barrier.created()
            return ResetBarrierProcessor(barrier: barrier, blocksReset: ordinal == 2)
        }, preservesTiming: true)
        let a = item(aURL, id: "queue-a"), b = item(bURL, id: "queue-b")
        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(mode: .gapless)))
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        try await engine.prepareNext(b, ticket: ticket)
        try engine.play()
        for _ in 0..<150 {
            if engine.state.itemID == b.itemID { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(engine.state.itemID == b.itemID)
        try engine.setRate(1.5)
        try await engine.seek(to: .milliseconds(100))
        for _ in 0..<100 {
            if barrier.isResetting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(barrier.isResetting)
        try await Task.sleep(for: .milliseconds(60))
        // The replacement cannot touch B until B's old serial owner has
        // finished releasing its processor. No decoder internals are mocked.
        #expect(barrier.creationCount == 2)
        barrier.release()
        let output = FormatSwitchOutputCapture()
        engine.audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil,
                                                    block: makeFormatSwitchOutputTap(output))
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(barrier.creationCount == 3)
        #expect(output.energy > 1 && engine.state.itemID == b.itemID)
    }

    @Test func routeRebuildInvalidatesAndRearmsTheSuccessor() async throws {
        let url = try fixture("transition-route-next.wav", frequency: 440, duration: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let a = item(url, id: "route-next-a"), b = item(url, id: "route-next-b")
        try await engine.prepare(a, startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(mode: .gapless)))
        let ticket = PlaybackTransitionTicket(sessionID: UUID(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: UUID())
        var invalidated: [PlaybackTransitionTicket] = []
        var commits: [LogicalPlaybackCommit] = []
        engine.setTransitionInvalidationHandler { value, reason in
            #expect(reason == .outputRebuilt)
            invalidated.append(value)
        }
        engine.setTransitionCommitHandler { commits.append($0) }
        try await engine.prepareNext(b, ticket: ticket)
        try engine.play()
        try await Task.sleep(for: .milliseconds(80))
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine.audioEngine)
        #expect(invalidated == [ticket])
        let replacement = PlaybackTransitionTicket(sessionID: ticket.sessionID, intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: ticket.nextEntryID)
        try await engine.prepareNext(b, ticket: replacement)
        for _ in 0..<300 {
            if !commits.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(commits.count == 1 && commits.first?.ticket == replacement)
        #expect(engine.state.itemID == b.itemID)
    }

    @Test func softFadeDeadlineAllowsOutputSchedulingDelay() async throws {
        let url = try fixture("transition-fade-deadline.wav", frequency: 440, duration: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(item(url, id: "fade-deadline"), startAt: nil)
        try engine.apply(AudioEffectConfiguration(transition: AudioTransitionConfiguration(fadeOutDuration: .milliseconds(120))))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.audioEngine.stop()
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.play()
        try await Task.sleep(for: .milliseconds(40))
        _ = try renderEnergy(engine, format: format, blocks: 4)
        engine.pause()
        // Delay output callbacks beyond the nominal fade duration. A wall
        // timer must allow render to complete the requested sample envelope.
        try await Task.sleep(for: .milliseconds(180))
        try #require(engine.audioEngine.isRunning)
        #expect(try renderEnergy(engine, format: format, blocks: 16) > 0.1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!engine.audioEngine.isRunning && engine.state.phase == .paused)
    }

    @Test(arguments: [false, true])
    func naturalEndPreservesFinalOutput(_ graph: Bool) async throws {
        let url = try fixture("transition-complete-output.wav", frequency: 440, duration: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let rate: Float = graph ? 1 : 1.5
        try engine.setRate(rate)
        try await engine.prepare(item(url, id: "complete-output"), startAt: nil)
        let output = ContinuousOutputCapture()
        engine.audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil,
                                                    block: makeContinuousOutputTap(output))
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }
        let started = ContinuousClock.now
        try engine.play()
        let latency = engine.audioEngine.attachedNodes.first(where: { $0 is AVAudioSourceNode })?.outputPresentationLatency
        for _ in 0..<250 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.state.phase == .stopped)
        let expected = 48_000 / Double(rate)
        let elapsed = started.duration(to: .now)
        print("complete output graph=\(graph) signalFrames=\(output.result.signalFrames) expected=\(expected) latency=\(latency ?? 0) elapsed=\(elapsed)")
        // Taps may withhold a final partial block, so their frame count alone
        // cannot prove lost audio. Realtime output cannot play the complete
        // signal faster than its duration divided by the configured rate.
        #expect(elapsed >= .seconds(1 / Double(rate)) - .milliseconds(10))
        #expect(output.result.signalFrames > 1_000)
    }

    private func renderEnergy(_ engine: FFmpegPlaybackEngine, format: AVAudioFormat, blocks: Int) throws -> Double {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var energy = 0.0
        for _ in 0..<blocks {
            #expect(try engine.audioEngine.renderOffline(512, to: buffer) == .success)
            if let data = buffer.floatChannelData {
                for i in 0..<Int(buffer.frameLength) { energy += Double(data[0][i] * data[0][i]) }
            }
        }
        return energy
    }

    private func item(_ url: URL, id: String) -> PlaybackItem {
        PlaybackItem(itemID: MediaItemID(sourceID: .local, externalID: id), resource: .localFile(url),
            displaySnapshot: PlaybackDisplaySnapshot(title: id))
    }
    private func fixture(_ name: String, frequency: Double, duration: Double = 0.4, sampleRate: Double = 48000, channels: AVAudioChannelCount = 1, compressed: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let layoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2
            ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | channels
        let layout = try #require(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        let frames = UInt32(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * frequency * 2 * .pi / sampleRate) * 0.5) }
        }
        let settings: [String: Any] = compressed
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 16] : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
}

private final class ProcessorResetBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var count = 0
    private var resetting = false
    func created() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var creationCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var isResetting: Bool { lock.lock(); defer { lock.unlock() }; return resetting }
    func blockReset() {
        lock.lock(); resetting = true; lock.unlock()
        _ = gate.wait(timeout: .now() + 3)
    }
    func release() { gate.signal() }
}

private final class ResetBarrierProcessor: FFmpegPCMProcessing {
    let barrier: ProcessorResetBarrier
    let blocksReset: Bool
    init(barrier: ProcessorResetBarrier, blocksReset: Bool) { self.barrier = barrier; self.blocksReset = blocksReset }
    func process(_ buffer: AVAudioPCMBuffer) throws {}
    func reset() { if blocksReset { barrier.blockReset() } }
}

private final class ProcessorCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var createdCount = 0
    private var resetCount = 0
    private var maximumLive = 0
    func created() { lock.lock(); createdCount += 1; maximumLive = max(maximumLive, createdCount - resetCount); lock.unlock() }
    func reset() { lock.lock(); resetCount += 1; lock.unlock() }
    var counts: (created: Int, reset: Int, maximumLive: Int) { lock.lock(); defer { lock.unlock() }; return (createdCount, resetCount, maximumLive) }
}
private final class HalfGainProcessor: FFmpegPCMProcessing {
    let counter: ProcessorCounter
    init(counter: ProcessorCounter) { self.counter = counter }
    func process(_ buffer: AVAudioPCMBuffer) throws {
        guard let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { data[channel][frame] *= 0.5 }
        }
    }
    func reset() { counter.reset() }
}

private final class FormatSwitchOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0.0
    var energy: Double { lock.lock(); defer { lock.unlock() }; return sum }
    func record(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        var value = 0.0
        for frame in 0..<Int(buffer.frameLength) { value += Double(samples[frame] * samples[frame]) }
        lock.lock(); sum += value; lock.unlock()
    }
}

private func makeFormatSwitchOutputTap(_ output: FormatSwitchOutputCapture) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in output.record(buffer) }
}

private final class ContinuousOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var activeFrames: [Bool] = []
    private var sampleRate = 0.0

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData else { return }
        var activity = [Bool](repeating: false, count: Int(buffer.frameLength))
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<Int(buffer.format.channelCount) where abs(samples[channel][frame]) > 0.0001 {
                activity[frame] = true
                break
            }
        }
        lock.lock()
        sampleRate = buffer.format.sampleRate
        activeFrames.append(contentsOf: activity)
        lock.unlock()
    }

    var result: (signalFrames: Int, longestInternalSilence: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard sampleRate > 0,
              let first = activeFrames.firstIndex(of: true),
              let last = activeFrames.lastIndex(of: true)
        else { return (0, .infinity) }
        var signalFrames = 0
        var silentRun = 0
        var longestSilentRun = 0
        for active in activeFrames[first...last] {
            if active {
                signalFrames += 1
                silentRun = 0
            } else {
                silentRun += 1
                longestSilentRun = max(longestSilentRun, silentRun)
            }
        }
        return (signalFrames, Double(longestSilentRun) / sampleRate)
    }
}

private func makeContinuousOutputTap(_ output: ContinuousOutputCapture) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in output.record(buffer) }
}
