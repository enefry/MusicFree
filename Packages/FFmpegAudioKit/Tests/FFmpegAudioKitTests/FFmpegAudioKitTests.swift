import XCTest
@testable import FFmpegAudioKit

final class FFmpegAudioKitTests: XCTestCase {
    private var sampleURL: URL {
        ProcessInfo.processInfo.environment["SAMPLE_AUDIO"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.module.bundleURL.appendingPathComponent("dsd-quarter-second.dsf")
    }

    func testPackagedBinaryDecodesDSF() throws {
        let url = Bundle.module.bundleURL.appendingPathComponent("dsd-quarter-second.dsf")
        let probe = try FFmpegProbe.probe(localFileURL: url)
        XCTAssertTrue(probe.tracks.contains { $0.codec == "dsd_lsbf_planar" && $0.isDecodable })
        let decoder = try FFmpegAudioDecoder(localFileURL: url)
        XCTAssertGreaterThan(try decoder.nextBuffer()?.frameLength ?? 0, 0)
    }

    func testCUEFrameSeekPreservesSubmillisecondPosition() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffmpeg-cue-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frameCount = 8_820
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frameCount * 2))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(44_100))
        append(UInt32(88_200))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        append(UInt32(frameCount * 2))
        for frame in 0 ..< frameCount { append(Int16(frame)) }
        try wav.write(to: url)

        let sequential = try FFmpegAudioDecoder(localFileURL: url)
        var reference: [Float] = []
        while let buffer = try sequential.nextBuffer() {
            guard let samples = buffer.floatChannelData?[0] else {
                XCTFail("Missing PCM channel")
                return
            }
            reference.append(contentsOf: UnsafeBufferPointer(
                start: samples, count: Int(buffer.frameLength)
            ))
        }
        XCTAssertEqual(reference.count, frameCount)

        for cueFrame in [1, 2, 4] {
            let decoder = try FFmpegAudioDecoder(localFileURL: url)
            try decoder.seek(to: .seconds(Double(cueFrame) / 75))
            let buffer = try XCTUnwrap(decoder.nextBuffer(frameCapacity: 128))
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            let expectedFrame = cueFrame * 44_100 / 75
            XCTAssertEqual(Int(buffer.frameLength), 128)
            for index in 0 ..< 128 {
                XCTAssertEqual(samples[index], reference[expectedFrame + index])
            }
        }
    }

    func testProbeReadsContainerAndDuration() throws {
        let result = try FFmpegProbe.probe(localFileURL: sampleURL)
        XCTAssertFalse(result.tracks.isEmpty, "应至少探测到一条音频流")
        XCTAssertNotNil(result.duration)
    }

    func testDecoderProducesFrames() throws {
        let decoder = try FFmpegAudioDecoder(localFileURL: sampleURL)
        let buffer = try decoder.nextBuffer()
        XCTAssertNotNil(buffer)
        XCTAssertGreaterThan(buffer?.frameLength ?? 0, 0)
    }

    func testMetadataReads() throws {
        let meta = try FFmpegMetadataReader.read(localFileURL: sampleURL)
        // 至少能读到时长；标签/封面因文件而异，不强断言。
        XCTAssertNotNil(meta.duration)
    }
}
