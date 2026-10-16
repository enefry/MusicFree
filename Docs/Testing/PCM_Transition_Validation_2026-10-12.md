# 智能渐变的实际 PCM 存储与音频验证

## 记录节点

```text
FFmpeg A/B 解码 → 每曲 DSP → 转换为共享 PCM → C 双路过渡/淡入淡出
                                                   ↓ transition-mix.wav
              → timePitch → EQ → 后置效果链 → mainMixer 总音量
                                                   ↓ output.wav
```

`FFmpegPCMStorageNode` 是可选的诊断存储阶段。默认不创建文件、不启动写盘队列。调用 `FFmpegPlaybackEngine.startPCMRecording(in:)` 后，在当前 transition graph 的输出及最终输出开始记录。源混音包含实际过渡包络和每曲 DSP；最终输出包含 EQ、后置 AudioUnit 和音量/静音。

每个节点有独立、预分配的 Float32 C SPSC 环形缓冲，默认容量约 2 秒。生产者是源渲染回调、实时 tap 或离线 render 返回块，消费者是文件队列。实时路径无文件 I/O、锁、任务分发或缓冲分配。后台每 10 ms 排空，使用可复用的 16384 帧 AVAudioPCMBuffer 写入 WAV。

满缓冲时丢弃整个输入块并累计 `droppedFrames`；格式、采样率或声道不匹配累计 `rejectedFrames`。报告保留写入错误、收到/写入帧数及采样格式，不能把存在丢帧/格式拒绝/写入错误的文件视为验证成功。丢块时不补零，时间轴因此可能拼接；报告明确标记数据不完整。

## 公开使用方式

实时诊断：在 prepare 后、play 前调用 `startPCMRecording(in:)`，正常播放，暂停或停止输出后 `await finishPCMRecording()`。结束方法等待后台排空并关闭 WAV，返回 `FFmpegPCMRecordingReport`，同时保存 `recording.json`。运行期间开始/结束录音会抛出 `requiresStoppedEngine`，不在实时回调更换记录指针。相同目标文件已存在时拒绝覆盖。

离线验证可以仅使用公开接口：

```swift
try await engine.prepare(currentItem, startAt: nil)
let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
try engine.enableOfflinePCMRendering(format: format, maximumFrameCount: 480)
try await engine.prepareNext(nextItem, ticket: transitionTicket)
try engine.startPCMRecording(in: evidenceDirectory)
try engine.play()

let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
while engine.state.phase == .playing {
    let status = try engine.renderOfflineRecording(480, to: buffer)
    // Check status and bound the loop in a test/export caller.
    guard status == .success else { throw ExportError.renderFailed }
    try await Task.sleep(for: .milliseconds(1)) // Let producers/polling progress.
}
let report = try await engine.finishPCMRecording()
try engine.disableOfflinePCMRendering()
```

`transitionTicket` 使用当前播放 generation 和队列会话；调用者负责设置实际歌曲与合法票据。测试中的循环有明确上限，并验证结束状态；示例省略该调用方样板。

离线输出必须使用 `renderOfflineRecording`，它记录实际 AVAudioEngine 返回的每个成功块。普通 realtime tap 可能不交付末尾不足一块的数据；`persistedAllDeliveredFrames` 表示收到的数据完整写盘，不代表 tap 交付整段输出。精确音频验收使用离线返回块，不能用实时 tap 的帧数推断尾部完整性。

seek、路由重建、重播、停止或取消 feeder 会先停止输出，再移除记录链接和 tap，关闭当前会话输入。报告以 `endedByGraphChange` 标明提前结束。新 graph 不沿用旧会话，避免不同源时间轴混入同一证据。`dispose` 也会排空关闭；需要读取结果时，应先显式调用 `finishPCMRecording`。

## 测试素材和结果

每首 14 秒、44100 Hz、双声道。A 使用 440/880 Hz，B 使用 660/1320 Hz，便于从保存的混音中独立分离两条信号。每拍有 30 ms 的音量脉冲，2 ms attack / 3 ms release。开头静音 400 ms，结尾静音 600 ms。B 为 16-bit ALAC，经过真实 FFmpeg 解码后转换到 48000 Hz 混音总线。最终总音量统一为 0.5，EQ 和后置效果不启用。

| 场景 | A / B 周期 | 算法选择 | 实际过渡时长 |
| --- | --- | --- | --- |
| fixed | 0.5 / 0.5 秒 | 固定上限，短曲一半保护 | 6.519979 秒 |
| smart-beats | 0.5 / 0.5 秒 | 稳定节拍网格 | 4.040000 秒 |
| smart-energy | 0.5 / 0.7 秒 | 响度曲线 | 3.900000 秒 |
| smart-levels | 0.5 / 0.7 秒，约 14 dB 音量差 | 响度曲线短过渡 | 1.500000 秒 |

四组设置相同的 12 秒上限，并启用首尾静音跳过。A retirement 为 625918 帧，约 13.039958 秒；有声数据保留原速，仅去除边缘静音并保留 20 ms 保护。不同节拍场景保持 0.5 / 0.7 秒原节拍，能量策略不改变速度。音量差场景不对整首歌做响度归一化，只改变过渡窗口。

两个节点保存的 Float32 PCM 均无丢帧、格式拒绝、非有限样本或削波。重新读取两处 WAV，在共同前缀上比较最终输出与混音 × 0.5，两声道相对 RMS 误差约 4.9e-8。源节点因预拉取多记录 4064 帧，不能把回调块总长当作歌曲时长；原始 WAV 保留末尾零帧作为证据。

## 验证发现的修正

1. 音频开头出现有声攻击时，原起音列表可能把这次孤立攻击当成第一拍。生成音频实际错拍约 100 ms，即使规划器的符号测试通过。现在将起音聚合到稳定周期网格，用网格拍点选择过渡。独立频率分析从保存的混音区分 A/B 脉冲，同拍过渡中最大峰位置差 ≤20 ms（50 ms 窗口、10 ms 步长，包络渐变会影响峰位置）。
2. 离线 AVAudioEngine 会提前拉取源 PCM。源 EOF 时立即暂停引擎，会使最终输出缺少约 40–80 ms 的尾部。离线录音现以收到的源回调帧数计算待排空输出时钟，达到该位置后才发布自然结束。测试及独立脚本都比较实际有声末尾，确认尾部完整，而不只是记录收到的帧数。

修正尾部后，四组最终有声结束位置约为 19.540、22.020、22.160、24.560 秒，与裁剪后两首长度减去重叠及尾部保护相符。

## 证据与复现

播放流程测试在 `Packages/MusicFreeFFmpegAdapter/Tests/MusicFreeFFmpegAdapterTests/FFmpegPCMStorageTests.swift`。模拟器测试写入受控的 `Documents/PCMTransitionValidation`，之后导出到工程稳定目录：

```text
.noindex/artifacts/pcm-transition/
  index.html                   # 四组完整音频和过渡片段试听
  rms-comparison.png           # 保存 PCM 的 RMS 对照
  beat-alignment.png           # 保存 PCM 的拍点对照
  analysis.json                # 独立重读音频分析结果
  test-summary.json            # 最终 xcresult 执行统计
  scenarios/<scenario>/
    a.wav / b.m4a              # 生成输入
    decoded-b.wav              # FFmpeg 解码输入证据
    transition-mix.wav         # C 混音输出 Float32 PCM
    output.wav                 # 最终输出 Float32 PCM
    recording.json             # 写盘统计及结束原因
    validation.json            # 实际 commit/retirement 和验证数据
    listen.wav                 # PCM16 试听副本，未归一化
    transition-listen.wav      # 过渡前 2 秒至退场后 3 秒片段
```

`Scripts/analyze_transition_pcm.py` 重新读取保存文件，检查帧数、增益、边界、原速周期和实际拍点，再生成 PNG / JSON / PCM16 试听副本。需要 NumPy / Matplotlib，设置 `MPLCONFIGDIR` 为工程 `.noindex/tmp/matplotlib` 后运行：

```bash
MPLCONFIGDIR="$PWD/.noindex/tmp/matplotlib" \
  python3 Scripts/analyze_transition_pcm.py .noindex/artifacts/pcm-transition
```

最终模拟器回归覆盖 44 个测试函数，0 失败、0 跳过，包括存储/实时 tap/seek 会话关闭、节拍网格、过渡控制和静音。6 项 C 存储数值验证在 ASan/UBSan 和 TSan 下均通过：mono/stereo/8 声道精确环绕、满缓冲/非法布局、交错布局/链接移除、100000 帧并发复制。架构检查通过。

日志：`.noindex/logs/pcm-transition-verified-tests.log`、`pcm-storage-numerical.log`、`pcm-storage-tsan.log`、`pcm-transition-analysis.log`、`pcm-transition-architecture.log`。构建复用 `.noindex/DerivedData/MusicPlayer`，未创建额外 DerivedData。

本节结果验证了模拟器中合成素材的实际 PCM 效果、文件完整性与生命周期。后续 iPhone 12 Pro 的实时验证、系统输出前 PCM、85.33 ms 尾音排空修复及明确的验收边界，见 [真机验证记录](iPhone12_Transition_PCM_Validation_2026-10-12.md)。未进行真实曲库风格验收或 Archive；自动音频分析不能替代主观听感。
