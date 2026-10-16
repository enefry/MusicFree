# 淡出曲线优化与复查（2026-10-10）

## 实现

- 暂停、停止、手动下一曲/选择歌曲的主包络使用 cubic smoothstep：`gain = startGain × (1 - (3t² - 2t³))`。两端斜率为零，中途恢复或重新下达命令从最后渲染的增益开始。
- 歌曲自然尾部使用以 60dB 为尺度的指数衰减：`gain = (exp(ln(1000) × remainingProgress) - 1) / 999`。起点为 1，最后一个源音频帧为 0；不是在末端直接从 0.001 切断。
- 主包络先在 double 精度完成插值再转 Float，避免 S 曲线在末端因进度舍入提前归零、提前暂停。
- 交叉淡化沿用原有成对归一化等功率包络。淡入、独立设置、零时长立即控制、播放速度能力回退保持原有语义。
- 暂停/恢复仍最多 80ms；停止和手动切歌使用配置时长。自然尾部继续遵守下一曲意图抑制和单调增益规则，晚到的 next 不会抬高已淡出的当前曲。

本次仅修改 `CPlaybackTransition/transition.c` 和两个过渡测试文件；保留工作区原有修改。

## 验证

### C 数值测试

36 项通过，启用 `-Wall -Wextra -Werror -fsanitize=address,undefined`，无 sanitizer 报错。包括：

- 0/1/2 帧、80ms/120ms/3 秒包络；端点、单调性和 S 曲线端点斜率。
- 分数增益下取消、恢复、再淡出；诊断的进度与实际渲染一致。
- 自然尾部的分贝变化、最后一帧归零、短曲和禁用设置。
- 任意渲染分块保持相同样本和源时钟；starvation 冻结时钟。
- gapless、crossfade、下一曲取消/重用、晚到 EOF 和尾部 arm 连续性。
- 5,000 次并发取消与 10,001 个相关信号混合峰值检查。

日志：`.noindex/FadeCurves/numerical.log`。

### iOS Simulator

MusicFree Regression / iPhone 17 Pro / iOS 26.5，复用 `.noindex/DerivedData/MusicPlayer` 并取得共享构建锁。

最终 `xcodebuild test` 成功。xcresult 核对为 **41 个测试定义、89 个执行 case，0 失败、0 跳过、0 预期失败**。运行 `FFmpegPlaybackTransitionTests` 和 Core `PlaybackTransitionTests`。

新增测试从 `AVAudioEngine` 主混音器实际返回的 PCM 测量增益，1kHz 本地 WAV，每块 480 帧：

| 淡出类型 | 25% | 50% | 75% |
| --- | ---: | ---: | ---: |
| 停止 S 曲线 | 0.84336 | 0.49950 | 0.15590 |
| 自然尾部指数曲线 | 0.17102 | 0.02959 | 0.00444 |

实时暂停实测约 **99ms**，通过 250ms 上限断言。gapless 的最小块能量为 0.12103，通过 0.10 下限；公开 Coordinator 路径的暂停、停止、下一曲、选择/重新选择歌曲也全部通过。覆盖 seek、重播、变速回退、混合格式、DSP 和交叉淡化回归。

第一轮新增 PCM 测试使用输出静音时刻对齐曲线，受离线混音预读和停止回调影响导致断言失败；已改为从返回 PCM 的半幅值交点对齐，并重新运行完整的上述测试。精确末端样本与时长由 C 数值测试验证。

最终结果：`.noindex/FadeCurves/verified-final.xcresult`。
日志：`.noindex/FadeCurves/verified-final.log`。
统计：`.noindex/FadeCurves/final-summary.json`。

## 复查结论与边界

本次改动未增加实时线程锁、分配或日志；曲线计算是有界标量运算。命令序号、halted 绑定、ticket/generation、源帧时钟和跨曲归一化逻辑保留。`git diff --check` 通过，本次改动范围内未发现新的 P0/P1 问题。

以上为 C 数值、Simulator 实时控制和离线主混音 PCM 证据；未完成真机主观听感或 Archive 验证，也未在本次重新执行插件和全仓库测试。
