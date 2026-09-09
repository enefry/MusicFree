# 在线源：增强试听与正式播放器接入对比

状态：基于 2026-09-08 当前工作区代码的对比评估。A（独立增强试听）主链路已经落地代码，试听相关行为测试已有通过记录，最新 iOS generic `build-for-testing` 已通过；真实在线源和真机长播仍未验收。B/C 仍是后续正式播放器接入方案。工时为方案估算，不是已完成工作量或交付承诺。

已确认的试听方案见 [在线源试听体验优化规划](Online_Source_Audition_Enhancement_Plan.md)。本文只比较替代路径，不撤销已确认的独立悬浮条选择。

## 结论

接入正式播放器可行，主要成本在播放对象、持久化和来源生命周期，不在解码器。现有 VLC、进度控制、播放模式、主播放界面、Now Playing 和远程控制能够复用，但“把远程 URL 传给主播放器”不足以完成接入。

如果用途是挑选歌曲、下载前确认，独立试听最符合原需求。如果用途已经是长时间在线听歌，建议优先评估正式播放器接入：短期改动更大，长期避免维护第二套队列、控制面板、状态机和双播放器协调。

完整播放应拆成两层：

1. **完整播放控制**：主播放器播放在线歌曲、上下首、进度、循环随机、锁屏及后台；可以暂不支持在线收藏、历史和重启恢复。
2. **完整产品整合**：在上一层基础上，实现可恢复队列、在线播放历史、收藏／歌单、歌词和来源失效处理。这一层涉及数据模型，不能因复用播放器 UI 就视为免费获得。

## 当前代码证据

以下相对路径均从本文件所在目录指向仓库代码，结论针对当前未提交工作区。

| 链路 | 当前实现及含义 |
| --- | --- |
| 远程资源与解码 | [PlaybackResource](../../Packages/MusicFreeCore/Sources/MediaSourceAPI/PlaybackResource.swift) 已定义 remote(RemotePlaybackRequest)，请求不可 Codable 且描述脱敏；[VLCMediaFactory](../../Packages/MusicFreeVLCKitAdapter/Sources/VLCKitPlaybackAdapter/VLCMediaFactory.swift) 已有远程请求处理。无需新增解码内核。 |
| 正式播放入口 | [PlaybackCoordinator](../../Packages/MusicFreeCore/Sources/AppServices/PlaybackCoordinator.swift) 的 prepareAndPlay 必须 loadTrack 成功，再通过 track.assetID 和 sourceResolver 解析资源；仅提供目录条目的 ID 会在无 Track 时失败。 |
| 来源装配 | [AppServiceContainer](../../Packages/MusicFreeCore/Sources/AppServices/AppServiceContainer.swift) 分别装配 MediaSourceRegistry、OnlineSourceCoordinator 和独立试听引擎。在线来源不能自动成为正式播放器可解析的来源。 |
| 来源用途 | [OnlineSourceAPI](../../Packages/MusicFreeCore/Sources/MediaSourceAPI/OnlineSourceAPI.swift) 的 PlaybackPurpose 当前仅有 audition。正式接入应增加明确用途，并继续经过 OnlineSourceCoordinator 的应用及来源授权检查。 |
| 队列持久化 | [PlaybackQueue](../../Packages/MusicFreeCore/Sources/PlaybackAPI/PlaybackQueue.swift) 保存稳定逻辑 ID、变体 ID 和播放意图，不保存曲名或 URL；在线项需要可重建的元数据来源。 |
| 队列 UI | [PlayerQueueViewController](../../Packages/MusicFreeUI/Sources/PlayerFeature/UIKit/PlayerQueueViewController.swift) 从 LibraryServing.track 读取歌曲，故资源解析成功不代表队列能正确显示歌曲信息。 |
| 历史与统计 | [LibraryPersistenceStore](../../Packages/MusicFreeInfrastructure/Sources/LibraryPersistenceAdapter/LibraryPersistenceStore.swift) 的播放事件写入要求 track 已存在，否则报 danglingReference；PlaybackCoordinator 对部分历史写入采用 try?，不能用“未报错”证明历史有效。 |
| 歌词 | [LyricsCoordinator](../../Packages/MusicFreeCore/Sources/AppServices/LyricsCoordinator.swift) 查询依赖 library.track，不能直接沿用到只存在内存目录中的歌曲。 |
| 后台与系统控制 | PlaybackCoordinator 已有 AudioSession、NowPlaying、RemoteCommand 集成；[Info.plist](../../App/Info.plist) 已声明 audio 后台模式。试听会话在失焦和后台阶段保留，不主动停止；这不等于已经验证在线长播、后台出声及地址续期。 |
| 现有试听 | [OnlineAuditionCoordinator](../../Packages/MusicFreeCore/Sources/AppServices/OnlineAuditionCoordinator.swift) 使用独立引擎；[SceneDelegate](../../App/SceneDelegate.swift) 在失焦及后台阶段不再主动停止试听，会话和队列由试听服务保留。启动正式播放时仍需协调它与正式远程播放。 |

## 成本与效果

估算前提：一名熟悉工程的开发者，先覆盖现有具备 onlinePlayback 能力的来源（以 DS Audio 为首个真实验收源），复用现有设计系统，包含针对性测试、模拟器和真机回归。排除新增 Provider、服务端修改及大规模媒体库界面重做。人日按有效开发投入计算，等待设备／服务不计入；当前工作区并行改动可能扩大区间。

| 维度 | A：已确认的增强试听 | B：正式播放器＋临时在线会话 | C：正式播放器＋持久化在线歌曲 |
| --- | --- | --- | --- |
| 首轮投入估算 | 4–7 人日 | 7–12 人日 | 15–25 人日 |
| 界面 | 新增悬浮条、展开面板和临时列表 | 复用主播放条、详情和队列，补在线标识及能力判断 | 与本地统一，增加在线项的可用性和管理语义 |
| 连播 | 点击时已加载歌曲，顺序播放 | 复用队列、循环和随机能力 | 同 B，并支持稳定恢复及本地／在线混排 |
| 后台／锁屏 | 试听会话和队列在离开/后台阶段保留，不主动停止；后台出声、锁屏控制和地址续期仍需验证 | 纳入交付，但需验证认证、地址有效期与中断恢复 | 同 B，增加跨启动的恢复能力 |
| 正式本地队列 | 保留原队列，试听结束不自动恢复声音 | 建议保存原本地队列和位置；结束在线会话后恢复为暂停 | 可使用同一持久化队列，开始播放时需明确替换／追加动作 |
| 重启恢复 | 无 | 不恢复临时在线会话，保留原本地队列 | 可恢复稳定 ID、元数据及位置，播放时重新获取访问地址 |
| 历史／收藏／歌词 | 不包含 | 首版按能力禁用，不冒充已支持 | 需要完善存储、查询及在线元数据关联后支持 |
| 回归范围 | 试听链路、根布局、双引擎互斥 | 主播放会话、队列保存、恢复、系统控制 | 再扩大到媒体库、历史、歌单、数据迁移和来源管理 |
| 长期维护 | 两套控制及队列逻辑，功能越多重复越多 | 一套播放核心，但需维护临时／持久会话策略 | 前期最重，长期统一程度最高 |

这些是三个从当前状态出发的总投入区间，不能简单相加。B 不是 C 的完整交付，B 到 C 的增量需要在存储方案验证后重新估算。A 中可复用的主要是体验设计、测试场景和部分状态约定；若后续转 C，悬浮宿主及独立队列实现可能被替换。

## 正式接入的建议实现路径

### 第一步：验证播放对象解耦（预计 1–2 人日，包含于 B/C）

- 引入统一的播放对象解析边界：稳定身份、展示元数据、播放选择及本次临时资源；本地路径仍由媒体库 Track 提供，在线路径使用目录元数据和来源访问服务。
- 使用现有正式引擎播放一个真实在线项目，验证暂停、seek、下一首及锁屏显示；在线 URI、Header 和令牌不进入队列或日志。
- 此验证只回答主链路是否跑通，不为“完整历史、收藏、歌词”背书。

### 第二步：实现 B 的正式在线会话

- 给 PlaybackServing 增加可接受在线列表上下文的入口，保留既有本地 ID 入口；在线会话使用同一 PlaybackCoordinator、引擎和控制界面。
- 会话策略明确区分临时和持久：临时在线队列不写入原队列仓库，不触发要求本地 Track 的历史写入；关闭在线会话恢复原本地队列及位置，保持暂停。
- 队列和正在播放界面通过统一展示解析器读取元数据，不再对所有条目强制 library.track。在线不支持的收藏、歌词等操作按能力隐藏或禁用。
- 来源访问增加 formalPlayback 用途，逐曲重新取地址；过期时允许一次重新解析和恢复位置，失败呈现明确错误，禁止无限重试。
- 正式在线会话继续使用现有后台及远程控制；来源撤权、删除、禁用必须同步终止当前在线资源和后续解析。
- B 默认仍冻结点击时已加载列表，不自动追加分页，不引入新的在线来源能力。

### 第三步：实现 C 的持久化整合

- 为在线歌曲建立持久元数据记录，仅保存来源实例 ID、对象 ID、曲名、歌手、时长等安全展示字段；不伪造本地文件路径，不把全部浏览结果自动导入本地媒体库。
- 先验证现有 Track／Asset 模型是否可正确表达在线项，再决定扩展媒体库模型或独立目录元数据存储；该设计决策是 C 开工前的必要评审项，当前静态检查尚不足以定案。
- 同步完善队列恢复、历史展示和统计、收藏／歌单引用、歌词查询和封面获取；不能只解除播放入口的 Track 检查。
- 在线来源不可用时保留歌曲身份并标记不可用，支持重新授权后解析；下载导入后的本地／在线身份关联需要显式规则，不能按标题自动合并。
- 迁移保持现有本地队列可读；不得持久化临时地址。重启后恢复展示和位置，不自动出声，用户开始播放时重新校验来源权限并获取资源。

## 风险与验收

- **首播及音质**：复用主播放器不会自然加快来源取址，也不会改变远程转码质量；收益主要是控制、后台和统一队列。用同一音源对照首帧出声时间、缓冲和 seek 耗时。
- **可定位性**：引擎支持 seek 不代表每个在线响应支持；长连接、转码流和未知时长需单独验证，不支持时明确降级。
- **后台认证**：后台不能依靠弹出登录 UI 完成续期；续期失败应停止并要求回到前台处理。
- **来源撤权**：检查正在播放、准备中、旧请求返回和后台切歌四种状态；安全终止不能仅覆盖旧试听服务。
- **队列兼容**：本地播放、混合队列（C）、临时会话恢复（B）、重复歌曲、随机循环、上次位置、来源失效均需回归。
- **产品完整性**：C 必须读回验证历史／统计和收藏歌单；未入库在线项不能被 try? 吞错后仍宣称记录成功。
- **真实设备**：至少验证 DS Audio 连续多曲播放、锁屏切歌、耳机控制、系统中断、网络切换和过期地址重取；源服务不可达时应记为未验证，不记为通过。
- 构建复用 .noindex/DerivedData；A 的实现状态和验收矩阵见 [在线源试听体验优化规划](Online_Source_Audition_Enhancement_Plan.md)。当前仍需补齐真实在线源、真机后台音频、连续播放、定位和系统控制证据。B/C 的正式播放器验证路径仍按本文后续步骤执行。

## 建议

当前已落地的 A 已包含全局入口、展开面板和连播，投入明显超过最小试听。若下一步要求锁屏、后台和循环随机，建议先完成第一步的正式播放器验证，再决定走 B 或 C，避免在目标尚未确定时维护第二套完整播放器控制。

若明确坚持独立悬浮入口、仅前台试听且不影响正式队列，继续 A 更直接。若目标是长期在线听歌，B 可先交付核心播放体验，C 才是媒体库层面的完整整合。本文评估不代表用户已经选择切换路线。
