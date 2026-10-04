

2026-10-03 更新：用户已授权先提交现有工作，再迁移既有能力。歌词/歌曲信息、DS Audio/Google Drive 和 EQ 已进入生产 Runtime 路径，旧实现保留；后文规划基线中的兼容路径/roadmap 描述以 [当前迁移记录](../Testing/1.4_BUILTIN_PLUGIN_MIGRATION_2026-10-03.md) 为准。
# MusicFree 1.4 内置插件系统详细计划（支线 A）

状态：实施中；2026-10-01 用户已授权两个独立 session 并行开发。

- 日期：2026-10-01
- 仓库：/Users/chenrenwei/developer/MusicPlayer
- 分支：feature/1.4.0_dev
- 基线：27bc43f5bb00ef9aa6e7e5a040ed116645c5f8cb

本文是支线 A 的实施方案。按 1.4_PARALLEL_DEVELOPMENT_SESSIONS.md 的主责和锁协议在现有 checkout 实施；不创建/切换分支，不暂存、提交或合并，不修改 thirdpart/。支线 B 的平滑播放不属于本方案前置条件；两条支线仅通过窄音频图接口合流。开发与验证证据持续写入 PLUGIN_SYSTEM_1.4_DEVELOPMENT_LOG.md。

2026-10-01 用户修订：既有歌词和在线源后续拆离为插件，列入 roadmap；thirdpart/MusicLyricsAPI 暂不处理；播放器 UI 插件本版不提供实现或接口，列入 roadmap。本版提供四类数据/音频能力的通用基础及参考接入，不冻结未来 UI 插件设计。

## 1. 范围与边界

1. 1.4 提供歌词、歌曲信息、在线源、DSP 四类通用契约、Runtime、宿主桥与参考实现。播放器 UI 插件整体列入 roadmap，本版不提供主题/组件/完整播放器/MiniPlayer 的插件接口或实现。
2. 本版保持原有歌词、元数据、在线源正常工作，先允许新能力可选注册与适配。后续 roadmap 将既有歌词 Provider 和在线源实现拆离为插件；播放引擎、UIKit 播放器及宿主 Coordinator 继续拥有基础播放、队列、状态与事务，不把本版兼容路径规定成永久架构。
3. 插件随 App 编译，使用编译期可选 registration 和强类型 capability/factory；不做远程可执行插件、动态模块下载或插件商店。
4. 插件与宿主同进程、同信任边界，不是安全沙箱；安全依靠私有仓库控制、构建签名、代码审查和最小权限。
5. 现有 thirdpart/ 有未跟踪内容，继续保留且不修改。MusicLyricsAPI 暂缓，不查找、恢复、创建或接入该包，不迁移其偏好，不开发或验收网易/QQ/酷我私有协议及专用构建入口。
6. 通用契约继续与业务 Core/App 解耦，默认公开构建没有私有依赖；参考实现使用公开、离线或受控 fixture，不依赖 MusicLyricsAPI。
7. Runtime 不拥有播放队列、切歌调度或 Now Playing 状态；当前播放器 UI 保持宿主实现。

## 2. 当前实时证据

- App/AppContainer.swift:429-675 已在组合根创建 FFmpegPlaybackEngine、metadata providers、lyrics providers、DefaultOnlineSourceFactory，并把数组/工厂/引擎传入 AppDependencies。
- Packages/MusicFreeCore/Sources/AppServices/AppDependencies.swift:11-42 已有 mediaSources、onlineSources、onlineSourceFactory、metadataEnrichmentProviders、lyricsProviders、playbackEngine 和 onlineAuditionEngine 的协议化注入点。
- Packages/MusicFreeCore/Sources/AppServices/AppServiceContainer.swift:80-205 已集中构建 MediaSourceRegistry、OnlineSourceCoordinator、PlaybackCoordinator、MetadataEnrichmentCoordinator 和 LyricsCoordinator。
- AppServiceContainer.swift:225-301 在启动时读取 settings、应用在线源和 provider 偏好，再应用 playback settings；插件 lifecycle 应嵌入此顺序而非旁路。
- MusicDomain/LyricsProvider.swift:4-69 已有 LyricsProviderID、LyricsQuery、LyricsProviding；LyricsCoordinator.swift:9-108 先返回本地歌词，再按顺序查询并保存。
- LyricsCoordinator.swift:424-444 已将 provider enabled、已注册实例和 privacy policy 作为运行时条件；取消 preload/query 必须复用该语义。
- LibraryAPI/MetadataEnrichment.swift:7-20、846-858 已有字段枚举、候选查询、授权和 artwork contract；MetadataEnrichmentRecord 按 provider 记录状态和更新字段。
- FeatureServices.swift:323-337 的 LibraryServing.supplementMetadata 是增量写入口，插件不能直接写 SwiftData。
- MediaSourceAPI/OnlineSourceAPI.swift:4-19、76-138、440-525、536-593 已有 provider kind、source instance、Keychain 引用、privacy gate 和 OnlineSourceFactory。
- OnlineSourceCoordinator.swift:13-67、178-311 已负责 adapter 重建、授权检查、错误映射和 snapshot；插件只提供 typed factory。
- OnlineCredentialStore.swift:4-103 表明配置只应保存 credential record ID；DSAudioHTTPTransport.swift:5-64、796-894 表明 account/password/device/session 是敏感或实例级身份。
- PlaybackEngine.swift:1-45 是 @MainActor 单资源控制协议；PlaybackModels.swift:4-141 以 PlaybackGeneration 过滤晚到事件。
- FFmpegPlaybackEngine.swift:16-82、264-271 当前图为 playerNode -> timePitch -> EQ -> mixer；FFmpegAudioDecoder.swift:8-117 输出 planar Float32，FFmpegDecodeFeeder.swift:20-138 在专用 queue 投喂 buffer。
- FFmpegPlaybackEngine.swift:557-599、824-884 已有 seek/路由变化后的 feeder 取消、节点重连和 format rebuild 点。

## 3. 推荐架构

### 3.1 契约、运行时与宿主桥分层

1. MusicFreePluginAPI 基础 target：只依赖 Foundation，包含身份、版本、描述、配置、操作上下文及歌词/歌曲信息/在线源独立 DTO 和契约；不导入业务 Core、UIKit、AVFAudio、App 或私有实现。
2. 同一 SDK 的独立 MusicFreePluginDSPAPI、MusicFreePluginAppleAudioAPI target：分别描述 PCM/分析、Apple 音频节点。音频插件选择所需产品，基础数据插件不被迫依赖音频框架；本版不创建 UIKit 插件契约 target。
3. MusicFreePluginRuntime：只依赖 Foundation-only 的基础 API 与 DSPAPI 的 actor registry、typed factory、偏好/权限、generation、取消及实例租约；不导入 Core，不拥有播放队列。不同能力仍使用各自线程契约。
4. MusicFreePluginHostBridge：依赖 Runtime、对应音频契约和现有 Core 端口，持有 Provider adapters、配置/凭据/权限桥和音频挂载适配。Core 只接收现有端口或窄服务端口，不反向依赖该 bridge 或具体 Runtime，防止循环依赖。
5. MusicFreePluginAudio 宿主产品：离线 renderer 和音频图挂载；可以使用平台框架和宿主端口，不作为数据插件依赖。DSP 先接当前单轨，不等待平滑播放。

依赖方向：App 组装 -> HostBridge -> Runtime -> 基础 API + DSPAPI（均仅依赖 Foundation）; 基础 API <- 数据插件；DSP 插件 -> 专用音频 API -> 基础 API。插件返回独立 DTO，由 HostBridge 转换为 LyricsQuery/TrackLyrics、metadata supplement 或在线源端口，不能把 Core 类型放入公共插件签名。

### 3.2 公共 typed 草案

~~~swift
struct PluginID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: String
}
enum PluginKind: String, Codable, Sendable {
    case lyrics, metadata, onlineSource, dsp
}
struct PluginCapability: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt64
}
struct PluginOperationContext: Sendable {
    let pluginID: PluginID
    let instanceID: String?
    let operationID: UUID
    let generation: UInt64
    let privacySnapshot: PluginPrivacySnapshot
}
~~~

四类分别使用 LyricsPluginFactory、MetadataPluginFactory、OnlineSourcePluginFactory、DSPPluginFactory。一个插件可以提供多个能力，registry 不接受返回 Any 的万能 factory。descriptor 包含稳定 PluginID、插件版本、API major/minor、配置 schemaVersion、权限及能力项；不兼容插件保留配置并解释不可用原因。重复 ID、能力与 factory 不一致只隔离该 registration，不阻塞 App；不预留 playerUI capability、factory 或空接口。

### 3.3 编译期 registration

本版只注册公开 provider/reference plugin；宿主注入 [any BuiltInPluginRegistrationProvider]，注册描述与工厂而不启动联网。公开 project.yml 和默认 package graph 不声明私有包依赖。compiledOut/incompatible 仍作为通用可用性语义，用 fixture 验证；不新增 MusicLyricsAPI registration、overlay 或私有构建测试。

## 4. 本版四类能力方案

### 4.1 歌词

HostBridge 的 PluginLyricsProviderAdapter 实现现有 LyricsProviding，把 LyricsQuery 转为独立插件 query DTO，把插件原文/译文/逐字 DTO 转为 TrackLyrics。LyricsCoordinator 继续负责本地歌词优先、顺序、privacy、preload、取消和 supplementMetadata。插件不读本地路径、不直接写库、不访问歌词 UI。

本版以离线歌词参考插件验证 query/candidate/原文/译文/逐字 DTO 与宿主接入；匹配验证覆盖歌手、时长和版本证据，歧义不能采用第一条结果。no match 继续下一个已授权 provider，网络/格式错误与未命中区分，撤销 privacy 或取消时不写结果。本版不拆离既有 metadata server/LRCLIB；后续 roadmap 将其 Provider 实现改为插件注册，保留身份、顺序、缓存和隐私同意。

### 4.2 歌曲信息

HostBridge 的 PluginMetadataProviderAdapter 实现 MetadataEnrichmentProviding，把独立候选 DTO 和封面引用转换为宿主候选与 artwork 数据；封面可独立 Provider，现有 MusicKit、MusicBrainz、metadata server、Discogs 保留。

候选必须是字段级 patch，不允许整条 Track 覆盖。字段至少区分 unchanged/set，clear 默认不允许。宿主合并规则：用户编辑优先、已有非空字段默认保留、只提交声明字段、封面复用 ArtworkWriteReceipt 和 library transaction。query fingerprint、candidate count、status、updatedFields 和错误码复用 MetadataEnrichmentRecord；不保存原始 response、token、路径。

### 4.3 在线源

当前 OnlineProviderKind 是闭合 enum。推荐迁移为保持旧 raw value 的 RawRepresentable 强类型 ID，并保留 dsAudio、googleDrive、baiduPan、gateway 静态值；未知 raw value 只有匹配 registration 才能运行，不静默当 gateway。若用户否决该迁移，备选是 OnlineSourceConfiguration 的 pluginID/providerID sidecar，但一致性和迁移成本更高。

CompositeOnlineSourceFactory 将已知原有 Provider 委托给 DefaultOnlineSourceFactory，已注册新 ID 委托给插件 factory，未知 ID 返回可解释的不可用状态；OnlineSourceCoordinator 继续负责 App privacy、global/source enabled、source privacy、snapshot 和认证错误。添加/编辑表单由 registry descriptor 驱动，替换 UIKit 中的封闭 switch；现有专用 Google Drive 配置及授权回调仍保留并向新配置文档渐进适配。

PluginID、ProviderID、SourceInstanceID、SourceObjectID 分开；每个 source instance 独立拥有既有 MediaSourceID、endpoint/root、credentialRecordID、policy version 和 typed fields。一般字段由宿主表单生成，OAuth/验证码/文件选择通过专门授权动作和受控呈现端口。密码、cookie、token、SID、OTP 和签名材料只在 Keychain/内存及必要协议请求中使用，不持久化到 UserDefaults 或播放历史，不写日志；签名播放 URL/headers 是短期访问值。

browse/search/download/playbackAccess/refresh 分为可选能力，支持仅播放、仅下载和同 Provider 多账户；不能让播放协议继承“必须下载”。迁移保留既有 SourceID、source object ID、已导入关联、账户同意与下载恢复记录。未知 Provider 保留配置并展示不可用，不删账户；撤销单实例取消它的任务、访问刷新和试听，不能影响其他账户。

本版用受控在线源参考插件验证通用注册和配置，既有 DS Audio/Google Drive 等继续走原 factory；开放注册 ID 不等于已经拆离旧实现。后续 roadmap 再把既有 adapter、配置/授权描述和 factory registration 移入独立插件，宿主保留浏览/下载/导入/试听 Coordinator。

### 4.4 DSP

第一阶段只接当前单轨 FFmpeg 图并提供离线 renderer，不等待 B 的 transition：

~~~swift
@MainActor protocol AudioGraphDSPAdapter: AnyObject {
    func attach(_ instance: any DSPPluginInstance,
                to format: PCMFormat,
                graphGeneration: UInt64) throws
    func detach(graphGeneration: UInt64)
    func rebuild(for format: PCMFormat, graphGeneration: UInt64) throws
}
~~~

DSP 区分三个位置：解码队列上的同步 PCM transform、图上的实时音频效果、只读 PCM/图分析。每个实例声明格式、每轨/混音后作用域、latencyFrames、reset/tail/bypass 行为；正式播放与试听独立实例，保留当前 EQ 顺序。分析必须有实际样本生产者、有界队列及降频 UI 订阅，不能只定义协议。

宿主把现有 planar Float32 AVAudioPCMBuffer 适配为只在同步调用期间有效的 PCMBufferView，插件不得保存指针、跨队列或 await 持有它。配置和预分配在 attach/reconfigure 完成；实时 callback 不 await、不分配、不阻塞、不访问偏好/网络/日志。协作式错误或超预算在返回后检测并旁路后续处理；无法抢占已卡住的同步插件，也不能捕获任意原生崩溃或保证本帧没有 underrun。seek、route change、media reset、stop 由图适配器串行处理，A 不重写 B 的 transition 拓扑。

离线原型先验证格式、EOF、reset、reconfigure、取消、NaN/Inf 和错误旁路。实时 budget（推荐单 plugin 不超过 callback period 25%，全链 50%）属于原型决策，需后续真机测量确认。


## 5. UserDefaults、权限和生命周期

### 5.1 三个独立开关

~~~swift
struct PluginPreference: Codable, Hashable, Sendable {
    let pluginID: PluginID
    let isVisible: Bool
    let isEnabled: Bool
    let isLoadAllowed: Bool
    let configuration: PluginConfigurationValues
}
~~~

UserDefaults 只通过现有 SettingsRepository 保存非敏感偏好、排序、配置引用和 schema。推荐新公共参考插件 visible=true、enabled=false、loadAllowed=false；现有服务保持当前行为，DSP 默认 bypass。MusicLyricsAPI 的偏好不属于本版迁移。

isVisible 只控制设置或入口展示，不授予联网许可，也不隐式停止已启用能力。effective load 条件为 compiled && registered && enabled && loadAllowed && 所需权限已授予 && capabilityContext；不含 visible。离线 DSP 不要求不存在的联网 consent，联网能力额外检查 App/provider/source privacy；plugin policy 与 source instance policy 分开。

注册仅保存 descriptor/factory，不创建 Provider 或网络会话。每个实例最多一个 in-flight load，使用 lease/reference count 和 generation 防止 actor await 期间重复加载。搜索前、请求歌词前及结果交付前重检许可；停用取消任务、拒绝迟到结果、释放实例。已经发送的请求不能宣称已从服务端撤回。

### 5.2 Runtime 状态机

~~~text
registered -> disabled/loadBlocked/permissionRequired
permissionGranted + enabled + loadAllowed -> loading(generation) -> ready(instanceID,generation)
ready -> running(独立 operation leases) -> ready
loading/running -> invalidated(移除 generation、取消 leases、异步 shutdown) -> registered 或 disabled/loadBlocked/permissionRequired
loading -> failed -> loading（下次显式请求）
shutdown -> unloaded
~~~

compiledOut/incompatible 是注册可用性，不经普通加载转为 ready；isVisible 是独立呈现偏好，不在生命周期状态机内。每次操作产生 operation ID 并捕获实例 generation；load/unload/配置/授权变化递增实例 generation，查询另有 request ID，不能因并行查询递增实例 generation 而彼此作废。晚到结果校验 generation、instanceID、query fingerprint 后才能提交。CancellationError 是正常控制流，不记录为失败重试。

### 5.3 异常和 fallback

- registration/descriptor 错误：隔离单插件，默认 App 启动。
- provider no match：继续链；网络/响应错误：映射现有错误并保留 fallback。
- metadata 过期：丢弃，不覆盖用户编辑。
- online auth/credential/factory 失败：source unavailable/authenticationRequired，不影响其他 source。
- privacy 撤销：停止新请求并取消当前 generation；已成功写入 library 的数据不回滚。
- DSP 协作式 error/nonfinite：恢复本块输入并旁路单个效果；连续三次 CPU 超预算才旁路，后续配置修改可重建恢复；原生崩溃或阻塞无法由 Runtime 隔离。
- startup plugin Runtime 失败：只记录 plugin dependency unavailable，不把现有 library/playback 标成不可用。

## 6. 迁移和文件清单

### 6.1 设置迁移

在 AppSettings 增加可选 pluginPreferences 聚合，旧 payload 缺省为空；现有 SettingsMigration 继续经 AppSettings 向后兼容 decode。新增字段为可选，当前 AppSettings/envelope schema 保持 1；实际 UserDefaults envelope 重开测试覆盖兼容性。现有 ImportPreferences 的 lyrics/metadata/online provider preference 保持原 key/语义，不自动迁移成 plugin preference。

OnlineProviderKind 若迁移为 RawRepresentable，旧四个 raw value 逐字兼容；未知值保留为 unavailable/disabled。新 Keychain 记录使用 pluginID+instanceID 命名空间；旧 credentialRecordID 原样兼容，迁移不能让已有账户重新登录或失联。停用/缺包保留配置及凭据；用户显式删除账户才清理明确归属的 secret。

MusicLyricsAPI 及其私有源 ID/偏好、仓库忽略规则、许可证与私有构建入口暂不处理；不把其恢复或迁移作为当前阶段前置条件。

### 6.2 计划新增文件

- Packages/MusicFreePluginAPI/Package.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginAPI/PluginIdentity.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginAPI/PluginConfiguration.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginAPI/PluginOperation.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginAPI/LyricsPluginAPI.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginAPI/MetadataPluginAPI.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginAPI/OnlineSourcePluginAPI.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginDSPAPI/DSPPluginAPI.swift
- Packages/MusicFreePluginAPI/Sources/MusicFreePluginAppleAudioAPI/AudioGraphPluginAPI.swift
- Packages/MusicFreePluginRuntime/Package.swift
- Packages/MusicFreePluginRuntime/Sources/MusicFreePluginRuntime/PluginRegistry.swift
- Packages/MusicFreePluginRuntime/Sources/MusicFreePluginRuntime/PluginLifecycle.swift
- Packages/MusicFreePluginRuntime/Sources/MusicFreePluginRuntime/PluginPreferences.swift
- Packages/MusicFreePluginRuntime/Sources/MusicFreePluginRuntime/PluginRuntime.swift
- Packages/MusicFreePluginHostBridge/Package.swift
- Packages/MusicFreePluginHostBridge/Sources/MusicFreePluginHostBridge/LyricsProviderAdapter.swift
- Packages/MusicFreePluginHostBridge/Sources/MusicFreePluginHostBridge/MetadataProviderAdapter.swift
- Packages/MusicFreePluginHostBridge/Sources/MusicFreePluginHostBridge/CompositeOnlineSourceFactory.swift
- Packages/MusicFreePluginAudio/Sources/MusicFreePluginAudio/PCMBufferView.swift
- Packages/MusicFreePluginAudio/Sources/MusicFreePluginAudio/AudioGraphDSPAdapter.swift
- Packages/MusicFreePluginAudio/Sources/MusicFreePluginAudio/OfflineDSPRenderSession.swift
- Packages/MusicFreePluginAudio/Package.swift

### 6.3 计划修改文件

- App/AppContainer.swift：注入 compile-time registrations，公开构建默认空/公开项。
- Packages/MusicFreeCore/Sources/AppServices/AppDependencies.swift：接收窄插件管理服务/既有 provider 端口，不导入具体 Runtime 或 HostBridge。
- Packages/MusicFreeCore/Sources/AppServices/AppServiceContainer.swift：通过注入的服务应用设置/consent，使用宿主桥提供的 adapters，不反向组装具体 Runtime。
- Packages/MusicFreeCore/Sources/AppServices/FeatureServices.swift：增加最小 PluginServing façade。
- Packages/MusicFreeCore/Sources/SettingsAPI/AppSettings.swift：增加可迁移 plugin preference。
- Packages/MusicFreeCore/Sources/MediaSourceAPI/OnlineSourceAPI.swift：按确认方案扩展 provider ID。
- Packages/MusicFreeCore/Sources/AppServices/OnlineSourceCoordinator.swift：仅接入 composite factory，保留现有 gate/error/snapshot。
- Packages/MusicFreeInfrastructure/Sources/OnlineSourceAdapter/OnlineCredentialStore.swift：复用 Keychain 并增加命名空间 helper。
- Packages/MusicFreeInfrastructure/Sources/OnlineSourceAdapter/OnlineSourceFactory.swift：保留现有 provider，委托 composite factory。
- project.yml、相关 Package.swift/target membership：A 按协调协议持共享锁串行接线、生成和验证，保留 B 的产品及测试。
- Packages/MusicFreeUI/Sources/SettingsFeature/SettingsViewModel.swift、SettingsScene.swift 及新增 PluginSettingsView：插件状态/开关/顺序、配置/授权动作和缺包解释；与 B 划分具体设置文件后接入。
- Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/OnlineSourcesViewController.swift：registry 表单、旧专用授权动作兼容、每实例状态及未知 Provider 展示。
- Scripts/check_architecture.sh：增加公共 API/Runtime 零业务依赖检查及专用 AppleAudio target 的精确允许范围，保留既有其他限制。

当前文件清单不含 MusicLyricsAPI 或播放器 UI 插件接口/实现；插件设置页面属于宿主设置功能，不属于播放器 UI 插件。

## 7. 阶段交付和独立验收

### 阶段 0：确认与接口冻结

交付：确认本版四类通用能力、分层 target、provider ID 方案、三开关、consent、Keychain、DSP budget 和 shared-file owner，明确延期项不进入本版交付。用户已批准实施，批准与并行职责记录在 1.4_PARALLEL_DEVELOPMENT_SESSIONS.md。

### 阶段 1：API、registry、公开空构建

交付：typed descriptors/capabilities/factories、duplicate validation、compiledOut 语义。验收：无私有包时公共宿主仍可使用现有服务；registration 无网络副作用。

### 阶段 2：Runtime、偏好、consent、代次

交付：UserDefaults migration、actor lifecycle、取消和 fallback。验收：旧设置可读；停止/替换/撤销不会留下可提交的旧 Task；display/enabled/load 可独立验证。

### 阶段 3：歌词和歌曲信息

交付：reference adapter、现有 coordinator 接入、字段 patch、record/fallback。验收：本地歌词优先；插件关闭时零调用；metadata 不覆盖用户编辑；既有公开 provider 行为不变。

### 阶段 4：通用在线源能力

交付：composite factory、可扩展 provider ID、instance config/Keychain/consent 和受控参考源。验收：既有源保持原 factory 行为；参考源多账户/仅播放/仅下载/撤销隔离通过；不依赖 MusicLyricsAPI，不在本版拆离既有源。

### 阶段 5：DSP 原型和单轨图

交付：PCM contract、offline renderer、当前单轨 graph adapter。验收：离线格式/EOF/reset/reconfigure/取消/错误旁路；实时 callback 无 await/阻塞分配；B 未实现时仍可独立完成。

### 阶段 6：公开构建与组合验收

交付：按[版本协调计划](../Versions/1.4.0_FEATURE_REQUIREMENTS.md)的仅 A、仅 B、组合矩阵记录构建和运行证据。四类参考接入和 DSP 原型可单独验收；与 B 只核对 AudioGraphDSPAdapter，不等待 B 整项完成。

自动化矩阵包括：重复注册/API 不兼容/缺包、加载并发去重、取消/停用/授权撤回与迟到结果、隐藏但已启用的能力、旧配置及未知插件保留、歌词歧义与版本不符、metadata 编辑保护、多账户单实例撤销、只播放/只下载、下载恢复、DSP 数值/链顺序/bypass/reset/tail。四类各有参考实现实际运行；原有歌词/在线源、宿主播放器 UI 正常回归。播放器 UI 插件和私有歌词协议不列入本版验收。

基础契约与 Runtime 独立 SwiftPM 测试，AppleAudio 契约单独编译，公开 App 构建/Simulator 设置交互/真机 DSP 听音与开销/最终 Archive 分别记录。开发记录持续更新实际用例数、资源预算及明确未验证项。

## 8. 已批准范围及实施决策

1. 用户已明确本版不提供播放器 UI 插件接口/实现，既有歌词/在线源拆离和 MusicLyricsAPI 暂缓；当前交付四类通用能力与参考接入。
2. 推荐基础 API/Runtime 零业务依赖，专用 DSP/AppleAudio 契约和宿主桥独立 target；数据插件不依赖 Core/UI。
3. 推荐 OnlineProviderKind 迁移为可扩展 raw ID，旧 raw value 兼容。
4. 推荐 display、enabled、loadAllowed 三字段独立；新参考插件默认不启用/加载，既有服务行为保留。
5. MusicLyricsAPI 已由用户明确暂不处理，无需作为本次开发确认项。
6. 推荐 account ID 为非密实例字段，所有 password/token/session/签名材料入 Keychain/内存。
7. 推荐 metadata 默认不允许自动 clear，用户编辑优先。
8. 推荐 DSP 先做当前单轨图和离线 renderer；callback budget、PCM ownership、无锁策略属于原型决策，需后续实测。
9. 播放器 UI 插件设计待后续讨论；本版不冻结 factory、surface、主题或组件契约。
10. 推荐与平滑播放只保留 AudioGraphDSPAdapter 窄接口；两项可以并行开发、独立验收。

## 9. Roadmap（不属于 1.4 交付）

- **既有歌词拆离为插件**：在通用契约/Runtime 稳定后，将现有 Provider 实现从宿主组合根拆入独立插件；保留本地歌词优先、ProviderID、顺序、缓存、设置与隐私同意，LyricsCoordinator 继续由宿主管理。后续专门制定迁移与无插件回退计划。
- **既有在线源拆离为插件**：迁移 DS Audio/Google Drive 等具体 adapter 与注册/配置描述，使宿主不再硬编码其实现；保留账户/SourceID、凭据引用、访问刷新、下载恢复与授权回调，浏览/下载/导入/试听 Coordinator 留在宿主。按 Provider 分步迁移。
- **MusicLyricsAPI**：暂缓全部处理，后续单独决定恢复/接入及私有源计划；本版不查找或改动此包。
- **播放器 UI 插件**：主题、组件、完整播放器和 MiniPlayer 都仅作为候选方向。后续先讨论交互/状态/生命周期边界，再设计接口；1.4 不增加 UIKit 插件 target、capability、factory、占位协议或参考实现。

## 10. 当前状态

四类 API/Runtime、宿主设置及 Provider/source 桥、正式播放/试听 PCM 和 post-EQ graph 接入、公开参考插件已实施。50 个相关自动化/Simulator 用例通过，包含真实 FFmpeg 输出增益和 graph tap 分析订阅；命令与工件见 PLUGIN_SYSTEM_1.4_DEVELOPMENT_LOG.md。真机/真实外部服务/Archive/完整构建矩阵仍待验收；HTTP 字节级续传未实现。生产 PCM 仅支持零 latency/tail，并以未验证 timing 降级 gapless/crossfade；不把离线 tail 能力等同于生产补偿。

### 2026-10-03 全量审查后的契约澄清

Runtime 的 typed DSP factory 需要 Foundation-only DSPAPI，不依赖 AppleAudioAPI/AVFAudio/Core；这避免把音频契约塞进基础数据 API。架构脚本同时检查 import 和 manifest 的零业务依赖。实例失效先删除 generation 和 leases，再异步 shutdown；不保留可能阻塞新实例的 stopping tombstone。每次操作独立 lease，共享一次加载；快照汇总活动实例状态。DSP 是每个解码槽的独立同步实例，不走数据请求 actor 的 running 租约。

在线源与设置入口共用 descriptor 驱动的 UIKit 表单；插件、来源、App 三个许可独立。配置未知 JSON/permission 在降级读取时保留，运行验证拒绝未知或越界值并显示原因。运行中效果变更立即旁路旧效果，节点挂载推迟到输出停止。
