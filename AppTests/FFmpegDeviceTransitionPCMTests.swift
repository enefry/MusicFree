import AVFoundation
@testable import FFmpegPlaybackAdapter
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing
import UIKit

/// Real-time acceptance, hosted by the application on the physical phone.
/// These tests deliberately never enable AVAudioEngine manual rendering.
@MainActor @Suite(.serialized)
struct FFmpegDeviceTransitionPCMTests {
    @Test(arguments: ["fixed-12", "fixed-short", "fixed-min", "smart-beats", "smart-energy",
                      "smart-levels", "gapless-skip", "gapless-raw", "gapless-mixed",
                      "middle-silence", "fade-in", "fade-out", "fades-both", "effects-off"])
    func realtimeEffects(_ scenario: String) async throws {
        #if targetEnvironment(simulator)
        throw DeviceAcceptanceError.physicalDeviceRequired
        #endif
        let folder = try directory(scenario)
        let smart = scenario.hasPrefix("smart")
        let pair = !["fade-in", "fade-out", "fades-both", "effects-off"].contains(scenario)
        let fixed = scenario.hasPrefix("fixed")
        let skip = smart || ["fixed-12", "fixed-short", "gapless-skip", "middle-silence"].contains(scenario)
        let duration: Double = scenario == "fixed-12" ? 26 : smart || scenario == "fixed-short" ? 14 : scenario == "fades-both" ? 8 : 4
        let edges = pair
        let fadeIn: Duration = ["fade-in", "fades-both"].contains(scenario) ? .seconds(3) : .zero
        let fadeOut: Duration = ["fade-out", "fades-both"].contains(scenario) ? .seconds(3) : .zero
        let overlap: Duration = scenario == "fixed-min" ? .milliseconds(100) : .seconds(12)
        let aURL = folder.appendingPathComponent("a.wav")
        let bURL = folder.appendingPathComponent(smart ? "b.m4a" : "b.wav")
        try fixture(aURL, frequency: 440, period: 0.5, level: scenario == "smart-levels" ? 0.16 : 0.8,
                    duration: duration, edges: edges, pulses: pair, middleSilence: scenario == "middle-silence")
        if pair {
            try fixture(bURL, frequency: 660, period: scenario == "smart-tempo-faster" ? 0.52 : scenario == "smart-tempo-slower" ? 0.48 : ["smart-energy", "smart-levels"].contains(scenario) ? 0.7 : 0.5,
                        level: 0.8, duration: duration, edges: edges, pulses: true,
                        sampleRate: scenario == "gapless-mixed" ? 22_050 : 44_100,
                        channels: scenario == "gapless-mixed" ? 1 : 2)
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.apply(.init(transition: .init(mode: fixed || smart ? .crossfade : pair ? .gapless : .disabled,
            crossfadeDuration: fixed || smart ? overlap : nil, fadeInDuration: fadeIn, fadeOutDuration: fadeOut,
            skipBoundarySilence: skip, smartCrossfadeEnabled: smart)))
        let a = item(aURL, scenario + "-a"), b = item(bURL, scenario + "-b")
        var commits: [LogicalPlaybackCommit] = [], retirements: [PlaybackTransitionRetirement] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        engine.setTransitionRetirementHandler { retirements.append($0) }
        try await engine.prepare(a, startAt: nil)
        if pair { try await engine.prepareNext(b, ticket: ticket(engine, a)) }
        let plan = engine.lastSmartTransitionPlan
        try engine.setVolume(0.25)
        try engine.startPCMRecording(in: folder)
        let started = ContinuousClock.now
        try engine.play()
        #expect(!engine.audioEngine.isInManualRenderingMode)
        let nodeLatencies = engine.audioEngine.attachedNodes.map { node in
            ["type": String(describing: type(of: node)), "latency": node.latency,
             "outputPresentationLatency": node.outputPresentationLatency] as [String: Any]
        }
        for _ in 0..<1300 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = started.duration(to: .now)
        #expect(engine.state.phase == .stopped && engine.state.itemID == (pair ? b : a).itemID)
        if engine.audioEngine.isRunning { engine.hardPause() }
        let report = try await engine.finishPCMRecording()
        #expect(report.outputDelivery == "realtime-tap-blocks" && !report.endedByGraphChange)
        #expect(report.transitionMix.persistedAllDeliveredFrames && report.output.persistedAllDeliveredFrames)
        let mix = try pcm(report.transitionMix.fileURL), output = try pcm(report.output.fileURL)
        #expect(mix.frames == report.transitionMix.writtenFrames && output.frames == report.output.writtenFrames)
        #expect(mix.peak > 0.02 && mix.peak < 1 && output.peak > 0.005 && output.peak < 1)
        var metadata = routeMetadata(session)
        metadata["nodeLatencies"] = nodeLatencies
        if let plan {
            metadata["incomingStart"] = plan.incomingStart
            metadata["outgoingStart"] = plan.outgoingStart
            metadata["incomingRate"] = plan.incomingTempo?.rate ?? 1
            metadata["recoverySeconds"] = plan.incomingTempo?.recovery ?? 0
        }
        metadata.merge(["scenario": scenario, "sourceDuration": duration, "sourceEdges": edges,
            "skipBoundarySilence": skip, "smart": smart, "basis": plan?.basis.rawValue ?? (fixed ? "fixed" : "none"),
            "outputGain": 0.25, "mixSampleRate": mix.rate, "outputSampleRate": output.rate,
            "mixFrames": mix.frames, "outputFrames": output.frames,
            "elapsedSeconds": seconds(elapsed), "fadeInSeconds": seconds(fadeIn), "fadeOutSeconds": seconds(fadeOut),
            "commits": commits.count, "retirements": retirements.count,
            "mixPeak": mix.peak, "outputPeak": output.peak], uniquingKeysWith: { _, new in new })
        if pair {
            #expect(commits.count == 1 && retirements.count == 1)
            let commit = try #require(commits.first), retirement = try #require(retirements.first)
            let selected = Double(retirement.renderFrame - commit.renderFrame) / mix.rate
            metadata["commitFrame"] = commit.renderFrame
            metadata["retirementFrame"] = retirement.renderFrame
            metadata["selectedOverlapSeconds"] = selected
            let expectedRetirement = skip ? duration - 0.96 : duration
            #expect(abs(Double(retirement.renderFrame) / mix.rate - expectedRetirement) < 0.015)
            if scenario == "fixed-12" { #expect(abs(selected - 12) <= 1 / mix.rate) }
            if scenario == "fixed-short" { #expect(abs(selected - expectedRetirement / 2) < 0.015) }
            if scenario == "fixed-min" { #expect(abs(selected - 0.1) <= 1 / mix.rate) }
            if !fixed && !smart { #expect(selected == 0) }
            if smart {
                let plan = try #require(plan)
                #expect(plan.basis == (scenario == "smart-beats" || scenario.hasPrefix("smart-tempo-") ? .beats : .energy))
                if scenario.hasPrefix("smart-tempo-") { #expect(plan.incomingTempo != nil) }
                #expect(abs(selected - plan.overlap) <= 1 / mix.rate)
                if scenario == "smart-levels" { #expect(selected <= 1.51) }
            }
        } else { #expect(commits.isEmpty && retirements.isEmpty) }
        try save(metadata, folder: folder)
        print("DEVICE_PCM scenario=\(scenario) physical=true route=\(session.currentRoute.outputs.map(\.portType.rawValue)) elapsed=\(seconds(elapsed)) mixFrames=\(mix.frames) outputFrames=\(output.frames) folder=\(folder.path)")
    }

    func realtimeBeatMatchingTransport() async throws {
        #if targetEnvironment(simulator)
        throw DeviceAcceptanceError.physicalDeviceRequired
        #endif
        let folder = try directory("smart-tempo-transport")
        let aURL = folder.appendingPathComponent("a.wav"), bURL = folder.appendingPathComponent("b.m4a")
        try fixture(aURL, frequency: 440, period: 0.5, level: 0.8, duration: 14, edges: true, pulses: true)
        try fixture(bURL, frequency: 660, period: 0.52, level: 0.8, duration: 14, edges: true, pulses: true)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback); try session.setActive(true)
        defer { try? session.setActive(false) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.apply(.init(transition: .init(mode: .crossfade, crossfadeDuration: .seconds(12), smartCrossfadeEnabled: true)))
        let a = item(aURL, "beat-control-a"), b = item(bURL, "beat-control-b")
        var commits: [LogicalPlaybackCommit] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        try await engine.prepare(a, startAt: nil)
        try await engine.prepareNext(b, ticket: ticket(engine, a))
        #expect(engine.lastSmartTransitionPlan?.incomingTempo != nil)
        try engine.setVolume(0.25); try engine.play()
        for _ in 0..<600 {
            if !commits.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(commits.count == 1 && engine.state.itemID == b.itemID)
        try await Task.sleep(for: .milliseconds(500))
        engine.pause()
        for _ in 0..<100 {
            if !engine.audioEngine.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.state.phase == .paused && !engine.audioEngine.isRunning)
        let paused = engine.state.position
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.state.position == paused)
        try engine.play(); try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state.phase == .playing && engine.state.position >= paused)
        let seekStarted = ContinuousClock.now
        try await engine.seek(to: .seconds(5))
        let phaseImmediatelyAfterSeek = String(describing: engine.state.phase)
        // Seeking rebuilds the decoder and analyzes the selected source range.
        // Wait for actual playback readiness, with a bound that detects stalls.
        for _ in 0..<400 {
            if engine.state.phase == .failed ||
                (engine.state.phase == .playing && engine.state.position > .seconds(5)) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let seekReadySeconds = seconds(seekStarted.duration(to: .now))
        try #require(engine.state.itemID == b.itemID && engine.state.phase == .playing && engine.state.position > .seconds(5))
        let resumedPosition = engine.state.position
        for _ in 0..<40 {
            if engine.state.position > resumedPosition || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(engine.state.position > resumedPosition && engine.audioEngine.isRunning && commits.count == 1)
        print("DEVICE_BEAT_TRANSPORT seekReadySeconds=\(seekReadySeconds) position=\(seconds(engine.state.position))")
        engine.hardStop()
        #expect(engine.state.phase == .stopped && !engine.audioEngine.isRunning)
        var metadata = routeMetadata(session)
        metadata["scenario"] = "smart-tempo-transport"
        metadata["pauseResumeSeekStopPassed"] = true
        metadata["commits"] = commits.count
        metadata["seekReadySeconds"] = seekReadySeconds
        metadata["phaseImmediatelyAfterSeek"] = phaseImmediatelyAfterSeek
        metadata["postSeekPositionSeconds"] = seconds(engine.state.position)
        try save(metadata, folder: folder)
    }

    @Test func realtimeTransportAndRecordingLifetime() async throws {
        #if targetEnvironment(simulator)
        throw DeviceAcceptanceError.physicalDeviceRequired
        #endif
        let folder = try directory("transport")
        let url = folder.appendingPathComponent("a.wav")
        try fixture(url, frequency: 440, period: 0.5, level: 0.8, duration: 12, edges: false, pulses: false)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.apply(.init(transition: .init(mode: .crossfade, crossfadeDuration: .seconds(12),
            fadeInDuration: .seconds(3), fadeOutDuration: .seconds(3))))
        let a = item(url, "transport-a"), b = item(url, "transport-b")
        var commits: [LogicalPlaybackCommit] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        try await engine.prepare(a, startAt: nil)
        try await engine.prepareNext(b, ticket: ticket(engine, a))
        try engine.setVolume(0.25)
        try engine.startPCMRecording(in: folder)
        try engine.play()
        try await Task.sleep(for: .milliseconds(3300))
        engine.cancelNext() // Must preserve the current graph and its recording.
        try await Task.sleep(for: .milliseconds(200))
        let pauseStart = ContinuousClock.now
        engine.pause()
        for _ in 0..<50 {
            if !engine.audioEngine.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pauseSeconds = seconds(pauseStart.duration(to: .now))
        #expect(!engine.audioEngine.isRunning && engine.state.phase == .paused && pauseSeconds < 0.5)
        let pausedPosition = engine.state.position
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.state.position == pausedPosition)
        try engine.play()
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state.phase == .playing && engine.state.position >= pausedPosition)
        try await engine.seek(to: .seconds(6))
        try await Task.sleep(for: .milliseconds(200))
        engine.hardPause()
        let old = try await engine.finishPCMRecording()
        #expect(old.endedByGraphChange && old.transitionMix.persistedAllDeliveredFrames && old.output.persistedAllDeliveredFrames)
        #expect(commits.isEmpty && engine.state.itemID == a.itemID)
        // A fresh session records paused seek/resume and the full manual stop fade.
        try await engine.seek(to: .seconds(6))
        #expect(engine.state.phase == .paused && !engine.audioEngine.isRunning)
        let stopFolder = try directory("transport-stop")
        try engine.startPCMRecording(in: stopFolder)
        try engine.play()
        try await Task.sleep(for: .milliseconds(300))
        let stopStart = ContinuousClock.now
        engine.stop()
        for _ in 0..<400 {
            if !engine.audioEngine.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopSeconds = seconds(stopStart.duration(to: .now))
        #expect(!engine.audioEngine.isRunning && engine.state.phase == .stopped && engine.state.itemID == nil)
        #expect(stopSeconds >= 2.8 && stopSeconds < 3.6)
        let stopped = try await engine.finishPCMRecording()
        #expect(stopped.endedByGraphChange && stopped.transitionMix.persistedAllDeliveredFrames && stopped.output.persistedAllDeliveredFrames)
        var metadata = routeMetadata(session)
        metadata["scenario"] = "transport"
        metadata["pauseSeconds"] = pauseSeconds
        metadata["stopSeconds"] = stopSeconds
        metadata["commitsAfterCancellation"] = commits.count
        metadata["outputGain"] = 0.25
        try save(metadata, folder: folder)
        metadata["scenario"] = "transport-stop"
        try save(metadata, folder: stopFolder)
        print("DEVICE_TRANSPORT pauseSeconds=\(pauseSeconds) stopSeconds=\(stopSeconds) cancelledCommits=\(commits.count)")
    }

    @Test func realtimeNaturalEndLeavesNoAudiblePCMInPipeline() async throws {
        #if targetEnvironment(simulator)
        throw DeviceAcceptanceError.physicalDeviceRequired
        #endif
        let folder = try directory("natural-tail")
        let url = folder.appendingPathComponent("a.wav")
        try fixture(url, frequency: 440, period: 0.5, level: 0.8, duration: 1, edges: false, pulses: false)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(item(url, "natural-tail"), startAt: nil)
        try engine.setVolume(0.25)
        try engine.startPCMRecording(in: folder)
        try engine.play()
        let latencies = engine.audioEngine.attachedNodes.map {
            ["type": String(describing: type(of: $0)), "latency": $0.latency,
             "outputPresentationLatency": $0.outputPresentationLatency] as [String: Any]
        }
        for _ in 0..<300 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.state.phase == .stopped && !engine.audioEngine.isRunning)
        let report = try await engine.finishPCMRecording()
        #expect(report.transitionMix.persistedAllDeliveredFrames && report.output.persistedAllDeliveredFrames)
        let residualURL = folder.appendingPathComponent("residual.wav")
        if FileManager.default.fileExists(atPath: residualURL.path) { try FileManager.default.removeItem(at: residualURL) }
        let residual = try FFmpegPCMStorageNode(fileURL: residualURL, format: engine.audioEngine.mainMixerNode.outputFormat(forBus: 0))
        engine.audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: FFmpegPCMStorageNode.tap(residual))
        // Restart only the paused hardware engine: the source stays at EOF.
        // Audible data here would prove that natural end paused a buffered tail.
        try engine.audioEngine.start()
        try await Task.sleep(for: .milliseconds(350))
        engine.audioEngine.pause()
        engine.audioEngine.mainMixerNode.removeTap(onBus: 0)
        let residualReport = await residual.finish()
        let leftover = try pcm(residualURL)
        #expect(residualReport.persistedAllDeliveredFrames && leftover.frames > 4800)
        #expect(leftover.peak < 0.0001, "Natural end left audible PCM buffered downstream: \(leftover.peak)")
        var metadata = routeMetadata(session)
        metadata["scenario"] = "natural-tail"
        metadata["outputGain"] = 0.25
        metadata["residualPeak"] = leftover.peak
        metadata["residualFrames"] = leftover.frames
        metadata["nodeLatencies"] = latencies
        try save(metadata, folder: folder)
        print("DEVICE_TAIL residualPeak=\(leftover.peak) latencies=\(latencies)")
    }

    @Test func realtimeNaturalEndWithoutRecordingDrainsPipeline() async throws {
        #if targetEnvironment(simulator)
        throw DeviceAcceptanceError.physicalDeviceRequired
        #endif
        let folder = try directory("natural-tail-no-recording")
        let url = folder.appendingPathComponent("a.wav")
        try fixture(url, frequency: 440, period: 0.5, level: 0.8, duration: 1, edges: false, pulses: false)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try await engine.prepare(item(url, "tail-no-recording"), startAt: nil)
        try engine.setVolume(0.25)
        try engine.play() // Production path: no engine PCM recording session.
        for _ in 0..<300 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.state.phase == .stopped && !engine.audioEngine.isRunning)
        let residualURL = folder.appendingPathComponent("residual.wav")
        if FileManager.default.fileExists(atPath: residualURL.path) { try FileManager.default.removeItem(at: residualURL) }
        let storage = try FFmpegPCMStorageNode(fileURL: residualURL, format: engine.audioEngine.mainMixerNode.outputFormat(forBus: 0))
        engine.audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: FFmpegPCMStorageNode.tap(storage))
        try engine.audioEngine.start()
        try await Task.sleep(for: .milliseconds(350))
        engine.audioEngine.pause()
        engine.audioEngine.mainMixerNode.removeTap(onBus: 0)
        let report = await storage.finish()
        let leftover = try pcm(residualURL)
        #expect(report.persistedAllDeliveredFrames && leftover.frames > 4800 && leftover.peak < 0.0001)
        var metadata = routeMetadata(session)
        metadata["scenario"] = "natural-tail-no-recording"
        metadata["residualPeak"] = leftover.peak
        metadata["residualFrames"] = leftover.frames
        try save(metadata, folder: folder)
        print("DEVICE_TAIL_NO_RECORDING residualPeak=\(leftover.peak)")
    }

    @Test func realtimeEndDrainCannotStopAReplacement() async throws {
        #if targetEnvironment(simulator)
        throw DeviceAcceptanceError.physicalDeviceRequired
        #endif
        let folder = try directory("replace-during-drain")
        let aURL = folder.appendingPathComponent("a.wav"), bURL = folder.appendingPathComponent("b.wav")
        try fixture(aURL, frequency: 440, period: 0.5, level: 0.8, duration: 0.2, edges: false, pulses: false)
        try fixture(bURL, frequency: 660, period: 0.5, level: 0.8, duration: 2, edges: false, pulses: false)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let a = item(aURL, "replace-a"), b = item(bURL, "replace-b")
        try await engine.prepare(a, startAt: nil)
        try engine.setVolume(0.25)
        try engine.play()
        try await Task.sleep(for: .milliseconds(260))
        try await engine.prepare(b, startAt: nil)
        try engine.play()
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state.itemID == b.itemID && engine.state.phase == .playing && engine.audioEngine.isRunning)
        var metadata = routeMetadata(session)
        metadata["scenario"] = "replace-during-drain"
        metadata["replacementStillPlaying"] = true
        try save(metadata, folder: folder)
        engine.hardStop()
    }

    private func directory(_ name: String) throws -> URL {
        // Diagnostics are not shared media and must stay outside the automatic
        // Documents importer. devicectl can export Application Support as well.
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeviceTransitionValidation", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only these test-owned files are replaced on a repeat run.
        for file in ["a.wav", "b.wav", "b.m4a", "transition-mix.wav", "output.wav", "recording.json", "validation.json"] {
            let url = folder.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        return folder
    }

    private func fixture(_ url: URL, frequency: Double, period: Double, level: Double, duration: Double,
                         edges: Bool, pulses: Bool, middleSilence: Bool = false,
                         sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(duration * sampleRate)))
        pcm.frameLength = pcm.frameCapacity
        let data = try #require(pcm.floatChannelData)
        for i in 0..<Int(pcm.frameLength) {
            let time = Double(i) / sampleRate
            let audible = (!edges || (time >= 0.4 && time < duration - 0.6)) && (!middleSilence || time < 1.5 || time >= 2.1)
            let phase = time >= 0.5 ? (time - 0.5).truncatingRemainder(dividingBy: period) : 1
            let pulse = phase < 0.03 ? min(1, phase / 0.002, (0.03 - phase) / 0.003) : 0
            let amplitude = audible ? level * (pulses ? 0.08 + 0.42 * pulse : 0.25) : 0
            for channel in 0..<Int(channels) {
                data[channel][i] = Float(sin(2 * .pi * frequency * Double(channel + 1) * time) * amplitude)
            }
        }
        let settings: [String: Any] = url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitDepthHintKey: 16]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: pcm)
    }

    private func pcm(_ url: URL) throws -> (frames: UInt64, rate: Double, peak: Float) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192))
        var peak: Float = 0, finite = true
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = data[channel][frame]
                    finite = finite && value.isFinite
                    peak = max(peak, abs(value))
                }
            }
        }
        #expect(finite)
        return (UInt64(file.length), file.processingFormat.sampleRate, peak)
    }

    private func item(_ url: URL, _ name: String) -> PlaybackItem {
        .init(itemID: .init(sourceID: .local, externalID: name), resource: .localFile(url), displaySnapshot: .init(title: name))
    }

    private func ticket(_ engine: FFmpegPlaybackEngine, _ a: PlaybackItem) -> PlaybackTransitionTicket {
        .init(sessionID: .init(), intent: 1, queueRevision: 1, generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: .init())
    }

    private func routeMetadata(_ session: AVAudioSession) -> [String: Any] {
        ["physicalDevice": true, "deviceName": UIDevice.current.name, "systemVersion": UIDevice.current.systemVersion,
         "route": session.currentRoute.outputs.map { ["type": $0.portType.rawValue, "name": $0.portName] },
         "hardwareSampleRate": session.sampleRate, "outputChannels": session.outputNumberOfChannels,
         "ioBufferDuration": session.ioBufferDuration, "outputLatency": session.outputLatency,
         "systemVolume": session.outputVolume, "manualRendering": false]
    }

    private func save(_ value: [String: Any], folder: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("validation.json"), options: .atomic)
    }

    private func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }
}

@MainActor @Suite(.serialized)
struct FFmpegDeviceBeatMatchingTests {
    @Test(arguments: ["smart-tempo-faster", "smart-tempo-slower"])
    func realtimeTempo(_ scenario: String) async throws {
        try await FFmpegDeviceTransitionPCMTests().realtimeEffects(scenario)
    }

    @Test func transportDuringTempoMatching() async throws {
        try await FFmpegDeviceTransitionPCMTests().realtimeBeatMatchingTransport()
    }
}

private enum DeviceAcceptanceError: Error { case physicalDeviceRequired }
