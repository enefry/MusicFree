# 12 秒交叉渐变与首尾静音跳过

## 已实现

- Crossfade 的设置、迁移、效果契约和混音窗口统一支持最长 12 秒。独立淡入/淡出仍为最长 3 秒。
- 预读环形缓冲按所选重叠窗口分配，保留 EOF 探测余量；短曲仍将重叠限制为任一歌曲有效长度的一半。
- 设置 → 播放 → 歌曲过渡新增“跳过首尾静音”，默认关闭，独立于歌曲过渡开关。设置其他效果时保留该值，旧设置缺少字段时使用关闭值。
- 在解码队列上检测源 PCM 的每个声道，使用 -80 dB 峰值阈值，要求连续静音至少 250 ms，边缘保留 20 ms。检测长首尾静音时逐块读取，不缓存整首音频，可响应取消。
- 尾部截断只接受实际解码 EOF，容器时长只用于 seek 提示；未知或不一致的时长、检测失败时保留原始尾部。全静音文件继续正常播放。
- 原歌曲进度包含跳过的开头，退场已播放时长只计算输出帧。曲中停顿保留，拖动至曲中或尾部静音仍尊重用户指定位置。
- 生效范围为本地完整歌曲、1 倍速、保持时序的 DSP；网络播放、CUE 分段和变速保持原行为。

## 验证

以下 Simulator 与 37 项 C 测试结果来自包含既有 UIKit 设置迁移和过渡控制修复的开发工作区。本次独立提交包含过渡引擎、配置、文案及相关测试；UIKit 页面继续随迁移保留在工作区。独立暂存补丁另外通过 15 个 Swift 文件的语法检查、文案 JSON 检查及 22 项 C ASan / UBSan 数值测试，未对该补丁单独执行完整 App 构建。

Xcode 27.1，iOS 27.0，MusicFree Regression / iPhone 17 Pro（`43A20F94-717D-4ED8-BAF8-606B3C0A336E`）。复用 `.noindex/DerivedData/MusicPlayer`，未创建新的 DerivedData。

最终 Simulator 测试通过 70 个测试函数，0 失败、0 跳过；24 个参数化测试共执行 82 个参数组合。

| 范围 | 结果 |
| --- | --- |
| PlaybackTransitionTests | 18 个函数通过，覆盖迁移、设置独立性、切歌授权及新静音设置的能力裁剪/预加载失效 |
| FFmpegPlaybackTransitionTests + FFmpegSilenceSkippingTests | 30 个函数通过，真实 FFmpeg 解码与 AVAudioEngine 手动渲染 PCM |
| NativeSettingsPresentationTests + SettingsBoundarySilenceTests | 22 个函数通过，原生设置控件、12 秒范围、独立开关与保存/重开 |
| C 渲染器 ASan / UBSan | 37 项数值测试通过，覆盖跳过时间与输出时钟隔离、过渡边界及并发取消 |
| 架构检查、git diff --check | 通过 |
| 本次新增文案 | 5 个键均覆盖 en、zh-Hans、fr、de、es、ja |

实际音频证据：

- 25 秒压缩曲目在 48 kHz 公共输出时钟上，交叉渐变从 frame 624000 开始，上一首在 frame 1200000 退场，重叠恰为 576000 帧，即 12 秒。
- 测试音频包含 400 ms 开头静音、600 ms 结尾静音与 400 ms 曲中停顿。开启后退场帧从 96000 缩短至 49919，曲中静音保持 19200 帧；100 ms crossfade 的有效重叠仍为 4800 帧。
- 单侧声道的 -74 dB 音乐保留，31 秒开头/32 秒结尾静音正确识别；全静音文件、扫描取消及曲中 seek 用例通过。

复现命令：

```sh
xcodebuild -project MusicFree.xcodeproj -scheme MusicFree \
  -derivedDataPath "$PWD/.noindex/DerivedData/MusicPlayer" \
  -destination 'platform=iOS Simulator,id=43A20F94-717D-4ED8-BAF8-606B3C0A336E' \
  -only-testing:PlaybackTransitionTests \
  -only-testing:MusicFreeFFmpegAdapterTests/FFmpegSilenceSkippingTests \
  -only-testing:MusicFreeFFmpegAdapterTests/FFmpegPlaybackTransitionTests \
  -only-testing:MusicFreeUIFeatureTests/SettingsBoundarySilenceTests \
  -only-testing:MusicFreeUIFeatureTests/NativeSettingsPresentationTests \
  CODE_SIGNING_ALLOWED=NO test
```

证据保存于 `.noindex/logs/transition-silence-final-tests.log`、`.noindex/logs/transition-silence-render-tests.log`、`.noindex/artifacts/transition-silence/test-summary.json` 和 DerivedData 的最终 xcresult。

## 验证边界

以上为源码、完整 App 编译、Simulator 设置控件和实际离线 PCM 输出验证；尚未做物理设备听测或 Archive。

工程全量本地化检查仍报告 396 个既有缺项（包括其他设置/插件翻译和原有“无缝播放”等键）。本次新增键全部通过六语言覆盖检查，未修改无关文案。
