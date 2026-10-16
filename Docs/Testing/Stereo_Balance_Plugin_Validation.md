# 声道均衡插件首版验证

验证日期：2026-10-14（开发机 America/New_York）。本记录针对工作区开发版，不代表发布或真机听音验收。工作区已有其他未提交功能，未清理或提交这些改动。

## 已实现

- 原生每轨 DSP `builtin.dsp.stereoBalance`，默认关闭，独立配置和设置 companion。
- 显示强度保存为 0–100；DSP 只换算一次 `pMax = strengthPercent / 200`。默认显示 20% = 实际 10%。
- 固定模式精确使用用户比例；自动模式以此为上限，使用 6 dB 目标、100 ms 能量估计/attack、1.5 s release、10 ms 连续样本控制周期和 -50 dBFS 信号门限。
- 自动模式根据输入估计的能量及互相关约束目标比例，避免预计混音恶化失衡；预计能量损失约束为 3 dB。当前比例平滑回落，不是瞬时硬限制。
- UIKit 自动开关、1% 步进滑块、20%／30%／50% 快选、只恢复参数的重置、保存失败草稿与重试、连续修改合并保存。
- 沿用宿主延后安装机制，页面明确提示暂停再继续；没有新增音频图节点、归一化、延迟或尾音。

## 已通过

| 验证层级 | 结果和证据 |
| --- | --- |
| DSP 数值 | 新增 6 个 Swift Testing 测试函数通过（含参数化映射、44.1/48/96 kHz 和布局案例），原有 EQ 3 个测试函数通过。不同分块 1/31/441/8192 帧结果逐样本相同；覆盖默认值/非法配置、单侧、均衡恢复、等幅反相、reset、静音、非有限输入及 1/6 声道透传。日志 `.noindex/logs/stereo-balance-dsp.log` |
| 设置控件和保存 | 模拟器中 2 个测试函数通过：真实 UIKit 表单默认滑块、0 保存/重读、重置保留插件状态、连续编辑和保存失败重试。日志 `.noindex/logs/stereo-balance-simulator.log` |
| 实际播放链路 | 1 个集成测试函数通过：生成右侧 440 Hz WAV，经 PluginRuntime → PluginPCMHostController → PluginFFmpegPCMAdapter → FFmpegPlaybackEngine → AVAudioEngine 离线渲染；关闭插件基线、固定显示 20/30/50/100、默认自动 20 均符合预期输出，未失败旁路，确认没有重复混音。它验证离线引擎，不代表扬声器实际播放 |
| 构建 | Xcode 27.1（27A9275），iOS 27.0 模拟器 MusicFree Regression；`xcodebuild test` 为 `TEST SUCCEEDED`。复用 `.noindex/DerivedData/MusicPlayer` |
| 架构 | `bash Scripts/check_architecture.sh` 通过，日志 `.noindex/logs/stereo-balance-architecture.log` |
| 用户歌曲 | 正式编译的 SwiftPM `StereoBalanceDSPPlugin` 链接离线 runner 处理 Ticket To Ride 前 30 秒，无响度对齐。固定输出与交叉混音公式最大误差 1.49e-8；默认自动前 5 秒左右能量差约 19.0985 dB，固定实际 10/15/25% 分别为 19.0976/15.0805/9.5515 dB。原始约 41.09 dB。试听不是耳听验收 |

构建产物：`.noindex/DerivedData/MusicPlayer/Build/Products/Debug-iphonesimulator/MusicFree.app`，bundle ID `win.tools4me.music.debug`。

xcresult：`.noindex/DerivedData/MusicPlayer/Logs/Test/Test-MusicFree-2026.10.14_21-37-58--0400.xcresult`。

正式插件试听及可复用 runner：`.noindex/artifacts/stereo-balance-development/`，其中 `manifest.json` 记录源文件 SHA256、模式、比例和结果；`preview_auto_display20.wav` 为默认自动试听，其他三个 WAV 为固定显示 20/30/50%。这些文件没有采用先前试听的 RMS 对齐，因此不能直接按响度和先前试听比较。

## 复现命令

```sh
swift test --package-path Packages/MusicFreeBuiltinDSPPlugins --scratch-path .noindex/PluginSystem/BuiltinDSP
bash Scripts/check_architecture.sh
xcodegen generate
xcodebuild -project MusicFree.xcodeproj -scheme MusicFree \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=43A20F94-717D-4ED8-BAF8-606B3C0A336E' \
  -derivedDataPath "$PWD/.noindex/DerivedData/MusicPlayer" \
  -only-testing:MusicFreeTests/StereoBalancePlaybackTests \
  -only-testing:MusicFreeUIFeatureTests/StereoBalanceSettingsTests \
  CODE_SIGNING_ALLOWED=NO test
```

共享构建实际执行时使用 `.noindex/coordination/1.4-shared.lock` 的 fcntl 排他锁，避免与其他构建互相干扰。

## 尚未确认

- 模拟器图形界面未能通过当前工具打开，尚未人工检查完整应用导航、视觉布局及 VoiceOver/Dynamic Type；UIKit 控件与模型测试不能替代这些检查。
- 未端到端测量播放中修改后的关 gate、排队 PCM 边界和暂停/继续安装时点。界面提示沿用已知宿主机制。
- 未完整验证多轨 crossfade/取消、路由切换、权限撤销等组合场景；数值 reset/隔离验证不等于这些宿主路径的完整覆盖。
- 未做真机耳机/蓝牙/扬声器听音、CPU/耗电与连续超预算旁路测量；不宣称无可听爆音或具体性能收益。
- 未 Archive、上传或发布。
