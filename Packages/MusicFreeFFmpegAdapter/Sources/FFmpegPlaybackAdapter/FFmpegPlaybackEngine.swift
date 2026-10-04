import AVFoundation
import FFmpegAudioKit
import Foundation
import MediaSourceAPI
import MusicDomain
import OSLog
import PlaybackAPI

/// 独立于 VLC 的音频播放引擎：ffmpeg 解码 → AVAudioEngine 输出。
///
/// 范围：本地文件（`.localFile`）与 HTTP(S) 远程资源（`.remote`，经
/// `URLSessionByteSource` 读取）的 prepare/play/pause/stop/seek，变速
/// （timePitch），音量/静音。远程资源仅在服务端支持 Range 时可 seek
/// （`capabilities` 随之变化）。
/// 支持 CUE 分段播放及 AVAudioUnitEQ 均衡器。其它效果能力位按实现逐步点亮。
@MainActor
public final class FFmpegPlaybackEngine: PlaybackEngine, PlaybackAudioControlling, PlaybackTransitionControlling {
    private static let logger = Logger(subsystem: "win.tools4me.music", category: "ffmpeg-playback")
    /// 随当前资源变化：远程顺序流（服务端不支持 Range，或尚未拿到响应头）
    /// 不含 `.seeking`，供上层据此隐藏进度拖动。
    public var capabilities: PlaybackCapabilities {
        var result: PlaybackCapabilities = [.variableRate, .equalizer]
        if remoteSource?.isSeekable != false { result.insert(.seeking) }
        if configuredRate == 1, decoder.map({ $0.format.channelCount <= 8 }) ?? true {
            result.insert(.fade)
            if (currentItem.map(supportsLocalTransition) ?? true), pcmProcessorFactory == nil || processorPreservesTiming {
                result.formUnion([.gapless, .crossfade])
            }
        }
        return result
    }
    public var equalizerDescriptor: EqualizerDescriptor? { Self.equalizerLayout }

    /// Narrow hook handed off to A in the 1.4 playback development log. The
    /// existing single/dual source graph, queues and transition clocks remain
    /// unchanged. Each engine owns a separate zero-latency/tail effect instance.
    public func setPostEqualizerEffect(_ node: AVAudioNode?) throws {
        guard postEqualizerEffect !== node else { return }
        guard !audioEngine.isRunning else { throw PlaybackError.invalidEffects }
        audioEngine.disconnectNodeOutput(equalizerUnit)
        if let previous = postEqualizerEffect {
            audioEngine.disconnectNodeOutput(previous); previous.reset()
            audioEngine.detach(previous)
        }
        postEqualizerEffect = node
        if let node { audioEngine.attach(node) }
        if let decoder { connectPostEqualizerOutput(format: transitionGraph?.format ?? feederFormat(for: decoder)) }
    }

    private func connectPostEqualizerOutput(format: AVAudioFormat) {
        if let effect = postEqualizerEffect {
            effect.reset()
            audioEngine.connect(equalizerUnit, to: effect, format: format)
            audioEngine.connect(effect, to: audioEngine.mainMixerNode, format: format)
        } else {
            audioEngine.connect(equalizerUnit, to: audioEngine.mainMixerNode, format: format)
        }
    }

    private static let equalizerLayout: EqualizerDescriptor = {
        let bands = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].map {
            EqualizerBandDescriptor(
                centerFrequencyHz: Double($0),
                minimumGainDecibels: -12,
                maximumGainDecibels: 12
            )
        }
        let profiles: [(UInt32, String, [Float])] = [
            (0, "Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            (1, "Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
            (2, "Treble Boost", [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
            (3, "Vocal", [-2, -1, 0, 1, 2, 3, 3, 2, 0, -1])
        ]
        let presets = profiles.map { id, name, gains in
            EqualizerPresetDescriptor(
                id: id,
                name: name,
                configuration: EqualizerConfiguration(
                    bandGains: zip(bands, gains).map { band, gain in
                        EqualizerBandGain(
                            centerFrequencyHz: band.centerFrequencyHz,
                            gainDecibels: gain
                        )
                    }
                )
            )
        }
        return EqualizerDescriptor(bands: bands, presets: presets)
    }()
    public private(set) var state: PlaybackState = .idle
    public private(set) var volume: Float = 1
    public private(set) var isMuted: Bool = false

    let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    // Kept in the signal chain even when disabled so applying EQ does not
    // reconnect a running player and discard scheduled audio.
    let equalizerUnit = AVAudioUnitEQ(numberOfBands: 10)
    // Optional host-owned post-mix effect. This graph has no PluginRuntime dependency.
    private var postEqualizerEffect: AVAudioNode?
    private let decodeQueue = DispatchQueue(label: "com.musicfree.ffmpeg.decode")
    private let makeRemoteSource: (RemotePlaybackRequest) -> URLSessionByteSource

    private var eventContinuation: AsyncStream<PlaybackEvent>.Continuation?
    private var currentItem: PlaybackItem?
    private var currentDuration: Duration?
    private var configuredRate: Float = 1
    private var configuredEqualizer: EqualizerConfiguration?
    private var basePosition: Duration = .zero
    private var decoder: FFmpegAudioDecoder?
    // 远程资源的字节源。解码队列可能阻塞在它的 read 上，teardown 必须先取消它。
    private var remoteSource: URLSessionByteSource?
    private var feeder: DecodeFeeder?
    private var transitionGraph: FFmpegAudioTransitionGraph?
    private var transitionConfiguration: AudioTransitionConfiguration = .disabled
    private var transitionContinuation: AsyncStream<LogicalPlaybackCommit>.Continuation?
    private var transitionCommitHandler: (@MainActor (LogicalPlaybackCommit) -> Void)?
    private var transitionRetirementHandler: (@MainActor (PlaybackTransitionRetirement) -> Void)?
    private var transitionInvalidationHandler: (@MainActor (PlaybackTransitionTicket, PlaybackTransitionInvalidationReason) -> Void)?
    private var preparedNextTicket: PlaybackTransitionTicket?
    private var renderedDurationBase: Duration = .zero
    private var retirementDurationBases: [UUID: Duration] = [:]
    private var pcmProcessorFactory: FFmpegPCMProcessorFactory?
    private var processorPreservesTiming = false
    private var nextPreparationID: UUID?
    private var controlVersion: UInt64 = 0
    private var softControlTask: Task<Void, Never>?
    private var graphBasePosition: Duration = .zero
    private let nextDecodeQueue = DispatchQueue(label: "com.musicfree.ffmpeg.next")
    private var currentDecodeQueue: DispatchQueue?
    // 每次取消/替换 feeder 都递增。feeder 的结束/错误回调经 Task 异步 hop 回
    // MainActor，可能晚于 seek/stop 到达；只有 epoch 匹配的回调才生效。
    private var feederEpoch: UInt64 = 0
    // 用户意图是否在播放；实际输出还要求 feeder 不处于饥饿。
    private var wantsPlayback = false
    private var isStarved = true
    private var bufferingTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var didReachEnd = false
    private var recoveringSequentialRoute = false
    // 仅 init 写入、deinit 读取；NotificationCenter 的移除是线程安全的，故可从
    // nonisolated deinit 访问（Swift 6 严格并发要求显式标注）。
    private nonisolated(unsafe) var configChangeObserver: NSObjectProtocol?

    /// 远程探测读取上限：够大多数容器识别编码参数，同时控制起播耗时。
    private static let remoteProbeSize: Int64 = 1024 * 1024
    private static let defaultInFlightBufferCount = 3
    private static let queueHeadroomDuration: TimeInterval = 1
    private static let maximumInFlightBufferCount = 256
    /// 饥饿持续超过该时长才对外发布 `.buffering`，避免短暂抖动闪烁加载态。
    private static let bufferingDebounce: Duration = .milliseconds(300)

    static func inFlightBufferCount(
        sampleRate: Double,
        outputLatency: TimeInterval
    ) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return Self.defaultInFlightBufferCount
        }
        let reportedLatency = outputLatency.isFinite ? max(0, outputLatency) : 0
        let targetQueueDuration = reportedLatency + Self.queueHeadroomDuration
        // Clamp before converting to Int, including overflow from extreme latency values.
        let targetBufferCount = Int(min(Double(Self.maximumInFlightBufferCount), ceil(
            targetQueueDuration * sampleRate / Double(DecodeFeeder.bufferFrameCapacity)
        )))
        return min(
            Self.maximumInFlightBufferCount,
            max(
                Self.defaultInFlightBufferCount,
                targetBufferCount
            )
        )
    }

    public convenience init() {
        self.init(remoteSessionConfiguration: .default)
    }

    init(remoteSessionConfiguration: URLSessionConfiguration) {
        makeRemoteSource = { request in
            URLSessionByteSource(request: request, configuration: remoteSessionConfiguration)
        }
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
        audioEngine.attach(equalizerUnit)
        for (band, descriptor) in zip(equalizerUnit.bands, Self.equalizerLayout.bands) {
            band.filterType = .parametric
            band.frequency = Float(descriptor.centerFrequencyHz)
            band.bandwidth = 1
            band.gain = 0
            band.bypass = false
        }
        equalizerUnit.bypass = true
        // AVAudioEngine 在音频会话路由/硬件格式变化时会 post 配置变更通知，并
        // 自行停止（例如会话激活后硬件采样率协商、插拔耳机）。不处理就会「播了
        // 一下就没声」——已排队 buffer 放完后引擎已停、`.dataPlayedBack` 回调不
        // 再触发，投喂循环卡在信号量上永久静默。收到通知即从当前位置重建。
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    public func makeEventStream() -> AsyncStream<PlaybackEvent> {
        guard eventContinuation == nil else { return AsyncStream { $0.finish() } }
        let (stream, continuation) = AsyncStream<PlaybackEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        eventContinuation = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.eventContinuation = nil
            }
        }
        return stream
    }

    public func prepare(_ item: PlaybackItem, startAt: Duration?) async throws {
        try Task.checkCancellation()
        let logicalDuration = item.selection.range?.duration ?? item.display.duration
        try validatePosition(startAt ?? .zero, duration: logicalDuration)

        let open: @Sendable () throws -> FFmpegAudioDecoder
        var source: URLSessionByteSource?
        switch item.resource {
        case let .localFile(url), let .leasedLocalFile(url, _):
            open = { try FFmpegAudioDecoder(localFileURL: url) }
        case let .remote(request):
            guard let scheme = request.url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                throw PlaybackError.resourceUnavailable
            }
            guard !request.isExpired(at: Date()) || request.canRefresh else {
                throw PlaybackError.resourceUnavailable
            }
            let remote = makeRemoteSource(request)
            let probeSize = Self.remoteProbeSize
            source = remote
            open = {
                try remote.open()
                return try FFmpegAudioDecoder(byteSource: remote, probeSize: probeSize)
            }
        }

        let generation = state.generation.advanced()
        teardown()
        currentItem = item
        currentDuration = logicalDuration
        basePosition = startAt ?? .zero
        didReachEnd = false
        remoteSource = source

        // 先同步发布新 generation，再进入异步打开；await 期间到来的 stop/新
        // prepare 会改写 state，恢复后据此识别本次 prepare 已过期。
        state = PlaybackState(
            phase: .preparing,
            generation: generation,
            itemID: item.itemID,
            position: basePosition,
            duration: currentDuration
        )
        yield(.phaseChanged(generation: generation, itemID: item.itemID, phase: .preparing))

        let decoder: FFmpegAudioDecoder
        let sourceToCancel = source
        do {
            decoder = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    decodeQueue.async {
                        do {
                            continuation.resume(returning: try open())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                sourceToCancel?.cancel()
            }
        } catch {
            if Task.isCancelled {
                if isCurrentPreparation(generation) { stop() }
                throw CancellationError()
            }
            guard isCurrentPreparation(generation) else { throw CancellationError() }
            Self.logger.error("prepare failed: \(Self.safeErrorCode(error), privacy: .public)")
            let playbackError = Self.playbackError(from: error, fallbackCode: "ffmpeg_open_failed")
            fail(playbackError, generation: generation, itemID: item.itemID)
            throw playbackError
        }
        guard isCurrentPreparation(generation) else { throw CancellationError() }
        if Task.isCancelled {
            stop()
            throw CancellationError()
        }

        self.decoder = decoder
        renderedDurationBase = .zero
        currentDecodeQueue = decodeQueue
        currentDuration = item.selection.range?.duration ?? decoder.duration ?? item.display.duration

        let format = feederFormat(for: decoder)
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: equalizerUnit, format: format)
        connectPostEqualizerOutput(format: format)
        timePitch.rate = configuredRate
        timePitch.bypass = configuredRate == 1
        playerNode.volume = 1
        audioEngine.mainMixerNode.outputVolume = isMuted ? 0 : volume

        audioEngine.prepare()

        if let range = item.selection.range, range.start > .zero,
           remoteSource?.isSeekable == false {
            let error = PlaybackError.unsupportedCapability(.seeking)
            fail(error, generation: generation, itemID: item.itemID)
            throw error
        }
        if basePosition > .zero, remoteSource?.isSeekable == false {
            // 顺序流无法定位到续播点，只能从头开始；须在发布状态前归零，
            // 否则 displayPosition 会一直停在续播点。
            basePosition = .zero
        }

        state = PlaybackState(
            phase: .preparing,
            generation: generation,
            itemID: item.itemID,
            position: basePosition,
            duration: currentDuration
        )

        let absoluteStart = item.selection.range?.absolutePosition(
            forLogicalPosition: basePosition
        ) ?? basePosition
        // A CUE selection beginning at file offset zero can play on an HTTP
        // stream without Range support; even seek(0) requires a seekable input.
        let initialSeek: Duration? = absoluteStart > .zero ? absoluteStart : nil
        startFeeder(
            decoder: decoder,
            initialSeek: initialSeek,
            generation: generation,
            itemID: item.itemID
        )
    }

    public func play() throws {
        softControlTask?.cancel(); softControlTask = nil
        controlVersion &+= 1
        transitionGraph?.onHalted = nil
        if recoveringSequentialRoute {
            guard currentItem != nil else { throw PlaybackError.noCurrentItem }
            wantsPlayback = true
            return
        }
        guard let item = currentItem, let decoder else { throw PlaybackError.noCurrentItem }
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                throw PlaybackError.engineFailure(code: "audio_engine_start_failed")
            }
        }
        let generation = state.generation
        var position = state.position
        if didReachEnd {
            // 自然播完后再 play：feeder 已结束，从头重新投喂，否则只会静默地「播放」。
            if remoteSource?.isSeekable == false {
                // 顺序流不能 seek 回零；重新打开请求及解码器才能重播。
                Task { @MainActor [weak self] in
                    guard let self, self.didReachEnd,
                          self.currentItem?.itemID == item.itemID else { return }
                    do {
                        try await self.prepare(item, startAt: .zero)
                    } catch {
                        // prepare 已发布失败事件；stop/切歌引起的取消无需再上报。
                        return
                    }
                    do {
                        try self.play()
                    } catch let error as PlaybackError {
                        self.fail(error, generation: self.state.generation, itemID: item.itemID)
                    } catch {
                        self.fail(
                            .engineFailure(code: "audio_engine_restart_failed"),
                            generation: self.state.generation,
                            itemID: item.itemID
                        )
                    }
                }
                return
            }
            restartFeeder(
                decoder: decoder,
                from: .zero,
                generation: generation,
                itemID: item.itemID
            )
            position = .zero
        }
        wantsPlayback = true
        transitionGraph?.ramp(configuredRate == 1 ? transitionConfiguration.fadeInDuration : .zero, pause: false)
        updateOutput()
        if state.phase == .failed { throw state.error ?? PlaybackError.engineFailure(code: "audio_engine_start_failed") }
        state = PlaybackState(
            phase: .playing,
            generation: generation,
            itemID: item.itemID,
            position: position,
            duration: currentDuration
        )
        yield(.phaseChanged(generation: generation, itemID: item.itemID, phase: .playing))
        startPositionUpdates()
    }

    public func pause() {
        if configuredRate == 1, let graph = transitionGraph, transitionConfiguration.fadeOutDuration > .zero,
           audioEngine.isRunning {
            cancelNext()
            controlVersion &+= 1
            let version = controlVersion
            let graph = transitionGraph ?? graph
            graph.ramp(transitionConfiguration.fadeOutDuration, pause: true)
            graph.onHalted = { [weak self] in
                guard let self, self.controlVersion == version else { return }
                self.hardPause()
            }
            scheduleSoftDeadline(transitionConfiguration.fadeOutDuration, version: version, stop: false)
            wantsPlayback = false
            let position = displayPosition()
            state = PlaybackState(phase: .paused, generation: state.generation,
                                  itemID: state.itemID, position: position, duration: currentDuration)
            if let itemID = state.itemID { yield(.phaseChanged(generation: state.generation, itemID: itemID, phase: .paused)) }
            return
        }
        hardPause()
    }

    public func hardPause() {
        softControlTask?.cancel(); softControlTask = nil
        wantsPlayback = false
        updateOutput()
        cancelNext()
        controlVersion &+= 1
        nextPreparationID = nil
        let position = displayPosition()
        transitionGraph?.interruptOverlap()
        bufferingTask?.cancel()
        bufferingTask = nil
        positionTask?.cancel()
        positionTask = nil
        let generation = state.generation
        state = PlaybackState(
            phase: .paused,
            generation: generation,
            itemID: state.itemID,
            position: position,
            duration: currentDuration
        )
        if let itemID = state.itemID {
            yield(.phaseChanged(generation: generation, itemID: itemID, phase: .paused))
        }
    }

    public func stop() {
        if configuredRate == 1, let graph = transitionGraph, transitionConfiguration.fadeOutDuration > .zero,
           audioEngine.isRunning {
            cancelNext()
            controlVersion &+= 1
            let version = controlVersion
            let graph = transitionGraph ?? graph
            graph.ramp(transitionConfiguration.fadeOutDuration, pause: true)
            graph.onHalted = { [weak self] in
                guard let self, self.controlVersion == version else { return }
                self.hardStop()
            }
            scheduleSoftDeadline(transitionConfiguration.fadeOutDuration, version: version, stop: true)
            wantsPlayback = false
            state = PlaybackState(phase: .stopped, generation: state.generation,
                itemID: state.itemID, position: displayPosition(), duration: currentDuration)
            return
        }
        hardStop()
    }

    public func waitForSoftStop() async { await softControlTask?.value }

    public func hardStop() {
        softControlTask?.cancel(); softControlTask = nil
        cancelNext()
        controlVersion &+= 1
        nextPreparationID = nil
        let generation = state.generation
        let itemID = currentItem?.itemID
        teardown()
        currentItem = nil
        currentDuration = nil
        // itemID 置空：协调器据此在下一次 resume 时重新 prepare，而不是对已拆除
        // 的引擎直接 play()。
        state = PlaybackState(
            phase: .stopped,
            generation: generation,
            position: state.position,
            duration: state.duration
        )
        if let itemID {
            yield(.phaseChanged(generation: generation, itemID: itemID, phase: .stopped))
        }
    }

    public func seek(to position: Duration) async throws {
        cancelNext()
        softControlTask?.cancel(); softControlTask = nil
        controlVersion &+= 1
        guard capabilities.contains(.seeking) else {
            throw PlaybackError.unsupportedCapability(.seeking)
        }
        guard let item = currentItem, let decoder else {
            throw PlaybackError.noCurrentItem
        }
        try validatePosition(position, duration: currentDuration)

        let generation = state.generation
        restartFeeder(
            decoder: decoder,
            from: position,
            generation: generation,
            itemID: item.itemID
        )
        state = PlaybackState(
            phase: state.phase,
            generation: generation,
            itemID: item.itemID,
            position: position,
            duration: currentDuration
        )
        updateOutput()
        if wantsPlayback {
            startPositionUpdates()
        }
        if state.phase == .failed { throw state.error ?? PlaybackError.engineFailure(code: "audio_engine_start_failed") }
    }

    public func setRate(_ rate: Float) throws {
        guard rate.isFinite, rate > 0 else { throw PlaybackError.invalidRate }
        guard rate == 1 || capabilities.contains(.variableRate) else {
            throw PlaybackError.unsupportedCapability(.variableRate)
        }
        if configuredRate != rate { cancelNext() }
        configuredRate = rate
        timePitch.rate = rate
        timePitch.bypass = rate == 1
        // Rejoin the transition bus after a resource was prepared or seeked
        // at non-1 speed, retaining its serial decoder owner and position.
        if rate == 1, transitionGraph == nil, let decoder, let item = currentItem,
           decoder.format.channelCount <= 8, capabilities.contains(.seeking),
           !didReachEnd, !recoveringSequentialRoute {
            restartFeeder(decoder: decoder, from: displayPosition(),
                          generation: state.generation, itemID: item.itemID)
            updateOutput()
            if state.phase == .failed { throw state.error ?? PlaybackError.engineFailure(code: "audio_engine_start_failed") }
        }
        transitionGraph?.configureFadeOut(rate == 1 ? transitionConfiguration.fadeOutDuration : .zero)
        if rate != 1 { transitionGraph?.ramp(.zero, pause: false) }
    }

    public func apply(_ effects: AudioEffectConfiguration) throws {
        if let equalizer = effects.equalizer {
            _ = try equalizer.validated(against: Self.equalizerLayout)
        }
        if effects.replayGain.mode != .disabled {
            throw PlaybackError.unsupportedCapability(.replayGain)
        }
        if transitionConfiguration.mode != effects.transition.mode || transitionConfiguration.crossfadeDuration != effects.transition.crossfadeDuration { cancelNext() }
        transitionConfiguration = effects.transition
        transitionGraph?.configureFadeOut(effects.rate == 1 ? effects.transition.fadeOutDuration : .zero)
        try setRate(effects.rate)
        configuredEqualizer = effects.equalizer
        applyConfiguredEqualizer()
    }

    private func applyConfiguredEqualizer() {
        guard let configuration = configuredEqualizer else {
            equalizerUnit.bypass = true
            return
        }
        for (gain, band) in zip(configuration.bandGains, equalizerUnit.bands) {
            band.gain = gain.gainDecibels
        }
        equalizerUnit.globalGain = configuration.preampDecibels
        equalizerUnit.bypass = false
    }

    public func setVolume(_ volume: Float) throws {
        guard volume.isFinite, (0 ... 1).contains(volume) else {
            throw PlaybackError.invalidEffects
        }
        self.volume = volume
        audioEngine.mainMixerNode.outputVolume = isMuted ? 0 : volume
    }

    public func setMuted(_ muted: Bool) throws {
        isMuted = muted
        audioEngine.mainMixerNode.outputVolume = muted ? 0 : volume
    }

    public func dispose() {
        teardown()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        eventContinuation?.finish()
        eventContinuation = nil
        transitionContinuation?.finish()
        transitionContinuation = nil
        transitionCommitHandler = nil
        transitionRetirementHandler = nil
        transitionInvalidationHandler = nil
    }

    // MARK: - Private

    // A wall-clock deadline only terminates a starved/non-rendering soft stop;
    // it never drives gain. Network reads cannot keep a soft control alive.
    private func scheduleSoftDeadline(_ duration: Duration, version: UInt64, stop: Bool) {
        softControlTask?.cancel()
        softControlTask = Task { [weak self] in
            // The command begins on an output callback; completion is polled
            // afterwards. Normal completion still stops at envelope zero.
            do { try await Task.sleep(for: duration + .milliseconds(250)) } catch { return }
            guard let self, self.controlVersion == version else { return }
            if stop { self.hardStop() } else { self.hardPause() }
        }
    }

    public func makeTransitionStream() -> AsyncStream<LogicalPlaybackCommit> {
        guard transitionContinuation == nil else { return AsyncStream { $0.finish() } }
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { transitionContinuation = $0 }
    }

    /// Install while output is stopped. Every decoder slot receives a separate
    /// queue-owned processor. Unknown DSP delay/tail disables overlap timing.
    public func setPCMProcessorFactory(_ factory: FFmpegPCMProcessorFactory?, preservesTiming: Bool = false) throws {
        guard !audioEngine.isRunning else { throw PlaybackError.invalidEffects }
        cancelNext()
        pcmProcessorFactory = factory; processorPreservesTiming = preservesTiming
        if let decoder, let item = currentItem {
            restartFeeder(decoder: decoder, from: displayPosition(), generation: state.generation, itemID: item.itemID)
        }
    }

    public func setTransitionCommitHandler(_ handler: (@MainActor (LogicalPlaybackCommit) -> Void)?) {
        transitionCommitHandler = handler
    }

    public func setTransitionRetirementHandler(_ handler: (@MainActor (PlaybackTransitionRetirement) -> Void)?) {
        transitionRetirementHandler = handler
    }

    public func setTransitionInvalidationHandler(_ handler: (@MainActor (PlaybackTransitionTicket, PlaybackTransitionInvalidationReason) -> Void)?) {
        transitionInvalidationHandler = handler
    }

    // All unsegmented sources use decoder EOF as their exact boundary. A
    // container suffix or AVAudioFile.length cannot prove decoded PCM length.
    private func reliableFrames(_ item: PlaybackItem, format: AVAudioFormat) -> Int64? { nil }

    private func remainingFrames(for item: PlaybackItem, decoder: FFmpegAudioDecoder, position: Duration) -> Int64? {
        let total = item.selection.range.map { Self.seconds($0.duration) * decoder.format.sampleRate }
            ?? reliableFrames(item, format: decoder.format).map(Double.init)
        return total.map { max(0, Int64($0.rounded()) - Int64((Self.seconds(position) * decoder.format.sampleRate).rounded())) }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func supportsLocalTransition(_ item: PlaybackItem) -> Bool {
        guard item.selection.range == nil else { return false }
        switch item.resource {
        case .localFile, .leasedLocalFile: return true
        case .remote: return false
        }
    }

    private func feederFormat(for decoder: FFmpegAudioDecoder) -> AVAudioFormat {
        configuredRate == 1 && decoder.format.channelCount <= 8
            ? FFmpegAudioTransitionGraph.renderFormat(for: decoder.format) : decoder.format
    }

    public func prepareNext(_ item: PlaybackItem, ticket: PlaybackTransitionTicket) async throws {
        guard configuredRate == 1, (pcmProcessorFactory == nil || processorPreservesTiming),
              let currentItem, decoder != nil, let graph = transitionGraph,
              ticket.generation == state.generation, ticket.currentItemID == currentItem.itemID,
              supportsLocalTransition(currentItem), supportsLocalTransition(item),
              transitionConfiguration.mode != .disabled else {
            throw PlaybackError.unsupportedCapability(.gapless)
        }
        let url: URL
        switch item.resource {
        case .localFile(let value), .leasedLocalFile(let value, _): url = value
        case .remote: throw PlaybackError.unsupportedCapability(.gapless)
        }
        let operationID = UUID()
        nextPreparationID = operationID
        preparedNextTicket = ticket
        var prepared = false
        defer {
            if !prepared, nextPreparationID == operationID {
                nextPreparationID = nil
                preparedNextTicket = nil
                cancelNext()
            }
        }
        // A still owns its decoder during A/B overlap. Release that slot
        // before opening C, keeping the engine at two decoder instances.
        try await graph.releaseNextSlot()
        guard nextPreparationID == operationID, transitionGraph === graph else { throw CancellationError() }
        let queue = currentDecodeQueue === decodeQueue ? nextDecodeQueue : decodeQueue
        let opened: FFmpegAudioDecoder = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try FFmpegAudioDecoder(localFileURL: url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        guard nextPreparationID == operationID, transitionGraph === graph else { throw CancellationError() }
        guard opened.format.channelCount == graph.format.channelCount ||
                (opened.format.channelCount <= 2 && graph.format.channelCount == 2) else {
            throw PlaybackError.unsupportedCapability(.gapless)
        }
        let frames = reliableFrames(item, format: opened.format)
        let overlap = transitionConfiguration.mode == .crossfade ? transitionConfiguration.crossfadeDuration ?? .zero : .zero
        try await graph.prepareNext(decoder: opened, item: item, ticket: ticket, frameCount: frames ?? -1,
                                   overlap: overlap, queue: queue) { [weak self, weak graph] commit in
            guard let self, self.transitionGraph === graph else { return }
            self.nextPreparationID = nil
            self.preparedNextTicket = nil
            self.retirementDurationBases[ticket.id] = self.renderedDurationBase
            self.renderedDurationBase = .zero
            self.currentItem = item; self.decoder = opened; self.currentDecodeQueue = queue
            self.currentDuration = frames.map { .seconds(Double($0) / opened.format.sampleRate) }
                ?? opened.duration ?? item.display.duration
            self.graphBasePosition = .zero
            self.state = PlaybackState(phase: .playing, generation: self.state.generation.advanced(),
                itemID: item.itemID, position: graph?.position ?? .zero, duration: self.currentDuration)
            self.transitionCommitHandler?(commit)
            self.transitionContinuation?.yield(commit)
        }
        try Task.checkCancellation()
        guard nextPreparationID == operationID else { throw CancellationError() }
        prepared = true
    }

    public func cancelNext() {
        transitionGraph?.synchronize()
        var pausedForCommit = false
        transitionGraph?.cancelNext {
            // Only the tiny in-flight render claim needs quiescence. Ordinary
            // cancellation leaves the running graph and fade untouched.
            pausedForCommit = audioEngine.isRunning
            if pausedForCommit { audioEngine.pause() }
        }
        nextPreparationID = nil
        preparedNextTicket = nil
        if pausedForCommit {
            do { try audioEngine.start() }
            catch {
                if let itemID = state.itemID {
                    fail(.engineFailure(code: "audio_engine_start_failed"), generation: state.generation, itemID: itemID)
                }
            }
        }
    }

    private func isCurrentPreparation(_ generation: PlaybackGeneration) -> Bool {
        state.generation == generation && state.phase == .preparing
    }

    private func startFeeder(
        decoder: FFmpegAudioDecoder,
        initialSeek: Duration?,
        generation: PlaybackGeneration,
        itemID: MediaItemID
    ) {
        // A seek/rate change can rebuild a converted bus as a native-format
        // legacy feeder. Release prepared formats before reconnecting the
        // whole output chain, including when EOF has already paused output.
        audioEngine.stop()
        let outputFormat = feederFormat(for: decoder)
        audioEngine.connect(timePitch, to: equalizerUnit, format: outputFormat)
        connectPostEqualizerOutput(format: outputFormat)
        if configuredRate == 1, decoder.format.channelCount <= 8,
           decoder.format.sampleRate > 0, let item = currentItem {
            let epoch = feederEpoch
            let frameCount = remainingFrames(for: item, decoder: decoder, position: basePosition)
            let graph: FFmpegAudioTransitionGraph
            do { graph = try FFmpegAudioTransitionGraph(decoder: decoder, item: item,
                start: initialSeek, frameCount: frameCount ?? -1, queue: currentDecodeQueue ?? decodeQueue,
                processorFactory: pcmProcessorFactory,
                onEnd: { [weak self] in
                    guard let self, epoch == self.feederEpoch, let itemID = self.state.itemID else { return }
                    self.handlePlaybackEnded(epoch: epoch, generation: self.state.generation, itemID: itemID)
                }, onError: { [weak self] error in
                    guard let self, epoch == self.feederEpoch else { return }
                    self.transitionGraph?.synchronize()
                    guard let itemID = self.state.itemID else { return }
                    self.handleDecodeError(error, epoch: epoch, generation: self.state.generation, itemID: itemID)
                }) } catch {
                fail(.engineFailure(code: "transition_graph_failed"), generation: generation, itemID: itemID)
                return
            }
            transitionGraph = graph
            graph.onSecondaryFailure = { [weak self] in
                guard let self else { return }
                let ticket = self.preparedNextTicket
                self.cancelNext()
                if let ticket { self.transitionInvalidationHandler?(ticket, .preparationFailed) }
            }
            graph.onStarvationChanged = { [weak self] starved in self?.handleStarvationChanged(starved, epoch: epoch) }
            graph.onRetirement = { [weak self] ticket, frame, duration, reason in
                guard let self, self.feederEpoch == epoch else { return }
                let base = self.retirementDurationBases.removeValue(forKey: ticket.id) ?? .zero
                self.transitionRetirementHandler?(PlaybackTransitionRetirement(ticket: ticket,
                    renderFrame: frame, playedDuration: base + duration, reason: reason))
            }
            graphBasePosition = basePosition
            audioEngine.attach(graph.node)
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.connect(graph.node, to: timePitch, format: graph.format)
            graph.configureFadeOut(transitionConfiguration.fadeOutDuration)
            graph.ramp(wantsPlayback ? transitionConfiguration.fadeInDuration : .zero, pause: !wantsPlayback)
            isStarved = false
            return
        }
        // The transition source disconnects this node. Restore the legacy
        // chain before scheduling buffers after a rate/seek/replay rebuild.
        audioEngine.connect(playerNode, to: timePitch, format: decoder.format)
        let epoch = feederEpoch
        isStarved = true
        logOutputDiagnostics(event: "feeder-start", decoderSampleRate: decoder.format.sampleRate)
        let session = AVAudioSession.sharedInstance()
        let outputLatency = max(
            session.outputLatency,
            audioEngine.outputNode.presentationLatency
        )
        let feeder = DecodeFeeder(
            decoder: decoder,
            playerNode: playerNode,
            queue: currentDecodeQueue ?? decodeQueue,
            initialSeek: initialSeek,
            playbackDuration: currentItem?.selection.range.map { $0.duration - basePosition },
            maxInFlight: Self.inFlightBufferCount(
                sampleRate: decoder.format.sampleRate,
                outputLatency: outputLatency
            ),
            processorFactory: pcmProcessorFactory,
            onEnd: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handlePlaybackEnded(epoch: epoch, generation: generation, itemID: itemID)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleDecodeError(error, epoch: epoch, generation: generation, itemID: itemID)
                }
            },
            onStarvationChanged: { [weak self] starved in
                Task { @MainActor [weak self] in
                    self?.handleStarvationChanged(starved, epoch: epoch)
                }
            }
        )
        self.feeder = feeder
        feeder.start()
    }

    private func cancelFeeder() {
        nextPreparationID = nil
        preparedNextTicket = nil
        if let graph = transitionGraph {
            renderedDurationBase += graph.position
            audioEngine.stop()
            graph.cancel()
            audioEngine.disconnectNodeOutput(graph.node)
            audioEngine.detach(graph.node)
            transitionGraph = nil
        } else if feeder != nil {
            // A later return to the transition bus must retain the samples
            // rendered by the legacy feeder, excluding seek offsets.
            renderedDurationBase += max(.zero, currentPosition() - basePosition)
        }
        feeder?.cancel()
        feeder = nil
        feederEpoch &+= 1
    }

    /// 丢弃已排队 buffer，从 `position` 重新投喂（seek / 配置变更 / 播完重放）。
    private func restartFeeder(
        decoder: FFmpegAudioDecoder,
        from position: Duration,
        generation: PlaybackGeneration,
        itemID: MediaItemID
    ) {
        cancelFeeder()
        if let source = remoteSource {
            // 旧任务可能阻塞在网络读取上；打断它，并在串行队列上排在新任务之前恢复。
            source.interruptReads()
            decodeQueue.async { source.resumeReads() }
        }
        playerNode.stop() // 丢弃已排队 buffer，sampleTime 归零
        basePosition = position
        didReachEnd = false
        // 解码器此前已读过数据，即使回到 0 也必须显式 seek。
        startFeeder(
            decoder: decoder,
            initialSeek: currentItem?.selection.range.map {
                $0.absolutePosition(forLogicalPosition: position)
            } ?? position,
            generation: generation,
            itemID: itemID
        )
    }

    /// 按「用户想播 && 有数据可播」驱动 playerNode。饥饿时暂停节点，使时间轴
    /// 停在已播放内容处，而不是空转产生进度漂移。
    private func updateOutput() {
        if transitionGraph != nil {
            if wantsPlayback, !audioEngine.isRunning {
                do { try audioEngine.start() }
                catch {
                    if let itemID = state.itemID {
                        fail(.engineFailure(code: "audio_engine_start_failed"), generation: state.generation, itemID: itemID)
                    }
                }
            }
            if !wantsPlayback, audioEngine.isRunning { audioEngine.pause() }
            return
        }
        if wantsPlayback, !isStarved {
            if !audioEngine.isRunning {
                do { try audioEngine.start() }
                catch {
                    if let itemID = state.itemID {
                        fail(.engineFailure(code: "audio_engine_start_failed"), generation: state.generation, itemID: itemID)
                    }
                    return
                }
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
        } else {
            if playerNode.isPlaying {
                playerNode.pause()
            }
            if !wantsPlayback, audioEngine.isRunning {
                audioEngine.pause()
            }
        }
    }

    private func handleStarvationChanged(_ starved: Bool, epoch: UInt64) {
        guard epoch == feederEpoch else { return }
        isStarved = starved
        updateOutput()
        guard let itemID = state.itemID else { return }

        if starved {
            guard wantsPlayback, bufferingTask == nil else { return }
            bufferingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.bufferingDebounce)
                guard let self, !Task.isCancelled else { return }
                self.bufferingTask = nil
                guard epoch == self.feederEpoch, self.isStarved, self.wantsPlayback,
                      self.state.phase == .playing
                else { return }
                self.state = PlaybackState(
                    phase: .buffering,
                    generation: self.state.generation,
                    itemID: itemID,
                    position: self.displayPosition(),
                    duration: self.currentDuration
                )
                self.yield(.phaseChanged(
                    generation: self.state.generation,
                    itemID: itemID,
                    phase: .buffering
                ))
            }
        } else {
            bufferingTask?.cancel()
            bufferingTask = nil
            guard state.phase == .buffering, wantsPlayback else { return }
            state = PlaybackState(
                phase: .playing,
                generation: state.generation,
                itemID: itemID,
                position: displayPosition(),
                duration: currentDuration
            )
            yield(.phaseChanged(generation: state.generation, itemID: itemID, phase: .playing))
        }
    }

    private func startPositionUpdates() {
        positionTask?.cancel()
        positionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.state.phase == .playing, !self.isStarved,
                      let itemID = self.state.itemID
                else { continue }
                let position = self.displayPosition()
                let generation = self.state.generation
                self.state = PlaybackState(
                    phase: .playing,
                    generation: generation,
                    itemID: itemID,
                    position: position,
                    duration: self.currentDuration
                )
                self.yield(.positionChanged(
                    generation: generation,
                    itemID: itemID,
                    position: position,
                    duration: self.currentDuration
                ))
            }
        }
    }

    private func currentPosition() -> Duration {
        if let graph = transitionGraph { return graphBasePosition + graph.position }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0
        else {
            return basePosition
        }
        let seconds = Double(playerTime.sampleTime) / playerTime.sampleRate
        return basePosition + .seconds(max(0, seconds))
    }

    /// 对外发布的位置。节点暂停/未渲染时 `currentPosition()` 会退回
    /// basePosition；seek/重放都会同步改写 `state.position`，故取二者较大值不会
    /// 挡住合法的回退。
    private func displayPosition() -> Duration {
        let position = max(currentPosition(), state.position)
        return currentDuration.map { min(position, $0) } ?? position
    }

    private func handlePlaybackEnded(
        epoch: UInt64,
        generation: PlaybackGeneration,
        itemID: MediaItemID
    ) {
        guard epoch == feederEpoch, generation == state.generation, !didReachEnd else { return }
        didReachEnd = true
        wantsPlayback = false
        bufferingTask?.cancel()
        bufferingTask = nil
        positionTask?.cancel()
        positionTask = nil
        let endPosition = currentDuration ?? currentPosition()
        updateOutput()
        state = PlaybackState(
            phase: .stopped,
            generation: generation,
            itemID: itemID,
            position: endPosition,
            duration: currentDuration
        )
        yield(.positionChanged(
            generation: generation,
            itemID: itemID,
            position: endPosition,
            duration: currentDuration
        ))
        yield(.ended(generation: generation, itemID: itemID, reason: .ended))
    }

    private func handleDecodeError(
        _ error: Error,
        epoch: UInt64,
        generation: PlaybackGeneration,
        itemID: MediaItemID
    ) {
        guard epoch == feederEpoch, generation == state.generation else { return }
        Self.logger.error("decode failed: \(Self.safeErrorCode(error), privacy: .public)")
        fail(
            Self.playbackError(from: error, fallbackCode: "ffmpeg_decode_failed"),
            generation: generation,
            itemID: itemID
        )
    }

    private func fail(_ error: PlaybackError, generation: PlaybackGeneration, itemID: MediaItemID) {
        teardown()
        state = PlaybackState(
            phase: .failed,
            generation: generation,
            itemID: itemID,
            position: state.position,
            duration: currentDuration,
            error: error
        )
        yield(.phaseChanged(generation: generation, itemID: itemID, phase: .failed))
        yield(.failed(generation: generation, itemID: itemID, error: error))
    }

    /// 把字节源/解码器错误映射为 `PlaybackError`。诊断码不含 URL 或请求头。
    private static func safeErrorCode(_ error: Error) -> String {
        switch error {
        case let URLSessionByteSource.SourceError.httpStatus(status):
            return "http_\(status)"
        case let URLSessionByteSource.SourceError.network(code):
            return "network_\(code.rawValue)"
        case URLSessionByteSource.SourceError.invalidResponse:
            return "invalid_response"
        case URLSessionByteSource.SourceError.notSeekable:
            return "not_seekable"
        case URLSessionByteSource.SourceError.cancelled:
            return "cancelled"
        case URLSessionByteSource.SourceError.interrupted:
            return "interrupted"
        case let FFmpegAudioDecoder.DecoderError.open(status):
            return "decoder_open_\(status)"
        case FFmpegAudioDecoder.DecoderError.io:
            return "decoder_io"
        case FFmpegAudioDecoder.DecoderError.unsupportedFormat:
            return "unsupported_format"
        default:
            return "other"
        }
    }

    private static func playbackError(from error: Error, fallbackCode: String) -> PlaybackError {
        switch error {
        case let error as PlaybackError:
            return error
        case URLSessionByteSource.SourceError.cancelled:
            return .cancelled
        case let URLSessionByteSource.SourceError.httpStatus(code):
            switch code {
            case 401, 403, 404, 410:
                return .resourceUnavailable
            default:
                return .engineFailure(code: "remote_http_\(code)")
            }
        case let URLSessionByteSource.SourceError.network(code):
            return .engineFailure(code: "remote_network_\(code.rawValue)")
        case URLSessionByteSource.SourceError.notSeekable:
            return .unsupportedCapability(.seeking)
        case URLSessionByteSource.SourceError.invalidResponse:
            return .engineFailure(code: "remote_invalid_response")
        default:
            return .engineFailure(code: fallbackCode)
        }
    }

    private func validatePosition(_ position: Duration, duration: Duration?) throws {
        guard position >= .zero, duration == nil || position <= duration! else {
            throw PlaybackError.invalidPosition
        }
    }

    private func teardown() {
        softControlTask?.cancel(); softControlTask = nil
        controlVersion &+= 1
        recoveringSequentialRoute = false
        wantsPlayback = false
        bufferingTask?.cancel()
        bufferingTask = nil
        positionTask?.cancel()
        positionTask = nil
        cancelFeeder()
        // 先唤醒可能阻塞在网络读取上的解码队列，后续 feeder/prepare 才不会排队干等。
        remoteSource?.cancel()
        remoteSource = nil
        decoder = nil
        playerNode.stop()
        // EOF and pause leave a prepared graph even when isRunning is false.
        // Release those resources before connecting the next decoder's format.
        audioEngine.stop()
    }

    /// 处理 AVAudioEngine 配置变更（路由/硬件格式变化）。此时引擎已自行停止，
    /// 需重连节点、重启引擎，并从当前位置恢复投喂，否则播放会在已排队 buffer
    /// 放完后静默。逻辑与 `seek` 的重建路径一致。
    private func handleConfigurationChange() {
        // Flush a rendered handoff before capturing the decoder. Tell the
        // queue owner when rebuilding discards its still-pending successor.
        let invalidatedTicket = preparedNextTicket
        cancelNext()
        defer {
            if let invalidatedTicket {
                transitionInvalidationHandler?(invalidatedTicket, .outputRebuilt)
            }
        }
        guard let decoder, let item = currentItem, !didReachEnd else { return }
        logOutputDiagnostics(
            event: "engine-configuration-change",
            decoderSampleRate: decoder.format.sampleRate
        )
        switch state.phase {
        case .playing, .preparing, .paused, .buffering:
            break
        default:
            return
        }
        let resumePosition = displayPosition()
        let generation = state.generation

        if case let .remote(request) = item.resource,
           remoteSource?.isSeekable == false {
            restartSequentialStreamAfterConfigurationChange(
                request: request,
                item: item,
                position: resumePosition,
                generation: generation
            )
            return
        }

        cancelFeeder()
        playerNode.stop()

        let format = feederFormat(for: decoder)
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: equalizerUnit, format: format)
        connectPostEqualizerOutput(format: format)
        timePitch.rate = configuredRate
        playerNode.volume = 1
        audioEngine.mainMixerNode.outputVolume = isMuted ? 0 : volume

        do {
            audioEngine.prepare()
            if wantsPlayback {
                try audioEngine.start()
            }
        } catch {
            fail(
                .engineFailure(code: "audio_engine_restart_failed"),
                generation: generation,
                itemID: item.itemID
            )
            return
        }

        restartFeeder(
            decoder: decoder,
            from: resumePosition,
            generation: generation,
            itemID: item.itemID
        )
        updateOutput()
    }

    private func logOutputDiagnostics(event: String, decoderSampleRate: Double) {
        let session = AVAudioSession.sharedInstance()
        let routes = session.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        let ioBufferMilliseconds = session.ioBufferDuration * 1_000
        let outputLatencyMilliseconds = session.outputLatency * 1_000
        let presentationLatencyMilliseconds = audioEngine.outputNode.presentationLatency * 1_000
        Self.logger.info(
            "audio output event=\(event, privacy: .public) routes=\(routes, privacy: .public) decoderRate=\(decoderSampleRate, privacy: .public) sessionRate=\(session.sampleRate, privacy: .public)"
        )
        Self.logger.info(
            "audio timing event=\(event, privacy: .public) ioBufferMs=\(ioBufferMilliseconds, format: .fixed(precision: 2), privacy: .public) outputLatencyMs=\(outputLatencyMilliseconds, format: .fixed(precision: 1), privacy: .public) presentationLatencyMs=\(presentationLatencyMilliseconds, format: .fixed(precision: 1), privacy: .public) engineRunning=\(self.audioEngine.isRunning, privacy: .public) wantsPlayback=\(self.wantsPlayback, privacy: .public)"
        )
    }

    private func restartSequentialStreamAfterConfigurationChange(
        request: RemotePlaybackRequest,
        item: PlaybackItem,
        position: Duration,
        generation: PlaybackGeneration
    ) {
        cancelFeeder()
        remoteSource?.cancel()
        let source = makeRemoteSource(request)
        remoteSource = source
        decoder = nil
        recoveringSequentialRoute = true
        playerNode.stop()
        isStarved = true
        basePosition = position
        state = PlaybackState(
            phase: .preparing,
            generation: generation,
            itemID: item.itemID,
            position: position,
            duration: currentDuration
        )
        yield(.phaseChanged(generation: generation, itemID: item.itemID, phase: .preparing))

        let probeSize = Self.remoteProbeSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            let replacement: FFmpegAudioDecoder
            do {
                replacement = try await withCheckedThrowingContinuation { continuation in
                    self.decodeQueue.async {
                        do {
                            try source.open()
                            let decoder = try FFmpegAudioDecoder(
                                byteSource: source, probeSize: probeSize
                            )
                            let components = position.components
                            let seconds = Double(components.seconds)
                                + Double(components.attoseconds) / 1_000_000_000_000_000_000
                            let skipCount = min(
                                max(0, (seconds * decoder.format.sampleRate).rounded(.down)),
                                9_000_000_000_000_000
                            )
                            var remaining = Int64(skipCount)
                            if source.isSeekable, remaining > 0 {
                                try decoder.seek(to: position)
                            } else {
                                while remaining > 0 {
                                    let capacity = AVAudioFrameCount(min(remaining, 8192))
                                    guard let buffer = try decoder.nextBuffer(frameCapacity: capacity) else {
                                        throw PlaybackError.resourceUnavailable
                                    }
                                    remaining -= Int64(buffer.frameLength)
                                }
                            }
                            continuation.resume(returning: decoder)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                guard self.isCurrentSequentialRouteRecovery(
                    generation: generation, itemID: item.itemID, source: source
                ) else { return }
                self.fail(
                    Self.playbackError(from: error, fallbackCode: "remote_route_reopen_failed"),
                    generation: generation,
                    itemID: item.itemID
                )
                return
            }
            guard self.isCurrentSequentialRouteRecovery(
                generation: generation, itemID: item.itemID, source: source
            ) else { return }
            self.recoveringSequentialRoute = false
            self.decoder = replacement
            let format = replacement.format
            self.audioEngine.connect(self.playerNode, to: self.timePitch, format: format)
            self.audioEngine.connect(self.timePitch, to: self.equalizerUnit, format: format)
            self.connectPostEqualizerOutput(format: format)
            self.timePitch.rate = self.configuredRate
            self.playerNode.volume = 1
            self.audioEngine.mainMixerNode.outputVolume = self.isMuted ? 0 : self.volume
            do {
                self.audioEngine.prepare()
                if self.wantsPlayback {
                    try self.audioEngine.start()
                }
            } catch {
                self.fail(
                    .engineFailure(code: "audio_engine_restart_failed"),
                    generation: generation,
                    itemID: item.itemID
                )
                return
            }
            self.startFeeder(
                decoder: replacement,
                initialSeek: nil,
                generation: generation,
                itemID: item.itemID
            )
            let phase: PlaybackPhase = self.wantsPlayback ? .playing : .paused
            self.state = PlaybackState(
                phase: phase,
                generation: generation,
                itemID: item.itemID,
                position: position,
                duration: self.currentDuration
            )
            self.yield(.phaseChanged(generation: generation, itemID: item.itemID, phase: phase))
            self.updateOutput()
            if self.wantsPlayback { self.startPositionUpdates() }
        }
    }

    private func isCurrentSequentialRouteRecovery(
        generation: PlaybackGeneration,
        itemID: MediaItemID,
        source: URLSessionByteSource
    ) -> Bool {
        recoveringSequentialRoute && state.generation == generation &&
            state.itemID == itemID && remoteSource === source
    }

    private func yield(_ event: PlaybackEvent) {
        eventContinuation?.yield(event)
    }
}
