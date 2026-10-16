# 节拍匹配与保音高时间伸缩

## 行为

设置 → 播放 → 歌曲过渡 → 交叉淡化 → 智能交叉渐变。延续默认关闭的智能模式设置，时长滑块仍按 0.1 秒步进，最长 12 秒。

| 阶段 | 上一首 A | 下一首 B |
| --- | --- | --- |
| 重叠前 | 原速播放 | 解码队列完成静音、响度和可靠节拍分析，等待歌曲对计划 |
| 重叠期间 | 原速退场 | 以 `B 节拍周期 / A 节拍周期` 的速度进入，保留原音高 |
| 重叠结束后 | 已退场 | 最多 3 秒平滑恢复原速，之后继续原始 PCM |

两个解码槽位分别持有伸缩状态。采用 40 ms WSOLA 粒窗、20 ms 交叠和 ±5 ms 波形搜索；所有声道共享粒窗偏移。恢复结束时，先选择最后一个相关性匹配的粒窗，再从该源位置连续复制到 EOF，避免强制跳回名义相位造成振幅凹陷。该衔接偏移不超过 5 ms，同步计入源时间映射和渲染总帧数。

队列只保留附近的搜索区和解码块，实时渲染回调继续使用既有 C 混音器。原始歌曲位置按速度曲线积分和粒窗衔接偏移换算；播放历史的已播放时长仍按实际输出时间计数。

仅可靠的 60–180 BPM 网格、周期差不超过 6%、差异至少 0.2%、重叠至少 2 秒且有空间恢复时启用伸缩。响度差超过 12 dB、短曲、晚准备和不可靠节拍使用原有渐变策略。恢复在 B 的源时间前半段结束，保证下一次过渡读取已恢复的节拍网格。

## 验证方法

- 独立伸缩测试：0.94×、0.96×、1×、1.04×、1.06×；以不规则解码块输入 440 Hz 正弦和尾部标记，检查输出长度、音高、反相立体声关系、恢复后的原始波形和完整尾部。
- 生产链路离线测试：A 为 120 BPM，B 周期分别为 0.48、0.52、0.50、0.70 秒。44.1 kHz WAV / ALAC 经过 FFmpeg 解码、逐曲 DSP、48 kHz 转换、独立时间伸缩、交叉渐变和最终输出。保存 `transition-mix.wav`、`output.wav` 及会话诊断。
- 独立脚本 `Scripts/analyze_beat_matching_pcm.py` 重读 WAV，以 20 ms Hann 窗提取载波包络，在 5 ms 采样网格上插值定位脉冲的 50% 上升沿；FFT 测量音高，后段拍点间隔检查恢复。同时检查应用音量、非有限样本、削波、存储丢帧和尾音覆盖。
- 真机套件 `FFmpegDeviceBeatMatchingTests` 使用 iPhone 实时输出路径，分别验证加速/减速；另检查变速过程中的暂停、恢复、跳转和停止。
- C 数值测试使用 ASan / UBSan，验证变速后的源时间与实际输出时间分别计数，槽位复用清除旧速度计划。

产物统一保存在 `.noindex/artifacts/beat-matching/`，日志在 `.noindex/logs/beat-matching-*.log`，复用 `.noindex/DerivedData/MusicPlayer`。

## 本次验证结果

最终版本的 Simulator 回归通过：7 个测试套件、49 个测试函数、104 次执行，零失败、零跳过。运行设备为 MusicFree Regression（iPhone 17 Pro、iOS 27.0 Simulator），耗时约 152 秒。覆盖原有过渡、静音跳过、PCM 存储、智能规划、独立时间伸缩及生产解码/混音链路。

| B 原始拍间隔 | B 重叠期速度 | 实测重叠时长 | 恢复时间 | 最大对拍误差 | 恢复后拍间隔 |
| --- | --- | --- | --- | --- | --- |
| 0.48 秒 | 0.96× | 4.045 秒 | 3 秒 | 约 3.28 ms | 0.480000 秒 |
| 0.52 秒 | 1.04× | 4.035375 秒 | 3 秒 | 约 3.55 ms | 0.520000 秒 |
| 0.50 秒 | 1× | 4.040 秒 | 无需恢复 | 约 0.05 ms | 0.500000 秒 |
| 0.70 秒 | 1×，能量策略回退 | 3.900 秒 | 无需恢复 | 不要求对拍 | 0.700000 秒 |

四组均保留 B 的 660 Hz 载波音高；最终输出与混音乘以应用音量后的相对 RMS 误差约 `3.25e-8` 至 `3.30e-8`。无非有限样本、削波、PCM 存储丢帧或可测尾音缺失。恢复阶段逐拍间隔检查通过；独立正弦测试同时检查恢复接点的振幅连续性，覆盖相关粒窗切换到原始 PCM 的衔接。

C 渲染数值测试在 ASan / UBSan 下通过 38 组场景，架构检查及 `git diff --check` 通过。

证据路径（相对工程根目录）：

- 试听与波形：`.noindex/artifacts/beat-matching/simulator/index.html`
- 独立测量结果：`.noindex/artifacts/beat-matching/simulator/analysis.json`
- 最终测试统计：`.noindex/artifacts/beat-matching/final-test-summary.json`
- Xcode 结果：`.noindex/DerivedData/MusicPlayer/Logs/Test/Test-PlaybackTransitions-2026.10.15_22-01-48--0400.xcresult`
- 回归日志：`.noindex/logs/beat-matching-final-tests.log`
- C 数值 / 架构日志：`.noindex/logs/beat-matching-numerical.log`、`.noindex/logs/beat-matching-architecture.log`

## 真机验证结果

iPhone 12 Pro（ip12、iOS 17.6.1）已解锁并安装最终 Debug 版本。内置扬声器输出，系统音量 25%，应用音量 25%，48 kHz 双声道。`manualRendering=false`，系统输出前 PCM 来自 `realtime-tap-blocks`。

`MusicFreeTests/FFmpegDeviceBeatMatchingTests` 最终通过：2 个测试函数、3 次执行，零失败、零跳过，约 70.1 秒。覆盖加速、减速及过渡期间的暂停、恢复、跳转、停止。

| 场景 | B 速度 | 实测重叠 | 恢复原速 | 最大起拍偏差 | 恢复后拍间隔 |
| --- | --- | --- | --- | --- | --- |
| `smart-tempo-faster` | 1.04× | 4.035375 秒 | 2.233835 秒 | 约 3.34 ms | 0.520000 秒 |
| `smart-tempo-slower` | 0.96× | 4.045000 秒 | 2.636789 秒 | 约 2.32 ms | 0.480000 秒 |

两组载波音高均保持 660 Hz；补偿实测的 4096 帧 / 85.333 ms 下游延迟后，系统输出前 PCM 与混音乘以应用音量后的相对 RMS 误差约 `8.63e-8` 至 `8.67e-8`。无非有限样本、削波、存储丢帧或可测尾音缺失。恢复阶段的逐拍间隔检查通过。

暂停后位置保持不变，恢复后继续前进。首次测试采用跳转后固定等待 0.5 秒，未等到重新分析完成，导致一项检查失败。改为有 10 秒上限的就绪等待，并要求位置再次前进；本次跳转到第 5 秒后约 1.77 秒恢复播放，停止检查通过。因此跳转仍存在音频重新分析带来的可感知等待。

真机的两种载波同时位于每个声道，矩形分析窗会把另一载波的瞬态计入拍点；平顶脉冲的局部最大值也会随波形相位移动。最终测量使用 Hann 窗和半高上升沿，两路错开 0.2 秒、30/40 ms 脉冲的独立校准偏差不超过 1.12 ms，沿用 25 ms 的对拍检查上限。四组 Simulator PCM 与两组真机 PCM 已用同一最终脚本重新分析并通过。

只导出本次 `DeviceTransitionValidation/smart-tempo-*` 合成测试目录。证据路径：

- 真机试听与波形：`.noindex/artifacts/beat-matching/device/index.html`
- 真机独立测量：`.noindex/artifacts/beat-matching/device/analysis.json`
- 控制验证与跳转耗时：`.noindex/artifacts/beat-matching/device/smart-tempo-transport/validation.json`
- 最终真机统计：`.noindex/artifacts/beat-matching/device-test-summary.json`
- 真机 Xcode 结果：`.noindex/DerivedData/MusicPlayer/Logs/Test/Test-MusicFree-2026.10.15_22-20-05--0400.xcresult`
- 最终真机日志：`.noindex/logs/beat-matching-device-final-tests.log`
- 最终独立测量与检测器校准日志：`.noindex/logs/beat-matching-final-pcm-analysis.log`

## 验证边界

受控正弦和节奏脉冲的 PCM 测量用于确认处理流程、拍点与速度恢复。真人演唱、复杂鼓组、自由速度音乐的主观音质，以及蓝牙、AirPlay、后台和路由切换，需要分别听测与验证。
