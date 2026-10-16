# iPhone 12 Pro 过渡效果与系统输出前 PCM 验证

## 设备与执行方式

- `ip12`，iPhone 12 Pro（iPhone13,3），iOS 17.6.1，UDID `00008101-000E1C501152001E`。
- 通过 USB 恢复连接，已配对、开发者模式开启。安装 Debug `win.tools4me.music.debug`，版本 1.4.6 / 2026101203；正式版使用独立 bundle ID。
- 最终验证使用内置扬声器，硬件与混音总线均为 48000 Hz、双声道，系统媒体音量 25%，应用音量 0.25。真实 AVAudioEngine 实时渲染，没有启用 manual rendering。
- 复用 `.noindex/DerivedData/MusicPlayer`。未创建新 worktree 或一次性 DerivedData，未执行 Archive、上传或提交。

真机测试位于 `AppTests/FFmpegDeviceTransitionPCMTests.swift`，由 App test host 执行。14 组音频参数场景，加上控制操作、带/不带录音的自然结束和结束期间更换歌曲，共 **18 个真机过渡与控制场景**。xcresult 统计为 5 个 Swift Testing 测试函数，0 失败、0 跳过，其中一个函数包含 14 个参数用例。另一个已有测试函数完成 27 种打包格式的完整播放及各自 CUE 范围播放，0 失败、0 跳过。

## 系统输出前的存储位置

```text
FFmpeg A/B → 每曲 DSP → 共享 PCM → C 过渡混音/包络
                                       ↓ transition-mix.wav
          → timePitch → EQ → 后置效果 → mainMixer 应用音量
                                       ↓ output.wav
          → 系统音量 / 硬件输出 / 内置扬声器
```

`output.wav` 是最终主混音器的 Float32 PCM，位于交给系统输出前，包含应用音量与效果链。系统媒体音量在这个节点之后生效，所以系统音量为零时仍能记录非零 PCM，但不能据此声称扬声器已发声。两处记录使用已有 SPSC 存储节点，实时路径只复制数据，后台写盘。

本轮输入、原始 PCM、记录统计和 route 元数据保存在设备 `Library/Application Support/DeviceTransitionValidation`，避免 Documents 自动导入。导出的验证产物为 `.noindex/artifacts/iphone12-transition/verified`；其中 `index.html` 提供试听，`comparison.png` 展示 RMS，`analysis.json` 为独立文件分析。试听副本只从 Float32 转为 PCM16，不做归一化。

## 结果

| 场景 | 真机结果与独立 PCM 测量 |
| --- | --- |
| 固定 12 秒 | 每首 26 秒，实际重叠 12.000000 秒 |
| 固定短曲保护 | 每首 14 秒，有效时长约 13.04 秒，重叠 6.519979 秒 |
| 固定最小时长 | 实际重叠 0.100000 秒 |
| 智能同拍 | 120 / 120 BPM，重叠 4.04 秒，频率分离测得拍点偏差 ≤20 ms |
| 智能异拍 | 120 / 约 86 BPM，采用能量策略，重叠 3.90 秒，两条原节拍保持不变 |
| 智能响度差 | 输入相差约 14 dB，重叠 1.50 秒，未整曲归一化 |
| 无缝 + 静音跳过 | 零重叠、一次 commit/retirement；换歌低电平约 40 ms，来自两首各保留 20 ms 边缘保护，没有增加额外间隙 |
| 无缝、静音跳过关闭 | 零重叠，保留输入本身的首尾静音 |
| 无缝、混合格式 | 44100 Hz 双声道 A → 22050 Hz 单声道 B，转换到 48000 Hz 双声道，一次连续衔接 |
| 曲中静音 | 首尾裁剪，曲中 600 ms 静音完整保留，前后信号仍存在 |
| 仅淡入 | 3 秒线性淡入；0.5 / 1.5 / 2.7 秒实测增益约 0.166667 / 0.500000 / 0.900000 |
| 仅淡出 | 3 秒自然指数淡出；窗口内实测增益与预期差 <0.001 |
| 同时淡入淡出 | 两条曲线分别符合预期，未把单曲淡入淡出合并为固定交叉时间 |
| 效果关闭 | 首尾非零信号保持单位源增益，没有附加淡入淡出 |
| 暂停、恢复、seek、取消下一首 | 取消后没有误切歌；暂停后进度冻结、恢复继续、paused seek 不启动输出；seek 结束旧录音会话 |
| 手动停止 | 源包络按配置执行 3 秒淡出；带录音时连同排空，硬件引擎约 3.246 秒后停止 |
| 自然结束，录音开启/关闭 | 两种路径都已排空；仅重启暂停的硬件引擎，源保持 EOF，残留 PCM 峰值均为 0 |
| 结束排空期间换歌 | 新歌曲持续播放，旧结束任务不会停止新 graph |

连续播放场景两处 WAV 均无非有限样本、削波、写盘丢块、格式拒绝或写入错误。测得 timePitch 下游延迟 **4096 帧 / 85.333 ms**。补偿这段实际延迟后，最终输出与混音 ×0.25 的相对 RMS 误差约 `8.1e-8–8.8e-8`，连续场景的有声尾部覆盖差为 0。

暂停/恢复和 seek 会改变捕获时钟；实时 tap 可扣留不足一块的数据，seek 又会有意关闭旧会话。`transport` 的逐样本增益对比仅覆盖连续的前 3 秒，不能用全文件强制一个固定偏移。`persistedAllDeliveredFrames` 证明收到的块完整写盘，不证明控制中断时交付了每一个硬件帧。精确离线导出仍使用 `renderOfflineRecording`。本轮连续实时场景通过延迟对齐及独立尾部检查，而不是仅以收到/写入帧数相等验收。

## 真机发现并修复的问题

首轮常规场景通过了 commit/retirement 和写盘统计，但 12 秒过渡的 `output.wav` 缺少按下游延迟对齐后的约 145 ms 尾部；这还混合了 tap 扣留末尾块的影响，不能单独据此认定播放截断。

随后受控测试在自然结束后，仅重启硬件引擎而不重置源 EOF，实际输出了峰值 **0.05000041** 的残留信号。节点报告 timePitch 处理延迟 85.333 ms，源节点 downstream presentation latency 约 95.604 ms。这证明旧实现在源 EOF 后立即暂停，确实把有声 PCM 留在了管线里。

现在自然 EOF 与软暂停/软停止完成包络后，会等待节点报告的 downstream presentation latency 加一个硬件 I/O quantum，再停止硬件输出。开启诊断录音时额外容纳约 100 ms 的实时 tap 批次，以交付有声尾部。等待不驱动包络；曲线仍由 C render 帧推进。替换/seek/teardown 取消自然结束任务，软控制保持版本保护。离线路径仍按成功返回的 render block 排空，不等待实时墙钟。

修复后上述 18 个真机场景和 27 种格式通过；残留峰值由 0.05000041 降为 0。另跑 44 个模拟器过渡、规划、静音和 PCM 存储回归函数，0 失败、0 跳过；架构检查与 `git diff --check` 通过。

## 可复现证据

- 真机过渡：`.noindex/logs/iphone12-transition-verified-tests.log`；xcresult `Test-MusicFree-2026.10.12_23-07-13--0400.xcresult`。
- 真机格式：`.noindex/logs/iphone12-format-verified-tests.log`；xcresult `Test-MusicFree-2026.10.12_23-12-46--0400.xcresult`。
- 不带录音和过期回调：`.noindex/logs/iphone12-drain-lifetime-tests.log`；xcresult `Test-MusicFree-2026.10.12_23-14-48--0400.xcresult`。
- 失败复现：`.noindex/logs/iphone12-natural-tail-executed-tests.log`。更早的无括号函数筛选实际执行 0 个测试，未计入验证。
- 模拟器回归：`.noindex/logs/iphone12-fix-regression-tests.log`；xcresult `Test-MusicFree-2026.10.12_23-15-49--0400.xcresult`。
- 独立 PCM 分析：`Scripts/analyze_device_transition_pcm.py`；日志 `.noindex/logs/iphone12-transition-analysis.log`。
- xcresult 统计 JSON 位于 `verified/*-test-summary.json`。

所有 xcresult 均位于 `.noindex/DerivedData/MusicPlayer/Logs/Test/`。文件重新分析需 NumPy / Matplotlib，设置 `MPLCONFIGDIR=.noindex/tmp/matplotlib` 后执行 `python3 Scripts/analyze_device_transition_pcm.py .noindex/artifacts/iphone12-transition/verified`。

本轮确认了这台手机内置扬声器路线的实时 PCM、时序、控制和管线排空。没有外部麦克风回录或人工主观听感结论，也未覆盖 Bluetooth、AirPlay、锁屏/后台路线变化、所有真实曲库风格。不能把内部 tap 记录等同于扬声器的声学响应或 Apple Music 的完整 AutoMix 能力。
