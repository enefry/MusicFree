# 爆音抑制插件

目标是播放器内可开关的实时 DSP 插件。用户提供的《请不要再爱我》MP3 仅作为验证 sample，19、23、24、28、48 秒及左声道是重点观察区域；任务不以修复或输出该音频文件为交付目标。

## 实现

- 独立 SwiftPM product `DeclickDSPPlugin`，仅依赖 Foundation 和插件 SDK。
- 注册 ID：`builtin.dsp.declick`；显示名称：爆音抑制。通过现有插件管理页启用、允许加载和配置，默认关闭。
- 检测灵敏度 0–100（默认 35），抑制强度 0–100%（默认 100%）。任一参数为 0 时保留原始 PCM。
- 各声道独立维护局部斜率预测、残差背景、包络和短异常计数，避免从右声道复制或混合数据到左声道。
- 最长连续抑制约 0.3 ms；超过后接受新起音，并保护约 4 ms 以重新学习背景。开始或重置后约 1 ms 用于学习。
- 无前瞻、额外延迟、尾音、重采样或帧数变化。状态跨任意处理块连续，复用现有正式播放、试听与过渡轨道的独立工厂实例和撤销门控。
- `process` 内无文件读写、日志、阻塞或显式内存分配；prepare 分配声道状态，reset 原地清空。
- 输入格式不匹配或非有限样本会在改动状态之前拒绝；预测值限制在近期已接受信号的包络内。

## 验证

定向核心测试覆盖 44.1/48/96 kHz、正负人工脉冲、静音和正弦背景、只损坏左声道时右声道逐样本保留、块大小 1/7/31/4096/8192 的结果一致、seek 重置、无效参数/样本、0 强度/0 灵敏度原声旁路、持续起音恢复及渐入 6 kHz 正弦保留。

SwiftPM 内置 DSP 包全量回归通过：声道均衡 6 个测试、均衡器 3 个测试、去爆音 5 个测试（包含外部 sample 数值检查；参数化用例在对应测试内另行执行）。HostBridge 的插件注册、启用挂载和禁用撤销测试通过。架构检查通过，iOS Simulator Debug App 构建通过。

外部 sample 数值检查读取临时解码 PCM，通过生产 Swift 处理器处理整首 8,849,400 帧，并确认帧数不变、输出有限且采样峰值没有增加。默认参数下，改动超过 0.001 满刻度的声道样本占 0.06576%。各指定时间窗口左右声道均有检测响应。这些数字表示处理覆盖范围，不是已确认的爆音数量、正确率或听感改善比例。

调试构建中，处理整首 200.667 秒 sample 的渲染及内存准备约用 4.78 秒；这只是宿主 Mac 的离线吞吐量，不能代替手机实时 CPU、功耗、蓝牙或 AirPlay 验证。结果在工程内 `.noindex/artifacts/declick/plugin-sample-validation.json`，没有输出 sample 的修复音频。

真实 FFmpeg → PluginPCMHostController → PluginFFmpegPCMAdapter → AVAudioEngine 输出的模拟器定向测试通过：1 个测试，0 失败，`TEST SUCCEEDED`。测试覆盖左声道人工脉冲、右声道保留、禁用和 0 强度旁路；原始左声道峰值须大于 0.5，开启后小于 0.16，右声道与原声以及 0 强度与禁用输出的峰值误差均不超过 0.001。执行结果见 `.noindex/logs/declick-ios-test.log`。

## 边界

这是短脉冲抑制器，不是双向插值恢复器或真峰值限制器。无法保证区分所有噪声与军鼓、镲片、拨弦等正常起音；较高灵敏度可能改变正常瞬态。不能修复持续削波、编码已经丢失的信息或由后续 EQ/设备引入的失真。sample 主观 A/B、真机实时播放与设备路由尚未验收。

## 复现

```sh
swift test --package-path Packages/MusicFreeBuiltinDSPPlugins --scratch-path .noindex/PluginSystem/BuiltinDSP
swift test --package-path Packages/MusicFreePluginHostBridge --scratch-path .noindex/PluginSystem/HostBridge --filter declickRegistration
bash Scripts/check_architecture.sh
```

外部 sample 测试默认跳过；先在 `.noindex/tmp/declick-sample.f32` 放置 44.1 kHz 双声道交错 Float32 PCM，再用 `MUSICFREE_DECLICK_SAMPLE_PCM` 指定其绝对路径执行测试。可用 `MUSICFREE_DECLICK_SAMPLE_REPORT` 指定数值 JSON 的输出路径。测试后应清理临时 PCM。

App 测试复用 `.noindex/DerivedData/MusicPlayer` 和 `.noindex/coordination/1.4-shared.lock`，测试标识为 `MusicFreeTests/PluginDSPAppTests/testDeclickProcessesActualFFmpegOutputAndBypassesAtZeroStrength`。
