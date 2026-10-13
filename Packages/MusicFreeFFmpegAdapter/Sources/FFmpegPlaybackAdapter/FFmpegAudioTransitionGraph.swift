import AVFoundation
import CPlaybackTransition
import FFmpegAudioKit
import Foundation
import MusicDomain
import PlaybackAPI

/// Queue-owned conversion. DSP sees the original source format; both slots
/// publish the same planar Float32 format to the render thread.
private final class TransitionPCMReader {
    let renderFrameCount: Int64
    private let decoder: FFmpegAudioDecoder
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private var sourceRemaining: Int64
    private var outputRemaining: Int64
    private var processor: (any FFmpegPCMProcessing)?

    init(decoder: FFmpegAudioDecoder, format: AVAudioFormat, frameCount: Int64,
         processorFactory: FFmpegPCMProcessorFactory?) throws {
        self.decoder = decoder
        self.format = format
        sourceRemaining = frameCount < 0 ? .max : frameCount
        renderFrameCount = frameCount < 0 ? -1 : Int64((Double(frameCount) * format.sampleRate / decoder.format.sampleRate).rounded())
        outputRemaining = renderFrameCount < 0 ? .max : renderFrameCount
        if decoder.format == format { converter = nil }
        else {
            guard let converter = AVAudioConverter(from: decoder.format, to: format) else {
                throw FFmpegAudioDecoder.DecoderError.unsupportedFormat
            }
            self.converter = converter
        }
        processor = try processorFactory?(decoder.format)
    }

    func reset() { processor?.reset(); processor = nil; converter?.reset() }

    private func readSource(_ capacity: UInt32) throws -> AVAudioPCMBuffer? {
        guard sourceRemaining > 0 else { return nil }
        guard let buffer = try decoder.nextBuffer(frameCapacity: UInt32(min(Int64(capacity), sourceRemaining))) else {
            sourceRemaining = 0
            return nil
        }
        sourceRemaining -= Int64(buffer.frameLength)
        try processor?.process(buffer)
        return buffer
    }

    func nextBuffer() throws -> AVAudioPCMBuffer? {
        guard outputRemaining > 0 else { return nil }
        let buffer: AVAudioPCMBuffer
        if let converter {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(min(8192, outputRemaining))) else {
                throw FFmpegAudioDecoder.DecoderError.unsupportedFormat
            }
            var conversionError: NSError?
            var sourceError: Error?
            let status = converter.convert(to: output, error: &conversionError) { [self] count, status in
                do {
                    guard let input = try readSource(min(count, 8192)) else {
                        status.pointee = .endOfStream
                        return nil
                    }
                    status.pointee = .haveData
                    return input
                } catch {
                    sourceError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let sourceError { throw sourceError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw FFmpegAudioDecoder.DecoderError.unsupportedFormat }
            // Drain the converter through EOF, including the last partial block.
            if output.frameLength == 0 {
                guard status == .endOfStream else { throw FFmpegAudioDecoder.DecoderError.unsupportedFormat }
                return nil
            }
            buffer = output
        } else {
            guard let input = try readSource(UInt32(min(8192, outputRemaining))) else { return nil }
            buffer = input
        }
        outputRemaining -= Int64(buffer.frameLength)
        return buffer
    }
}

/// A private two-slot PCM bus. Decoding/polling run outside render; render only
/// reads bounded SPSC rings, atomics and a frame envelope.
@MainActor
final class FFmpegAudioTransitionGraph {
    final class Storage: @unchecked Sendable {
        let handle: OpaquePointer
        let capacity: UInt32
        init(format: AVAudioFormat, overlapSeconds: Double) throws {
            // Decode beyond the selected overlap (up to 12 seconds). The extra two
            // blocks allow EOF discovery before its overlap starts, even when
            // the last decoded block is full. Memory stays bounded per slot.
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 384_000,
                  (1...8).contains(format.channelCount) else { throw FFmpegAudioDecoder.DecoderError.unsupportedFormat }
            capacity = UInt32(max(3, min(12, overlapSeconds)) * format.sampleRate) + 2 * 8192
            guard let handle = mft_create(format.channelCount, capacity) else {
                throw PlaybackError.engineFailure(code: "transition_allocation_failed")
            }
            self.handle = handle
        }
        deinit { mft_destroy(handle) }
    }

    private final class Producer: @unchecked Sendable {
        let queue: DispatchQueue
        let storage: Storage
        let decoder: FFmpegAudioDecoder
        let slot: Int32
        let start: Duration?
        let total: Int64
        let skipBoundarySilence: Bool
        let format: AVAudioFormat
        private var timer: DispatchSourceTimer?
        private var started = false
        private var cancelled = false
        private let processorFactory: FFmpegPCMProcessorFactory?
        private var reader: TransitionPCMReader?
        private let scanCancellation = FFmpegBoundaryScanCancellation()
        let onError: @Sendable (Error) -> Void

        init(storage: Storage, decoder: FFmpegAudioDecoder, slot: Int32,
             start: Duration?, total: Int64, skipBoundarySilence: Bool, format: AVAudioFormat, queue: DispatchQueue, processorFactory: FFmpegPCMProcessorFactory?, onError: @escaping @Sendable (Error) -> Void) {
            self.storage = storage; self.decoder = decoder; self.slot = slot
            self.start = start; self.total = total; self.format = format; self.onError = onError
            self.queue = queue
            self.processorFactory = processorFactory
            self.skipBoundarySilence = skipBoundarySilence
        }

        func begin() {
            queue.async { [self] in
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(10))
                timer.setEventHandler { [weak self] in self?.fill() }
                self.timer = timer
                timer.resume()
            }
        }
        private func stop() { cancelled = true; timer?.cancel(); timer = nil; reader?.reset(); reader = nil }
        func cancel() { scanCancellation.cancel(); queue.async { [self] in stop() } }
        func cancelAndWait() async {
            scanCancellation.cancel()
            await withCheckedContinuation { continuation in
                queue.async { [self] in stop(); continuation.resume() }
            }
        }
        private func fill() {
            guard !cancelled else { return }
            do {
                if !started {
                    started = true
                    var frameCount = total
                    if skipBoundarySilence {
                        // Analysis failures fall back to the original song. All
                        // seek/decode work stays serialized with this producer.
                        let boundaries = (try? FFmpegSilenceBoundaries.analyze(decoder, isCancelled: {
                            self.scanCancellation.isCancelled
                        })) ?? .init()
                        if scanCancellation.isCancelled { stop(); return }
                        let origin = start ?? .zero
                        let rate = decoder.format.sampleRate
                        let originSeconds = Double(origin.components.seconds) + Double(origin.components.attoseconds) / 1e18
                        let originFrame = Int64((originSeconds * rate).rounded(.up))
                        // A seek into the outro remains at the requested point.
                        // Likewise, middle-of-song silence is never trimmed.
                        let canTrim = boundaries.endFrame.map { $0 > originFrame } ?? true
                        let firstFrame = canTrim ? max(originFrame, boundaries.startFrame) : originFrame
                        try decoder.seek(to: .seconds(Double(firstFrame) / rate))
                        if canTrim, let end = boundaries.endFrame { frameCount = end - firstFrame }
                        mft_set_source_offset(storage.handle, slot,
                            Int64((Double(firstFrame - originFrame) * format.sampleRate / rate).rounded()))
                    } else if let start { try decoder.seek(to: start) }
                    let reader = try TransitionPCMReader(decoder: decoder, format: format, frameCount: frameCount,
                                                         processorFactory: processorFactory)
                    self.reader = reader
                    mft_set_total(storage.handle, slot, reader.renderFrameCount)
                }
                while mft_space(storage.handle, slot) >= 8192 {
                    guard let buffer = try reader?.nextBuffer(), let data = buffer.floatChannelData else {
                        // EOF publishes the actual converted sample count;
                        // compressed duration metadata is never a cutoff.
                        mft_set_eof(storage.handle, slot)
                        timer?.cancel(); timer = nil
                        return
                    }
                    // Pointers are borrowed only while publishing this block.
                    let planes = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) as UnsafePointer<Float>? }
                    let accepted = planes.withUnsafeBufferPointer {
                        mft_push(storage.handle, slot, $0.baseAddress, buffer.frameLength)
                    }
                    guard accepted else { throw PlaybackError.engineFailure(code: "transition_ring_write_failed") }
                }
            } catch {
                cancelled = true; timer?.cancel(); timer = nil
                onError(error)
            }
        }
    }

    let node: AVAudioSourceNode
    let format: AVAudioFormat
    private let storage: Storage
    private var producers: [Producer?] = [nil, nil]
    private var producerIDs: [UUID?] = [nil, nil]
    private var items: [PlaybackItem?] = [nil, nil]
    private var tickets: [PlaybackTransitionTicket?] = [nil, nil]
    private var polling: Task<Void, Never>?
    private var seenHandoff: Int64 = -1
    private var retirements: [Int32: PlaybackTransitionTicket] = [:]
    private var ended = false
    private var cancelled = false
    private var wasStarved = false
    private var onCommit: ((LogicalPlaybackCommit) -> Void)?
    private var preparationID: UUID?
    private let onEnd: () -> Void
    private let onError: (Error) -> Void
    private let processorFactory: FFmpegPCMProcessorFactory?
    private let skipBoundarySilence: Bool
    var onSecondaryFailure: (() -> Void)?
    var onHalted: (() -> Void)?
    var onStarvationChanged: ((Bool) -> Void)?
    var onRetirement: ((PlaybackTransitionTicket, Int64, Duration, PlaybackCompletionReason) -> Void)?
    var isOverlapping: Bool { mft_overlapping(storage.handle) }
    var activeSlot: Int32 { Int32(mft_active(storage.handle)) }
    var position: Duration { .seconds(Double(mft_source_position(storage.handle, activeSlot)) / format.sampleRate) }
    var playedDuration: Duration { .seconds(Double(mft_position(storage.handle, activeSlot)) / format.sampleRate) }
    func supportsOverlap(_ duration: Duration) -> Bool {
        seconds(duration) * format.sampleRate <= Double(storage.capacity - 2 * 8192)
    }

    static func renderFormat(for source: AVAudioFormat) -> AVAudioFormat {
        // Mono and stereo tracks share one bus, including low-rate BVT/WMA.
        // Preserve the original layout for multichannel sources. Apple's
        // channel-count-only initializer only constructs mono/stereo formats.
        guard source.channelCount <= 2 else { return source }
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    }

    init(decoder: FFmpegAudioDecoder, item: PlaybackItem, start: Duration?, frameCount: Int64, queue: DispatchQueue,
         processorFactory: FFmpegPCMProcessorFactory?,
         maximumOverlap: Duration = .seconds(3), skipBoundarySilence: Bool = false,
         onEnd: @escaping () -> Void, onError: @escaping (Error) -> Void) throws {
        let format = Self.renderFormat(for: decoder.format)
        self.format = format
        self.onEnd = onEnd; self.onError = onError
        self.processorFactory = processorFactory
        self.skipBoundarySilence = skipBoundarySilence
        let overlapSeconds = Double(maximumOverlap.components.seconds) + Double(maximumOverlap.components.attoseconds) / 1e18
        let storage = try Storage(format: format, overlapSeconds: overlapSeconds)
        self.storage = storage
        node = Self.makeNode(format: format, storage: storage)
        items[0] = item
        install(decoder: decoder, slot: 0, start: start, frameCount: frameCount, queue: queue)
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                guard let self, !Task.isCancelled else { return }
                self.poll()
            }
        }
    }

    // AVAudioSourceNode's SDK block is not annotated Sendable. Construct it
    // outside MainActor so Swift does not insert an executor assertion on RT.
    private nonisolated static func makeNode(format: AVAudioFormat, storage: Storage) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [storage] _, _, count, buffers in
            mft_render_buffers(storage.handle, buffers, count)
            return noErr
        }
    }

    private func install(decoder: FFmpegAudioDecoder, slot: Int32, start: Duration?, frameCount: Int64, queue: DispatchQueue) {
        let producerID = UUID()
        producerIDs[Int(slot)] = producerID
        let producer = Producer(storage: storage, decoder: decoder, slot: slot, start: start,
                                total: frameCount, skipBoundarySilence: skipBoundarySilence, format: format, queue: queue,
                                processorFactory: processorFactory) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled, self.producerIDs[Int(slot)] == producerID else { return }
                if self.activeSlot == slot { self.onError(error) }
                else { self.onSecondaryFailure?() }
            }
        }
        producers[Int(slot)] = producer
        producer.begin()
    }

    func releaseNextSlot() async throws {
        let slot = 1 - activeSlot
        while !mft_idle(storage.handle, slot) {
            try await Task.sleep(for: .milliseconds(10))
            if cancelled { throw CancellationError() }
        }
        try Task.checkCancellation()
        // Deliver retirement before clearing its render evidence, and wait for
        // the old queue owner to release its processor before slot reuse.
        poll(reportEnd: false)
        await producers[Int(slot)]?.cancelAndWait()
        try Task.checkCancellation()
        guard !cancelled, !mft_ended(storage.handle) else { throw CancellationError() }
        producers[Int(slot)] = nil; producerIDs[Int(slot)] = nil
        items[Int(slot)] = nil; tickets[Int(slot)] = nil
    }

    func prepareNext(decoder: FFmpegAudioDecoder, item: PlaybackItem, ticket: PlaybackTransitionTicket,
                     frameCount: Int64, overlap: Duration, queue: DispatchQueue, onCommit: @escaping (LogicalPlaybackCommit) -> Void) async throws {
        let operationID = UUID()
        preparationID = operationID
        try await releaseNextSlot()
        guard preparationID == operationID else { throw CancellationError() }
        let slot = 1 - activeSlot
        // Previous producer stopped at EOF before retirement; a slot is never
        // reused while its samples are still in the render overlap.
        mft_reset_slot(storage.handle, slot)
        items[Int(slot)] = item; tickets[Int(slot)] = ticket; self.onCommit = onCommit
        install(decoder: decoder, slot: slot, start: nil, frameCount: frameCount, queue: queue)
        while mft_space(storage.handle, slot) == storage.capacity {
            if mft_slot_eof(storage.handle, slot) { throw PlaybackError.resourceUnavailable }
            try await Task.sleep(for: .milliseconds(10))
            if cancelled || preparationID != operationID { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard preparationID == operationID else { throw CancellationError() }
        let availableA = max(0, Int64(seconds(overlap) * format.sampleRate))
        // The render thread clamps short tracks after decoded totals become
        // available, including totals learned at EOF after arming.
        mft_arm(storage.handle, slot, UInt32(min(availableA, Int64(12 * format.sampleRate))))
    }

    func cancelNext(quiesceRender: () -> Void) {
        preparationID = nil
        if mft_disarm(storage.handle) { quiesceRender() }
        // Keep callbacks for a handoff already claimed by the render thread.
        // releaseNextSlot stops the old producer before resetting its ring.
        poll(reportEnd: false)
        let slot = 1 - activeSlot
        if mft_idle(storage.handle, slot) {
            producerIDs[Int(slot)] = nil
            producers[Int(slot)]?.cancel()
        }
    }

    func interruptOverlap() {
        mft_interrupt_overlap(storage.handle)
        poll(reportEnd: false, retirementReason: .interrupted)
    }

    func ramp(_ duration: Duration, pause: Bool) {
        let frames = UInt32(min(3 * format.sampleRate, max(0, seconds(duration) * format.sampleRate)))
        mft_command(storage.handle, frames, pause)
    }

    func configureFadeOut(_ duration: Duration) {
        mft_fade_out(storage.handle, UInt32(min(3 * format.sampleRate, max(0, seconds(duration) * format.sampleRate))))
    }

    func cancel() {
        cancelled = true
        poll(reportEnd: false)
        for (slot, ticket) in retirements {
            onRetirement?(ticket, mft_frame(storage.handle), .seconds(Double(mft_position(storage.handle, slot)) / format.sampleRate), .interrupted)
        }
        retirements.removeAll()
        polling?.cancel(); polling = nil
        producers.forEach { $0?.cancel() }
        onCommit = nil; onHalted = nil; onSecondaryFailure = nil; onRetirement = nil; onStarvationChanged = nil
    }
    func synchronize() { poll() }
    private func poll(reportEnd: Bool = true, retirementReason: PlaybackCompletionReason = .ended) {
        let starved = mft_starved(storage.handle)
        if reportEnd, wasStarved != starved { wasStarved = starved; onStarvationChanged?(starved) }
        let handoff = mft_handoff(storage.handle)
        if handoff >= 0, handoff != seenHandoff,
           let item = items[Int(activeSlot)], let ticket = tickets[Int(activeSlot)] {
            seenHandoff = handoff
            retirements[1 - activeSlot] = ticket
            onCommit?(LogicalPlaybackCommit(ticket: ticket, item: item, renderFrame: handoff, sampleRate: format.sampleRate))
        }
        for (slot, ticket) in retirements {
            let frame = mft_retired_frame(storage.handle, slot)
            if frame >= 0 {
                retirements[slot] = nil
                onRetirement?(ticket, frame, .seconds(Double(mft_position(storage.handle, slot)) / format.sampleRate), retirementReason)
            }
        }
        if mft_halted(storage.handle) { let action = onHalted; onHalted = nil; action?() }
        if reportEnd, mft_ended(storage.handle), !ended { ended = true; onEnd() }
    }
    private func seconds(_ value: Duration) -> Double {
        Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
    }
}
