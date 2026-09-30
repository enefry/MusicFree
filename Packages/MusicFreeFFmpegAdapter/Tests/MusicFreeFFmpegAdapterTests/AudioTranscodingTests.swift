import AVFoundation
import FFmpegAudioKit
import Foundation
import MediaSourceAPI
import Testing
@testable import FFmpegPlaybackAdapter

@Suite(.serialized) struct AudioTranscodingTests {
    @Test(arguments: AACLCBitRate.allCases)
    func transcodesEveryAACLCBitRate(_ bitRate: AACLCBitRate) async throws {
        let inputURL = Bundle.module.bundleURL.appendingPathComponent("current.m4a")
        let outputURL = try outputURL(
            named: "aac-\(bitRate.rawValue)-\(UUID().uuidString).m4a"
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sourceProbe = try await FFmpegMediaProbe().probe(.localFile(inputURL))
        let sourceTrack = try #require(sourceProbe.decodableAudioTracks.first)
        let result = try await AppleAudioMediaTranscoder().transcode(
            MediaTranscodeRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                target: .aacLC(bitRate),
                sourceTrack: sourceTrack,
                sourceDuration: sourceProbe.duration
            ),
            progress: { _ in }
        )

        #expect(result.target == .aacLC(bitRate))
        #expect(result.processedFrames > 0)
        let outputProbe = try await FFmpegMediaProbe().probe(.localFile(outputURL))
        let outputTrack = try #require(outputProbe.decodableAudioTracks.first)
        #expect(outputTrack.codec == "aac")
        #expect(outputTrack.channelCount == sourceTrack.channelCount)
        #expect((try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
    }

    @Test(arguments: ["aiff.aiff", "pcm24.wav"])
    func alacPreservesIntegerPCMSamples(_ fixture: String) async throws {
        let inputURL = Bundle.module.bundleURL.appendingPathComponent(fixture)
        let outputURL = try outputURL(named: "alac-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sourceProbe = try await FFmpegMediaProbe().probe(.localFile(inputURL))
        let sourceTrack = try #require(sourceProbe.decodableAudioTracks.first)
        let result = try await AppleAudioMediaTranscoder().transcode(
            MediaTranscodeRequest(
                inputURL: inputURL,
                outputURL: outputURL,
                target: .alac,
                sourceTrack: sourceTrack,
                sourceDuration: sourceProbe.duration
            ),
            progress: { _ in }
        )

        #expect(result.target == .alac)
        let outputProbe = try await FFmpegMediaProbe().probe(.localFile(outputURL))
        #expect(outputProbe.decodableAudioTracks.first?.codec == "alac")
        #expect(try integerSamples(at: inputURL) == integerSamples(at: outputURL))
    }

    private func integerSamples(at url: URL) throws -> [[Int32]] {
        let decoder = try FFmpegAudioDecoder(localFileURL: url)
        let channelCount = Int(decoder.format.channelCount)
        var result = [[Int32]](repeating: [], count: channelCount)
        while let buffer = try decoder.nextIntegerBuffer() {
            let frames = Int(buffer.frameLength)
            let channels = try #require(buffer.int32ChannelData)
            for channel in 0..<channelCount {
                result[channel].append(contentsOf: UnsafeBufferPointer(
                    start: channels[channel],
                    count: frames
                ))
            }
        }
        return result
    }

    private func outputURL(named name: String) throws -> URL {
        var repositoryRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let directory = repositoryRoot
            .appendingPathComponent(".noindex/tmp/audio-transcoding-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
