# MusicFree 1.4 B 线：淡入淡出与歌曲平滑切换

状态：B 线实现完成；数值、Core、Simulator 和宿主 Debug 验证通过，真机听音/路由与 Archive 未验证。实施范围、降级限制与确切证据以 [B 开发记录](PLAYBACK_TRANSITIONS_1.4_DEVELOPMENT_LOG.md) 为准。

规划基线：/Users/chenrenwei/developer/MusicPlayer，feature/1.4.0_dev，HEAD 27bc43f5bb00ef9aa6e7e5a040ed116645c5f8cb。

以下保留初始规划作为设计依据。2026-10-01 用户后续授权覆盖本文原有“待确认/不开发/不构建”限制；默认值和实施细节可按协调文档在既定范围内推进。当前 checkout 直接实施，不创建分支、提交、合并；MusicLyricsAPI 和 thirdpart/ 用户已有内容不处理。

2026-10-01 用户修订：过渡时长支持用户调整、关闭，最长 3 s。本方案按淡入、淡出、crossfade 三项分别设置 0-3 s 规划，0 表示关闭对应效果；gapless 是无重叠衔接，保留独立开关。本轮不改偏好源码。

## 1. 独立范围

B 线直接使用现有 PlaybackAPI、PlaybackCoordinator、FFmpegPlaybackEngine、AudioSession 和 PlayerFeature 快照，独立于 A 线 PluginRuntime、歌词协议、私有歌词包和插件 UI。B 不等待 A 线完成，也不把 A 线变成前置依赖。

本线交付三种行为：

1. 单曲 fade：单轨开始、恢复、用户暂停/停止和手动切歌的有限淡入淡出；紧急停止绕过 fade。
2. gapless：相邻曲目在同一 render timeline 上无重叠、无意外空隙地衔接。
3. crossfade：同一个 engine 音频图内两个 track slot 短时重叠、等功率交叉淡化。

AppContainer 当前注入的两个 FFmpegPlaybackEngine 分别属于正式播放和 online audition，不是 A/B deck。B 只允许在单个 engine 内增加有限的双 slot；两个 engine 继续隔离。

## 2. Live 证据

以下是当前源码核对结果，规划时不把“已有配置/能力位”误写成“已有实现”。

| 当前文件与行 | 证据 | 规划含义 |
| --- | --- | --- |
| Docs/Versions/1.4.0_FEATURE_REQUIREMENTS.md:7-16,28-40 | A/B 独立；B 负责 PlaybackAPI 过渡契约、Coordinator、解码投喂、轨道调度和 FFmpeg 音频图；过渡不依赖 PluginRuntime。 | B 直接基于当前播放体系实现；共享组装文件只交合流接口。 |
| Packages/MusicFreeCore/Sources/PlaybackAPI/PlaybackEngine.swift:3-28 | engine 只控制一个 current resource；队列、repeat/shuffle、持久化在 AppServices。 | 过渡必须是窄的可选 engine 扩展，不能把队列下沉。 |
| Packages/MusicFreeCore/Sources/PlaybackAPI/PlaybackModels.swift:4-5,36-45,88-141 | PlaybackGeneration 和 PlaybackEvent generation guard 已存在；ended/failed 是 terminal。 | 新增 transition token 和 queueVersion，不能只依赖 generation。 |
| Packages/MusicFreeCore/Sources/PlaybackAPI/AudioEffects.swift:86-135 | 现有 mode 是 disabled/gapless/crossfade；crossfade duration 要为正；effects 已带 rate。 | 单曲 fade 需独立配置，且要做 legacy Codable 迁移。 |
| Packages/MusicFreeCore/Sources/PlaybackAPI/PlaybackCapabilities.swift:3-27 | 已有 gapless/crossfade 位，但 FFmpeg 当前未点亮；all 仅是声明集合。 | capability 以真实 runtime/原型证据为准，不能凭设置展示启用。 |
| Packages/MusicFreeCore/Sources/AppServices/PlaybackCoordinator.swift:12-50,350-424 | Coordinator 持有 queue/history/engine/NowPlaying；命令用 playbackIntentVersion；volume/mute 与 effects 分开。 | Coordinator 继续拥有切歌、提交点和竞态；transition gain 不复用用户音量。 |
| Packages/MusicFreeCore/Sources/AppServices/PlaybackCoordinator.swift:1390-1578 | queue 保存 entry、logicalTrackID、variant、repeat/shuffle；clipped 会按 capability 降级。 | 预准备绑定 entry、顺序快照和 queueVersion；不支持时走 fallback。 |
| Packages/MusicFreeCore/Sources/AppServices/PlaybackCoordinator.swift:1636-1770 | NowPlaying 从 snapshot 发布；stopped/failed clear；已有 intent、队列和 engine preparation 串行化。 | logical handoff 先更新 snapshot，再发布 NowPlaying；沿用取消/串行化。 |
| Packages/MusicFreeFFmpegAdapter/Sources/FFmpegPlaybackAdapter/FFmpegPlaybackEngine.swift:61-100,181-305 | 当前一个 engine 只有一个 playerNode、decoder、feeder 和 decodeQueue；prepare 支持 CUE、远程 URL、generation/cancellation。 | 双轨只在同一 engine 内新增有限 slot；CUE 和远程取消必须保留。 |
| Packages/MusicFreeFFmpegAdapter/Sources/FFmpegPlaybackAdapter/FFmpegPlaybackEngine.swift:307-499,507-582 | 当前 apply 拒绝 gapless/crossfade；volume 直接写 playerNode；feederEpoch、interruptReads、stop 后重投喂已存在。 | 需要独立 master gain、过渡图和双 slot cancel，不把 transition 写入 playerNode.volume。 |
| Packages/MusicFreeFFmpegAdapter/Sources/FFmpegPlaybackAdapter/FFmpegDecodeFeeder.swift:6-22,148-285 | feeder 在独占 serial queue 解码，默认至少三块、有限 in-flight、lookahead 识别 EOF/CUE、starvation 回调 hop 到 MainActor。 | 复用有限 feeder；边界依赖 frame clock/frame limit，不依赖 UI timer。 |
| Packages/MusicFreeFFmpegAdapter/Sources/FFmpegPlaybackAdapter/URLSessionByteSource.swift:5-18,29-58,80-198 | seekable 4 MiB、顺序流 32 MiB；retry/refresh 有上限；cancel 永久终止，interruptReads 只打断当前读。 | secondary 远程预准备必须有硬上限；不可 seek 流默认降级。 |
| Packages/MusicFreeCore/Sources/AppServices/OnlineAuditionCoordinator.swift:7-50,82-156,421-605 | audition 有独立 engine、临时队列，不入正式 queue/history/NowPlaying；start 会 pause formal；session/operation/generation 过滤迟到事件。 | audition 与 formal 保持互斥；transition ticket 必须绑定各自 session。 |
| App/AppContainer.swift:489-490 | 当前确有两个独立 FFmpegPlaybackEngine 实例。 | 不能把它们当作同一过渡的两个 deck。 |
| Packages/MusicFreeCore/Sources/LibraryAPI/PlaybackHistoryRepository.swift:17-35,37-136 | history 区分 started、validPlayback、completed、skipped。 | prepare 不记 started；logical handoff 和完成/跳过各 exactly once。 |

## 3. 推荐默认值与待确认决策

推荐值是提案，不代表当前行为：

- 旧设置缺少 single-track fade 字段时将新增 fade 设为关闭；原 gapless 开关保留，旧 crossfadeDuration 在 0-3 s 内保留，超过 3 s 的值迁移为 3 s。旧值为 0 时不自动启用。
- 新安装推荐 single-track fade-in 80 ms、fade-out 120 ms；boundary 默认 gapless 开启，crossfade 关闭。
- 淡入、淡出、crossfade 各自支持用户设置 0-3 s；0 关闭，非零启用，3 s 为设置校验和实际调度硬上限。crossfade 默认关闭，首次明确开启且没有自选时长时建议预设 1 s；该默认值仍为提案，不能覆盖用户自选值。实际窗口按两曲有效 logical duration 进一步缩短。
- crossfade/gapless handoff 以下一轨首个有效输出 render frame 为提交点；crossfade 要求其 envelope gain>0，不检测或裁剪音源自身静音。此时切换 NowPlaying、歌词宿主 current item 和下一轨 started。
- next prepare 失败时当前曲继续，降级为单曲 fade 或硬切；不因预准备失败提前停止当前曲。
- 首个 crossfade/gapless 只对已验证 common render format、rate=1、可靠 frame clock 点亮；其它情况降级。
- online audition 默认只启用 isolated fade，不启用 boundary gapless/crossfade。
- 精确边界要求可靠的有效样本范围；PCM/无 padding 且样本边界可靠的格式可独立验证。压缩格式的 encoder delay/padding 只取可信解码信息，信息不足则不点亮该组合的精确 gapless，不按能量阈值猜补偿；crossfade 不因缺少 padding 元数据一律禁用。
- user volume 是 transition bus 后的独立 master gain；mute 只把 master 置零；transition envelope 不能改写用户音量。

用户已确认“可调整、可关闭、最长 3 s”。其余待确认项为：80/120 ms 和首次开启 crossfade 1 s 的默认提案、普通暂停/停止的软 fade、在线试听范围、格式/速度降级、有效样本边界和共享文件规则；本轮不写入设置。

设置使用明确的“关闭”选项和 0-3 s 时长控件（建议 0.01 s 精度以表达 80/120 ms 默认值）。偏好持久化、API 校验与实际包络统一上限，外部旧值不能绕过 3 s。修改时长使旧预准备计划失效；关闭时取消对应未提交过渡，已提交切换不得回滚当前曲或继续旧时长的重叠。修改不覆盖用户音量/静音，不隐式关闭 gapless。

## 4. 架构与接口草案

### 4.1 PlaybackAPI

新增独立的 PlaybackTransition.swift，保持 PlaybackEngine 基础协议 source-compatible。建议值类型：

- AudioFadeConfiguration：fadeInDuration、fadeOutDuration，各为 0-3 s，0 即关闭；启用状态由时长导出，避免 enabled 与 duration 冲突。
- PlaybackTransitionCapabilities：fade、gapless、crossfade、sampleAccurateEnvelope、formatConversion、variableRateTransition、remotePrefetch。
- PlaybackTransitionRequest：generation、queueVersion、currentEntryID、nextEntryID、PlaybackItem、startAt、rate、policy。
- PlaybackTransitionTicket：opaque ID、generation、queueVersion、entry ID、session scope；不携带 decoder、PCM、URL 或 header。
- PlaybackTransitionEvent：prepared、armed、committed、completed、cancelled、degraded、failed；包含 ticket、generation、queueVersion 和 render frame。

窄适配协议 PlaybackTransitionControlling 只提供 capabilities、prepareNext、arm、cancel、makeTransitionEventStream、hardStopTransitions。Coordinator 用可选类型转换探测；不支持的 FakePlaybackEngine 或未来适配器继续走单资源路径。

保留 AudioTransitionMode 的 boundary 语义，给 AudioTransitionConfiguration 增加独立 fade 配置和 fallback policy。旧 mode/crossfadeDuration 继续可解码；旧时长超过 3 s 时迁移为 3 s，新字段缺失用关闭默认值。共同最大时长为 Duration.seconds(3)，设置/API/引擎共享校验规则。

### 4.2 Coordinator 状态

新增 transient queueVersion、activeTransitionPlan 和 logical commit guard：

- queueVersion 在外部 queue edit、手动改变 current entry、repeat/shuffle、库删除、启动 canonicalize 后递增，不写入持久化快照；本过渡自身的 logical handoff 不使自己的 finishing/completed 事件失效。
- plan 捕获 playbackIntentVersion、queueVersion、activeGeneration、currentEntryID、nextEntryID、ordered queue digest、repeat/shuffle。
- ticket 只提交一次；session、intent、generation、queueVersion、ticket 任一不匹配就丢弃迟到事件。
- PlaybackCoordinator 继续决定 next；PlaybackEngine 不读持久 queue，不写 history/NowPlaying。

状态草案：idle -> preparing -> prepared -> armed -> overlap/boundary -> committedFinishing -> completed；任何阶段可因新命令转为 cancelling -> idle，准备/调度错误进入 degraded 或 failed。prepareNext 不递增当前会话 generation 以致 A 的事件失效；每轨独立 slotID/slotEpoch，并区分会话代次、队列修订和命令 intent。自身提交后的 A finishing 事件只用于释放/历史结算，不再次推进队列。repeat-one 的同 itemID 也必须用 entry/pass/slot 身份区别。

### 4.3 FFmpeg 音频图

推荐单 engine 内拓扑：

primary decoder -> 可选 PCM transform -> converter -> timePitch -> 可选每轨 DSP -> primary transition gain
secondary decoder -> 可选 PCM transform -> converter -> timePitch -> 可选每轨 DSP -> secondary transition gain
两个 slot -> transition bus -> 可选 DSP graph hook -> 现有 EQ -> master user-volume -> main output

本拓扑是实现目标；AVAudioEngine 的具体 node/format 自动转换能力仍标记为原型决策。不得让 EQ 或 DSP 重连正在播放的 node 后丢弃已排队 buffer。

transition gain 必须按 slot 独立；user volume 放在 transition bus 后。可选 DSP hook 区分每轨/混音后作用域，只暴露插入点、format、latency/reset/tail、生命周期和失败 fallback；默认空实现保持 B 独立，不引入 PluginRuntime 或完整插件协议。新增参考 DSP 不改变既有 EQ 的参数和用户偏好。

## 5. 三种行为与时钟

### 5.1 单曲 fade

单轨开始/恢复按用户 fadeInDuration 从 0 到 1。普通用户 pause/stop 按 fadeOutDuration 从当前 gain 异步淡出（建议初始值 120 ms，可关闭，最多 3 s），到完成点暂停 node/冻结位置或停止释放；命令意图立即更新且不阻塞 MainActor。0 时立即完成对应操作，fade 期间新 play/seek/next/stop 使旧回调失效，缓冲已断或超出期限时直接停止。resume 从实际暂停位置重新 arm，不复活旧包络。

中断、耳机拔出、权限撤回、scene/session dispose、明确立即停止和正式/试听接管使用 hardStop，不等待淡出。手动 next/previous 建议有限淡出后切换已准备目标，并受新 intent 取消；不要把普通用户 stop 与 hardStop 混成一个语义。该策略仍需用户确认及输出延迟原型验证。

单曲 fade 不改变 logical current，不提前写下一曲 history/NowPlaying。若只能做 block-level ramp，只报告 blockRamp capability，不宣称 sample accurate。

### 5.2 gapless

Coordinator 在当前轨稳定起播后预准备 orderedEntries 的 next；next 具备 decoder、CUE selection、common format、frame duration 和最小 buffer 后才 arm。A 最后有效 render frame 紧接 B 第一帧，无 overlap。

B 首个有效输出帧提交 currentEntryID、清除 resumePosition、更新 snapshot/NowPlaying/歌词宿主、recordPlaybackStarted(B)。A 的 dataPlayedBack/ended 可迟到，但只能完成 A 或被 token guard 丢弃，不能再次推进 B。

repeat off 无 next；repeat one 是新的 playback pass 且清除 EOF position；repeat all 按 persisted shuffleOrder 回绕。队列编辑影响 current/next 时取消 ticket 并重算。

### 5.3 crossfade

同一 engine 使用 primary/secondary slot。crossfadeDuration=0 时不安排重叠；非零窗口不超过用户时长、3 s 以及两曲有效长度。B 在 overlap startFrame 前准备完成；A/B 在 render frame 区间按等功率 envelope：

- gA = cos(theta * pi / 2)
- gB = sin(theta * pi / 2)
- theta 由 render frame 计算，禁止以 wall clock/250 ms position timer 驱动。

等功率曲线本身不保证防削波。首个原型比较无保护曲线与连续的保守 mix normalization（输入峰值有界时按 1/max(1,gA+gB) 提供混音余量）；后者会改变严格等功率听感，最终策略需输出数值和听音裁决，不先引入相关性估计或 limiter。峰值测量覆盖混音点以及 EQ/DSP 后实际输出；混音保护不保证后级效果或超幅源不会削波。保护曲线不能在窗口边界突然切换。

B 首个有效输出帧是逻辑 handoff；A 到 endFrame 后释放。短曲按有效 duration 缩短 envelope；每首 duration 小于窗口时限制到可播放范围，禁止三轨叠加。首个原型只验证 rate=1 和共同输出格式；不同采样率/声道布局转换及非 1 倍速通过后再点亮对应能力，未通过组合明确降级。是否作为 1.4 发布限制列入确认，而非提前宣称完全支持。

### 5.4 RenderFrame clock

新增 TransitionClock，主单位为 common render format 的 Int64 render frame，同时记录 source frame、logical frame、sample rate、rate、CUE frame limit、encoder delay/padding 和 timing accuracy。rate=1 可直接映射；rate 非 1 需要原型确认 timePitch 输出 frame 与 source EOF 的映射。

原型决策：优先验证 AVAudioEngine 可否提供稳定的共同 render format、双 slot sample/frame clock 和每 block 连续 envelope；未验证前只允许 isolated fade 或 legacy hard boundary。

## 6. 生命周期、异常与网络

### 6.1 pause/stop/interrupt

- pause 立即使旧 next prepare/arm intent 失效；按普通 fade 策略在有限期限内冻结 clock/暂停输出，hardPause 则立即暂停。远程 secondary 默认取消；两轨正在 overlap 时同时受控衰减，不保留第三轨。
- stop/next/previous/seek 立即使旧 plan 失效并取消预准备/refresh。soft stop/手动切歌可以用新的有限停止计划完成淡出；seek 与 hardStop 立即停止节点和 feeder/source。不能等待自然 EOF，也不能让旧完成回调恢复声音。
- interruption、旧设备拔出、media-services reset 都 hard stop transition；route recovery 生成新的 epoch/ticket，旧 slot 不得重接。
- resume 按 current logical position 重新 prepare，再重新计算 next；不自动复活旧 overlap。

### 6.2 预准备和资源失败

- next prepare 失败：A 继续；到边界按 fade/hard fallback。
- A decode/output 失败：所有 slot teardown，formal snapshot failed，NowPlaying clear；B 不能越过 Coordinator 直接救援。
- B 在 logical commit 前失败：取消 B，若 A 仍在播放则连续恢复其单轨 gain；commit 后 B 失败按当前曲失败语义处理，不自动退回已结算的 A，也不未经宿主授权跳过后续多首。
- history repository 写失败不阻塞 render；Coordinator 通过 session/item/commit guard 异步重入。

### 6.3 URL refresh/cancel

RemotePlaybackRequest 仍是 ephemeral，不进 queue。每个 secondary ticket 独立持有 refresh closure；ticket 失效即取消 refresh 和 URLSessionByteSource。401/403/过期 URL 继续使用既有 refresh 上限。

seekable 远程可按 offset 恢复；non-seekable 顺序流不复制第二个长缓存，默认退回单曲 fade。cancel 先唤醒阻塞 read，再让 decode task 收敛；MainActor 不同步等待网络。

### 6.4 formal/audition arbitration

正式播放仍通过 transientPlaybackPreflight 关闭 audition。OnlineAuditionCoordinator 仍不入正式 queue/history/NowPlaying；其 ticket 绑定 sessionID、operationID、generation，close 或 formal 接管即 hardStop。两个 FFmpeg engine 不共享 buffer、clock 或 transition ticket。

## 7. 逻辑提交、Now Playing、歌词和 history

- prepare/armed 不是 started。
- single fade 不产生新的 logical current。
- gapless/crossfade 在 B 首个有效输出帧建立 LogicalPlaybackCommit，串行提交内存 queue current 和统一 snapshot，再发布 NowPlaying。数据库写入是异步持久化，不宣称与音频 callback/系统 NowPlaying 跨组件原子；按 commit ID 保存并重试，失败不得回滚到已播放的 A。渲染事件携带帧时间戳，以检验 MainActor 交付延迟。
- crossfade 中 NowPlaying/歌词显示 B；A 的迟到 position/ended 不能写回 A。
- B commit 时 recordPlaybackStarted(B)；A 的 validPlayback 依据实际 render/logical duration，不因 gain 小于 1 被记成零。
- A 自然结束或 crossfade 完成时 recordCompleted(A)；用户 next/previous/stop 按既有 skip/completion 规则 exactly once。
- B 不实现歌词 API；PlayerFeature 只消费 PlaybackSessionSnapshot.currentItemID/position。A 线之后可消费该快照，但不能将插件对象放入 ticket。

## 8. 性能与线程约束

- Coordinator、engine 状态、ticket、snapshot 和提交点在 MainActor。
- 每个 decoder 只在自己的 serial decode queue 访问；render callback 不调用 FFmpeg、URLSession、async 或锁等待。
- TransitionGainProcessor render path 只读取原子/不可变 envelope snapshot；不分配、不日志、不触发 MainActor。
- 每个 engine 最多 active 一个 slot 加 secondary 一个 slot；不创建第三个 decoder/URL source。
- 复用 feeder 当前默认至少 3 个 buffer；transition 总 in-flight 建议上限 6，PCM 总时长每 slot 建议不超过 1 秒；超过需原型内存证据。
- 复用远程 4 MiB/32 MiB 上限；secondary non-seekable 默认不预取。
- 同时最多一个 next preparation Task 和一个 refresh Task；每个都有明确 cancel path。

## 9. 文件级修改清单

### B 线直接负责

1. Packages/MusicFreeCore/Sources/PlaybackAPI/AudioEffects.swift：fade 配置、fallback、Codable 迁移。
2. Packages/MusicFreeCore/Sources/PlaybackAPI/PlaybackCapabilities.swift：fade 和经验证的 timing/transition capability。
3. Packages/MusicFreeCore/Sources/PlaybackAPI/PlaybackEngine.swift：可选 PlaybackTransitionControlling 声明。
4. 新增 Packages/MusicFreeCore/Sources/PlaybackAPI/PlaybackTransition.swift：request/ticket/event/clock 值类型。
5. Packages/MusicFreeCore/Sources/AppServices/PlaybackCoordinator.swift：queueVersion、预准备、提交、取消、旧事件 guard、history/NowPlaying 绑定。
6. Packages/MusicFreeCore/Sources/AppServices/OnlineAuditionCoordinator.swift：audition ticket 生命周期和 isolated fade 默认接入。
7. Packages/MusicFreeFFmpegAdapter/Sources/FFmpegPlaybackAdapter/FFmpegPlaybackEngine.swift：双 slot graph、master volume、capability/fallback/hard stop。
8. Packages/MusicFreeFFmpegAdapter/Sources/FFmpegPlaybackAdapter/FFmpegDecodeFeeder.swift：有限 slot、render frame accounting、CUE boundary 和 cancellation。
9. 新增 Packages/MusicFreeFFmpegAdapter/Sources/FFmpegPlaybackAdapter/FFmpegAudioTransitionGraph.swift：slot gain、transition bus、可选 DSP hook。
10. Packages/FFmpegAudioKit/Sources/FFmpegAudioKit/FFmpegAudioDecoder.swift：仅在 C 桥可验证时补 DecoderTimingMetadata。
11. Packages/MusicFreeUI/Sources/SettingsFeature/SettingsViewModel.swift 及当前承载过渡设置的同目录视图：设置值、能力、范围和 fallback 状态。
12. Packages/MusicFreeCore/Sources/SettingsAPI/PlaybackPreferences.swift：新增独立淡入/淡出偏好，保留 gapless/crossfade 旧键，最大时长从历史 30 s 改为用户要求的 3 s，旧超限值迁移。
13. Packages/MusicFreeCore/Sources/AppServices/SettingsCoordinator.swift：偏好到 effects/能力的映射，不把降级结果反写为用户意图；与 A 的 PluginServing 注入划分具体改动。

### 共享合流负责人负责

- App/AppContainer.swift：保持 formal/audition 两个 engine 独立注入。
- Packages/MusicFreeCore/Sources/AppServices/AppServiceContainer.swift：核对 effective effects、preflight 和 service 注入顺序。
- Package.swift、project.yml、生成工程和公共索引：需要时一次性纳入新文件；B 不并发改。
- Packages/MusicFreeCore/Sources/SettingsAPI/AppSettings.swift、Packages/MusicFreeInfrastructure/Sources/PreferencesPersistenceAdapter/SettingsMigration.swift：合并 A 的 plugin schema 与 B 的 fade schema，逐步验证旧 payload，不由两线同时增加不兼容版本号。

## 10. 迁移与阶段验收

### 迁移

旧设置缺少新字段时淡入/淡出为 0；旧 gaplessPlaybackEnabled 保留，crossfadeDuration 的 0-3 s 值保留，大于 3 s 的历史合法值钳制为 3 s。负值/损坏字段按既有策略回退关闭并记录迁移诊断；当前用户输入或 API 非法超限值明确拒绝，不能把 capability 降级反写为用户关闭。新增字段通过 SettingsMigration/自定义 decode 兼容旧 payload；transition ticket 不落盘，重启/dispose/close 后失效。版本号本次不改。

### 阶段 0：契约/图原型

交付 API、migration matrix、token/queueVersion 和 graph hook。验收只看接口 review、Fake engine fallback 和无插件依赖；必要的 AVAudioEngine 双 slot/format/frame clock 细节标为原型决策。

### 阶段 1：单曲 fade

离线 PCM 验证 0/80 ms/120 ms/3 s 包络、精确帧数、用户音量独立、mute/pause/resume；Simulator 验证时长修改/关闭及命令竞态、interrupt、route；真机听音单独验证 click/残留声；Archive 只证明产物可归档。

### 阶段 2：gapless/预准备

离线 PCM 验证 A/B 边界无丢帧/重叠，CUE/repeat/shuffle；Simulator 验证 cancel、URL refresh、non-seekable fallback、NowPlaying 和 formal/audition；真机验证多格式/耳机/蓝牙；Archive 不替代无缝听感。

### 阶段 3：crossfade

离线 PCM 验证 equal-power/混音余量、0/1/3 s 窗口、短曲裁剪、handoff frame、exactly-once；Simulator 验证调时长/关闭、双 slot 失败、迟到 event、stop/pause/interruption/network；真机验证格式、网络、route、后台和长时间播放；Archive 仅记录 configuration/artifact。

### 阶段 4：设置与合流

验证三项独立时长控件、关闭与 3 s 边界、重启持久化、旧 0/1/3/6/30 s 偏好迁移、超限输入拒绝、新安装默认、能力隐藏、无 engine fallback、正式播放与 audition 互斥。所有实际输出窗口不得超过 3 s。最终报告区分源码检查、自动化、Simulator、physical listening、Archive；不把仅编译或零匹配测试称为通过。

## 11. 用户确认清单

1. 用户已明确支持调整/关闭、最长 3 s；是否采用三项独立时长、新安装淡入 80 ms/淡出 120 ms 和首次主动开启 crossfade 1 s 的推荐默认值，普通暂停/停止使用有限软 fade。
2. 是否以 B 首个有效输出帧作为 NowPlaying、歌词宿主和 history started 的 handoff，不用能量检测剔除自然静音。
3. next prepare 失败是否接受当前曲继续并降级。
4. 首版是否限制 rate=1、已验证 common format/frame clock，其他情况降级。
5. online audition 是否坚持 isolated fade only。
6. 有效样本边界不可靠时是否禁用对应精确 gapless 而不猜补偿；是否先原型裁决防削波曲线和不同格式/速度支持范围。
7. 是否接受可选 PlaybackTransitionControlling、独立 PlaybackTransition.swift 和 shared-file 合流规则。

结论：当前仅完成可审核规划，状态为“待用户确认，未开发”。
