# 播放效果文件日志排查

## 用户提供的日志

`musicfree.log` 仅有 10 条，时间均为 `2026-10-06T17:27:32Z`（纽约时间 13:27:32）。记录包含在线源设置应用、DS Audio 适配器构建成功，以及元数据处理空闲；没有均衡器参数、播放操作、淡入淡出或交叉淡化记录。

这份文件不足以判断用户设备上的效果是否生效，也不能据没有错误记录认定播放正常。代码确认 FFmpeg 原有 Logger 仅写 Apple 系统日志，应用分享文件由 MusicLogger 单独写入；均衡器宿主原先缺少参数应用和节点安装诊断。

## 本次修改

- FFmpeg 日志改用 MusicLogger，保留系统日志并接入已有、由用户开关控制的文件日志。记录实例 ID、播放代次、操作、速度、过渡时长、变速下 fade 是否适用、音频图/运行状态、音频路由类型和稳定错误码。
- 设置加载/保存记录请求参数与按能力裁剪后的有效参数，包括均衡器开关、前级、频段和过渡时长。
- EQ 插件记录启用/加载许可、Runtime 状态、处理位置，以及固定数字字段；不输出未知配置或凭据。
- postMix 宿主记录安装成功、实际 AVAudioUnitEQ 参数、是否连接引擎和旁路；perTrack 宿主记录工厂安装及许可 gate。安装延后只在待安装插件集合/错误类型改变时记录，避免每次位置更新刷屏。

播放器日志的 `external=true bypass=true` 表示旧 EQ 节点由插件替代，需继续对照插件的 `equalizer-applied ... bypass=false` 或 PCM 工厂记录。`attached=true` 和工厂安装成功说明控制链路已应用，仍不能单独证明用户听到了预期音色。没有在音频 render 回调中增加文件写入。

## 验证

复用 `.noindex/DerivedData/MusicPlayer`，经共享构建锁串行运行；日志 `.noindex/logs/playback-effect-file-diagnostics.log`。

- 9 项 App DSP 测试通过，含新增可分享日志验证和已有实际音频处理测试。
- 31 项插件宿主测试、2 项 Core 设置集成测试、1 项恢复预设 AudioUnit 验证通过。
- 架构检查及 `git diff --check` 通过；架构日志 `.noindex/logs/playback-effect-diagnostics-architecture.log`。
- 新日志测试使用真实 UserDefaults 设置仓库，保存 1 kHz +3 dB、前级 -6 dB，验证插件节点实际值及播放器旧 EQ 旁路记录进入同一文件；切换 perTrack 后验证工厂安装和 gate 记录。测试文件和 UserDefaults 域在结束后清理。
- 未执行 Archive、发布、更新用户安装包或真机听音。

## 下一次设备复现

需要先安装包含本次修改的版本；旧安装包导出的文件不会自动增加新日志。开启文件日志后，在同一首歌曲中切换平直/预设和自定义；若排查过渡，设置明确的时长并记录播放速度，分别操作播放、暂停、下一首和自然播完。复现后立即分享日志，并提供安装版本与异常操作时间。

## 第二份日志：musicfree 3.log

共 47 条；前 10 条为旧记录，新记录范围 `18:50:41Z–18:52:31Z`（纽约时间 14:50–14:52）。

- 第 11、34、43、47 行设置均为 1 倍速、淡入 3000 ms、淡出 3000 ms；gapless 开启、crossfade 关闭。没有设置 commit，不能据此判断切换设置是否失效。
- EQ 开启，但前级和全部频段为 0 dB，因此这段配置不应产生 EQ 音色变化。`external=true bypass=true` 是旧 EQ 节点被插件接管；这份日志没有插件节点记录，可能是开启日志晚于插件初始化，不能据缺失认定插件未加载。
- 引擎 apply/play/pause/stop 均使用同一实例，graph 存在。四次 pause 入口均 running=true，满足现有软淡出条件。
- `play running=false` 是启动前的入口状态，不能解释为播放失败。18:51:07 与 18:51:09 两次 stop 间隔短于 3 秒，会重新发出控制命令；现有记录不足以证明它与用户反馈有关。
- 没有 warning/error；也没有包络进度、render 确认或暂停完成原因，不能认定 3 秒渐变实际输出正常。

## 补充包络执行诊断

针对第二份日志的证据缺口，增加 `ffmpeg-envelope` 分类：

- 主线程记录 graph/engine ID、请求与 render 已接收的命令序号、目标增益、包络增益、已完成/请求渐变帧数、采样率、回调累计帧数、源帧数，以及 halted/starved/ended。
- `command` 记录请求；`render-progress` 按约四分之一进度去重；`render-complete` 表示源节点包络帧执行完成。音频输出延迟与设备最终听感仍需另行判断。
- `play-started` 补充启动后的引擎状态；`fade-complete-pause/stop` 区分 render 完成；`fade-deadline-pause/stop` 表示达到时长加 250 ms 的兜底期限。`hard-pause/stop` 保留直接硬控制证据。
- C render 每个块只发布原子数值，不分配、不写日志。增益和对应进度打包发布；快照各字段可能跨相邻块，仅用于诊断，不参与控制决策。原有声音包络和控制逻辑不变。

排查时先确认请求命令是否等于 render 命令；随后比较 rampFrame/rampFrames 和 gain。callbackFrames 增长而源帧与包络停滞可结合 starved 判断缺数据；callbackFrames 不增长说明源节点未获回调。完成日志不能单独证明设备听感。

开启文件日志后重启应用，可同时捕获插件初始化；然后以超过 3 秒的操作间隔测试播放、暂停和恢复。若验证 EQ，请选择非零增益预设；交叉淡化需明确开启并让歌曲自然进入下一首。

### 补充验证结果

- C ASan/UBSan：22 个数值场景通过，新增诊断验证将增益快照与实际 PCM 比较，覆盖 144000 帧（48 kHz / 3 秒）、中途 pause/resume、缺数据时包络冻结但 callbackFrames 增长、最终零增益和 halted。日志 `.noindex/logs/playback-envelope-numerical.log`。
- Simulator App DSP：10 项 XCTest 通过，含共享文件中的包络进度、实际音频幅度渐增/渐减、render 完成和无回调时 deadline 区分。日志 `.noindex/logs/playback-envelope-diagnostics-verified.log`。
- Simulator 过渡回归：19 个 Swift Testing 函数（47 个实际用例）通过，含保存设置驱动 pause/stop/next/select/reselect、长达 3 秒的压缩 EOF 交接、软暂停重缓冲和输出延迟。日志 `.noindex/logs/playback-envelope-diagnostics.log`；该首次命令整体失败于新增 XCTest 的采样断言，过渡套件通过，新增 XCTest 最终结果见上项。
- 新 XCTest 的初始 120 ms 采样窗口受到 AVAudioEngine 预取影响；最终使用 8 秒固定音调和 1 秒渐变、匹配源节点的 48 kHz stereo 输出。deadline 等待改为引擎已有 `waitForSoftStop()`，直接等待软控制任务结束。
- 架构检查和 `git diff --check` 通过；日志 `.noindex/logs/playback-envelope-diagnostics-architecture.log`。
- 未发布安装包、未执行 Archive、未验证用户真机听感。本轮补足诊断证据，未将用户异常标记为已修复。
