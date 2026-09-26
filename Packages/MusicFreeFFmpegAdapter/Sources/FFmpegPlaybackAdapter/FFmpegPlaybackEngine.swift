import AVFoundation
import FFmpegAudioKit
import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI

/// 独立于 VLC 的音频播放引擎：ffmpeg 解码 → AVAudioEngine 输出。
///
/// 范围：本地文件（`.localFile`）与 HTTP(S) 远程资源（`.remote`，经
/// `URLSessionByteSource` 读取）的 prepare/play/pause/stop/seek，变速
/// （timePitch），音量/静音。远程资源仅在服务端支持 Range 时可 seek
/// （`capabilities` 随之变化）。
/// 支持 CUE 分段播放及 AVAudioUnitEQ 均衡器。其它效果能力位按实现逐步点亮。
@MainActor
public final class FFmpegPlaybackEngine: PlaybackEngine, PlaybackAudioControlling {
    /// 随当前资源变化：远程顺序流（服务端不支持 Range，或尚未拿到响应头）
    /// 不含 `.seeking`，供上层据此隐藏进度拖动。
    public var capabilities: PlaybackCapabilities {
        remoteSource?.isSeekable == false
            ? [.variableRate, .equalizer] : [.seeking, .variableRate, .equalizer]
    }
    public var equalizerDescriptor: EqualizerDescriptor? { Self.equalizerLayout }

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
    /// 饥饿持续超过该时长才对外发布 `.buffering`，避免短暂抖动闪烁加载态。
    private static let bufferingDebounce: Duration = .milliseconds(300)

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
        precondition(
            eventContinuation == nil,
            "FFmpegPlaybackEngine supports one active event stream"
        )
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
        case let .localFile(url):
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
        currentDuration = item.selection.range?.duration ?? decoder.duration ?? item.display.duration

        let format = decoder.format
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: equalizerUnit, format: format)
        audioEngine.connect(equalizerUnit, to: audioEngine.mainMixerNode, format: format)
        timePitch.rate = configuredRate
        playerNode.volume = isMuted ? 0 : volume

        do {
            // 音频会话由 App 侧 AudioSessionManaging 统一配置并激活（在本 prepare
            // 之前完成）。引擎不再自行 setActive，避免二次激活刚启动即触发路由/
            // 配置变更而中断播放。
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            let playbackError = PlaybackError.engineFailure(code: "audio_engine_start_failed")
            fail(playbackError, generation: generation, itemID: item.itemID)
            throw playbackError
        }

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
        updateOutput()
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
        wantsPlayback = false
        playerNode.pause()
        bufferingTask?.cancel()
        bufferingTask = nil
        positionTask?.cancel()
        positionTask = nil
        let generation = state.generation
        state = PlaybackState(
            phase: .paused,
            generation: generation,
            itemID: state.itemID,
            position: displayPosition(),
            duration: currentDuration
        )
        if let itemID = state.itemID {
            yield(.phaseChanged(generation: generation, itemID: itemID, phase: .paused))
        }
    }

    public func stop() {
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
    }

    public func setRate(_ rate: Float) throws {
        guard rate.isFinite, rate > 0 else { throw PlaybackError.invalidRate }
        guard rate == 1 || capabilities.contains(.variableRate) else {
            throw PlaybackError.unsupportedCapability(.variableRate)
        }
        configuredRate = rate
        timePitch.rate = rate
    }

    public func apply(_ effects: AudioEffectConfiguration) throws {
        if let equalizer = effects.equalizer {
            _ = try equalizer.validated(against: Self.equalizerLayout)
        }
        if effects.replayGain.mode != .disabled {
            throw PlaybackError.unsupportedCapability(.replayGain)
        }
        switch effects.transition.mode {
        case .disabled: break
        case .gapless: throw PlaybackError.unsupportedCapability(.gapless)
        case .crossfade: throw PlaybackError.unsupportedCapability(.crossfade)
        }
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
        playerNode.volume = isMuted ? 0 : volume
    }

    public func setMuted(_ muted: Bool) throws {
        isMuted = muted
        playerNode.volume = muted ? 0 : volume
    }

    public func dispose() {
        teardown()
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Private

    private func isCurrentPreparation(_ generation: PlaybackGeneration) -> Bool {
        state.generation == generation && state.phase == .preparing
    }

    private func startFeeder(
        decoder: FFmpegAudioDecoder,
        initialSeek: Duration?,
        generation: PlaybackGeneration,
        itemID: MediaItemID
    ) {
        let epoch = feederEpoch
        isStarved = true
        let feeder = DecodeFeeder(
            decoder: decoder,
            playerNode: playerNode,
            queue: decodeQueue,
            initialSeek: initialSeek,
            playbackDuration: currentItem?.selection.range.map { $0.duration - basePosition },
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
        if wantsPlayback, !isStarved {
            if !playerNode.isPlaying {
                playerNode.play()
            }
        } else if playerNode.isPlaying {
            playerNode.pause()
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
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    /// 处理 AVAudioEngine 配置变更（路由/硬件格式变化）。此时引擎已自行停止，
    /// 需重连节点、重启引擎，并从当前位置恢复投喂，否则播放会在已排队 buffer
    /// 放完后静默。逻辑与 `seek` 的重建路径一致。
    private func handleConfigurationChange() {
        guard let decoder, let item = currentItem, !didReachEnd else { return }
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

        let format = decoder.format
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: equalizerUnit, format: format)
        audioEngine.connect(equalizerUnit, to: audioEngine.mainMixerNode, format: format)
        timePitch.rate = configuredRate
        playerNode.volume = isMuted ? 0 : volume

        do {
            audioEngine.prepare()
            try audioEngine.start()
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
            self.audioEngine.connect(self.equalizerUnit, to: self.audioEngine.mainMixerNode, format: format)
            self.timePitch.rate = self.configuredRate
            self.playerNode.volume = self.isMuted ? 0 : self.volume
            do {
                self.audioEngine.prepare()
                try self.audioEngine.start()
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
