import AudioToolbox
import AVFoundation
import FFmpegAudioKit
import Foundation
import MediaSourceAPI

/// FFmpeg decoding with the system AAC-LC and ALAC encoders.
public struct AppleAudioMediaTranscoder: MediaTranscoding, MediaLosslessValidating, Sendable {
    public init() {}

    public func transcode(
        _ request: MediaTranscodeRequest,
        progress: @escaping @Sendable (MediaTranscodeProgress) -> Void
    ) async throws -> MediaTranscodeResult {
        let task = Task.detached(priority: .utility) {
            try Self.transcodeSynchronously(request, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func validateLosslessPCM(inputURL: URL, outputURL: URL) async throws {
        let task = Task.detached(priority: .utility) {
            try Self.validateLosslessPCMSynchronously(inputURL: inputURL, outputURL: outputURL)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func validateLosslessPCMSynchronously(
        inputURL: URL,
        outputURL: URL
    ) throws {
        let input = try FFmpegAudioDecoder(localFileURL: inputURL)
        let output = try FFmpegAudioDecoder(localFileURL: outputURL)
        guard input.format.channelCount == output.format.channelCount,
              input.format.sampleRate == output.format.sampleRate
        else {
            throw MediaTranscodeError.validationFailed
        }

        while true {
            try Task.checkCancellation()
            let inputBuffer = try input.nextIntegerBuffer()
            let outputBuffer = try output.nextIntegerBuffer()
            guard inputBuffer?.frameLength == outputBuffer?.frameLength else {
                throw MediaTranscodeError.validationFailed
            }
            guard let inputBuffer, let outputBuffer else { return }
            guard let inputChannels = inputBuffer.int32ChannelData,
                  let outputChannels = outputBuffer.int32ChannelData
            else {
                throw MediaTranscodeError.validationFailed
            }
            let sampleByteCount = Int(inputBuffer.frameLength) * MemoryLayout<Int32>.size
            for channel in 0..<Int(inputBuffer.format.channelCount) {
                guard memcmp(inputChannels[channel], outputChannels[channel], sampleByteCount) == 0
                else {
                    throw MediaTranscodeError.validationFailed
                }
            }
        }
    }

    private static func transcodeSynchronously(
        _ request: MediaTranscodeRequest,
        progress: @escaping @Sendable (MediaTranscodeProgress) -> Void
    ) throws -> MediaTranscodeResult {
        try Task.checkCancellation()
        guard request.inputURL.isFileURL,
              request.outputURL.isFileURL,
              request.inputURL.standardizedFileURL != request.outputURL.standardizedFileURL,
              (request.sourceTrack.channelCount ?? 0) > 0,
              (request.sourceTrack.channelCount ?? 0) <= 2,
              let sourceSampleRate = request.sourceTrack.sampleRate,
              sourceSampleRate.isFinite,
              sourceSampleRate > 0
        else {
            throw MediaTranscodeError.unsupportedInput
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: request.outputURL.path) {
            try fileManager.removeItem(at: request.outputURL)
        }

        var outputFile: ExtAudioFileRef?
        do {
            let decoder = try FFmpegAudioDecoder(localFileURL: request.inputURL)
            let channelCount = Int(decoder.format.channelCount)
            guard channelCount == request.sourceTrack.channelCount else {
                throw MediaTranscodeError.unsupportedInput
            }

            let outputSampleRate: Double
            let outputBitDepth: Int?
            var outputFormat: AudioStreamBasicDescription
            switch request.target {
            case .aacLC:
                outputSampleRate = aacSampleRate(for: sourceSampleRate)
                outputBitDepth = nil
                outputFormat = encodedFormat(
                    formatID: kAudioFormatMPEG4AAC,
                    flags: 0,
                    sampleRate: outputSampleRate,
                    channelCount: channelCount,
                    framesPerPacket: 1_024
                )
            case .alac:
                guard let bitDepth = request.sourceTrack.bitDepth ?? decoder.sourceBitDepth,
                      bitDepth == 16 || bitDepth == 24
                else {
                    throw MediaTranscodeError.unsupportedBitDepth
                }
                outputSampleRate = sourceSampleRate
                outputBitDepth = bitDepth
                outputFormat = encodedFormat(
                    formatID: kAudioFormatAppleLossless,
                    flags: alacFlags(for: bitDepth),
                    sampleRate: outputSampleRate,
                    channelCount: channelCount,
                    framesPerPacket: 4_096
                )
            }
            try fillFormatInfo(&outputFormat)

            var createStatus = ExtAudioFileCreateWithURL(
                request.outputURL as CFURL,
                kAudioFileM4AType,
                &outputFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &outputFile
            )
            guard createStatus == noErr, let file = outputFile else {
                throw EncoderStatus(createStatus)
            }

            let clientFormat: AVAudioFormat
            switch request.target {
            case .aacLC:
                clientFormat = decoder.format
            case .alac:
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatInt32,
                    sampleRate: decoder.format.sampleRate,
                    channels: decoder.format.channelCount,
                    interleaved: false
                ) else {
                    throw MediaTranscodeError.unsupportedInput
                }
                clientFormat = format
            }
            var clientDescription = clientFormat.streamDescription.pointee
            createStatus = ExtAudioFileSetProperty(
                file,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout.size(ofValue: clientDescription)),
                &clientDescription
            )
            guard createStatus == noErr else { throw EncoderStatus(createStatus) }

            if case .aacLC(let bitRate) = request.target {
                try setAACBitRate(bitRate.rawValue, on: file)
            }

            let totalFrames = totalSourceFrames(
                duration: request.sourceDuration ?? decoder.duration,
                sampleRate: sourceSampleRate
            )
            var processedFrames: Int64 = 0
            progress(MediaTranscodeProgress(
                stage: .decoding,
                completedFrames: 0,
                totalFrames: totalFrames
            ))

            while true {
                try Task.checkCancellation()
                let buffer: AVAudioPCMBuffer?
                switch request.target {
                case .aacLC:
                    buffer = try decoder.nextBuffer()
                case .alac:
                    buffer = try decoder.nextIntegerBuffer()
                }
                guard let buffer else { break }
                let status = ExtAudioFileWrite(
                    file,
                    buffer.frameLength,
                    buffer.mutableAudioBufferList
                )
                guard status == noErr else { throw EncoderStatus(status) }
                processedFrames += Int64(buffer.frameLength)
                progress(MediaTranscodeProgress(
                    stage: .encoding,
                    completedFrames: processedFrames,
                    totalFrames: totalFrames
                ))
            }

            progress(MediaTranscodeProgress(
                stage: .finalizing,
                completedFrames: processedFrames,
                totalFrames: totalFrames
            ))
            let disposeStatus = ExtAudioFileDispose(file)
            outputFile = nil
            guard disposeStatus == noErr else { throw EncoderStatus(disposeStatus) }
            try Task.checkCancellation()

            let values = try request.outputURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize > 0 else {
                throw MediaTranscodeError.invalidOutput
            }
            return MediaTranscodeResult(
                outputURL: request.outputURL,
                target: request.target,
                processedFrames: processedFrames,
                sampleRate: outputSampleRate,
                channelCount: channelCount,
                bitDepth: outputBitDepth
            )
        } catch {
            if let file = outputFile {
                ExtAudioFileDispose(file)
                outputFile = nil
            }
            try? fileManager.removeItem(at: request.outputURL)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? MediaTranscodeError { throw error }
            if error is FFmpegAudioDecoder.DecoderError {
                throw MediaTranscodeError.decoderFailed
            }
            throw MediaTranscodeError.encoderFailed
        }
    }

    private static func encodedFormat(
        formatID: AudioFormatID,
        flags: AudioFormatFlags,
        sampleRate: Double,
        channelCount: Int,
        framesPerPacket: UInt32
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: flags,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    private static func fillFormatInfo(_ format: inout AudioStreamBasicDescription) throws {
        var size = UInt32(MemoryLayout.size(ofValue: format))
        let status = AudioFormatGetProperty(
            kAudioFormatProperty_FormatInfo,
            0,
            nil,
            &size,
            &format
        )
        guard status == noErr else { throw EncoderStatus(status) }
    }

    private static func setAACBitRate(_ bitRate: Int, on file: ExtAudioFileRef) throws {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        let getStatus = ExtAudioFileGetProperty(
            file,
            kExtAudioFileProperty_AudioConverter,
            &size,
            &converter
        )
        guard getStatus == noErr, let converter else {
            throw MediaTranscodeError.encoderUnavailable
        }

        var value = UInt32(bitRate)
        let setStatus = AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout.size(ofValue: value)),
            &value
        )
        guard setStatus == noErr else { throw EncoderStatus(setStatus) }

        var appliedValue: UInt32 = 0
        var appliedSize = UInt32(MemoryLayout.size(ofValue: appliedValue))
        let readStatus = AudioConverterGetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            &appliedSize,
            &appliedValue
        )
        guard readStatus == noErr else { throw EncoderStatus(readStatus) }
        guard appliedValue == value else { throw MediaTranscodeError.encoderFailed }
    }

    private static func alacFlags(for bitDepth: Int) -> AudioFormatFlags {
        switch bitDepth {
        case 16: return AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData)
        case 24: return AudioFormatFlags(kAppleLosslessFormatFlag_24BitSourceData)
        default: return 0
        }
    }

    private static func aacSampleRate(for source: Double) -> Double {
        guard source > 48_000 else { return source }
        let family44Distance = abs(source / 44_100 - (source / 44_100).rounded())
        let family48Distance = abs(source / 48_000 - (source / 48_000).rounded())
        return family44Distance < family48Distance ? 44_100 : 48_000
    }

    private static func totalSourceFrames(
        duration: Duration?,
        sampleRate: Double
    ) -> Int64? {
        guard let duration else { return nil }
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let frames = seconds * sampleRate
        guard frames.isFinite, frames > 0, frames <= Double(Int64.max) else { return nil }
        return Int64(frames.rounded())
    }

}

private struct EncoderStatus: Error, Sendable {
    let rawValue: OSStatus

    init(_ rawValue: OSStatus) {
        self.rawValue = rawValue
    }
}
