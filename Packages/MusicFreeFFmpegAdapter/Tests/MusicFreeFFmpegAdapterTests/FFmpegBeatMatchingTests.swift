import AVFoundation
import Foundation
import MusicDomain
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

@Suite struct FFmpegTransitionTempoTests {
    @Test(arguments: [0.94, 0.96, 1.0, 1.04, 1.06])
    func independentStretchersPreservePitchStereoAndTheOriginalTail(_ rate: Double) throws {
        let sampleRate = 48_000.0, frames = 12 * 48_000
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let tempo = FFmpegTransitionTempo(rate: rate, hold: 4, recovery: 3)
        let stretcher = FFmpegTransitionTimeStretcher(format: format, sourceFrames: Int64(frames), tempo: tempo)
        let source = (0..<frames).map { i in
            i >= frames - 4800 ? Float(0.123) : Float(0.3 * sin(2 * .pi * 440 * Double(i) / sampleRate))
        }
        var offset = 0, output: [Float] = [], phaseError: Float = 0, peak: Float = 0
        var finite = true
        while let pcm = try stretcher.nextBuffer(read: {
            guard offset < frames else { return nil }
            // Irregular decoder blocks exercise buffering independently of grain size.
            let count = min(frames - offset, offset % 3001 + 997)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)))
            pcm.frameLength = UInt32(count)
            let planes = try #require(pcm.floatChannelData)
            for i in 0..<count { planes[0][i] = source[offset + i]; planes[1][i] = -source[offset + i] * 0.5 }
            offset += count
            return pcm
        }) {
            let planes = try #require(pcm.floatChannelData)
            for i in 0..<Int(pcm.frameLength) {
                finite = finite && planes[0][i].isFinite && planes[1][i].isFinite
                peak = max(peak, abs(planes[0][i]))
                phaseError = max(phaseError, abs(planes[1][i] + planes[0][i] * 0.5))
                output.append(planes[0][i])
            }
        }
        let expected = Double(frames) - (rate - 1) * (4 + 1.5) * sampleRate
        #expect(finite && peak <= 0.300001 && phaseError < 1e-7)
        #expect(abs(Double(output.count) - expected) <= 241)
        #expect(output.count == stretcher.outputFrames)
        for start in [48_000, 8 * 48_000] {
            let crossings = (start..<(start + 48_000 - 1)).filter { output[$0] <= 0 && output[$0 + 1] > 0 }.count
            #expect(abs(crossings - 440) <= 1)
        }
        #expect(output.suffix(1000).allSatisfy { abs($0 - 0.123) < 1e-7 })
        // Following recovery, the saved waveform again follows the original
        // source clock, rather than leaving a hidden rate or phase offset.
        for i in stride(from: 8 * 48_000, to: output.count - 5000, by: 79) {
            let sourceIndex = Int(tempo.sourceFrame(Double(i), sampleRate: sampleRate).rounded()) + Int(stretcher.directSourceCorrection)
            #expect(abs(output[i] - source[sourceIndex]) < 1e-6)
        }
        for start in stride(from: 6 * 48_000, to: 8 * 48_000, by: 480) {
            let rms = (output[start..<(start + 960)].reduce(0.0) { $0 + Double($1 * $1) } / 960).squareRoot()
            #expect(rms > 0.19 && rms < 0.23, "Recovery must preserve a steady tone without a phase-cancellation dip")
        }
    }

    @Test func recoveryHasContinuousSpeedAndEndsAtUnity() {
        let tempo = FFmpegTransitionTempo(rate: 1.04, hold: 4, recovery: 3)
        func speed(_ seconds: Double) -> Double {
            (tempo.sourceFrame((seconds + 0.0001) * 48_000, sampleRate: 48_000)
             - tempo.sourceFrame(seconds * 48_000, sampleRate: 48_000)) / 4.8
        }
        #expect(abs(speed(1) - 1.04) < 1e-7)
        #expect(abs(speed(4) - 1.04) < 1e-7)
        #expect(abs(speed(5.5) - 1.02) < 1e-5)
        #expect(abs(speed(7) - 1) < 1e-7 && abs(speed(9) - 1) < 1e-7)
    }
}

@Suite(.serialized) @MainActor
struct FFmpegBeatMatchingPCMTests {
    @Test(arguments: [0.48, 0.52, 0.5, 0.7])
    func savedProductionPCMMatchesBeatsAndRecoversOriginalTempo(_ period: Double) async throws {
        let name = String(format: "period-%.2f", period)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeatMatchedTransitionValidation/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in ["a.wav", "b.m4a", "transition-mix.wav", "output.wav", "recording.json", "validation.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
        }
        let aURL = root.appendingPathComponent("a.wav"), bURL = root.appendingPathComponent("b.m4a")
        try fixture(aURL, channel: 0, period: 0.5, frequency: 440)
        try fixture(bURL, channel: 1, period: period, frequency: 660)
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.apply(.init(transition: .init(mode: .crossfade, crossfadeDuration: .seconds(12), smartCrossfadeEnabled: true)))
        let a = item(aURL, "beat-a"), b = item(bURL, "beat-b")
        try await engine.prepare(a, startAt: nil)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableOfflinePCMRendering(format: format, maximumFrameCount: 480)
        var commits: [LogicalPlaybackCommit] = [], retirements: [PlaybackTransitionRetirement] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        engine.setTransitionRetirementHandler { retirements.append($0) }
        let ticket = PlaybackTransitionTicket(sessionID: .init(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: .init())
        try await engine.prepareNext(b, ticket: ticket)
        let plan = try #require(engine.lastSmartTransitionPlan)
        let matched = period == 0.48 || period == 0.52
        #expect((plan.incomingTempo != nil) == matched)
        try engine.setVolume(0.5)
        try engine.startPCMRecording(in: root)
        try engine.play()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        for _ in 0..<4200 {
            #expect(try engine.renderOfflineRecording(480, to: buffer) == .success)
            try await Task.sleep(for: .milliseconds(1))
            if engine.state.phase == .stopped { break }
        }
        #expect(engine.state.phase == .stopped && engine.state.itemID == b.itemID)
        let report = try await engine.finishPCMRecording()
        try engine.disableOfflinePCMRendering()
        #expect(report.transitionMix.persistedAllDeliveredFrames && report.output.persistedAllDeliveredFrames)
        let commit = try #require(commits.first), retired = try #require(retirements.first)
        #expect(commits.count == 1 && retirements.count == 1)
        #expect(abs(Double(retired.renderFrame - commit.renderFrame) / 48_000 - plan.overlap) < 1 / 48_000)
        let file = try AVAudioFile(forReading: report.transitionMix.fileURL)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        try file.read(into: pcm)
        let data = try #require(pcm.floatChannelData)
        let samples = (0..<2).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(pcm.frameLength))) }
        #expect(samples.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) < 1 } })
        let aPeaks = peaks(samples[0]), bPeaks = peaks(samples[1])
        let handoff = Double(commit.renderFrame) / 48_000, retirement = Double(retired.renderFrame) / 48_000
        let overlapPeaks = bPeaks.filter { $0 > handoff + 0.6 && $0 < retirement - 0.3 }
        let beatOffsets = overlapPeaks.map { b in aPeaks.map { abs($0 - b) }.min() ?? 10 }
        if plan.basis == .beats {
            #expect(beatOffsets.count >= 4)
            #expect((beatOffsets.max() ?? 10) <= 0.025)
        }
        let recovery = plan.incomingTempo?.recovery ?? 0
        let after = bPeaks.filter { $0 > retirement + recovery + 0.5 && $0 < Double(pcm.frameLength) / 48_000 - 0.5 }
        let restored = zip(after.dropFirst(), after).map { $0.0 - $0.1 }
        #expect(restored.count >= 5 && restored.allSatisfy { abs($0 - period) <= 0.015 })
        let start = Int((handoff + 1) * 48_000), end = start + 48_000
        let crossings = (start..<end).filter { samples[1][$0] <= 0 && samples[1][$0 + 1] > 0 }.count
        #expect(abs(crossings - 660) <= 2)
        let metadata: [String: Any] = ["scenario": name, "inputPeriod": period, "basis": plan.basis.rawValue,
            "incomingRate": plan.incomingTempo?.rate ?? 1, "recoverySeconds": recovery,
            "overlapSeconds": plan.overlap, "handoffSeconds": handoff, "retirementSeconds": retirement,
            "maximumBeatOffsetSeconds": beatOffsets.max() ?? 0, "measuredPitchHz": crossings,
            "restoredBeatIntervals": restored, "mixFrames": pcm.frameLength, "sampleRate": 48_000,
            "droppedFrames": report.transitionMix.droppedFrames + report.output.droppedFrames]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("validation.json"))
        print("BEAT_PCM \(name) rate=\(plan.incomingTempo?.rate ?? 1) overlap=\(plan.overlap) maxOffset=\(beatOffsets.max() ?? 0) root=\(root.path)")
    }

    private func peaks(_ samples: [Float]) -> [Double] {
        let hop = 240
        let levels = stride(from: 0, through: samples.count - hop, by: hop).map { start in
            (samples[start..<(start + hop)].reduce(0.0) { $0 + Double($1 * $1) } / Double(hop)).squareRoot()
        }
        var result: [Double] = []
        for i in 4..<(levels.count - 1) where levels[i] > 0.01 && levels[i] > levels[i - 1] && levels[i] >= levels[i + 1] &&
            levels[i] - levels[i - 4] > max(0.005, levels[i] * 0.15) {
            let time = (Double(i) + 0.5) * Double(hop) / 48_000
            if result.last.map({ time - $0 >= 0.2 }) ?? true { result.append(time) }
        }
        return result
    }

    private func item(_ url: URL, _ id: String) -> PlaybackItem {
        .init(itemID: .init(sourceID: .local, externalID: id), resource: .localFile(url), displaySnapshot: .init(title: id))
    }

    private func fixture(_ url: URL, channel: Int, period: Double, frequency: Double) throws {
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(18 * rate)))
        pcm.frameLength = pcm.frameCapacity
        let data = try #require(pcm.floatChannelData)
        for i in 0..<Int(pcm.frameLength) {
            let time = Double(i) / rate
            let phase = time >= 0.5 ? (time - 0.5).truncatingRemainder(dividingBy: period) : 1
            let pulse = phase < 0.04 ? min(1, phase / 0.002, (0.04 - phase) / 0.003) : 0
            let sample = time >= 0.4 && time < 17.4 ? Float(sin(2 * .pi * frequency * time) * (0.04 + 0.55 * pulse)) : 0
            data[0][i] = channel == 0 ? sample : 0
            data[1][i] = channel == 1 ? sample : 0
        }
        let settings: [String: Any] = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: pcm)
    }
}
