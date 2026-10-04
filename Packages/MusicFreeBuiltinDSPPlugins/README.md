# 内置 DSP 插件

`EqualizerDSPPlugin` 为独立 SwiftPM product，仅依赖插件 SDK 和 Apple Audio。提供原来的十段 EQ（32–16000 Hz，±12 dB）：每轨位置使用分通道 PCM 滤波器，总线位置使用 AVAudioUnitEQ。默认总线混音后，可在插件设置中切换。

原 EQ 设置、预设与插件参数由 HostBridge 同步。正式播放、试听和过渡轨道使用独立实例；生产引擎旁路旧 EQ 实现，避免重复处理。总线参数更新保留节点身份；图结构及每轨处理器变更在暂停/停止后生效。

运行离线验证：

```sh
swift test --package-path Packages/MusicFreeBuiltinDSPPlugins --scratch-path .noindex/PluginSystem/BuiltinDSP
```

接入与验证记录见 [现有能力迁移](../../Docs/Testing/1.4_BUILTIN_PLUGIN_MIGRATION_2026-10-03.md)。
