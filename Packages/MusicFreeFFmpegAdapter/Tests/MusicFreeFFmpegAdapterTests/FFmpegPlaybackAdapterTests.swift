import AVFoundation
import Foundation
import FFmpegAudioKit
import LocalMediaAdapter
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import PlaybackAPI
import Testing
import UIKit
@testable import FFmpegPlaybackAdapter

private final class AudioLevelCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0
    private var energy = [Double](repeating: 0, count: 5)
    private var frames = [Int](repeating: 0, count: 5)

    func setPhase(_ value: Int) {
        lock.lock()
        phase = value
        lock.unlock()
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var sum = 0.0
        for index in 0 ..< count {
            sum += Double(samples[index] * samples[index])
        }
        lock.lock()
        energy[phase] += sum
        frames[phase] += count
        lock.unlock()
    }

    func level(_ value: Int) -> (frames: Int, rms: Double) {
        lock.lock()
        defer { lock.unlock() }
        let count = frames[value]
        return (count, count > 0 ? sqrt(energy[value] / Double(count)) : 0)
    }
}

private func makeAudioLevelTap(
    _ levels: AudioLevelCapture
) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in levels.record(buffer) }
}

private final class AudioToneCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0
    private var samples = [[Float]](repeating: [], count: 2)
    private var sampleRates = [Double](repeating: 0, count: 2)

    func setPhase(_ value: Int) {
        lock.lock()
        phase = value
        lock.unlock()
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let input = UnsafeBufferPointer(start: channel, count: frames)
        let energy = input.reduce(0.0) { $0 + Double($1 * $1) } / Double(frames)
        guard energy > 0.0001 else { return }

        lock.lock()
        let available = max(0, 120_000 - samples[phase].count)
        samples[phase].append(contentsOf: input.prefix(available))
        sampleRates[phase] = buffer.format.sampleRate
        lock.unlock()
    }

    func output(_ value: Int) -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (samples[value], sampleRates[value])
    }
}

private func makeAudioToneTap(
    _ capture: AudioToneCapture
) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in capture.record(buffer) }
}

private func toneAmplitude(_ samples: [Float], sampleRate: Double, frequency: Double) -> Double {
    let count = samples.count / 2
    let start = (samples.count - count) / 2
    var sine = 0.0
    var cosine = 0.0
    for index in 0 ..< count {
        let angle = 2 * Double.pi * frequency * Double(index) / sampleRate
        let sample = Double(samples[start + index])
        sine += sample * sin(angle)
        cosine += sample * cos(angle)
    }
    return hypot(sine, cosine) / Double(count)
}

@Suite struct FFmpegPlaybackAdapterTests {
    @MainActor
    @Test func packageLinks() {
        // 能实例化引擎即说明库与 ffmpeg 动态库链接成功。
        _ = FFmpegPlaybackEngine()
    }

    @MainActor
    @Test func equalizerAppliesAndRejectsInvalidEffectsWithoutChangingOutput() throws {
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let descriptor = try #require(engine.equalizerDescriptor)
        #expect(engine.capabilities.contains(.equalizer))
        #expect(descriptor.bandCount == engine.equalizerUnit.bands.count)
        let gains = descriptor.bands.enumerated().map { index, band in
            EqualizerBandGain(
                centerFrequencyHz: band.centerFrequencyHz,
                gainDecibels: index == 0 ? 6 : -3
            )
        }
        try engine.apply(AudioEffectConfiguration(equalizer: EqualizerConfiguration(
            preampDecibels: -4,
            bandGains: gains
        )))
        #expect(!engine.equalizerUnit.bypass)
        #expect(engine.equalizerUnit.globalGain == -4)
        #expect(engine.equalizerUnit.bands.first?.gain == 6)
        #expect(engine.equalizerUnit.bands.last?.gain == -3)

        #expect(throws: PlaybackError.invalidEffects) {
            try engine.apply(AudioEffectConfiguration(
                equalizer: EqualizerConfiguration(bandGains: Array(gains.dropLast()))
            ))
        }
        #expect(engine.equalizerUnit.bands.first?.gain == 6)
        try engine.apply(.neutral)
        #expect(engine.equalizerUnit.bypass)
    }

    @MainActor
    @Test func audioEngineConfigurationChangeResumesLocalPlayback() async throws {
        let url = Bundle.module.bundleURL.appendingPathComponent("cue-seek-chirp.m4a")
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "route-change"),
            resource: .local(url),
            displaySnapshot: PlaybackDisplaySnapshot(title: "Route change")
        )

        try await engine.prepare(item, startAt: nil)
        let levels = AudioLevelCapture()
        engine.audioEngine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 1024, format: nil, block: makeAudioLevelTap(levels)
        )
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }
        try engine.play()
        for _ in 0 ..< 100 where engine.state.position < .milliseconds(250) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let positionBeforeChange = engine.state.position
        #expect(positionBeforeChange >= .milliseconds(250))
        #expect(levels.level(0).rms > 0.001)

        engine.audioEngine.stop()
        levels.setPhase(1)
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: engine.audioEngine
        )
        for _ in 0 ..< 100 where levels.level(1).rms <= 0.001 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let resumedOutput = levels.level(1)
        #expect(resumedOutput.frames >= 4_000)
        #expect(resumedOutput.rms > 0.001)
        for _ in 0 ..< 200 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position >= positionBeforeChange)
    }

    @MainActor
    @Test func equalizerChangesRenderedAudioLevel() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicfree-ffmpeg-eq-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try WAVFixture.make(frames: 132_300).write(to: file)

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "eq-signal"),
            resource: .local(file),
            displaySnapshot: PlaybackDisplaySnapshot(title: "EQ signal")
        )
        try await engine.prepare(item, startAt: nil)

        let levels = AudioLevelCapture()
        engine.audioEngine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 1024, format: nil, block: makeAudioLevelTap(levels)
        )
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }

        try engine.play()
        for _ in 0 ..< 100 where levels.level(0).frames < 20_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let flat = levels.level(0)
        #expect(flat.frames >= 20_000)
        #expect(flat.rms > 0.001)

        let descriptor = try #require(engine.equalizerDescriptor)
        let gains = descriptor.bands.map { band in
            EqualizerBandGain(
                centerFrequencyHz: band.centerFrequencyHz,
                gainDecibels: band.centerFrequencyHz == 500 ? 12 : 0
            )
        }
        try engine.apply(AudioEffectConfiguration(equalizer: EqualizerConfiguration(
            bandGains: gains
        )))
        try await Task.sleep(for: .milliseconds(150))
        levels.setPhase(1)
        for _ in 0 ..< 100 where levels.level(1).frames < 20_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let boosted = levels.level(1)
        #expect(boosted.frames >= 20_000)
        #expect(boosted.rms > flat.rms * 1.5)

        try engine.apply(.neutral)
        #expect(engine.equalizerUnit.bypass)
        try await Task.sleep(for: .milliseconds(150))
        levels.setPhase(2)
        for _ in 0 ..< 100 where levels.level(2).frames < 20_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = levels.level(2)
        #expect(restored.frames >= 20_000)
        #expect(restored.rms > flat.rms * 0.6)
        #expect(restored.rms < boosted.rms * 0.8)
    }

    @MainActor
    @Test func variableRateKeepsPitchAndChangesOutputDuration() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicfree-ffmpeg-rate-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try WAVFixture.make(frames: 44_100).write(to: file)

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "rate-pitch"),
            resource: .local(file),
            displaySnapshot: PlaybackDisplaySnapshot(title: "Rate", duration: .seconds(1))
        )
        let output = AudioToneCapture()
        engine.audioEngine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 1024, format: nil, block: makeAudioToneTap(output)
        )
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }

        for (phase, rate) in [Float(0.5), 2].enumerated() {
            output.setPhase(phase)
            try engine.setRate(rate)
            try await engine.prepare(item, startAt: nil)
            try engine.play()
            for _ in 0 ..< 180 {
                if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(engine.state.phase == .stopped, "\(rate)x did not finish playback")
            let rendered = output.output(phase)
            #expect(rendered.samples.count >= 10_000)
            let fundamental = toneAmplitude(
                rendered.samples, sampleRate: rendered.sampleRate, frequency: 440
            )
            let halfPitch = toneAmplitude(
                rendered.samples, sampleRate: rendered.sampleRate, frequency: 220
            )
            let doublePitch = toneAmplitude(
                rendered.samples, sampleRate: rendered.sampleRate, frequency: 880
            )
            #expect(fundamental > max(halfPitch, doublePitch) * 3)
        }
        let slow = output.output(0)
        let fast = output.output(1)
        #expect(slow.samples.count > fast.samples.count * 2)
    }

    @MainActor
    @Test func volumeAndMuteChangeRenderedOutput() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicfree-ffmpeg-volume-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try WAVFixture.make(frames: 176_400).write(to: file)

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "volume-mute"),
            resource: .local(file),
            displaySnapshot: PlaybackDisplaySnapshot(title: "Volume", duration: .seconds(4))
        )
        try await engine.prepare(item, startAt: nil)
        let levels = AudioLevelCapture()
        engine.audioEngine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 1024, format: nil, block: makeAudioLevelTap(levels)
        )
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }

        try engine.play()
        try await Task.sleep(for: .milliseconds(150))
        levels.setPhase(1)
        for _ in 0 ..< 100 where levels.level(1).frames < 20_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let full = levels.level(1)
        #expect(full.frames >= 20_000)
        #expect(full.rms > 0.001)

        try engine.setVolume(0.5)
        try await Task.sleep(for: .milliseconds(150))
        levels.setPhase(2)
        for _ in 0 ..< 100 where levels.level(2).frames < 20_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let quiet = levels.level(2)
        #expect(quiet.frames >= 20_000)
        #expect(quiet.rms > full.rms * 0.3)
        #expect(quiet.rms < full.rms * 0.7)

        try engine.setMuted(true)
        #expect(engine.isMuted)
        try await Task.sleep(for: .milliseconds(150))
        levels.setPhase(3)
        for _ in 0 ..< 100 where levels.level(3).frames < 20_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let muted = levels.level(3)
        #expect(muted.frames >= 20_000)
        #expect(muted.rms < quiet.rms * 0.05)

        try engine.setMuted(false)
        #expect(!engine.isMuted)
        #expect(engine.volume == 0.5)
        try await Task.sleep(for: .milliseconds(150))
        levels.setPhase(4)
        for _ in 0 ..< 100 where levels.level(4).frames < 20_000 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = levels.level(4)
        #expect(restored.frames >= 20_000)
        #expect(restored.rms > quiet.rms * 0.8)
        #expect(restored.rms < full.rms * 0.7)
    }

    @Test func dsfDecodesWithThePackagedFFmpegBinary() throws {
        // Synthetic quarter-second mono DSD64 fixture: DSF header and 0x69 payload.
        let url = Bundle.module.bundleURL.appendingPathComponent("dsd-quarter-second.dsf")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let probe = try FFmpegProbe.probe(localFileURL: url)
        #expect(probe.tracks.contains { $0.codec == "dsd_lsbf_planar" })
        #expect(probe.tracks.allSatisfy { $0.isDecodable })
        let decoder = try FFmpegAudioDecoder(localFileURL: url)
        let frame = try #require(try decoder.nextBuffer())
        #expect(frame.frameLength > 0)
    }

    @Test(arguments: [
        ("ac3.ac3", "ac3"), ("alac.m4a", "alac"), ("eac3.eac3", "eac3"),
        ("opus.opus", "opus"), ("tta.tta", "tta"), ("vorbis.ogg", "vorbis"),
        ("wavpack.wv", "wavpack"), ("wmav2.wma", "wmav2"),
        ("pcm24.wav", "pcm_s24le"), ("aiff.aiff", "pcm_s16be"),
        ("caf.caf", "pcm_s24le"), ("w64.w64", "pcm_s16le"),
        ("au.au", "pcm_s16be"), ("matroska.mka", "flac"),
        ("dts.dts", "dts"),
        ("wmav1.wma", "wmav1"), ("pcm32.wav", "pcm_s32le"),
        ("pcmfloat.wav", "pcm_f32le"), ("pcmu8.wav", "pcm_u8"),
        ("aiff24.aiff", "pcm_s24be"),
    ])
    func packagedBinaryDecodesRepresentativeAudioFormats(
        filename: String, codec: String
    ) throws {
        // Generated with FFmpeg from the same 523 Hz, 0.4 s sine signal.
        // Probe and decode must both work with the binary actually linked by Xcode.
        let url = Bundle.module.bundleURL.appendingPathComponent(filename)
        let probe = try FFmpegProbe.probe(localFileURL: url)
        #expect(probe.tracks.contains { $0.codec == codec && $0.isDecodable },
                "\(filename) probe did not report a decodable \(codec) stream")
        let decoder = try FFmpegAudioDecoder(localFileURL: url)
        var frames = 0
        var peak: Float = 0
        while let buffer = try decoder.nextBuffer() {
            let samples = try #require(buffer.floatChannelData)[0]
            frames += Int(buffer.frameLength)
            for index in 0 ..< Int(buffer.frameLength) {
                peak = max(peak, abs(samples[index]))
            }
        }
        #expect(frames > 0, "\(filename) produced no PCM")
        #expect(peak.isFinite && peak > 0.01, "\(filename) decoded silent or non-finite PCM")
    }

    @MainActor
    @Test func packagedFormatsPlayToCompletionAcrossEngineReuse() async throws {
        let filenames = [
            "ac3.ac3", "alac.m4a", "eac3.eac3", "opus.opus", "tta.tta",
            "vorbis.ogg", "wavpack.wv", "wmav2.wma", "pcm24.wav", "aiff.aiff",
            "caf.caf", "w64.w64", "au.au", "matroska.mka", "dts.dts",
            "wmav1.wma", "pcm32.wav", "pcmfloat.wav", "pcmu8.wav", "aiff24.aiff",
            "dsd-quarter-second.dsf",
        ]
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        let range = PlaybackRange(start: .milliseconds(50), end: .milliseconds(175))

        for filename in filenames {
            let url = try #require(Bundle.module.url(forResource: filename, withExtension: nil))
            let probe = try FFmpegProbe.probe(localFileURL: url)
            let item = PlaybackItem(
                itemID: MediaItemID(sourceID: .local, externalID: filename),
                resource: .local(url),
                displaySnapshot: PlaybackDisplaySnapshot(
                    title: filename,
                    duration: probe.duration
                )
            )
            try await engine.prepare(item, startAt: nil)
            try engine.play()
            for _ in 0 ..< 120 {
                if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(engine.state.phase == .stopped, "\(filename) did not finish playback")
            #expect(engine.state.position > .zero, "\(filename) ended without progress")

            try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))
            let cueItem = PlaybackItem(
                itemID: MediaItemID(sourceID: .local, externalID: "cue-\(filename)"),
                resource: .local(url),
                selection: PlaybackSelection(range: range),
                displaySnapshot: PlaybackDisplaySnapshot(title: filename, duration: probe.duration)
            )
            try await engine.prepare(cueItem, startAt: nil)
            #expect(engine.state.duration == range.duration)
            #expect(!engine.equalizerUnit.bypass)
            try engine.play()
            for _ in 0 ..< 120 {
                if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(engine.state.phase == .stopped, "\(filename) CUE range did not finish")
            #expect(engine.state.position == range.duration)
        }
    }

    @Test(arguments: [
        "ac3.ac3", "alac.m4a", "eac3.eac3", "opus.opus", "tta.tta",
        "vorbis.ogg", "wavpack.wv", "wmav2.wma", "pcm24.wav", "aiff.aiff",
        "caf.caf", "w64.w64", "au.au", "matroska.mka", "dts.dts",
        "wmav1.wma", "pcm32.wav", "pcmfloat.wav", "pcmu8.wav", "aiff24.aiff",
    ])
    func packagedFormatSeekMatchesSequentialPCM(filename: String) throws {
        let url = Bundle.module.bundleURL.appendingPathComponent(filename)
        let sequential = try FFmpegAudioDecoder(localFileURL: url)
        var reference: [Float] = []
        while let buffer = try sequential.nextBuffer() {
            let channel = try #require(buffer.floatChannelData)[0]
            reference.append(contentsOf: UnsafeBufferPointer(
                start: channel, count: Int(buffer.frameLength)
            ))
        }

        let seeked = try FFmpegAudioDecoder(localFileURL: url)
        try seeked.seek(to: .milliseconds(100))
        let buffer = try #require(try seeked.nextBuffer(frameCapacity: 512))
        let actual = try #require(buffer.floatChannelData)[0]
        let expectedFrame = Int((seeked.format.sampleRate * 100 / 1_000).rounded(.up))
        let count = min(256, Int(buffer.frameLength))
        #expect(count > 0 && reference.count >= expectedFrame + count)
        guard count > 0, reference.count >= expectedFrame + count else { return }
        let averageError = (0 ..< count).reduce(0.0) { sum, index in
            sum + Double(abs(actual[index] - reference[expectedFrame + index]))
        } / Double(count)
        var bestOffset = 0
        var bestError = Double.infinity
        if averageError >= 0.03 {
            let oneMillisecond = Int((seeked.format.sampleRate / 1_000).rounded(.up))
            for offset in -oneMillisecond ... oneMillisecond where expectedFrame + offset >= 0
                && expectedFrame + offset + count <= reference.count {
                let error = (0 ..< count).reduce(0.0) { sum, index in
                    sum + Double(abs(actual[index] - reference[expectedFrame + offset + index]))
                } / Double(count)
                if error < bestError {
                    bestOffset = offset
                    bestError = error
                }
            }
        }
        #expect(averageError < 0.03 || bestError < 0.015,
                "\(filename) seek at 100 ms: error \(averageError), best offset within 1 ms is \(bestOffset) frames with error \(bestError)")
    }

    @Test(arguments: [
        ("ac3.ac3", "ac3"), ("alac.m4a", "alac"), ("eac3.eac3", "eac3"),
        ("opus.opus", "opus"), ("tta.tta", "tta"), ("vorbis.ogg", "vorbis"),
        ("wavpack.wv", "wavpack"), ("wmav2.wma", "wmav2"),
        ("pcm24.wav", "pcm_s24le"), ("aiff.aiff", "pcm_s16be"),
        ("caf.caf", "pcm_s24le"), ("w64.w64", "pcm_s16le"),
        ("au.au", "pcm_s16be"), ("matroska.mka", "flac"),
        ("dts.dts", "dts"), ("wmav1.wma", "wmav1"),
        ("pcm32.wav", "pcm_s32le"), ("pcmfloat.wav", "pcm_f32le"),
        ("pcmu8.wav", "pcm_u8"), ("aiff24.aiff", "pcm_s24be"),
    ])
    func appAdaptersProbeAndReadMetadataAcrossFormats(
        filename: String, codec: String
    ) async throws {
        let url = try #require(Bundle.module.url(
            forResource: filename, withExtension: nil
        ))
        let resource = PlaybackResource.localFile(url)
        let result = try await FFmpegMediaProbe().probe(resource)
        #expect(result.isPlayable, "\(filename) has no playable audio stream")
        #expect(result.audioTracks.contains { track in
            track.codec == codec && track.isDecodable
                && track.stableID == "ffmpeg-stream:\(track.index)"
                && (track.sampleRate ?? 0) > 0
        }, "\(filename) lost its audio track information in the app adapter")
        if let duration = result.duration {
            #expect(duration > .zero && duration < .seconds(10))
        }
        let metadata = try await FFmpegMetadataReader().readMetadata(from: resource)
        if let duration = metadata.duration {
            #expect(duration > .zero && duration < .seconds(10))
        }
    }

    @Test func appMetadataReaderPreservesUnicodeTagsAndArtwork() async throws {
        // Metadata-only FLAC with a 32x32 JPEG attached picture and UTF-8 tags.
        let url = try #require(Bundle.module.url(
            forResource: "tagged-metadata", withExtension: "flac"
        ))
        let metadata = try await FFmpegMetadataReader().readMetadata(
            from: .localFile(url)
        )
        #expect(metadata.title == "秋の音")
        #expect(metadata.artist == "陈测试")
        #expect(metadata.album == "試聴アルバム")
        #expect(metadata.albumArtist == "合辑作者")
        #expect(metadata.trackNumber == 3)
        #expect(metadata.discNumber == 2)
        #expect(metadata.year == 2020)
        let artwork = try #require(metadata.firstArtwork)
        #expect(artwork.mimeType == "image/jpeg")
        #expect(artwork.data.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    @Test func localVideoArtworkComesFromEachAsset() async throws {
        var images: [Data] = []
        for name in ["artwork-red", "artwork-blue"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "mp4"))
            let probe = try await FFmpegMediaProbe().probe(.localFile(url))
            #expect(probe.isPlayable && probe.hasVideoTrack)
            let metadata = try await FFmpegMetadataReader().readMetadata(from: .localFile(url))
            let artwork = try #require(metadata.firstArtwork)
            let image = try #require(UIImage(data: artwork.data)?.cgImage)
            #expect(image.width == 64 && image.height == 64)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if name == "artwork-red" { #expect(pixel[0] > 200 && pixel[2] < 30) }
            else { #expect(pixel[2] > 200 && pixel[0] < 30) }
            images.append(artwork.data)
        }
        #expect(images[0] != images[1])
    }

    @MainActor
    @Test(arguments: ["current", "reencoded"])
    func realALACFixturesProbeDecodeAndPlayMiddleCUEWithEqualizer(name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "m4a"))
        let resource = PlaybackResource.localFile(url)
        let probe = try await FFmpegMediaProbe().probe(resource)
        #expect(probe.audioTracks.contains { $0.codec == "alac" && $0.isDecodable })
        #expect((probe.duration ?? .zero) > .seconds(190))
        let metadata = try await FFmpegMetadataReader().readMetadata(from: resource)
        #expect((metadata.duration ?? .zero) > .seconds(190))

        let sequentialDecoder = try FFmpegAudioDecoder(localFileURL: url)
        var decodedFrames = 0
        while let buffer = try sequentialDecoder.nextBuffer() {
            decodedFrames += Int(buffer.frameLength)
        }
        #expect(Double(decodedFrames) / sequentialDecoder.format.sampleRate > 190)

        let seekedDecoder = try FFmpegAudioDecoder(localFileURL: url)
        try seekedDecoder.seek(to: .seconds(100))
        #expect((try seekedDecoder.nextBuffer(frameCapacity: 512))?.frameLength ?? 0 > 0)

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let descriptor = try #require(engine.equalizerDescriptor)
        let preset = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: preset.configuration))
        let range = PlaybackRange(start: .seconds(100), end: .milliseconds(100_500))
        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "real-alac-\(name)"),
            resource: .local(url),
            selection: PlaybackSelection(range: range),
            displaySnapshot: PlaybackDisplaySnapshot(title: name, duration: probe.duration)
        )
        try await engine.prepare(item, startAt: nil)
        #expect(engine.state.duration == range.duration)
        try engine.play()
        for _ in 0 ..< 150 {
            if engine.state.phase == .stopped || engine.state.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.phase == .stopped, "\(name) failed to finish its CUE range")
        #expect(engine.state.position == range.duration)
    }

    @Test(arguments: ["current", "reencoded"])
    func realALACFixturesImportThroughFFmpegAdapters(name: String) async throws {
        let sourceURL = try #require(Bundle.module.url(forResource: name, withExtension: "m4a"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicFree-FFmpegALAC-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try LocalMediaConfiguration(
            managedRoot: root.appendingPathComponent("managed", isDirectory: true),
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
        )
        let repository = InMemoryLibraryRepository()
        let importer = try LocalMediaImporter(
            configuration: configuration,
            probe: FFmpegMediaProbe(),
            metadataReader: FFmpegMetadataReader(),
            libraryRepository: repository
        )
        var result: MediaImportResult?
        var failures: [String] = []
        for try await event in importer.importMedia(MediaImportRequest(
            importID: UUID(), urls: [sourceURL]
        )) {
            switch event {
            case .completed(_, let completed): result = completed
            case .itemFailed(_, _, let error): failures.append(error.diagnosticCode)
            default: break
            }
        }
        #expect(result?.imported == 1, "\(name): \(failures)")
        #expect(result?.failed == 0, "\(name): \(failures)")
        let importedTracks = await repository.appliedTransactions
            .flatMap(\.mutations)
            .compactMap { mutation -> Track? in
                guard case .upsert(.track(let track)) = mutation else { return nil }
                return track
            }
        #expect(importedTracks.count == 1)
    }

    @Test(arguments: ["m4a", "mp3", "flac", "ogg"], [0, 23, 200, 1_379, 2_899])
    func compressedCUESeekStartsAtRequestedAudioFrame(
        format: String, targetMilliseconds: Int
    ) throws {
        // A 3s, 44.1kHz mono chirp encoded as AAC/M4A. Generate the source with
        // f(t) = 430 + 240t Hz, then encode with ffmpeg -c:a aac -b:a 192k.
        // Comparing a seek against a sequential decode of the same file isolates
        // timestamp alignment from lossy encoding and resampler differences.
        let url = try #require(Bundle.module.url(
            forResource: "cue-seek-chirp", withExtension: format
        ))
        let sequential = try FFmpegAudioDecoder(localFileURL: url)
        var reference: [Float] = []
        while let buffer = try sequential.nextBuffer() {
            let channel = try #require(buffer.floatChannelData)
            reference.append(contentsOf: UnsafeBufferPointer(
                start: channel[0], count: Int(buffer.frameLength)
            ))
        }

        if targetMilliseconds == 0 {
            let fresh = try FFmpegAudioDecoder(localFileURL: url)
            let freshBuffer = try #require(try fresh.nextBuffer(frameCapacity: 1024))
            let first = try #require(freshBuffer.floatChannelData)[0]
            let freshError = (0 ..< 512).reduce(0.0) { sum, index in
                sum + Double(abs(first[index] - reference[index]))
            } / 512
            #expect(freshError < 0.015,
                    "\(format) two new decoders disagree by \(freshError)")
        }
        let seeked = try FFmpegAudioDecoder(localFileURL: url)
        try seeked.seek(to: .milliseconds(targetMilliseconds))
        let actualBuffer = try #require(try seeked.nextBuffer(frameCapacity: 1024))
        let actual = try #require(actualBuffer.floatChannelData)[0]
        let expectedFrame = (targetMilliseconds * Int(seeked.format.sampleRate) + 999) / 1_000
        #expect(reference.count > expectedFrame + 1024)
        let count = min(512, Int(actualBuffer.frameLength))
        let averageError = (0 ..< count).reduce(0.0) { sum, index in
            sum + Double(abs(actual[index] - reference[expectedFrame + index]))
        } / Double(count)
        #expect(averageError < 0.015,
                "\(format) seek at \(targetMilliseconds) ms: mean absolute PCM error \(averageError)")
    }

    @Test(arguments: ["m4a", "flac"], [1, 2, 4])
    func cueFrameSeekPreservesSubmillisecondBoundary(
        format: String, cueFrame: Int
    ) throws {
        let url = try #require(Bundle.module.url(
            forResource: "cue-seek-chirp", withExtension: format
        ))
        let sequential = try FFmpegAudioDecoder(localFileURL: url)
        var reference: [Float] = []
        while let buffer = try sequential.nextBuffer() {
            let channel = try #require(buffer.floatChannelData)
            reference.append(contentsOf: UnsafeBufferPointer(
                start: channel[0], count: Int(buffer.frameLength)
            ))
        }

        let seeked = try FFmpegAudioDecoder(localFileURL: url)
        let cuePosition = Duration.seconds(Double(cueFrame) / 75)
        try seeked.seek(to: cuePosition)
        let buffer = try #require(try seeked.nextBuffer(frameCapacity: 512))
        let actual = try #require(buffer.floatChannelData)[0]
        let expectedFrame = (cueFrame * Int(seeked.format.sampleRate) + 74) / 75
        let count = min(256, Int(buffer.frameLength))
        #expect(reference.count >= expectedFrame + count)
        let averageError = (0 ..< count).reduce(0.0) { sum, index in
            sum + Double(abs(actual[index] - reference[expectedFrame + index]))
        } / Double(count)
        #expect(averageError < 0.015,
                "\(format) CUE frame \(cueFrame): mean absolute PCM error \(averageError)")
    }

    @MainActor
    @Test func cueRangeSeekEndsOnceAtLogicalBoundaryAndReplays() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicfree-ffmpeg-cue-\(UUID().uuidString).wav")
        try WAVFixture.make(frames: 44_100).write(to: url)
        let engine = FFmpegPlaybackEngine()
        defer {
            engine.dispose()
            try? FileManager.default.removeItem(at: url)
        }
        let itemID = MediaItemID(sourceID: .local, externalID: "cue-range")
        let range = PlaybackRange(start: .milliseconds(200), end: .milliseconds(550))
        let events = engine.makeEventStream()
        let eventTask = Task { @MainActor in
            var captured: [PlaybackEvent] = []
            for await event in events {
                captured.append(event)
                if case .ended = event { break }
            }
            return captured
        }
        let item = PlaybackItem(
            itemID: itemID,
            resource: .local(url),
            selection: PlaybackSelection(range: range),
            displaySnapshot: PlaybackDisplaySnapshot(title: "CUE", duration: .seconds(1))
        )
        try await engine.prepare(item, startAt: .milliseconds(50))
        #expect(engine.state.duration == .milliseconds(350))
        #expect(engine.state.position == .milliseconds(50))
        await #expect(throws: PlaybackError.invalidPosition) {
            try await engine.seek(to: .milliseconds(351))
        }
        try await engine.seek(to: .milliseconds(100))
        #expect(engine.state.position == .milliseconds(100))
        try engine.play()
        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.phase == .stopped)
        #expect(engine.state.position == range.duration)
        if engine.state.phase != .stopped { eventTask.cancel() }
        let captured = await eventTask.value
        let ended = captured.filter { event in
            if case .ended(_, let id, _) = event { return id == itemID }
            return false
        }
        #expect(ended.count == 1)
        try engine.play()
        #expect(engine.state.position == .zero)
    }

    @MainActor
    @Test(arguments: ["m4a", "mp3", "flac", "ogg"])
    func compressedCUERangeWithEqualizerReachesLogicalEnd(format: String) async throws {
        let url = try #require(Bundle.module.url(
            forResource: "cue-seek-chirp", withExtension: format
        ))
        let range = PlaybackRange(start: .milliseconds(1_100), end: .milliseconds(1_450))
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))
        #expect(!engine.equalizerUnit.bypass)

        let item = PlaybackItem(
            itemID: MediaItemID(sourceID: .local, externalID: "cue-\(format)"),
            resource: .local(url),
            selection: PlaybackSelection(range: range),
            displaySnapshot: PlaybackDisplaySnapshot(title: format, duration: .seconds(3))
        )
        try await engine.prepare(item, startAt: .milliseconds(50))
        #expect(engine.state.duration == .milliseconds(350))
        #expect(engine.state.position == .milliseconds(50))
        try await engine.seek(to: .milliseconds(100))
        try engine.play()

        for _ in 0 ..< 100 {
            if engine.state.phase == .stopped { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(engine.state.phase == .stopped, "\(format) did not finish its CUE range")
        #expect(engine.state.position == range.duration)
    }

    @MainActor
    @Test func adjacentCUERangesPlayIndependentlyWithEqualizer() async throws {
        let url = try #require(Bundle.module.url(
            forResource: "cue-seek-chirp", withExtension: "m4a"
        ))
        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))

        let ranges = [
            PlaybackRange(start: .milliseconds(500), end: .milliseconds(900)),
            PlaybackRange(start: .milliseconds(900), end: .milliseconds(1_300)),
        ]
        var previousGeneration: PlaybackGeneration?
        for (index, range) in ranges.enumerated() {
            let itemID = MediaItemID(sourceID: .local, externalID: "adjacent-cue-\(index)")
            let item = PlaybackItem(
                itemID: itemID,
                resource: .local(url),
                selection: PlaybackSelection(range: range),
                displaySnapshot: PlaybackDisplaySnapshot(title: "CUE \(index)", duration: .seconds(3))
            )
            try await engine.prepare(item, startAt: nil)
            #expect(engine.state.itemID == itemID)
            #expect(engine.state.position == .zero)
            #expect(engine.state.duration == range.duration)
            #expect(engine.state.generation != previousGeneration)
            #expect(!engine.equalizerUnit.bypass)
            previousGeneration = engine.state.generation

            try engine.play()
            for _ in 0 ..< 100 {
                if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(engine.state.phase == .stopped, "CUE segment \(index) did not finish")
            #expect(engine.state.position == range.duration)
        }
    }

    @MainActor
    @Test func adjacentCUERangesRenderTheirOwnTone() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicfree-adjacent-cue-tones-\(UUID().uuidString).wav")
        try WAVFixture.make(frames: 88_200, secondToneAtFrame: 44_100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = FFmpegPlaybackEngine()
        defer { engine.dispose() }
        let descriptor = try #require(engine.equalizerDescriptor)
        let bassBoost = try #require(descriptor.presets.first { $0.name == "Bass Boost" })
        try engine.apply(AudioEffectConfiguration(equalizer: bassBoost.configuration))

        let output = AudioToneCapture()
        engine.audioEngine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 1024, format: nil,
            block: makeAudioToneTap(output)
        )
        defer { engine.audioEngine.mainMixerNode.removeTap(onBus: 0) }

        let ranges = [
            PlaybackRange(start: .zero, end: .seconds(1)),
            PlaybackRange(start: .seconds(1), end: .seconds(2)),
        ]
        for (index, range) in ranges.enumerated() {
            output.setPhase(index)
            let item = PlaybackItem(
                itemID: MediaItemID(sourceID: .local, externalID: "tone-cue-\(index)"),
                resource: .local(url),
                selection: PlaybackSelection(range: range),
                displaySnapshot: PlaybackDisplaySnapshot(title: "Tone \(index)", duration: .seconds(2))
            )
            try await engine.prepare(item, startAt: nil)
            try engine.play()
            for _ in 0 ..< 100 {
                if engine.state.phase == .stopped || engine.state.phase == .failed { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(engine.state.phase == .stopped, "CUE tone segment \(index) did not finish")
        }

        for (index, frequency) in [440.0, 880.0].enumerated() {
            let rendered = output.output(index)
            guard rendered.samples.count > 10_000, rendered.sampleRate > 0 else {
                Issue.record("CUE segment \(index) did not render enough audio")
                return
            }
            let expected = toneAmplitude(
                rendered.samples, sampleRate: rendered.sampleRate, frequency: frequency
            )
            let other = toneAmplitude(
                rendered.samples, sampleRate: rendered.sampleRate,
                frequency: frequency == 440 ? 880 : 440
            )
            #expect(expected > 0.005)
            #expect(expected > other * 5, "CUE segment \(index) contains the previous tone")
        }
    }
}
