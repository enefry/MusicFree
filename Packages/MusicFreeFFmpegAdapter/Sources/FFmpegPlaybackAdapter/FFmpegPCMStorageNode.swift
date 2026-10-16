import AVFoundation
import CPlaybackTransition
import Foundation

public struct FFmpegPCMStorageReport: Codable, Sendable {
    public let fileURL: URL
    public let sampleRate: Double
    public let channels: UInt32
    public let receivedFrames: UInt64
    public let writtenFrames: UInt64
    public let droppedFrames: UInt64
    public let rejectedFrames: UInt64
    public let writeError: String?
    /// Describes persistence of delivered blocks; a realtime tap can withhold
    /// its final partial block. Use offline rendering for exact output coverage.
    public var persistedAllDeliveredFrames: Bool {
        droppedFrames == 0 && rejectedFrames == 0 && writeError == nil && receivedFrames == writtenFrames
    }
}

/// Optional storage stage, separate from playback control. The single audio
/// producer only copies Float32 into a bounded C SPSC ring. AVAudioFile and the
/// reusable drain buffer are confined to fileQueue after initialization.
final class FFmpegPCMStorageNode: @unchecked Sendable {
    let handle: OpaquePointer
    let sampleRate: Double
    let channels: UInt32
    private let fileURL: URL
    private let fileQueue = DispatchQueue(label: "com.musicfree.pcm-storage", qos: .utility)
    private let timer: DispatchSourceTimer
    private let buffer: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private var writtenFrames: UInt64 = 0
    private var writeError: String?
    private var finished: FFmpegPCMStorageReport?

    init(fileURL: URL, format: AVAudioFormat, capacity: UInt32? = nil) throws {
        guard format.commonFormat == .pcmFormatFloat32,
              format.sampleRate.isFinite, (1...384_000).contains(format.sampleRate),
              (1...8).contains(format.channelCount),
              !FileManager.default.fileExists(atPath: fileURL.path),
              let planar = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                        channels: format.channelCount, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: planar, frameCapacity: 16_384) else {
            throw FFmpegPCMRecordingError.invalidFormatOrDestination
        }
        var settings = planar.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let handle = mfc_create(format.channelCount, capacity ?? UInt32(format.sampleRate * 2)) else {
            throw FFmpegPCMRecordingError.invalidFormatOrDestination
        }
        self.handle = handle; self.buffer = buffer
        self.fileURL = fileURL; sampleRate = format.sampleRate; channels = format.channelCount
        self.file = file
        timer = DispatchSource.makeTimerSource(queue: fileQueue)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.resume()
    }

    deinit { timer.cancel(); mfc_destroy(handle) }

    nonisolated func record(_ input: AVAudioPCMBuffer) {
        guard input.format.commonFormat == .pcmFormatFloat32,
              input.format.sampleRate == sampleRate, input.format.channelCount == channels else {
            mfc_reject(handle, input.frameLength); return
        }
        mfc_push_buffers(handle, input.audioBufferList, input.frameLength)
    }

    nonisolated static func tap(_ storage: FFmpegPCMStorageNode) -> AVAudioNodeTapBlock {
        { [storage] buffer, _ in storage.record(buffer) }
    }

    /// Quiesce/remove the producer before closing and freeing its handle.
    func closeInput() { mfc_close(handle) }

    var receivedFrames: UInt64 { mfc_stats(handle).receivedFrames }

    func finish() async -> FFmpegPCMStorageReport {
        closeInput()
        return await withCheckedContinuation { continuation in
            fileQueue.async { [self] in
                if let finished { continuation.resume(returning: finished); return }
                timer.cancel()
                drain()
                file = nil // Close/finalize the WAV header before returning.
                let stats = mfc_stats(handle)
                let report = FFmpegPCMStorageReport(fileURL: fileURL, sampleRate: sampleRate, channels: channels,
                    receivedFrames: stats.receivedFrames, writtenFrames: writtenFrames,
                    droppedFrames: stats.droppedFrames, rejectedFrames: stats.rejectedFrames, writeError: writeError)
                finished = report
                continuation.resume(returning: report)
            }
        }
    }

    private func drain() {
        while true {
            buffer.frameLength = buffer.frameCapacity
            let count = mfc_pop_buffers(handle, buffer.mutableAudioBufferList, buffer.frameCapacity)
            guard count > 0 else { return }
            buffer.frameLength = count
            guard writeError == nil else { continue }
            do { try file?.write(from: buffer); writtenFrames += UInt64(count) }
            catch { writeError = String(describing: error); closeInput() }
        }
    }
}

public enum FFmpegPCMRecordingError: Error {
    case requiresStoppedEngine
    case requiresPreparedTransitionGraph
    case alreadyRecording
    case notRecording
    case invalidFormatOrDestination
    case requiresOfflineRendering
}

public struct FFmpegPCMRecordingReport: Codable, Sendable {
    public let transitionMix: FFmpegPCMStorageReport
    public let output: FFmpegPCMStorageReport
    public let outputDelivery: String
    public let endedByGraphChange: Bool
}
