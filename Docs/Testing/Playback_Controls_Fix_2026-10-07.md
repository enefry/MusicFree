# 播放控制修复与验证（2026-10-07）

范围：用户反馈的无缝播放、暂停延迟、暂停后 seek。基线 `feature/1.4.0_dev` / `0554d74`，保留本工作区原有 UIKit、设置、插件和日志修改。本轮没有提交、发布或安装真机版本。

## 修复

1. **无缝衔接音量凹陷。** 原实现只在下一首已 arm 后抑制单曲尾部淡出。队列解析下一首、打开解码器或发布 handoff 的间隙，短曲会先进入 3 秒尾部淡出；`tailGain` 单调下降，随后准备成功也无法恢复。现在队列在异步解析之前同步发布“有后继歌曲”的意图，render 在此期间保留源音量。该意图跨越 handoff，直到队列同步决定新歌曲有无后继。队列结束或准备失败仍恢复原有尾部淡出，手动停止仍采用配置的完整淡出；无缝模式仍是零 overlap，交叉淡化仍独立控制。
2. **暂停响应。** 暂停及从暂停恢复使用最多 80 ms 的 transport 渐变；配置为零仍立即控制。首次播放、手动换歌和停止保留歌曲淡入淡出配置。暂停完成时发布最终位置，避免恢复时才更新淡出期间消耗的进度。正常完成由 render 驱动；无回调/饥饿时仍有 250 ms 的额外 deadline 容限，不承诺所有设备都在 80 ms 内停止声卡输出。
3. **暂停 seek / 恢复。** seek 先取消旧软控制任务和回调、停下暂停意图的输出，再同步 handoff 和重建 feeder；保留原暂停 phase，清理旧缓冲与位置更新任务。恢复先发布新的 render 命令再启动音频，避免用暂停命令预填输出缓冲。C 的 halted 完成信号绑定命令序号，旧暂停结果不能完成新命令。seek 重建失败也不再被随后写入的正常状态覆盖。

## 实证

修改前针对性测试实际执行 6 个用例：暂停及时停止、连续无缝音量两项失败，普通暂停 seek 的 4 个用例通过。不能据此声称已经复现用户所有暂停 seek 异常；本轮覆盖了旧控制回调、长淡入后的恢复以及实际目标音频片段。

- 3 首各 1 秒恒定正弦、无缝开启、淡出 3 秒、淡入为零：自动衔接前两首的最低 512 帧均方能量，修改前 `0.000275575`，修改后 `0.121025271`（理论能量约 `0.125`）。测试经过真实 AppServices 队列和 AVAudioEngine mixer，覆盖异步后继解析以及 handoff 后的下一次准备。
- 实时 AVAudioEngine、配置淡出 3 秒：暂停到 engine 完成停机测得约 **100.05 ms**，断言上限 250 ms。该测量在 iOS Simulator，不能外推蓝牙、AirPlay 或真机硬件延迟。
- 正式队列暂停后依次 seek 到 6 秒、1 秒、0 秒，等待 350 ms 确认旧 deadline 不改变暂停状态、位置、队列 resumePosition 或曲目身份。恢复后检测实际 PCM：6 秒为 880 Hz，1 秒和 0 秒为 440 Hz，目标信号幅度 >0.3，且至少为错误片段频率的 5 倍。
- 引擎另覆盖 1 / 1.5 倍速、淡出尚未完成 / 已硬暂停、前进 / 后退 / 回零、恢复后旧回调不重新暂停。
- C 数值测试额外覆盖后继意图发布早于 arm、跨 handoff 保持音量、最终曲恢复尾部淡出，以及旧 halted 信号对新命令失效；保留原有包络、饥饿、槽位复用及 5000 次并发取消测试。

## 验证结果与产物

使用 MusicFree Regression / iOS 26.5 / `C3DA6A33-6237-4B7E-ADFE-7E429DC54B69`，共享锁串行运行，复用 `.noindex/DerivedData/MusicPlayer`。

- Simulator：**50 个测试定义 / 97 个实际用例，0 失败、0 跳过、0 expected failure**。整套 FFmpeg transition、PlaybackTransitionTests 和 App PluginDSP 回归为 48 个定义 / 95 个用例；追加正式队列 PCM 与实时暂停为 2 个定义 / 2 个用例。
- C：**24 个数值场景，ASan / UBSan 通过**。
- `Scripts/check_architecture.sh` 与 `git diff --check` 通过。
- 日志：`.noindex/logs/playback-controls-before.log`、`playback-controls-after.log`、`playback-controls-position.log`、`playback-controls-numerical.log`、`playback-controls-architecture.log`。
- 实际用例计数、数值程序和最终源码校验：`.noindex/artifacts/playback-controls-2026-10-07/`。

初次构建出现测试参数顺序错误、一次运行使用错误的 App test target，均修正后重新执行。架构脚本与 xcresulttool 在沙箱内因缓存权限失败，使用已有授权的宿主权限后通过；未把这些失败运行记作验证成功。

## 尚未闭合的设备证据

原录屏末段低电平仍缺相应 `mpc8` 原文件对照。修复的是已复现的引擎音量凹陷，不证明源文件本身没有静音，也不增加自动裁剪歌曲静音。实际设备上的这三项体验、声卡路由和用户歌曲组合尚需新版本复测；未做真机、Archive、上传或全仓测试。UIKit 约束冲突属于先前报告的独立问题，不在本次音频控制修改范围内。

## 交叉时长入口补充

用户反馈交叉时间没有配置入口。现有 UIKit 页只在已选中交叉淡化时创建时长分区，默认无缝模式会隐藏它。现在支持交叉淡化时始终显示独立时长选项；开启歌曲过渡并选中交叉淡化后可调整 0.1–3 秒，步长 0.05 秒，风格行右侧同时显示生效时长。页脚说明该时间为两首歌曲重叠播放的时长。关闭或选择无缝时保留可见但不可编辑的时长控件，避免误改播放风格。

正确的 `MusicFreeUIFeatureTests` 目标实际执行 2 个设置用例并通过，覆盖默认可见、选中可编辑、2.25 秒保存、关闭再开启以及重开页面读取。日志 `.noindex/logs/crossfade-duration-settings-verified.log`；本次未重复运行音频套件，也未做真机界面验证。初次误选 `MusicFreeUITests` App UI 目标执行了 0 个测试，未计作成功证据。翻译 JSON 与 `git diff --check` 通过。
