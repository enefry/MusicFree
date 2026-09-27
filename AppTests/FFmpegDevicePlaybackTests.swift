import AVFoundation
import FFmpegAudioKit
import FFmpegPlaybackAdapter
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import Testing

private final class FFmpegFixtureBundleMarker {}
private let externalFFmpegFixtures: URL = {
    let bundled = Bundle(for: FFmpegFixtureBundleMarker.self)
        .bundleURL.appendingPathComponent("ExternalFixtures", isDirectory: true)
    if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("ExternalFixtures", isDirectory: true) ?? bundled
}()

/// Runs inside the App test host, so Xcode can exercise the real audio graph
/// on a physical device rather than a hostless Swift Package test bundle.
@MainActor
@Suite struct FFmpegDevicePlaybackTests {
    @Test("Packaged FFmpeg formats play to completion through the App audio graph")
    func packagedFormatsPlayToEnd() async throws {
        let bundle = Bundle(for: FFmpegFixtureBundleMarker.self)
        let fixtures = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
        // The tagged FLAC fixture has metadata and artwork but no PCM frames.
        let nonPlaybackNames: Set<String> = [
            "current.m4a", "reencoded.m4a", "tagged-metadata.flac"
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: fixtures, includingPropertiesForKeys: nil
        ).filter { !nonPlaybackNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(urls.count == 27)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.setVolume(0.05)
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))

        for url in urls {
            let filename = url.lastPathComponent
            do {
                let probe = try await FFmpegMediaProbe().probe(.localFile(url))
                #expect(probe.isPlayable, "\(filename) has no decodable audio track")
                _ = try await FFmpegMetadataReader().readMetadata(from: .localFile(url))
                let item = PlaybackItem(
                    itemID: MediaItemID(sourceID: .local, externalID: filename),
                    resource: .local(url),
                    displaySnapshot: PlaybackDisplaySnapshot(title: filename)
                )
                try await engine.prepare(item, startAt: nil)
                try engine.play()
                for _ in 0 ..< 120 {
                    if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(engine.state.phase == .stopped, "\(filename) did not play to its end")

                let range = PlaybackRange(start: .milliseconds(50), end: .milliseconds(175))
                let cueItem = PlaybackItem(
                    itemID: MediaItemID(sourceID: .local, externalID: "cue-\(filename)"),
                    resource: .local(url),
                    selection: PlaybackSelection(range: range),
                    displaySnapshot: PlaybackDisplaySnapshot(title: filename)
                )
                try await engine.prepare(cueItem, startAt: nil)
                #expect(engine.state.duration == range.duration)
                try engine.play()
                for _ in 0 ..< 120 {
                    if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(engine.state.phase == .stopped, "\(filename) CUE range did not finish")
                #expect(engine.state.position == range.duration)
            } catch {
                Issue.record("\(filename): \(error)")
            }
        }
    }

    @Test("Long ALAC fixtures play their middle CUE ranges through the App audio graph",
          arguments: ["current", "reencoded"])
    func longALACMiddleCUEPlaysToEnd(name: String) async throws {
        let bundle = Bundle(for: FFmpegFixtureBundleMarker.self)
        let fixtures = try #require(bundle.url(forResource: "Fixtures", withExtension: nil))
        let url = fixtures.appendingPathComponent("\(name).m4a")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.setVolume(0.05)
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))

        let range = PlaybackRange(start: .seconds(100), end: .milliseconds(100_500))
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "long-alac-\(name)"),
            resource: .local(url),
            selection: PlaybackSelection(range: range),
            displaySnapshot: PlaybackDisplaySnapshot(title: name, duration: .seconds(199))
        )
        try await engine.prepare(item, startAt: nil)
        try engine.play()
        for _ in 0 ..< 120 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(engine.state.phase == .stopped, "\(name) did not finish its CUE range")
        #expect(engine.state.position == range.duration)
    }

    @Test("CUE range and equalizer finish playback in the App audio graph")
    func cueRangeWithEqualizerPlaysToEnd() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicfree-device-cue-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        // A complete RIFF header avoids the indefinite-size WAV produced by
        // AVAudioFile on some simulator runtimes.
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        let frames = 44_100
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frames * 2))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(44_100))
        append(UInt32(88_200))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        append(UInt32(frames * 2))
        for frame in 0 ..< frames {
            append(Int16(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 8000))
        }
        try wav.write(to: file)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.setVolume(0.1)
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))

        let range = PlaybackRange(start: .milliseconds(200), end: .milliseconds(500))
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "device-cue-eq"),
            resource: .local(file),
            selection: PlaybackSelection(range: range),
            displaySnapshot: PlaybackDisplaySnapshot(title: "CUE + EQ", duration: .seconds(1))
        )
        try await engine.prepare(item, startAt: .milliseconds(100))
        #expect(engine.state.duration == .milliseconds(300))
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
    }

    @Test("External FFmpeg corpus decodes fully and seeks across its timeline",
          .enabled(if: FileManager.default.fileExists(atPath: externalFFmpegFixtures.path)))
    func externalFormatsDecodeAndSeek() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        defer { try? session.setActive(false) }

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        try engine.setVolume(0.05)
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))

        let samples = [
            ("ape.ape", "ape"),
            ("tak.tak", "tak"),
            ("mpc8.mpc", "musepack8"),
            ("als.mp4", "mp4als"),
            ("wmapro.wma", "wmapro"),
            ("mpc7.mpc", "musepack7"),
            ("wmalossless.wma", "wmalossless"),
            ("cook.rm", "cook"),
        ]
        for (fileName, codec) in samples {
            do {
                let url = externalFFmpegFixtures.appendingPathComponent(fileName)
                #expect(FileManager.default.fileExists(atPath: url.path), "Missing \(fileName)")
                let probe = try FFmpegProbe.probe(localFileURL: url)
                #expect(probe.tracks.contains { $0.codec == codec && $0.isDecodable },
                        "\(fileName) did not expose a decodable \(codec) track")
                let resource = PlaybackResource.localFile(url)
                #expect(try await FFmpegMediaProbe().probe(resource).isPlayable)
                _ = try await FFmpegMetadataReader().readMetadata(from: resource)

                let decoder = try FFmpegAudioDecoder(localFileURL: url)
                let duration = try #require(decoder.duration)
                let components = duration.components
                let durationSeconds = Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000
                let positions = [Duration.zero, .seconds(durationSeconds / 2),
                                 .seconds(max(0, durationSeconds - 5))]
                let targetFrames = positions.map { position in
                    let components = position.components
                    let microseconds = components.seconds * 1_000_000
                        + components.attoseconds / 1_000_000_000_000
                    return Int((microseconds * Int64(decoder.format.sampleRate) + 999_999) / 1_000_000)
                }
                var referencePCM = [[Float]](repeating: [], count: positions.count)
                var frames = 0
                var peak: Float = 0
                while let buffer = try decoder.nextBuffer() {
                    let samples = try #require(buffer.floatChannelData)[0]
                    for index in 0 ..< Int(buffer.frameLength) {
                        let sample = samples[index]
                        peak = max(peak, abs(sample))
                        for target in targetFrames.indices
                        where frames + index >= targetFrames[target]
                            && referencePCM[target].count < 512 {
                            referencePCM[target].append(sample)
                        }
                    }
                    frames += Int(buffer.frameLength)
                }
                #expect(frames > Int(decoder.format.sampleRate * 5),
                        "\(fileName) ended before five seconds")
                #expect(peak.isFinite && peak > 0.001, "\(fileName) decoded silent PCM")
                #expect(abs(Double(frames) / decoder.format.sampleRate - durationSeconds) < 5,
                        "\(fileName) decoded duration differs from its container")

                for (index, position) in positions.enumerated() {
                    do {
                        try decoder.seek(to: position)
                        let buffer = try #require(try decoder.nextBuffer(frameCapacity: 512),
                                                  "\(fileName) has no PCM after seek to \(position)")
                        let actualPCM = try #require(buffer.floatChannelData)[0]
                        #expect(referencePCM[index].count == Int(buffer.frameLength))
                        let maximumDifference = (0 ..< min(referencePCM[index].count,
                                                           Int(buffer.frameLength)))
                            .map { abs(actualPCM[$0] - referencePCM[index][$0]) }
                            .max() ?? 0
                        #expect(maximumDifference < 0.0001,
                                "\(fileName) seek to \(position) differs by \(maximumDifference)")
                    } catch {
                        Issue.record("\(fileName) seek to \(position): \(error)")
                    }
                }

                let range = PlaybackRange(
                    start: .seconds(durationSeconds / 2),
                    end: .seconds(durationSeconds / 2 + 0.3)
                )
                let item = PlaybackItem(
                    itemID: MediaItemID(sourceID: .local, externalID: fileName),
                    resource: .local(url),
                    selection: PlaybackSelection(range: range),
                    displaySnapshot: PlaybackDisplaySnapshot(title: fileName, duration: duration)
                )
                try await engine.prepare(item, startAt: nil)
                try engine.play()
                for _ in 0 ..< 100 {
                    if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                    try await Task.sleep(for: .milliseconds(40))
                }
                #expect(engine.state.phase == .stopped,
                        "\(fileName) did not finish its CUE range with equalizer")
                #expect(engine.state.position == range.duration)
            } catch {
                Issue.record("\(fileName): \(error)")
            }
        }
    }
}
