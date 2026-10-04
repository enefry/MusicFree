# 1.4 插件系统开发记录（Session A）

- 工作目录 /Users/chenrenwei/developer/MusicPlayer；分支 feature/1.4.0_dev；启动 HEAD 27bc43f。
- Session 01a0f740-0c47-7523-a2f6-98bd0b06a7a1；用户已授权实施，不受旧方案确认门槛阻止。
- 初始 dirty：Docs/README.md、Docs/Versions/README.md；方案/协调/1.4需求文档与 thirdpart/ 为未跟踪，全部保留。
- 读取协作协议与方案，先用 CodeGraph 定位当前组合根、歌词、元数据、在线源、设置端口。
- 基础契约、Runtime、参考插件及宿主接入已实施。当前自动化、Simulator 与边界限制见下方最终验证记录；真机与 Archive 未验证。

## 协调纠正

A 第二次获取共享锁失败后误继续修改 SettingsViewModel/FeatureServices 和在线源契约，并误移除了现有锁。已停止共享写入，恢复 B 的已登记 session 归属；原操作文字不可恢复。此次 patch 仅精确行修改，未整体覆盖文件，B 现有过渡设置和 FFmpeg 代码仍保留。后续必须检查 mkdir 成功结果后才执行独立的 apply_patch；释放前核对 owner。

## 独立自动化证据

- Runtime SwiftPM：8 个 Swift Testing 用例通过（加载去重、隐藏运行、撤权/停用/取消迟到、注册隔离、schema、匹配）。首次沙箱缓存拒绝后正常提权；发现独占读写冲突并修复后重跑通过。
- Audio SwiftPM：5 个 Swift Testing 用例通过（双声道链数值/EOF、非有限值与旁路、格式、真实样本有界分析队列/代次、离线取消）。日志 .noindex/plugin-runtime-test.log 与 .noindex/plugin-audio-test.log。

## 宿主闭环进展

- 更新后独立测试：Runtime 9/9、Audio 6/6（包含 AVAudioEngine 实际离线增益/拆卸）、HostBridge 6/6（包含仅播放无下载继承、多账户撤销隔离、真实 48000 帧 WAV 下载/解码、歌词翻译/逐字存储、metadata 字段过滤、旧设置/未知插件兼容）。
- XcodeGen 已生成并绑定新的本地包；主 checkout Debug generic iOS Simulator 构建通过，复用 .noindex/DerivedData。日志 .noindex/plugin-host-build.log。初次撞到 B 正在增加 PCM factory 的未初始化存储属性；待其源码完整后重跑，不修改该 feeder。A 自己的 decoder 属性命名错误已修正为实际 format。
- 架构脚本新插件音频分层白名单已补充；检查仍被 HEAD 已存在的 RootViewController.swift:13/1728 LibraryAudioConversion SwiftUI 路径阻挡，git show HEAD 已验证，不修复无关代码。基础 PluginAPI 与 Runtime 无 Core/UIKit/AVFAudio import。
- 现有 SettingsMigration 经 AppSettings 可选字段解码兼容；保持 envelope schema 1，未改变既有原始设置/账号身份。新增插件偏好只保存 schema-declared 非敏感字段和 Keychain 引用。
- Simulator 交互、AppTests UserDefaults、真实服务、真机听音/开销、Archive 尚未形成证据。

## DSP 给 B 的接线需求

A 提供 MusicFreePluginAudio 的同步 planar Float32 处理入口；生产者调用仅限现有 decode feeder 专用队列，buffer 不跨 await、不保存指针。每个正式播放/试听及未来双轨分别创建处理链。seek/stop/route/reconfigure 串行 reset/rebuild；保留已有 EQ。A 不编辑 B 的 FFmpeg graph 或 PlaybackAPI。

B 在 PLAYBACK_TRANSITIONS_1.4_DEVELOPMENT_LOG.md 明确交接可由 A 添加 EQ 后的可选 mix-bus hook。A 据此仅添加 FFmpegPlaybackEngine.setPostEqualizerEffect(AVAudioNode?) 和输出连接 helper，保留 B 的双槽/过渡状态与时钟。App 分别给正式播放、试听注入独立 PluginAudioHostController，插件层负责许可与实例；图不依赖 Runtime。当前图参考效果限定 postMix、零 latency/tail；perTrack PCM 原型通过 DSPProcessingChain 的实际 AVAudioPCMBuffer 入口独立验证，尚不接双槽 feeder。

## 范围

四类通用能力与公开离线/受控参考实现；既有歌词/在线源拆离仅 roadmap。MusicLyricsAPI、私有协议与 UIKit 播放器插件接口全部不处理。

## 2026-10-01：PCM 接线和当前验证

- B 已在自己的记录明确交接 `FFmpegPCMProcessing` / `FFmpegPCMProcessorFactory`。A 新增 `App/PluginFFmpegPCMAdapter.swift`，在 AppContainer 持锁注入正式播放与试听各自的 `PluginPCMHostController`，每个 feeder/双轨 slot 独立创建同步 DSP 链；图上插件 ID 从 per-track 链排除，避免重复应用同一效果。Runtime 不进入 FFmpeg target。
- PCM 停用、撤权及配置替换关闭 C11 atomic permission gate，后续解码块立即旁路；已经排队的音频不回写。播放中不能安全安装新 factory，因此新配置延迟到输出停止后，通过宿主 snapshot stream 重试。当前 per-track 接线只支持零 latency/tail，其他声明跳过；未验证的处理链 conservatively `preservesTiming=false`，故启用 PCM DSP 时 B 的 gapless/crossfade 降级。卸载后恢复无 PCM factory。
- processor 构造失败跳过该插件，prepare 失败仅旁路该插件；协作式 process error/NaN/Inf 回滚当前块并旁路，native 阻塞/崩溃不能由 Runtime 抢占或隔离。离线 renderer 则支持串联 tail 求和并限长，EOF 数值测试覆盖完整尾音。
- Reference PCM Gain (`reference.pcmGain`) 与 Reference Graph Gain 分开注册。图 tap 提供真实样本、有界分析 ring 和 10 Hz UI 订阅；Simulator 的 PCM 验证通过真实 WAV -> FFmpeg decoder/feeder -> AVAudioEngine offline output，比较启用前后峰值比为 0.5，未将直接 buffer 单测当作生产接线证据。
- Runtime 按 `(pluginID, instanceID, capability kind)` 独立加载，只调用被请求的 factory；多能力实例不会因账户配置或撤销而误加载其他能力。全局/source schema 分开。缺包配置继续保留并在管理页标记当前构建未包含；不可用配置不被空 schema 重写。
- 通用源下载按 preferred name、插件 suggested name、HTTP response name、URL 的有效扩展名落盘；不再把所有媒体标为 WAV。取消、失败或 Runtime 拒绝迟到结果时删除本次独立下载目录，HTTP 临时文件在错误分支也清理。已有 host queue identity/retry/restart 保留；**未实现 HTTP Range/字节级续传，allowsResume 当前仍会重新下载**。
- 三开关独立、schema 配置、通用来源账户增删改/consent、Keychain scoped references 已接入宿主设置页面。旧 DS/Google 专用配置和 factory 保留，未迁移私有服务。账户编辑/Keychain 本机真实交互未形成完整 UI 验收证据。

### 最新自动化证据

| 验证 | 当前结果 | 日志/工件 |
| --- | --- | --- |
| PluginRuntime SwiftPM | 13/13 通过：包含凭据 permission/account/record 隔离、缺包配置展示、capability-specific loading 和迟到结果拒绝 | `.noindex/plugin-runtime-test.log` |
| PluginAudio SwiftPM | 8/8 通过：包含真实 Apple offline graph、permission gate、prepare failure、串联 EOF tail 和有界分析生产者 | `.noindex/plugin-audio-test.log` |
| HostBridge SwiftPM | 8/8 通过：包含 PCM pending install/gate、真实 WAV 下载解码、source schema、多账户/仅播放、DTO/旧设置 | `.noindex/plugin-host-test.log` |
| 现有 Core 回归 | 14/14 通过：LyricsCoordinator、onlineSourceCoordinator/configuration/preferences、旧 logging settings | `.noindex/plugin-core-regression.log` |
| 主 checkout Debug Simulator 宿主测试 | 6/6 通过：2 UserDefaults envelope/reopen/legacy，4 graph mount/unload、独立 PCM 链/gate、真实 FFmpeg 输出比例、真实 graph tap 分析订阅 | `.noindex/plugin-simulator-test.log` |
| Simulator UI | 1/1 通过：启用/加载开关独立，terminate/relaunch 后持久化，恢复测试改变的偏好 | `.noindex/PluginSystem/plugin-host-simulator.xcresult` |

Simulator：MusicFree Regression，`C3DA6A33-6237-4B7E-ADFE-7E429DC54B69`，iOS 26.5。测试命令复用 `.noindex/DerivedData`，持锁 XcodeGen/编译/测试。`xcodebuild ... -only-testing:MusicFreeTests/PluginPersistenceTests -only-testing:MusicFreeTests/PluginDSPAppTests -only-testing:MusicFreeUITests/PluginSystemUITests test` 最终 TEST SUCCEEDED，实际执行 6+1，非零用例。与上表独立测试/既有回归合计 50 个相关用例通过；工件为当前源码的最终 Debug Simulator 结果。

过程中修正：AppContainer 的 optional closure ternary 触发 Swift compiler failed-to-produce-diagnostic，改为明确 if 赋值后编译通过；UI 起初点击 SwiftUI Toggle 外层整行 accessibility container，真实 hierarchy/screenshot 确认内部 UISwitch 未收到点击，改点内部控件后通过；输出绝对峰值包含声道混音增益，改为同图 baseline 比例验收后通过。一次失败后的 `simctl diagnose` 长时间占用结果收集，核对确属本次诊断 PID 后仅停止该采集，使已有结果落盘。

最后的 graph tap 分析测试捕获并修复真实线程崩溃：`MusicFree-2026-10-01-091610.ips` 的 faulting thread 为 `RealtimeMessenger.mServiceQueue`，堆栈为 `_dispatch_assert_queue_fail -> swift_task_checkIsolatedSwift -> closure #2 in PluginAudioHostController.apply`。SDK tap block 在 MainActor 方法中构造，隐式继承 isolation；改用 `nonisolated makeAnalysisTap` 创建后，真实播放 producer -> C ring -> 10 Hz 主线程 subscriber 的测试通过（非模拟塞入样本）。

### 仍待验收 / 明确限制

- 全量架构脚本仍失败于 **HEAD 已存在** `App/RootViewController.swift:13` import SwiftUI / `:1728` LibraryAudioConversion hosting；通过 git show HEAD 核对，不修复无关内容。新增插件基础 API/Runtime 无 Core/UIKit/AVFAudio 依赖，音频允许路径仅精确新增 audio target/bridge/`App/PluginFFmpegPCMAdapter.swift`。
- 真机听音、后台/Control Center、路由切换与实时 CPU/budget、真实外部服务/OAuth、最终 Archive 未执行；不以 Simulator/offline 数值替代这些证据。A-only/B-only/combined 完整版本矩阵也未全部执行；当前已通过的是共享组合源码 Debug Simulator。
- 生产 PCM 暂不做 latency compensation/tail scheduling，graph controller 当前安装一个匹配的 postMix 效果；当前只提供一个 graph reference。新插件 factory/config 在正在播放时等待停止，UI 配置替换可能先旁路旧 PCM；不保证即时热切换。
- 本次未创建分支/worktree，未暂存/提交/恢复或清理 B/thirdpart 的工作。版本身份 `1.4.0 (2026100103)`。

## 2026-10-03 DSP 双位置选择

插件新增支持位置与默认位置声明，设置保存每个插件的 `dspPlacement`。`reference.gain` 支持每轨混音前与总线混音后，默认总线；原有 EQ 保留。PCM 和图控制器按所选位置分流，修改时先撤销旧处理资格，输出停止后各自重试挂载。正式播放、试听和双轨槽各自创建实例，同一插件不会在两处同时处理。

本节替代此前按 graph ID 排除 PCM、开启 PCM 后禁用过渡的接线限制：PCM 适配器对 scope、零 latency/tail 的校验保证时间不变，App 宿主现在传入 `preservesTiming: true`，支持 gapless/crossfade。图侧仍为一个总线效果槽；缺失后端或槽已占用会暴露诊断。

配置兼容性、接线图、测试数量及工件见 [DSP 双位置验证](../Testing/1.4_DSP_PLACEMENT_2026-10-03.md)。
