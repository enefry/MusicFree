import AVFoundation
import FFmpegAudioKit
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing
@testable import FFmpegPlaybackAdapter

@Suite struct FFmpegSmartTransitionPlannerTests {
    private func profile(level: Double = 0.08, period: Double? = nil, end: Double = 24) -> FFmpegSmartTransitionProfile {
        func edge(_ origin: Double) -> FFmpegTransitionEdge {
            var rms = [Double](repeating: level, count: 1200)
            if let period {
                for time in stride(from: 0.12, to: 12, by: period) {
                    rms[Int((time * 100).rounded())] = 0.5
                }
            }
            return .init(origin: origin, rms: rms)
        }
        return .init(start: 0, end: end, head: edge(0), tail: edge(end - 12))
    }

    @Test(arguments: [0.4, 0.5, 0.8])
    func reliableBeatsAlignFirstIncomingOnset(_ period: Double) throws {
        let a = profile(period: period), b = profile(period: period)
        #expect(abs(try #require(a.tail.beatPeriod) - period) < 0.011)
        let plan = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: b, maximum: 12, currentPosition: 0)
        #expect(plan.basis == .beats && plan.overlap <= 12)
        let firstB = try #require(b.head.onsets.first)
        let correspondingA = try #require(plan.outgoingStart) + firstB
        #expect(a.tail.onsets.contains { abs($0 - correspondingA) < 0.0001 })
    }

    @Test func incompatibleTemposAndIrregularOnsetsUseEnergy() {
        let a = profile(period: 0.5), b = profile(period: 0.7)
        let plan = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: b, maximum: 12, currentPosition: 0)
        #expect(plan.basis == .energy)
        var irregular = [Double](repeating: 0.08, count: 1200)
        for index in [10, 50, 130, 200, 225, 280, 390, 420, 490, 600] { irregular[index] = 0.8 }
        #expect(FFmpegTransitionEdge(origin: 0, rms: irregular).beatPeriod == nil)
    }

    @Test func isolatedIntroAttackIsExcludedFromBeatAlignment() throws {
        func edge(_ origin: Double) -> FFmpegTransitionEdge {
            var rms = [Double](repeating: 0.09, count: 1200)
            for index in stride(from: 10, to: 1200, by: 50) { rms[index] = 0.5 }
            return .init(origin: origin, rms: rms)
        }
        let head = edge(0), tail = edge(12)
        #expect(head.onsets.first == 0)
        #expect(abs(try #require(head.beatPeriod) - 0.5) < 0.001)
        #expect(head.beatOnsets.count >= 6 && head.beatOnsets.first != 0)
        let profile = FFmpegSmartTransitionProfile(start: 0, end: 24, head: head, tail: tail)
        let plan = FFmpegSmartTransitionPlan.choose(outgoing: profile, incoming: profile, maximum: 12, currentPosition: 0)
        let incomingBeat = try #require(head.beatOnsets.first)
        let matching = try #require(plan.outgoingStart) + incomingBeat
        #expect(plan.basis == .beats && tail.beatOnsets.contains { abs($0 - matching) < 0.001 })
    }

    @Test func levelMismatchShortensBlend() {
        let a = profile(level: 0.02)
        let quiet = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: profile(level: 0.02), maximum: 12, currentPosition: 0)
        let loud = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: profile(level: 0.5), maximum: 12, currentPosition: 0)
        #expect(quiet.basis == .energy && abs(quiet.overlap - 4) < 0.051)
        #expect(loud.overlap < quiet.overlap && abs(loud.overlap - 1.5) < 0.051)
    }

    @Test func nearTemposMatchAndRecoverBeforeTheNextTransition() throws {
        let a = profile(period: 0.5), b = profile(period: 0.52)
        let plan = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: b, maximum: 12, currentPosition: 0)
        let tempo = try #require(plan.incomingTempo)
        #expect(plan.basis == .beats && plan.overlap >= 3)
        #expect(abs(tempo.rate - 1.04) < 0.001)
        #expect(abs((try #require(b.head.beatPeriod)) / tempo.rate - (try #require(a.tail.beatPeriod))) < 0.001)
        #expect(tempo.sourceFrame((tempo.hold + tempo.recovery) * 48_000, sampleRate: 48_000) <= b.duration / 2 * 48_000)
    }

    @Test func loudCrestMovesTheEntryPoint() {
        let flat = profile(level: 0.04)
        var rms = flat.tail.rms
        for i in 750..<850 { rms[i] = 0.6 }
        let crest = FFmpegSmartTransitionProfile(start: flat.start, end: flat.end, head: flat.head,
            tail: .init(origin: flat.tail.origin, rms: rms))
        let plan = FFmpegSmartTransitionPlan.choose(outgoing: crest, incoming: flat, maximum: 12, currentPosition: 0)
        #expect(plan.basis == .energy && plan.overlap > 3 && plan.overlap < 3.6)
        #expect(crest.tail.level(at: plan.outgoingStart ?? 0) < 0.1)
    }

    @Test(arguments: [0.1, 1, 3, 12])
    func capsShortSongsAndLatePreparation(_ cap: Double) {
        let a = profile(end: 3), b = profile(end: 2)
        let plan = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: b, maximum: cap, currentPosition: 2.8)
        #expect(plan.overlap >= 0 && plan.overlap <= min(cap, 0.15) + 0.0001)
        let short = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: b, maximum: cap, currentPosition: 0)
        #expect(short.overlap <= min(cap, 1))
    }

    @Test func unavailableAnalysisRetainsFixedWindow() {
        let plan = FFmpegSmartTransitionPlan.choose(outgoing: nil, incoming: nil, maximum: 12, currentPosition: 0)
        #expect(plan.basis == .fixed && plan.overlap == 12)
    }

    @Test func shortLateAndLoudTransitionsDoNotForceTempoChanges() {
        let a = profile(period: 0.5), b = profile(period: 0.52)
        let short = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: profile(period: 0.52, end: 6), maximum: 12, currentPosition: 0)
        let late = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: b, maximum: 12, currentPosition: 23)
        let loud = FFmpegSmartTransitionPlan.choose(outgoing: profile(level: 0.02, period: 0.5), incoming: profile(level: 0.5, period: 0.52), maximum: 12, currentPosition: 0)
        let minimum = FFmpegSmartTransitionPlan.choose(outgoing: a, incoming: b, maximum: 0.1, currentPosition: 0)
        #expect([short, late, loud, minimum].allSatisfy { $0.incomingTempo == nil })
    }
}

@MainActor
@Suite(.serialized)
struct FFmpegSmartTransitionPlaybackTests {
    @Test func cancelledPreparationCannotCommitItsAnalyzedSuccessor() async throws {
        let url = try fixture(period: 0.5, compressed: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.apply(.init(transition: .init(mode: .crossfade, crossfadeDuration: .seconds(12), smartCrossfadeEnabled: true)))
        let a = PlaybackItem(itemID: .init(sourceID: .local, externalID: "cancel-a"), resource: .localFile(url), displaySnapshot: .init(title: "A"))
        let b = PlaybackItem(itemID: .init(sourceID: .local, externalID: "cancel-b"), resource: .localFile(url), displaySnapshot: .init(title: "B"))
        try await engine.prepare(a, startAt: nil)
        let ticket = PlaybackTransitionTicket(sessionID: .init(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: .init())
        let preparation = Task { try await engine.prepareNext(b, ticket: ticket) }
        await Task.yield()
        preparation.cancel(); engine.cancelNext()
        do {
            try await preparation.value
            Issue.record("Cancelled smart preparation unexpectedly succeeded")
        } catch is CancellationError { }
        var commits: [LogicalPlaybackCommit] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        try engine.play()
        // Wait for the current decoder's independent analysis to finish.
        for _ in 0..<300 {
            if engine.state.phase == .playing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        var energy = 0.0
        for _ in 0..<1500 {
            if engine.state.phase == .stopped { break }
            #expect(try engine.audioEngine.renderOffline(480, to: buffer) == .success)
            if let data = buffer.floatChannelData {
                energy += (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(data[1][$1] * data[1][$1]) }
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(commits.isEmpty && engine.state.itemID == a.itemID && energy > 10)
    }

    @Test(arguments: [false, true])
    func decodedPCMProvidesSilenceLevelsAndBeats(_ compressed: Bool) throws {
        let url = try fixture(period: 0.5, compressed: compressed)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try FFmpegAudioDecoder(localFileURL: url)
        let boundary = try FFmpegSilenceBoundaries.analyze(decoder)
        let profile = try #require(try FFmpegSmartTransitionProfile.analyze(decoder, firstFrame: boundary.startFrame,
            endFrame: boundary.endFrame ?? boundary.decodedEndFrame, isCancelled: { false }))
        #expect(abs(profile.start - 0.38) < 0.011)
        #expect(abs(profile.end - 13.42) < 0.011)
        #expect(abs(try #require(profile.head.beatPeriod) - 0.5) < 0.011)
        #expect(abs(try #require(profile.tail.beatPeriod) - 0.5) < 0.011)
        #expect(profile.head.rms.count <= 1201 && profile.tail.rms.count <= 1201)
        #expect(throws: CancellationError.self) {
            _ = try FFmpegSmartTransitionProfile.analyze(decoder, firstFrame: boundary.startFrame,
                endFrame: boundary.endFrame, isCancelled: { true })
        }
    }

    @Test(arguments: [0.5, 0.7])
    func actualMixerUsesSelectedWindowAtOriginalSpeed(_ incomingPeriod: Double) async throws {
        let aURL = try fixture(period: 0.5, compressed: false)
        let bURL = try fixture(period: incomingPeriod, compressed: true)
        defer { try? FileManager.default.removeItem(at: aURL); try? FileManager.default.removeItem(at: bURL) }
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.apply(.init(transition: .init(mode: .crossfade, crossfadeDuration: .seconds(12), smartCrossfadeEnabled: true)))
        func item(_ url: URL, _ id: String) -> PlaybackItem {
            .init(itemID: .init(sourceID: .local, externalID: id), resource: .localFile(url),
                  displaySnapshot: .init(title: id))
        }
        let a = item(aURL, "smart-a"), b = item(bURL, "smart-b")
        try await engine.prepare(a, startAt: nil)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.audioEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        var commits: [LogicalPlaybackCommit] = [], retirements: [PlaybackTransitionRetirement] = []
        engine.setTransitionCommitHandler { commits.append($0) }
        engine.setTransitionRetirementHandler { retirements.append($0) }
        let ticket = PlaybackTransitionTicket(sessionID: .init(), intent: 1, queueRevision: 1,
            generation: engine.state.generation, currentItemID: a.itemID, nextEntryID: .init())
        try await engine.prepareNext(b, ticket: ticket)
        let plan = try #require(engine.lastSmartTransitionPlan)
        #expect(plan.basis == (incomingPeriod == 0.5 ? .beats : .energy))
        #expect(plan.overlap > 0 && plan.overlap < 12)
        try engine.play()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        var energy = 0.0
        for _ in 0..<3000 {
            #expect(try engine.audioEngine.renderOffline(480, to: buffer) == .success)
            if let data = buffer.floatChannelData {
                energy += (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(data[1][$1] * data[1][$1]) }
            }
            try await Task.sleep(for: .milliseconds(1))
            if engine.state.phase == .stopped { break }
        }
        let retired = try #require(retirements.first), commit = try #require(commits.first)
        #expect(commits.count == 1 && retirements.count == 1 && energy > 100)
        // Original-speed A retains all audible content; only edge silence goes.
        #expect(abs(retired.renderFrame - Int64(13.04 * 48_000)) <= 5)
        #expect(abs(retired.renderFrame - commit.renderFrame - Int64((plan.overlap * 48_000).rounded())) <= 1)
        #expect(engine.state.itemID == b.itemID && engine.state.phase == .stopped)
        print("SMART_PCM basis=\(plan.basis.rawValue) overlap=\(plan.overlap) commit=\(commit.renderFrame) retirement=\(retired.renderFrame) energy=\(energy)")
    }

    private func fixture(period: Double, compressed: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("smart-\(UUID().uuidString).\(compressed ? "m4a" : "wav")")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let frames = UInt32(14 * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            let time = Double(i) / rate
            let audible = time >= 0.4 && time < 13.4
            let pulse = time >= 0.5 && (time - 0.5).truncatingRemainder(dividingBy: period) < 0.03
            let sample = audible ? Float(sin(2 * .pi * 1000 * time) * (pulse ? 0.5 : 0.08)) : 0
            data[0][i] = 0 // The analyzer must include the other channel.
            data[1][i] = sample
        }
        let settings: [String: Any] = compressed
            ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate,
               AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16] : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
}
