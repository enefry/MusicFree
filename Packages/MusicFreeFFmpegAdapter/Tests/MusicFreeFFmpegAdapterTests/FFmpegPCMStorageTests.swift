import AVFoundation
import FFmpegAudioKit
import Foundation
import MusicDomain
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

@Suite(.serialized) @MainActor
struct FFmpegPCMStorageTests {
    private func directory(_ name: String) throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PCMTransitionValidation", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func storesInterleavedPCMAndReportsOverflowAndFormatRejection() async throws {
        let root = try directory("storage-unit")
        let url = root.appendingPathComponent("storage.wav")
        try? FileManager.default.removeItem(at: url)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let node = try FFmpegPCMStorageNode(fileURL: url, format: format, capacity: 64)
        let oversized = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        oversized.frameLength = 1024
        node.record(oversized) // Whole-block overflow is deterministic, even if the writer is awake.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let floats = try #require(buffer.floatChannelData)[0]
        for i in 0..<32 { floats[2 * i] = Float(i) / 64; floats[2 * i + 1] = -Float(i) / 64 }
        node.record(buffer)
        let wrong = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let mismatch = try #require(AVAudioPCMBuffer(pcmFormat: wrong, frameCapacity: 10))
        mismatch.frameLength = 10; node.record(mismatch)
        let report = await node.finish()
        #expect(report.receivedFrames == 1066 && report.writtenFrames == 32)
        #expect(report.droppedFrames == 1024 && report.rejectedFrames == 10 && report.writeError == nil)
        #expect(!report.persistedAllDeliveredFrames)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 32 && file.processingFormat.sampleRate == 48_000)
        let saved = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32))
        try file.read(into: saved)
        let data = try #require(saved.floatChannelData)
        for i in 0..<32 { #expect(data[0][i] == Float(i) / 64 && data[1][i] == -Float(i) / 64) }
        node.record(buffer)
        #expect(await node.finish().writtenFrames == 32)
        #expect(throws: FFmpegPCMRecordingError.self) { _ = try FFmpegPCMStorageNode(fileURL: url, format: format) }
        #expect(try AVAudioFile(forReading: url).length == 32)
    }

    @Test func generatedAudioIsStoredThroughActualTransitionAndOutputStages() async throws {
        let root = try directory("scenarios")
        for scenario in ["fixed", "smart-beats", "smart-energy", "smart-levels"] {
            let folder = root.appendingPathComponent(scenario, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["a.wav", "b.m4a", "decoded-b.wav", "transition-mix.wav", "output.wav", "recording.json", "validation.json"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            let aURL = folder.appendingPathComponent("a.wav"), bURL = folder.appendingPathComponent("b.m4a")
            let levels = scenario == "smart-levels"
            try fixture(aURL, frequency: 440, period: 0.5, level: levels ? 0.16 : 0.8)
            try fixture(bURL, frequency: 660, period: scenario == "smart-energy" || levels ? 0.7 : 0.5, level: 0.8)
            // A lossless compressed source also goes through the real FFmpeg decoder.
            let decoded = try FFmpegAudioDecoder(localFileURL: bURL)
            let decodedFile = try AVAudioFile(forWriting: folder.appendingPathComponent("decoded-b.wav"), settings: decoded.format.settings)
            while let pcm = try decoded.nextBuffer(frameCapacity: 8192) { try decodedFile.write(from: pcm) }
            let engine = FFmpegPlaybackEngine()
            defer { engine.dispose() }
            let smart = scenario != "fixed"
            try engine.apply(.init(transition: .init(mode: .crossfade, crossfadeDuration: .seconds(12),
                skipBoundarySilence: true, smartCrossfadeEnabled: smart)))
            let a = item(aURL, "capture-a"), b = item(bURL, "capture-b")
            try await engine.prepare(a, startAt: nil)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            try engine.enableOfflinePCMRendering(format: format, maximumFrameCount: 480)
            var commits: [LogicalPlaybackCommit] = [], retirements: [PlaybackTransitionRetirement] = []
            engine.setTransitionCommitHandler { commits.append($0) }
            engine.setTransitionRetirementHandler { retirements.append($0) }
            let ticket = PlaybackTransitionTicket(sessionID: .init(), intent: 1, queueRevision: 1,
                generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: .init())
            try await engine.prepareNext(b, ticket: ticket)
            let plan = engine.lastSmartTransitionPlan
            try engine.setVolume(0.5)
            try engine.startPCMRecording(in: folder)
            #expect(throws: FFmpegPCMRecordingError.self) { try engine.startPCMRecording(in: folder) }
            try engine.play()
            do { _ = try await engine.finishPCMRecording(); Issue.record("Finishing a running producer must fail") }
            catch FFmpegPCMRecordingError.requiresStoppedEngine { }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            var outputBlocks = 0
            for _ in 0..<3200 {
                #expect(try engine.renderOfflineRecording(480, to: buffer) == .success)
                outputBlocks += 1
                try await Task.sleep(for: .milliseconds(1))
                if engine.state.phase == .stopped { break }
            }
            #expect(engine.state.phase == .stopped && engine.state.itemID == b.itemID)
            let report = try await engine.finishPCMRecording()
            try engine.disableOfflinePCMRendering()
            #expect(!report.endedByGraphChange && report.outputDelivery == "offline-render-blocks")
            #expect(report.transitionMix.persistedAllDeliveredFrames && report.output.persistedAllDeliveredFrames)
            #expect(report.output.writtenFrames == UInt64(outputBlocks * 480))
            let commit = try #require(commits.first), retired = try #require(retirements.first)
            #expect(commits.count == 1 && retirements.count == 1)
            let overlap = Double(retired.renderFrame - commit.renderFrame) / 48_000
            #expect(abs(Double(retired.renderFrame) / 48_000 - 13.04) < 0.015)
            if smart {
                let plan = try #require(plan)
                #expect(plan.basis == (scenario == "smart-beats" ? .beats : .energy))
                #expect(abs(overlap - plan.overlap) <= 1 / 48_000)
                if levels { #expect(plan.overlap <= 1.51) }
            }
            let mix = try read(report.transitionMix.fileURL), output = try read(report.output.fileURL)
            #expect(mix.frames == Int(report.transitionMix.writtenFrames) && output.frames == Int(report.output.writtenFrames))
            #expect(mix.peak > 0.1 && mix.peak <= 1 && output.peak > 0.05 && output.peak <= 0.5)
            // Independent file readback confirms post-mix master volume is present.
            // Source callbacks may pull ahead of returned output blocks, so compare
            // their common prefix instead of assuming equal callback partitioning.
            let count = min(mix.samples.count, output.samples.count)
            var error = 0.0, reference = 0.0
            for i in 0..<count {
                error += pow(Double(output.samples[i]) - Double(mix.samples[i]) * 0.5, 2)
                reference += pow(Double(mix.samples[i]) * 0.5, 2)
            }
            #expect(reference > 10 && sqrt(error / reference) < 0.0001)
            let signalEnd = try #require(output.samples.lastIndex(where: { abs($0) > 0.0001 }))
            let expectedEnd = 2 * Double(retired.renderFrame) / 48_000 - overlap - 0.02
            #expect(abs(Double(signalEnd + 1) / 48_000 - expectedEnd) < 0.015)
            var metadata: [String: Any] = ["scenario": scenario, "basis": plan?.basis.rawValue ?? "fixed",
                "sampleRate": 48_000, "sourceSampleRate": 44_100, "channels": 2,
                "maximumSeconds": 12, "selectedOverlapSeconds": overlap,
                "commitFrame": commit.renderFrame, "retirementFrame": retired.renderFrame,
                "sourceAudibleSeconds": Double(retired.renderFrame) / 48_000,
                "mixFrames": mix.frames, "outputFrames": output.frames, "mixPeak": mix.peak,
                "outputPeak": output.peak, "outputGain": 0.5, "gainRelativeRMSError": sqrt(error / reference),
                "droppedFrames": report.transitionMix.droppedFrames + report.output.droppedFrames,
                "rejectedFrames": report.transitionMix.rejectedFrames + report.output.rejectedFrames]
            if scenario == "smart-beats" {
                let aPeaks = carrierPeaks(mix.samples, frequency: 440)
                let bPeaks = carrierPeaks(mix.samples, frequency: 660)
                let middle = bPeaks.filter { $0 > Double(commit.renderFrame) / 48_000 + 1 && $0 < Double(retired.renderFrame) / 48_000 - 1 }
                let differences = middle.map { incoming in aPeaks.map { abs($0 - incoming) }.min() ?? 100 }
                let maximum = try #require(differences.max())
                #expect(middle.count >= 3 && maximum <= 0.02)
                metadata["maximumMeasuredBeatOffsetSeconds"] = maximum
            }
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("validation.json"), options: .atomic)
            print("PCM_ARTIFACT scenario=\(scenario) overlap=\(overlap) mix=\(mix.frames) output=\(output.frames) gainError=\(sqrt(error / reference)) root=\(folder.path)")
        }
    }

    @Test func realtimeTapPersistsOutputAndSeekEndsSession() async throws {
        let root = try directory("realtime")
        for name in ["a.wav", "transition-mix.wav", "output.wav", "recording.json"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        let url = root.appendingPathComponent("a.wav")
        try fixture(url, frequency: 440, period: 0.5, level: 0.8, duration: 3)
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(item(url, "realtime-capture"), startAt: nil)
        try engine.startPCMRecording(in: root)
        try engine.play()
        try await Task.sleep(for: .milliseconds(900))
        try await engine.seek(to: .seconds(1)) // Closes old capture before reattaching a producer.
        engine.hardPause()
        let report = try await engine.finishPCMRecording()
        #expect(report.endedByGraphChange && report.outputDelivery == "realtime-tap-blocks")
        #expect(report.transitionMix.persistedAllDeliveredFrames && report.output.persistedAllDeliveredFrames)
        #expect(report.transitionMix.writtenFrames > 20_000 && report.output.writtenFrames > 20_000)
        #expect(try read(report.output.fileURL).peak > 0.1)
        do { _ = try await engine.finishPCMRecording(); Issue.record("Old recording must not be reused") }
        catch FFmpegPCMRecordingError.notRecording { }
    }

    private func read(_ url: URL) throws -> (samples: [Float], frames: Int, peak: Float) {
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length)))
        try file.read(into: pcm)
        let data = try #require(pcm.floatChannelData)
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength)))
        let finite = samples.allSatisfy { $0.isFinite }
        #expect(finite)
        return (samples, Int(pcm.frameLength), samples.map(abs).max() ?? 0)
    }

    private func item(_ url: URL, _ id: String) -> PlaybackItem {
        .init(itemID: .init(sourceID: .local, externalID: id), resource: .localFile(url), displaySnapshot: .init(title: id))
    }

    // Independent measurement of the saved mix: distinguish A/B carriers,
    // then locate their percussion peaks without consulting planner onsets.
    private func carrierPeaks(_ samples: [Float], frequency: Double) -> [Double] {
        let window = 2400, hop = 480
        let real = (0..<window).map { cos(2 * .pi * frequency * Double($0) / 48_000) }
        let imaginary = (0..<window).map { sin(2 * .pi * frequency * Double($0) / 48_000) }
        var amplitudes: [Double] = []
        for start in stride(from: 0, through: samples.count - window, by: hop) {
            var re = 0.0, im = 0.0
            for i in 0..<window { re += Double(samples[start + i]) * real[i]; im += Double(samples[start + i]) * imaginary[i] }
            amplitudes.append(hypot(re, im) * 2 / Double(window))
        }
        var peaks: [Double] = []
        for i in 1..<(amplitudes.count - 1) where amplitudes[i] > 0.08 && amplitudes[i] > amplitudes[i - 1] && amplitudes[i] >= amplitudes[i + 1] {
            let time = Double(i * hop + window / 2) / 48_000
            if peaks.last.map({ time - $0 > 0.18 }) ?? true { peaks.append(time) }
        }
        return peaks
    }

    private func fixture(_ url: URL, frequency: Double, period: Double, level: Double, duration: Double = 14) throws {
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * rate)))
        pcm.frameLength = pcm.frameCapacity
        let data = try #require(pcm.floatChannelData)
        for i in 0..<Int(pcm.frameLength) {
            let time = Double(i) / rate
            let audible = time >= 0.4 && time < duration - 0.6
            let phase = time >= 0.5 ? (time - 0.5).truncatingRemainder(dividingBy: period) : 1
            let pulse = phase < 0.03 ? min(1, phase / 0.002, (0.03 - phase) / 0.003) : 0
            let amplitude = audible ? level * (0.08 + 0.42 * pulse) : 0
            data[0][i] = Float(sin(2 * .pi * frequency * time) * amplitude)
            data[1][i] = Float(sin(2 * .pi * frequency * 2 * time) * amplitude)
        }
        let settings: [String: Any] = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: pcm)
    }
}
