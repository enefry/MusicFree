# 内置 DSP 插件

`EqualizerDSPPlugin` 为独立 SwiftPM product，仅依赖插件 SDK 和 Apple Audio。提供原来的十段 EQ（32–16000 Hz，±12 dB）：每轨位置使用分通道 PCM 滤波器，总线位置使用 AVAudioUnitEQ。默认总线混音后，可在插件设置中切换。

原 EQ 设置、预设与插件参数由 HostBridge 同步。正式播放、试听和过渡轨道使用独立实例；生产引擎旁路旧 EQ 实现，避免重复处理。总线参数更新保留节点身份；图结构及每轨处理器变更在暂停/停止后生效。

`StereoBalanceDSPPlugin` 是仅依赖插件 SDK 的每轨 PCM 插件，默认关闭。默认自动模式、显示强度 20%（实际混入上限 10%），提供 20%／30%／50% 快捷选择；关闭自动调整后采用固定交叉混音。显示 100% 对应固定模式单声道，自动模式只允许最多混入至该比例。单声道及多于两声道透传，不增加延迟或尾音。设置入口在插件详情页，播放中修改后需暂停再继续。

声道均衡的规格和验证边界见 [开发规格](../../Docs/Architecture/Stereo_Balance_Plugin_Plan.md) 与 [开发版验证记录](../../Docs/Testing/Stereo_Balance_Plugin_Validation.md)。

`DeclickDSPPlugin`（爆音抑制）是仅依赖插件 SDK 的逐曲 PCM 插件，默认关闭。各声道独立使用因果波形预测及自适应残差阈值，短暂异常期间抑制尖峰；持续变化触发起音保护，避免持续压平信号。提供检测灵敏度（0–100，默认 35）和抑制强度（0–100%，默认 100%）；任一参数为 0 时原样透传。它没有前瞻延迟或尾音，状态跨解码块连续，并在 seek/stop/reset 后清空。适用于短促脉冲，不能还原持续削波或录音失真；音乐瞬态仍可能误判，建议从低灵敏度开始对照试听。

通过“设置 → 插件 → 爆音抑制”启用、允许加载并配置；播放中改动后暂停再继续，使新处理器生效。正式播放、试听和过渡轨道沿现有插件工厂分别创建实例。数值与播放链路验证见 [验证记录](../../Docs/Testing/Declick_Plugin_Validation.md)。

运行离线验证：

```sh
swift test --package-path Packages/MusicFreeBuiltinDSPPlugins --scratch-path .noindex/PluginSystem/BuiltinDSP
```

接入与验证记录见 [现有能力迁移](../../Docs/Testing/1.4_BUILTIN_PLUGIN_MIGRATION_2026-10-03.md)。

## 处理优先级

同一处理位置内按优先级从小到大执行，相同值按插件 ID 排序。爆音抑制默认为 100、声道均衡为 200、EQ 为 300；未声明默认值的插件为 500。每轨和总线分别排序，优先级不会改变处理位置。

插件详情页的“处理优先级（高级）”可覆盖为 0–1000 的整数，或恢复插件默认值。旧设置无需迁移，修改顺序在暂停或停止后生效；正式播放、试听和过渡轨道共用排序规则。
