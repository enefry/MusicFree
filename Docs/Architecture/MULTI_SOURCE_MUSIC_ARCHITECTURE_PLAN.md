# MusicFree 多数据源音乐架构综合规划

状态：工作包 A（Local Media vNext）代码实现、Simulator 自动化、App BVT 和 App UI 回归完成；按当前范围已验收通过，真机不在本轮门禁；工作包 B 尚未实施

日期：2026-08-21

适用工程：`/Users/chenrenwei/developer/MusicPlayer/MusicFree`

关联基线：`Docs/Architecture/MODULE_INTERFACES.md`

当前状态说明：

- 工作包 A 已落地 LogicalTrack、TrackVariant、MediaAsset、PlaybackSelection、Folder Bundle、Cover/Sidecar、CUE、多文件、多碟、Compilation、Box Set 和容器音轨选择等本地能力。
- CUE 逻辑轨只保存逻辑 `MediaItemID`，播放时通过 `Track.assetID.mediaItemID` 解析共享物理资产；CUE 时间区间和容器音轨选择保存在 `PlaybackSelection`。
- 工作包 A 的源码、迁移、Core/Infrastructure/VLCKit/App 的 iOS Simulator 测试、App BVT/App UI 回归和架构检查已完成；当前功能以 iOS 26.5 Simulator 作为验收基线，真机媒体矩阵不属于本轮门禁。
- 工作包 B 仍是设计状态：尚未实现 DS Audio、OAuth/DSM Session、远程 Catalog、下载缓存或任何网盘 Provider。

本轮最终修复复审快照（2026-08-21）：

- `MusicFreeInfrastructureTests`：iOS 26.5 Simulator 执行通过 137/137，5 个 suite；结果包 `/tmp/MusicFreeInfrastructureWorkPackageA-final-4.xcresult`。
- `MusicFreeCoreTests`：iOS 26.5 Simulator 执行通过 159/159；结果包 `/tmp/MusicFreeCoreWorkPackageA-escalated.xcresult`。
- `MusicFreeVLCKitAdapterTests`：iOS 26.5 Simulator 执行通过 17/17；结果包 `/tmp/MusicFreeVLCKitWorkPackageA-escalated.xcresult`。
- `MusicFreeTests`：iOS 26.5 Simulator 执行通过 32/32；结果包 `/tmp/MusicFreeWorkPackageA-AppTests-20260821.xcresult`。
- App BVT：iOS 26.5 Simulator 执行通过 1/1；结果包 `/tmp/MusicFreeWorkPackageA-BVT-20260821.xcresult`。
- App UI：工程内 `MusicFreeUITests` 执行通过 15/15；结果包 `/tmp/MusicFreeWorkPackageA-AppUI-20260821.xcresult`。另有 `MusicFreeUI` Package 测试通过 120/120，结果包 `/tmp/MusicFreeWorkPackageA-UI-20260821.xcresult`。
- 新增回归覆盖：legacy collection member 键碰撞迁移、旧键冗余字段校验、根目录和嵌套发行的封面隔离、含 `|` 的发行分组键隔离；原有普通文件恢复、CUE、多文件、多碟、Box Set、共享资产和容器音轨测试继续通过。
- 架构检查和 `git diff --check` 通过；代码保持未提交。
- 当前功能不要求真机验收；iOS 26.5 Simulator 已覆盖本轮验收范围。已连接的 `ip12` 为 iOS 17.6.1，和工程 iOS 26.0 deployment target 不匹配，因此真机媒体矩阵与正式发布验证作为后续独立门禁，不阻塞工作包 A。

追加修复复审快照（2026-08-22）：

- CUE 身份优先绑定文件资源标识；资源标识不可用或发生变化时，使用不包含完整路径的来源结构指纹安全重识别。只有唯一候选才复用旧 ID，歧义候选明确失败。
- CUE、引用音频或文件夹封面变化会触发来源修订刷新；字段级来源快照采用旧来源值、当前资料库值和新来源值三方合并，保留用户或补全服务修改过的元数据。
- CUE 专辑封面随来源刷新时，即使单曲使用自定义封面，也会按最终事务把新专辑封面写入托管存储，不产生只有引用而没有文件的 artwork。
- `TrackVariant` 新增的来源身份、修订和元数据快照字段兼容旧 Codable payload；track-only 更新不会清除这些来源字段。
- 未知扩展只忽略明确不支持的未引用 sidecar；读取失败、超时、损坏媒体和已识别的 Musepack `.mpc` 会正常报告失败。
- `MusicFreeInfrastructureTests`：iOS 26.5 Simulator 执行通过 159/159，6 个 suite；结果包 `/tmp/MusicFreeInfrastructureTests-20260822-final-7.xcresult`。
- `MusicFreeCoreTests`：iOS 26.5 Simulator 执行通过 168/168，2 个 suite；结果包 `/tmp/MusicFreeCoreTests-20260822.xcresult`。
- `MusicFreeVLCKitAdapterTests`：iOS 26.5 Simulator 执行通过 18/18，1 个 suite；结果包 `/tmp/MusicFreeVLCKitAdapterTests-20260822.xcresult`。
- `MusicFree` App：iPhone 17 Pro、iOS 26.5 Simulator 完整构建通过。
- 新增回归覆盖旧 `TrackVariant` payload、无文件资源 ID 的 CUE 内容替换与歧义拒绝、CUE 移动/音频替换/旧 ID 迁移、来源元数据三方合并及聚合专辑快照、自定义单曲封面与来源专辑封面并存、未知扩展错误传播，以及无默认轨和新识别默认轨两类旧错误音轨选择修复。

## 1. 文档目的

本文档定义 MusicFree 从“本地音乐播放器”演进为“本地、NAS 和网盘统一音乐库”时的目标架构、领域模型、接口边界、迁移顺序和验收门禁。

目标架构保持统一，但实施拆成两个可独立验收的工作包：

```text
工作包 A：本地媒体能力升级
  普通文件迁移
    -> 文件夹 Bundle / Cover / Sidecar
    -> CUE / 多文件 CUE
    -> 多碟 / 合辑 / Box Set
    -> 容器多音轨
    -> 本地能力发布门禁

工作包 B：远程数据源逐个接入
  DS Audio
    -> Google Drive
    -> OneDrive
    -> 百度网盘
    -> 阿里云盘
    -> 123 云盘
    -> 天翼云盘
```

工作包 A 不依赖任何远程账号、认证服务、远程目录同步或下载缓存即可完成和发布。工作包 B 在 A 的领域模型和播放选择能力稳定后启动，并且每次只接入一个 Provider；当前 Provider 未形成完整闭环前，不并行铺开下一个 Provider。

计划覆盖以下来源：

- 内置本地媒体。
- Synology DS Audio / Audio Station。
- Google Drive。
- OneDrive。
- 百度网盘。
- 阿里云盘。
- 123 云盘。
- 天翼云盘。
- 必要时通过独立网关接入的其他来源。

计划同时覆盖以下媒体组织形式：

- 一首歌对应一个普通音频文件。
- 多个提供商拥有同一张专辑或同一首歌的不同副本。
- 整轨音频文件配合 CUE Sheet。
- 一个 CUE 引用多个音频文件。
- 文件夹内包含 `cover`、歌词和其他 sidecar 文件。
- Various Artists 合辑、多碟专辑和包含多张专辑的 Box Set。
- 一个媒体容器包含多条可选音频流。
- 网盘文件下载完成后播放、固定离线和自动淘汰。

本文档只锁定架构语义。示例类型名允许在实现前微调，但职责、身份和生命周期边界不得被弱化。

## 2. 核心结论

MusicFree 不能继续把“歌曲”“来源记录”和“物理文件”视为同一个对象。目标模型必须拆成以下层级：

```text
LibraryCollection                 多专辑合集、Box Set 或用户集合
└── AlbumGroup                    同一作品的多个发行版，可选
    └── AlbumRelease              一张具体发行版，跨提供商统一
        └── Disc                  CD1、CD2 或其他介质
            └── LogicalTrack      用户看到、收藏、统计和加入歌单的歌曲
                └── TrackVariant  某个提供商中的可播放副本
                    └── MediaAsset    一个真实文件或远程对象
                        + PlaybackSelection
                          - wholeFile
                          - timeRange
                          - audioStream
                          - timeRange + audioStream
```

由此锁定以下决策：

1. `MediaSourceID` 表示一个具体配置实例，不表示供应商类型。
2. `MediaItemID` 表示来源内的一条可播放副本，即 `TrackVariant`。
3. 新增 `MediaAssetID` 表示真实文件或远程对象；缓存按资产而不是按逻辑歌曲管理。
4. 一首逻辑歌曲可以同时拥有本地文件、DS Audio 流、Google Drive 下载文件和 CUE 片段等多个副本。
5. 一张具体发行版在资料库中只显示一次，但保留所有来源快照和来源副本。
6. `LogicalTrack` 表示一张具体发行版中的曲目位或一首独立单曲，不是跨所有专辑共享的全局 Recording；同一录音出现在原专辑、精选集和 Deluxe 时默认是不同 LogicalTrack。
7. Catalog、内容交付、下载、认证和播放准备必须分层。
8. `LibraryRepository` 继续作为标准化资料库，不为每个提供商建立独立业务 Repository。
9. 下载缓存不是本地音乐源，不能走本地托管媒体删除流程。
10. 短生命周期内容 URL、Token、Cookie、DSM SID、请求 Header 和完整用户路径不得进入持久化模型、队列或日志；用户配置的服务 endpoint 仅保存规范化 origin/base URL，不包含 userinfo、query 或 fragment。
11. DS Audio 和网盘必须通过相同的上层契约接入，但允许采用不同的认证和内容交付实现。
12. 实施分为“本地媒体能力升级”和“远程数据源接入”两个工作包；本地工作包必须先独立完成。
13. 本地阶段只提前实现以后难以补迁移的稳定语义：LogicalTrack、TrackVariant、MediaAsset、PlaybackSelection 和发行结构；不提前实现远程认证、同步、下载和 Provider UI。
14. 远程能力按 Provider 纵向接入。共享抽象由第一个真实 Provider 的证据驱动提取，不先为全部网盘实现一个无法验收的通用框架。
15. 每个 Provider 都必须独立完成协议探针、契约 fixture、Adapter、真实账号和真机验收；“上一个 Provider 已通过”不能代替当前 Provider 的验证。

## 3. 范围与非目标

### 3.1 本轮目标

- 第一工作包先完成本地媒体能力升级，不依赖任何远程服务即可交付。
- 第二工作包再按 DS Audio、Google Drive、OneDrive、百度、阿里、123、天翼的顺序逐个接入。
- 支持多个来源实例和多个同类型账号同时存在。
- 将来源目录同步为可离线浏览的标准化音乐库。
- 支持远程流播放、下载后播放和离线缓存。
- 支持同一专辑、歌曲在多个来源中的统一显示和副本选择。
- 支持普通文件、CUE、文件夹封面、多碟、合辑、Box Set 和容器音轨。
- 支持来源失效、Token 过期、文件版本更新和缓存淘汰后的可恢复行为。
- 保持现有 Swift Package 单向依赖和 Adapter 隔离。

### 3.2 首轮非目标

- 不在第一阶段同时实现全部六个网盘 Provider。
- 不在本地能力阶段实现 OAuth、DSM Session、远程 Catalog 同步、下载缓存或远程来源设置页。
- 不为了未来 Provider 一次性实现所有可选能力；只冻结必要契约，具体实现随 Provider 纵向落地。
- 不把 Python、Go CLI、`synology-api` 或 `cloud_mover` 二进制直接嵌入 iOS App。
- 不在首版支持远程文件删除、移动、重命名或元数据回写。
- 不在首版同步服务端歌单；先保证歌曲、专辑、目录、封面和播放链路。
- 不把标准版、豪华版、重制版或现场版自动合并成同一 `AlbumRelease`。
- 不在首版进行跨提供商的全库音频指纹扫描。
- 不在首版实现“边流边写缓存”；流播放和完整下载是两个明确策略。
- 不因移除一个来源而自动删除用户创建的歌单、收藏和播放历史。

## 4. 当前工程基线与远程缺口

工作包 A 已完成本地模型和导入/播放链路；下表保留本地 live 状态，并只列出远程阶段仍需补齐的部分。

| 当前能力 | 现状 | 多来源缺口 |
| --- | --- | --- |
| `MediaItemID` | 已包含 `sourceID + externalID` | 适合作为来源副本 ID，但不足以表达共享物理资产 |
| `MediaSource` | Local Source 按 `MediaAssetID` 解析物理文件并提供 artwork | 远程 Catalog、认证、下载和缓存策略未分离 |
| `MediaSourceRegistry` | 启动时由不可变数组构建 | 无法动态添加、注销、重连或禁用来源 |
| `LibraryRepository` | 统一保存旧 Track 投影、LogicalTrack/TrackVariant/MediaAsset/发行结构及本地 CUE 来源快照 | 远程 Provider 来源快照、跨 Provider match 和远程 Catalog 尚未接入 |
| `Track` | 已包含逻辑轨、物理资产和 `PlaybackSelection` | 跨 Provider 的 Variant 选择和 fallback 尚未接入 |
| `AlbumType` | 本地导入可写入 Compilation 等发行结构 | 远程发行匹配和版本合并尚未接入 |
| 文件夹导入 | 已按 Bundle 分类音频、CUE、封面、歌词和其他 sidecar | 远程目录的 Bundle/sidecar 同步尚未接入 |
| 媒体探测 | 可报告并持久化多条 `ProbedAudioTrack` | 远程 Provider 的流能力声明尚未接入 |
| `PlaybackItem` | 包含资源、CUE 时间区间和音轨选择 | 远程下载/流播放准备服务尚未接入 |
| 播放队列 | 持久化 `LogicalTrackID`、首选 Variant 和逻辑进度，并兼容旧 ID | 多来源自动选择和失败 fallback 尚未接入 |
| 存储维护 | 已区分托管媒体、导入 staging 和 quarantine | 下载缓存、partial、pinned cache 尚未接入 |
| SwiftData Schema | live schema 为 2.0.0，并有 1.0.0 -> 2.0.0 迁移 | 远程来源记录和缓存 schema 按 Provider 后续演进 |

现有关键调用链为：

```text
PlaybackCoordinator
  -> LibraryRepository.track(entry.itemID)
  -> MediaSourceResolving.source(for: track.assetID.sourceID)
  -> MediaSource.resolve(track.assetID.mediaItemID)
  -> PlaybackItem(selection: track.playbackSelection)
  -> PlaybackResource
  -> PlaybackEngine.prepare
```

远程阶段目标调用链为：

```text
PlaybackCoordinator
  -> PlaybackPreparationCoordinator.prepare(LogicalTrackID, policy)
      -> TrackVariantSelector
      -> DownloadCache lookup
      -> MediaSourceManager.source(for:)
      -> MediaContentProviding
      -> MediaDownloadCoordinator when required
  -> PreparedPlayback
  -> PlaybackEngine.prepare
```

## 5. 术语与身份模型

### 5.1 Provider 与来源实例

供应商类型和用户配置实例必须分开：

```swift
public enum MediaProviderKind: String, Codable, Sendable {
    case local
    case dsAudio
    case googleDrive
    case oneDrive
    case baiduPan
    case aliyunDrive
    case pan123
    case cloud189
    case gateway
}

public struct MediaSourceConfiguration: Codable, Sendable {
    public let sourceID: MediaSourceID
    public let providerKind: MediaProviderKind
    public let displayName: String
    public let endpoint: String?
    public let rootExternalID: String?
    public let syncPolicy: SourceSyncPolicy
    public let playbackPolicy: SourcePlaybackPolicy
    public let credentialRecordID: String?
}
```

示例：

```text
sourceID = google-drive-personal, providerKind = googleDrive
sourceID = google-drive-work,     providerKind = googleDrive
sourceID = nas-home,              providerKind = dsAudio
```

`credentialRecordID` 只是 Keychain 记录引用，不是 Token 本身。

### 5.2 主要标识

| 标识 | 语义 | 稳定性要求 |
| --- | --- | --- |
| `MediaSourceID` | 一个已配置来源实例 | 用户未删除来源时稳定 |
| `SourceObjectID` | Provider 返回的文件、目录或来源实体 ID | 优先使用 Provider 稳定 ID，不使用临时 URL |
| `MediaAssetID` | 一个实际媒体文件或远程对象 | 至少由 `sourceID + stableExternalObjectID` 隔离；文件移动后仍应尽量稳定 |
| `MediaItemID` | 来源内的一条可播放副本 | `sourceID + externalTrackID`，跨重启稳定 |
| `LogicalTrackID` | 用户语义上的歌曲 | 不因选择其他 Provider 而改变 |
| `AlbumReleaseID` | 一张具体发行版 | 标准版和 Deluxe 必须不同 |
| `AlbumGroupID` | 同一作品不同发行版的可选分组 | 不参与默认去重 |
| `LibraryCollectionID` | Box Set 或用户集合 | 与普通 Album 分离 |

普通文件通常是一对一：

```text
LogicalTrack -> TrackVariant -> MediaAsset -> wholeFile
```

整轨 CUE 是多对一：

```text
LogicalTrack 01 -> TrackVariant 01 --┐
LogicalTrack 02 -> TrackVariant 02 --+-> one MediaAsset(album.flac)
LogicalTrack 03 -> TrackVariant 03 --┘
```

多音轨容器则是多个播放选择共享一个资产：

```text
LogicalTrack -> TrackVariant -> MediaAsset(album.mka)
                               + audioStream(streamID)
```

### 5.3 来源快照与标准化实体

Provider 返回的原始元数据不能直接覆盖标准化 Album 或 Track。必须保留来源快照：

```swift
public struct SourceAlbumSnapshot: Codable, Sendable {
    public let sourceID: MediaSourceID
    public let externalAlbumID: String
    public let title: String
    public let albumArtist: String?
    public let releaseDate: Date?
    public let editionTitle: String?
    public let trackCount: Int?
    public let discCount: Int?
    public let providerMetadataRevision: String?
}

public struct SourceAlbumLink: Codable, Sendable {
    public let snapshotID: SourceAlbumSnapshotID
    public let releaseID: AlbumReleaseID
    public let confidence: MatchConfidence
    public let method: MatchMethod
    public let isUserConfirmed: Bool
}
```

统一实体保存当前展示值，来源快照保存证据。同步某个来源时不得采用“最后写入者获胜”。

## 6. 专辑、歌曲与多来源合并

### 6.1 合并单位

多来源去重发生在具体发行版 `AlbumRelease` 和逻辑歌曲 `LogicalTrack` 层，而不是模糊的作品名称层。

以下内容不能仅因标题相同而自动合并：

- 标准版与 Deluxe。
- 原版与 Remaster。
- Studio 与 Live。
- 不同地区、年份或曲目列表的发行版。
- 有无 Bonus Track 的版本。

### 6.2 专辑匹配顺序

匹配证据按强到弱排序：

1. MusicBrainz Release ID、UPC/EAN 或其他明确发行标识。
2. Provider 可验证的共享目录或内容关系。
3. 规范化专辑名、Album Artist、发行日期、版次、碟数和完整曲目表。
4. 曲号、碟号、标题、时长的高比例一致。
5. 下载后音频指纹或内容哈希辅助确认。
6. 用户手动合并或拆分。

只凭专辑名或父目录名属于低置信度，不得自动合并。

### 6.3 歌曲匹配顺序

先锁定发行上下文，再匹配曲目。自动合并的目标是“同一 AlbumRelease 中的同一曲目位在不同来源中的副本”，不是把同一录音在不同专辑中的所有出现位置压成一首歌。

1. 已确认 `AlbumRelease + Disc + TrackNumber`，并且标题、艺人和时长不冲突。
2. Provider 明确给出的同发行版曲目关系，或已确认 CUE/分轨对应关系。
3. ISRC、MusicBrainz Recording ID 等稳定录音标识，作为发行上下文内的强证据。
4. 规范化标题、艺人、时长容差和曲目位置。
5. 下载后的音频指纹。
6. 用户确认。

同一个 `LogicalTrack` 可以拥有不同编码、采样率、位深、声道和文件组织形式的多个 `TrackVariant`。

同一录音出现在原专辑、精选集、现场专辑或不同发行版时，保留各自 LogicalTrack、曲号、封面和统计上下文。若后续需要跨专辑聚合录音，可另增 `Recording` 实体，不复用 LogicalTrack 承担两种身份。

### 6.4 展示元数据优先级

字段级优先级固定为：

```text
用户手动编辑
> 用户指定的元数据来源
> 可信公共音乐数据库
> 用户指定的首选 Provider
> 信息最完整且稳定的来源快照
```

标题、Album Artist、发行日期、版次和封面分别记录 provenance，不能用一个整对象覆盖所有字段。

## 7. 目标领域模型

以下伪代码表达语义，不代表最终文件拆分：

```swift
public struct AlbumGroup: Codable, Sendable, Identifiable {
    public let id: AlbumGroupID
    public let canonicalTitle: String
    public let primaryArtistIDs: [ArtistID]
}

public struct AlbumRelease: Codable, Sendable, Identifiable {
    public let id: AlbumReleaseID
    public let groupID: AlbumGroupID?
    public let title: String
    public let albumArtistIDs: [ArtistID]
    public let releaseDate: Date?
    public let originalReleaseDate: Date?
    public let editionTitle: String?
    public let albumType: AlbumType?
    public let artwork: ArtworkReference?
}

public struct Disc: Codable, Sendable, Identifiable {
    public let id: DiscID
    public let releaseID: AlbumReleaseID
    public let number: Int
    public let title: String?
    public let trackCount: Int?
}

public struct LogicalTrack: Codable, Sendable, Identifiable {
    public let id: LogicalTrackID
    public let releaseID: AlbumReleaseID?
    public let discID: DiscID?
    public let title: String
    public let artistIDs: [ArtistID]
    public let trackNumber: Int?
    public let trackTotal: Int?
    public let discNumber: Int?
    public let discTotal: Int?
    public let duration: Duration?
    public let artwork: ArtworkReference?
    public let isFavorite: Bool
    public let statistics: PlaybackStatistics
}

public struct MediaAsset: Codable, Sendable, Identifiable {
    public let id: MediaAssetID
    public let sourceID: MediaSourceID
    public let externalObjectID: String
    public let contentRevision: ContentRevision?
    public let fileName: String?
    public let logicalFolderPath: String?
    public let byteCount: Int64?
    public let technicalInfo: MediaTechnicalInfo?
}

public struct TrackVariant: Codable, Sendable, Identifiable {
    public let id: MediaItemID
    public let logicalTrackID: LogicalTrackID
    public let assetID: MediaAssetID
    public let selection: PlaybackSelection
    public let availability: VariantAvailability
    public let sourceIdentityHint: String?
    public let sourceMetadataRevision: String?
    public let sourceMetadata: TrackSourceMetadataSnapshot?
}

public struct PlaybackSelection: Codable, Sendable {
    public let range: PlaybackRange?
    public let audioStream: AudioStreamSelection?
}

public struct LibraryCollection: Codable, Sendable, Identifiable {
    public let id: LibraryCollectionID
    public let kind: LibraryCollectionKind
    public let title: String
    public let artwork: ArtworkReference?
}

public struct LibraryCollectionMember: Codable, Sendable {
    public let collectionID: LibraryCollectionID
    public let releaseID: AlbumReleaseID
    public let position: Int
}
```

### 7.1 现有 `Track` 的迁移定位

现有 `Track` 暂时保留为兼容读模型，避免一次性重写 UI、播放列表和全部查询：

- 迁移阶段把每个现有 `Track` 映射为一个 `LogicalTrack`、一个 `TrackVariant` 和一个 `MediaAsset`。
- 普通本地文件的 `PlaybackSelection` 为 whole file。
- `LibraryRepository.track(id: MediaItemID)` 在过渡期继续返回当前来源副本的兼容投影。
- 新增 `logicalTrack(id:)`、`variants(for:)`、`release(id:)` 等查询。
- UI 和歌单迁移完成后，再评估是否收缩旧查询，而不是先破坏现有接口。

## 8. MediaSource 能力拆分

本章定义工作包 B 的目标边界，不表示工作包 A 需要一次性实现全部协议。本地阶段只使用现有内置 Local Source 完成资产解析和播放；Catalog、Authentication、动态来源管理和远程内容交付在接入第一个真实 Provider 时按需实现。

### 8.1 基础来源

`MediaSource` 最终只承载身份和能力，不继续膨胀为一个包含所有操作的协议：

```swift
public protocol MediaSource: Sendable {
    var descriptor: MediaSourceDescriptor { get }
    var capabilities: MediaSourceCapabilities { get }
}
```

现有 `resolve` 和 artwork 在迁移期保留兼容入口，调用方迁移到独立能力协议后再弃用。

### 8.2 Catalog

```swift
public protocol MediaCatalogProviding: MediaSource {
    func page(
        _ request: SourceCatalogPageRequest
    ) async throws -> SourceCatalogPage

    func search(
        _ query: SourceCatalogSearchQuery
    ) async throws -> SourceCatalogPage
}

public protocol MediaCatalogChangesProviding: MediaSource {
    func changes(
        since cursor: MediaSourceCursor?
    ) -> AsyncThrowingStream<MediaCatalogChange, Error>
}
```

Provider 没有可靠增量 API 时只声明全量同步能力，由 `CatalogSyncCoordinator` 执行标记扫描，不得伪造增量游标。

### 8.3 内容交付

```swift
public protocol MediaContentProviding: MediaSource {
    func contentAccess(
        for assetID: MediaAssetID,
        purpose: MediaContentPurpose
    ) async throws -> MediaContentAccess
}

public enum MediaContentAccess: Sendable {
    case localFile(URL)
    case remoteStream(RemotePlaybackRequest)
    case downloadable(RemoteDownloadAccess)
    case streamOrDownload(
        stream: RemotePlaybackRequest,
        download: RemoteDownloadAccess
    )
}
```

`RemoteDownloadAccess` 和 `RemotePlaybackRequest` 都必须：

- 不实现 `Codable`。
- 对 description、debugDescription 和 Mirror 脱敏。
- 带可选过期时间。
- 不被放入队列、SwiftData、UserDefaults、错误文本或诊断附件。

### 8.4 Artwork

```swift
public protocol MediaArtworkProviding: MediaSource {
    func artwork(
        for reference: SourceArtworkReference
    ) async throws -> ArtworkResource?
}
```

封面 URL 同样是短生命周期资源。标准化资料库只保存稳定引用和来源 provenance。

### 8.5 Authentication

```swift
public protocol MediaSourceAuthentication: Sendable {
    func state(for sourceID: MediaSourceID) async -> SourceAuthenticationState
    func connect(_ sourceID: MediaSourceID) async throws
    func refreshIfNeeded(_ sourceID: MediaSourceID) async throws
    func disconnect(_ sourceID: MediaSourceID) async
}
```

认证实现可以是 OAuth、DSM Session、Cookie、QR 登录或网关会话。上层只消费标准状态：

```text
disconnected
connecting
connected(expiresAt?)
refreshing
requiresUserAction
temporarilyUnavailable(retryAfter?)
```

## 9. 动态来源管理

当前启动时静态数组应演进为应用级 `MediaSourceManager` actor：

```swift
public protocol MediaSourceManaging: MediaSourceResolving, Sendable {
    func descriptors() async -> [MediaSourceDescriptor]
    func add(_ configuration: MediaSourceConfiguration) async throws
    func update(_ configuration: MediaSourceConfiguration) async throws
    func remove(_ sourceID: MediaSourceID) async throws
    func reconnect(_ sourceID: MediaSourceID) async throws
    func setEnabled(_ enabled: Bool, for sourceID: MediaSourceID) async throws
    func changes() -> AsyncStream<MediaSourceManagerChange>
}
```

职责边界：

- `MediaSourceConfigurationRepository` 保存非敏感配置、同步游标和连接偏好。
- `CredentialVault` 保存 OAuth refresh token、DSM 凭据、Cookie 或网关 secret。
- `MediaSourceFactory` 根据 Provider Kind 构造 Adapter。
- `MediaSourceManager` 管理实例生命周期和状态，不持久化凭据。
- 单个来源登录失效不能阻塞 App 启动或其他来源播放。
- App 启动和回到前台时按来源执行 `refreshIfNeeded`；收到 401/失效响应时只允许一次受控刷新与重试。
- Settings reset 不得顺带删除来源配置；删除来源必须是独立、确认过的操作。

## 10. Catalog 同步与标准化

### 10.1 同步链路

```text
MediaCatalogProviding
  -> SourceCatalogPage / Change
  -> SourceBundleAssembler
  -> Provider metadata snapshots
  -> Album/Track matcher
  -> LibraryTransaction
  -> LibraryRepository
```

Provider Adapter 不直接写 SwiftData。它只返回协议中立的数据和游标，`CatalogSyncCoordinator` 负责：

- 分页和取消。
- 同步 checkpoint。
- 全量扫描的 seen-set。
- 来源快照持久化。
- AlbumRelease / LogicalTrack 匹配。
- 原子 LibraryTransaction。
- 远端删除和不可用状态处理。

### 10.2 全量同步

全量同步必须使用“两阶段删除”：

1. 扫描时更新 seen 标记和内容版本。
2. 完整扫描成功后，才把未 seen 的来源实体标记为 missing。

分页失败、取消或认证过期时，不得把后续未扫描项目误判为已删除。

### 10.3 增量同步

增量游标是 Provider 私有 opaque 值：

- Google Drive changes token、OneDrive delta token 或其他游标只能由对应 Adapter 解释。
- 游标只在一批 LibraryTransaction 成功提交后前移。
- 游标失效时回退全量同步，但保留现有资料库直到新扫描完整成功。

### 10.4 远端删除

远端项目消失时：

- 对应 `TrackVariant` 标记 unavailable。
- 若还有其他可用 Variant，`LogicalTrack` 保持可播放。
- 若只有已下载缓存，可按用户策略继续离线播放并显示来源已失效。
- 没有任何可用 Variant 时保留歌单、收藏和历史引用，UI 显示不可用。
- 不立即物理删除标准化实体，清理需要独立保留策略。

## 11. 文件夹导入与 Sidecar 发现

### 11.1 Bundle 级导入

文件夹不能再被简单拆成若干互不相关的文件。目标流程为：

```text
Folder enumeration
  -> Resource classification
      audio
      cue
      artwork
      lyrics
      manifest
      ignored
  -> FolderImportBundle
  -> Bundle analysis
  -> ImportPlan preview
  -> Atomic execution
```

推荐接口：

```swift
public protocol MediaImportBundleAnalyzing: Sendable {
    func analyze(
        _ request: MediaImportBundleRequest
    ) async throws -> MediaImportPlan
}
```

`MediaImportPlan` 必须在写入前表达：

- 将创建的 AlbumRelease、Disc 和 LogicalTrack。
- 每个 TrackVariant 与 MediaAsset 的映射。
- CUE 解析结果和缺失引用。
- 选中的专辑封面及原因。
- 重复、冲突、跳过和不支持的文件。
- 预计复制或下载字节数。

### 11.2 资源分类

首版至少识别：

- 音频：由真实 probe 判定，不仅依赖扩展名。
- CUE：`.cue`。
- 歌词：`.lrc`，后续可扩展其他文本歌词。
- 图片：`.jpg`、`.jpeg`、`.png`、`.webp`、`.heic`，最终以安全解码为准。
- 隐藏文件、符号链接、package 和越界路径继续拒绝或忽略。

资源枚举限制仍需保留最大深度、文件数、单文件大小、图片字节和像素限制。

### 11.3 文件夹封面选择

AlbumRelease 封面的默认优先级：

```text
用户明确指定
> cover.*
> front.*
> folder.*
> album.*
> 内嵌 Front Cover
> 文件夹内唯一且合格的图片
> 在线元数据封面
```

比较规则必须确定性：

- 文件名匹配大小写不敏感。
- 同一优先级先比较有效像素面积，再使用规范化路径排序。
- 拒绝超出 Artwork 限制、无法解码或疑似 decompression bomb 的图片。
- AlbumRelease 保存专辑封面；LogicalTrack 默认继承，只有明确的 Track artwork 才覆盖。
- 一个目录识别出多张专辑时，根目录 `cover.jpg` 不自动应用到全部专辑。
- 优先使用离音频最近且只对应一个发行版的子目录封面。
- 可支持 `专辑名.jpg` 的规范化精确匹配，但低置信度时不自动应用。

### 11.4 原子性与恢复

本地导入必须保证：

- 音频、CUE 语义清单、必要 sidecar 和 artwork receipt 形成一个可恢复事务。
- LibraryTransaction 失败时回滚新复制资产和封面。
- App 中断后可识别未完成 staging，不生成半张专辑。
- 重新导入同一 bundle 是幂等的，但用户删除后允许显式重新导入。

远程目录同步使用相同 bundle analyzer，但不复制原始 sidecar；它持久化解析后的结构、来源对象 ID 和修订值。

## 12. CUE Sheet 支持

### 12.1 建模规则

- CUE 文件是 descriptor，不是可播放歌曲。
- 一个 CUE 可以引用一个或多个 MediaAsset。
- 每个 CUE TRACK 生成一个来源内稳定 `MediaItemID` 和一个 `TrackVariant`。
- 多个 TrackVariant 可以共享同一个 MediaAsset。
- 被有效 CUE 引用的音频资产默认由 CUE 接管，不再额外生成 whole-file LogicalTrack；同一 bundle 中未被 CUE 引用的音频仍按普通文件导入。
- 多个非等价 CUE 同时声明同一资产时必须在 ImportPlan 中报告冲突并等待选择，不能静默生成重复歌曲。
- CUE 自身有 descriptor revision；音频资产有独立 content revision。
- CUE 元数据变更不应让未变化的音频缓存失效。
- 音频资产变更时，引用它的所有 TrackVariant 重新验证区间。

推荐稳定来源 Track ID 的组成：

```text
(sourceID, stableCueObjectID, referencedFileOrdinal, cueTrackNumber)
```

revision、临时 URL、文件绝对路径和下载地址不得成为 ID。

### 12.2 解析范围

首版至少支持：

- `FILE`
- `TRACK`
- `TITLE`
- `PERFORMER`
- `SONGWRITER`
- `INDEX 00`
- `INDEX 01`
- `PREGAP`
- `POSTGAP`
- 常见 `REM` 字段的安全保留
- 单文件和多文件 CUE
- UTF-8、UTF-8 BOM，以及真实中文样本验证后的编码回退

解析器必须：

- 使用专门 parser，不通过字符串 split 临时拼接语义。
- 保存原始 diagnostics，但错误中不泄漏绝对路径。
- 校验 Track 编号、时间递增、FILE 引用和资产时长。
- 规范化 Windows 和 POSIX 路径分隔符。
- 禁止绝对路径和 `..` 越出已授权目录。
- 通过同目录大小写不敏感回退解析常见文件名差异。

### 12.3 区间规则

当前契约：

- Track 逻辑起点为 `INDEX 01`。
- 下一个 Track 的 `INDEX 01` 是当前 Track 的默认结束点。
- 如果下一个 Track 有 `INDEX 00`，当前 Track 的结束点取该 `INDEX 00`；没有 `INDEX 00` 时，结束点取下一个 Track 的 `INDEX 01 - PREGAP`。
- 当前 Track 的 `POSTGAP` 从当前逻辑轨结束点扣除；最后一轨以资产实际时长为默认结束点。
- 第一轨前的 pregap 默认不作为独立歌曲暴露。
- 当前测试锁定的边界样本为：起点 `[0, 120, 180]`，结束点 `[118, 178, 240]`；真实设备仍需验证播放器对这些区间的 seek/end 行为。

所有用户可见位置均为 LogicalTrack 相对时间。播放器内部换算：

```text
assetPosition = playbackRange.start + logicalPosition
logicalDuration = playbackRange.end - playbackRange.start
```

### 12.4 播放能力

`PlaybackAPI` 增加：

```swift
public struct PlaybackRange: Codable, Equatable, Sendable {
    public let start: Duration
    public let end: Duration?
}

public struct PreparedPlayback: Sendable {
    public let itemID: MediaItemID
    public let resource: PlaybackResource
    public let selection: PlaybackSelection
    public let display: PlaybackDisplaySnapshot
}
```

并增加能力：

```text
segmentPlayback
accurateSeeking
audioStreamSelection
```

VLCKit Adapter 必须在自己的边界内实现 start、stop、seek 和 stream selection，不能让 AppServices 构造原始 VLC option。

远程 CUE 播放要求内容访问支持可靠 Seek/Range。无法证明准确性的来源强制走下载后本地播放。

### 12.5 共享资产生命周期

- 下载一个整轨资产后，所有引用 TrackVariant 都显示可离线。
- 清除某一首歌曲的下载应解释为清除共享资产；UI 必须提示会影响同一整轨中的其他歌曲。
- 下载缓存副本在没有 active playback lease 且未 pinned 时可以删除；删除后保留 MediaAsset 和 TrackVariant，只把关联歌曲改为非离线状态。
- App 托管的原始媒体只有在资产引用计数为零，并完成可恢复删除事务后才能物理删除。
- 播放历史、收藏和完成统计记录在 LogicalTrack，不记录在整轨 MediaAsset。

## 13. Compilation、多碟和多专辑合集

### 13.1 Various Artists 合辑

```text
AlbumRelease
  albumType = compilation
  albumArtist = Various Artists 或来源提供的共同 Album Artist
  Track 1 artist = Artist A
  Track 2 artist = Artist B
```

不能用 Track Artist 生成多个 Album。Album identity 优先使用 Album Artist、发行标识和完整曲目表。

### 13.2 多碟专辑

一张 `AlbumRelease` 下创建多个 `Disc`：

```text
AlbumRelease
├── Disc 1: Studio Album
└── Disc 2: Bonus Tracks
```

需要补充 `trackTotal`、`discTotal`、`discTitle`，排序键为：

```text
discNumber -> trackNumber -> normalizedTitle -> LogicalTrackID
```

### 13.3 Box Set 或多专辑合集

包含多张独立专辑的合集使用 `LibraryCollection`：

```swift
public enum LibraryCollectionKind: String, Codable, Sendable {
    case boxSet
    case providerCollection
    case folderGroup
    case userDefined
}
```

`LibraryCollection` 只组织多个 AlbumRelease，不把所有歌曲压成一张超大 Album。

### 13.4 普通父文件夹

用户选择的父目录即使包含多张专辑，也默认只是导航文件夹。只有以下证据之一成立时才创建 Box Set：

- 明确的 Provider collection / box set 元数据。
- 可识别的合集 manifest。
- 一致的 Box Set 标签和子专辑结构。
- 用户确认。

## 14. 容器音轨与音轨号

“音轨”需要区分两个概念：

1. 用户看到的 LogicalTrack。
2. MediaAsset 容器中的 Audio Stream。

目标音频流模型：

```swift
public struct AudioStreamDescriptor: Codable, Equatable, Sendable {
    public let streamID: AudioStreamID
    public let indexHint: Int?
    public let language: String?
    public let title: String?
    public let codec: String?
    public let sampleRate: Int?
    public let bitDepth: Int?
    public let channelCount: Int?
    public let isDefault: Bool
}

public struct AudioStreamSelection: Codable, Equatable, Sendable {
    public let streamID: AudioStreamID
    public let fallbackSignature: AudioStreamSignature
}
```

不能只持久化数组下标。底层有稳定 stream ID 时优先保存；没有时使用语言、标题、codec、声道数和 index hint 重新匹配。

默认选择顺序：

1. 用户为当前 Variant 保存的选择。
2. 标记为 default 的可解码流。
3. 用户首选语言。
4. 符合音乐播放策略的声道布局。
5. 第一条可解码流。

普通多语言或多编码流默认是一个 TrackVariant 的不同播放选择，不自动生成多首歌曲。只有 Provider、章节或用户明确表明它们是不同节目时，才建立多个 LogicalTrack。

曲号相关字段至少包含：

```text
trackNumber
trackTotal
discNumber
discTotal
cueTrackNumber
sourceOrder
```

## 15. 播放准备与副本选择

### 15.1 播放准备服务

当前本地实现中，`PlaybackCoordinator` 管理队列、状态、generation、系统控制和播放历史，同时使用 Track 的 `assetID` 解析本地物理文件，并把 `playbackSelection` 传给引擎。远程 Provider 接入后，再把 Variant 选择、下载和认证恢复抽到独立的 Playback Preparation 服务。

```swift
public protocol PlaybackPreparationServing: Sendable {
    func prepare(
        logicalTrackID: LogicalTrackID,
        preferredVariantID: MediaItemID?,
        policy: PlaybackPreparationPolicy
    ) async throws -> PreparedPlayback
}
```

准备流程：

```text
Load LogicalTrack
  -> Load all TrackVariants
  -> Filter unavailable / unauthenticated variants
  -> Check asset cache and revision
  -> Apply explicit user preference
  -> Apply source and quality policy
  -> Resolve stream or download access
  -> Download when required
  -> Return resource + PlaybackSelection
```

### 15.2 选择规则

选择采用可解释的有序规则，不使用无法解释的综合分数：

1. 当前队列 entry 明确固定的 Variant。
2. 用户为当前歌曲或专辑指定的 Provider。
3. 离线时选择 revision 有效的完整缓存。
4. 过滤登录失效、内容缺失、不支持当前 Selection 的 Variant。
5. 应用用户全局来源优先级。
6. 应用播放策略：快速播放或音质优先。
7. 同级时比较 codec、bit depth、sample rate、channel layout 和最近成功状态。
8. 使用稳定 ID 排序作为最终确定性 tie-breaker。

默认策略：

| 模式 | 顺序 |
| --- | --- |
| 快速播放 | 用户指定 > 有效缓存 > 本地托管文件 > 可直接流 > 等待下载 |
| 音质优先 | 用户指定 > 最高音质有效缓存 > 最高音质可下载 > 可直接流 |
| 离线模式 | 用户指定缓存 > 其他有效缓存 > unavailable |

当前播放准备完成后固定本次 `MediaItemID`。播放过程中不自动切换资源；只有 prepare 或连接失败时才按剩余 Variant fallback。

### 15.3 队列与歌单

目标队列 entry：

```swift
public struct PlaybackQueueEntry: Codable, Sendable {
    public let id: UUID
    public let logicalTrackID: LogicalTrackID
    public let preferredVariantID: MediaItemID?
}
```

- App 创建的歌单记录 `LogicalTrackID` 和可选首选 Variant。
- Provider 歌单若以后同步，必须同时保存来源身份和映射，不冒充 App 本地歌单。
- Resume position 是 LogicalTrack 相对位置，不能保存 CUE 对应资产绝对时间。
- 正在播放的 queue entry 可保存本次 resolved Variant 作为会话状态，但不保存 URL 或 Header。

## 16. 下载与缓存

### 16.1 缓存单位

缓存键修正为：

```text
AssetCacheKey(MediaAssetID, ContentRevision)
```

不使用 LogicalTrackID 或 TrackVariant ID 作为物理文件缓存键。这样：

- 一个 CUE 整轨只下载一次。
- 多首歌曲共享同一容器资产。
- 同一 Provider 文件的元数据变化不必删除音频缓存。
- 内容 revision 变化时旧缓存明确失效。

跨 Provider 内容相同也默认保留两个资产。只有下载后有可信内容哈希且用户允许时，后续版本才考虑物理去重。

### 16.2 缓存记录

```swift
public struct DownloadCacheEntry: Codable, Sendable {
    public let key: AssetCacheKey
    public let relativePath: String
    public let expectedBytes: Int64?
    public let receivedBytes: Int64
    public let checksum: String?
    public let state: DownloadState
    public let isPinned: Bool
    public let lastAccessedAt: Date
}
```

状态机：

```text
notCached
  -> queued
  -> downloading
  -> paused
  -> verifying
  -> ready
  -> stale
  -> evicted

queued/downloading/verifying
  -> failed(retryable, retryAfter?)
  -> cancelled
```

### 16.3 DownloadCoordinator

`MediaDownloadCoordinator` actor 统一负责：

- 同一个 AssetCacheKey 的任务去重。
- 当前播放、下一曲预取、用户手动下载和后台同步优先级。
- Range 断点续传。
- Provider 不支持 Range 时从零重试。
- signed URL 或 session 过期后的 access refresh。
- partial 文件、元数据 checkpoint 和原子 rename。
- 长度、revision、ETag 或 checksum 校验。
- 低磁盘空间预检。
- 取消、App 重启恢复和后台下载事件接管。
- pinned、LRU 和容量上限淘汰。

Provider 只生成短生命周期下载访问，不自行决定本地目录、缓存额度或淘汰策略。

### 16.4 存储分类

```text
Managed Media
  用户导入并由 App 托管，不自动淘汰

Download Cache
  远程资产完整副本，可自动淘汰或固定

Download Partial
  未完成下载，可恢复或清理

Import Staging
  本地导入事务临时文件

Artwork Cache
  原图和派生图缓存

Quarantine
  可恢复删除隔离区
```

`StorageUsageSnapshot` 应分别报告这些类别。清除 Download Cache 不删除 LogicalTrack、来源配置或远端文件。

## 17. Provider 策略

| Provider | Catalog | 默认内容策略 | 认证 | 首要验证 |
| --- | --- | --- | --- | --- |
| Local | 导入 bundle | local file | 文件授权 | 新模型回归、CUE、sidecar |
| DS Audio | Audio Station catalog，全量优先 | stream preferred，可选下载 | DSM session | 真实 DSM 响应、分页、封面、Seek、过期 session |
| Google Drive | files + changes | download before play | OAuth | changes token、Range、signed/redirect 行为 |
| OneDrive | Graph list + delta | download before play | OAuth | delta、content redirect、Token refresh |
| 百度网盘 | 待协议探针 | download before play | Provider 特定 | 登录、限流、下载链接有效期 |
| 阿里云盘 | 待协议探针 | download before play | Provider 特定 | refresh、动态下载 URL、限流 |
| 123 | 待协议探针 | download before play | Provider 特定 | 签名、Cookie、限流、Range |
| 天翼云盘 | 待协议探针 | download before play | Provider 特定 | Cookie/Token、下载稳定性、Range |

### 17.1 DS Audio 特别约束

- 第三方 `synology-api` 仅作为协议探索参考，不作为 iOS 运行时依赖。
- 生产实现使用原生 Swift、URLSession 和类型化请求模型。
- Audio Station 文档和不同 DSM 版本可能存在差异，必须使用真实 NAS 进行协议探针并保存脱敏 JSON fixtures。
- 首版优先目录、歌曲、专辑、艺人、封面和流播放。
- QuickConnect、服务端歌单、远端编辑和删除不进入首版。
- 如果 DS Audio 只返回已切分的逻辑 Track，则采用服务端结构；只有能发现原始 CUE sidecar 和媒体文件时才执行客户端 CUE 解析，避免重复建轨。

### 17.2 官方直连与网关

推荐直接在 iOS 中实现官方且稳定的 OAuth/API Provider，例如 Google Drive 和 OneDrive。

对于需要频繁逆向、动态签名、长期 Cookie 或不适合在 App 内维护的 Provider，保留：

```text
MusicFree
  -> GatewayMediaSourceAdapter
  -> versioned HTTP/JSON contract
  -> provider service / cloud_mover / provider CLI
```

网关要求：

- 对 App 暴露稳定的 catalog、item metadata、download access 和 auth state 合约。
- Provider CLI 输出只在网关内部消费，不泄漏到 App 领域模型。
- 凭据由明确的一侧持有，不在 App 与网关之间重复长期存储。
- 错误为机器可读、可分类结构，不解析人类 Usage 文本。
- 网关是可选 Adapter，不成为 Local、DS Audio、Google Drive 的硬依赖。

## 18. 持久化与 Schema 迁移

### 18.1 新增记录

SwiftData schema 按工作包演进，不在本地阶段一次性创建全部远程记录。以下版本名表达职责，最终版本号以 live schema 为准。

`Local Media vNext` 在 Phase L0 至 L3 引入：

```text
AlbumGroupRecord
AlbumReleaseRecord
DiscRecord
LogicalTrackRecord
MediaAssetRecord
TrackVariantRecord
LibraryCollectionRecord
LibraryCollectionMemberRecord
```

Phase R1 随 DS Audio 引入：

```text
MediaSourceConfigurationRecord
MediaSourceSyncStateRecord
SourceAlbumSnapshotRecord
SourceTrackSnapshotRecord
TrackVariantPreferenceRecord
```

Phase R2 随第一个 download-before-play Provider 引入：

```text
DownloadCacheEntryRecord
```

远程 schema migration 不得成为本地媒体功能启动的前提。凭据在所有 Phase 都不进入 SwiftData。

### 18.2 现有数据迁移

对每个现有 Track：

1. 保留原 `MediaItemID` 作为 TrackVariant ID。
2. 创建一个 MediaAsset；本地来源 external object identity 由现有托管记录确定。
3. 创建一个 LogicalTrack。
4. 创建 whole-file PlaybackSelection。
5. 将收藏、统计、历史和展示元数据迁移到 LogicalTrack 或兼容 projection。

对每个现有 Album：

1. 创建一个 AlbumRelease。
2. 根据现有 discNumber 创建必要 Disc。
3. 关联迁移后的 LogicalTrack。

对现有歌单和队列：

- `MediaItemID` 映射到对应 LogicalTrackID。
- 原 item ID 保存为 preferredVariantID，确保迁移后首次播放行为不变。
- resume position 保持逻辑相对时间；普通 whole-file 迁移无需换算。

### 18.3 迁移要求

- 迁移必须确定性、幂等且有 fixture。
- 未迁移成功时不能部分打开新 schema。
- 迁移前后 Track、Album、歌单顺序、当前队列、收藏和统计数量必须可核对。
- 迁移测试必须覆盖空库、大库、孤立关系、损坏记录和已有 pending removal。
- 文档状态不能先于 live schema；完成实现后再更新 `MODULE_INTERFACES.md` 的冻结基线。

## 19. 模块与文件调整范围

### 19.1 `MusicFreeCore`

`MusicDomain`：

- 新增 AlbumGroup、AlbumRelease、Disc、LogicalTrack、MediaAsset、TrackVariant、LibraryCollection。
- 新增 `MediaAssetID`、`LogicalTrackID`、`AlbumReleaseID` 等强类型 ID。
- `LibraryFolder` ID 改为 `sourceID + normalizedPath`，避免不同来源同名目录冲突。
- 扩展发行、曲号总数、碟片标题和元数据 provenance。

`MediaSourceAPI`：

- 拆分 Catalog、Content、Artwork、Authentication 能力。
- 增加 Source Configuration、ContentRevision、RemoteDownloadAccess。
- 增加 CUE/sidecar 所需协议中立 catalog node。

`LibraryAPI`：

- 增加 release、logical track、variant、asset、collection 查询和事务 mutation。
- 增加来源快照和 match link 的持久化契约。
- 保留现有 Track 查询作为过渡兼容层。

`PlaybackAPI`：

- `PlaybackItem` 增加 PlaybackSelection。
- 增加 segment playback、accurate seeking、audio stream selection 能力。
- 队列迁移到 LogicalTrackID + preferredVariantID。

`SettingsAPI`：

- 增加来源播放策略、来源优先级、下载缓存额度、离线和 pinned 策略。
- 来源配置不塞入 `AppSettings.reset` 生命周期。

`AppServices`：

- Phase L1 至 L3（live）：`LocalMediaImporter`、`LocalMediaBundlePlanner` 和 `PlaybackCoordinator` 共同完成 Bundle 导入、资产解析和 PlaybackSelection 传递；独立的 `MediaImportBundleCoordinator` / `PlaybackPreparationCoordinator` 仍是远程阶段的可选抽取点。
- Phase R1：`MediaSourceManager`、`CatalogSyncCoordinator`、`AlbumTrackMatchingCoordinator`、`TrackVariantSelector`。
- Phase R2：`MediaDownloadCoordinator`。

### 19.2 `MusicFreeInfrastructure`

新增 Adapter target 或产品：

```text
Phase R1: SourceConfigurationPersistenceAdapter
Phase R1: CredentialPersistenceAdapter
Phase R1: RemoteMediaTransportAdapter
Phase R2: DownloadCacheAdapter
```

现有 `LocalMediaAdapter`：

- 从逐文件导入演进为 bundle analyze + execute。
- 新增 CUE parser、sidecar classifier 和 folder artwork resolver。
- 保持托管媒体、staging、quarantine 的恢复事务。

现有 `LibraryPersistenceAdapter`：

- 新增 schema 和迁移。
- 维持 SwiftData 只存在于该 Adapter target 的架构检查。

### 19.3 Provider targets

Provider 规模增长后建议独立 Package 或至少独立 target：

```text
DSAudioAdapter
GoogleDriveAdapter
OneDriveAdapter
GatewayMediaSourceAdapter
```

百度、阿里、123 和天翼确认直接接入或网关方案后再创建 target，避免先引入无效依赖。

### 19.4 `MusicFreeVLCKitAdapter`

- 支持 PlaybackRange。
- 支持按稳定音频流选择或可靠 fallback。
- 事件位置映射为 LogicalTrack 相对位置。
- 到达 segment end 时产生一次 finished，不重复推进队列。
- 相邻 CUE Track 共用资产的 gapless 优化放在正确性之后。
- 所有 Provider 凭据仍只能通过类型化、短生命周期资源进入 Adapter。

### 19.5 `MusicFreeUI`

- Settings 增加数据源列表、连接状态、同步、重新登录和移除来源。
- Library 增加来源筛选、Collection、Disc 和 Variant 信息。
- Album 页面显示来源摘要和“播放来源”选择。
- Track 详情显示音质、缓存、来源、CUE 片段和容器音轨。
- 下载管理显示 queued、progress、failed、pinned、shared asset。
- 共享 CUE 资产清理时明确影响范围。

## 20. UI 与用户决策

### 20.1 专辑展示

同一 AlbumRelease 只显示一次：

```text
Album A
3 个来源 · DS Audio / Google Drive / 百度网盘
默认来源：Google Drive
离线：8 / 12 首，1 个共享整轨资产
```

AlbumGroup 只在用户需要查看不同版本时出现，不把多个版本折叠成无法区分的 Track 列表。

### 20.2 来源选择

支持三层偏好：

- 全局 Provider 优先级。
- AlbumRelease 默认 Provider。
- 单曲 preferred Variant。

显式选择优先于自动策略。失败 fallback 后显示实际使用来源，但不静默修改用户永久偏好。

### 20.3 下载行为

- “下载歌曲”对普通文件下载一个资产。
- 对 CUE Track 下载共享整轨资产，并提示其他 Track 同时可离线。
- “下载专辑”先按当前来源策略为各 LogicalTrack 冻结一份 Variant manifest，再按其中唯一 MediaAsset 去重，不按 Track 数重复下载。
- “清除下载”只清理缓存，不删除资料库和远端文件。
- pinned 资产不参与自动淘汰，除非用户明确取消固定。

## 21. 安全与隐私

### 21.1 凭据

- OAuth refresh token、DSM 密码、SID、Cookie 和网关 secret 进入 Keychain 或等价安全存储。
- SwiftData 和 UserDefaults 只保存 credential record ID。
- disconnect 删除或失效凭据；remove source 是否同时删除缓存由用户确认。
- 日志只记录 provider kind、脱敏 source token、错误类别和 operation ID。

### 21.2 网络访问

- URL、Header 和 signed query 全部视为敏感。
- 重定向必须执行 scheme、host、credential propagation 和 downgrade 策略。
- Range、Content-Length、ETag、revision 和响应类型必须验证。
- Provider Adapter 不得把任意请求 Header 或 VLC option 暴露给 UI/AppServices。

### 21.3 文件与解析

- CUE 引用、sidecar 解析和下载落盘必须执行 root containment。
- 拒绝符号链接绕过、绝对路径、`..`、NUL 和非法文件名。
- 图片解码设置字节、像素、尺寸和格式限制。
- partial 文件使用随机或哈希内部文件名，不保存远端完整路径。

## 22. 错误、状态和可观测性

标准错误至少覆盖：

```text
authenticationRequired
authenticationExpired
sourceUnavailable
rateLimited(retryAfter)
catalogCursorExpired
itemNotFound
contentRevisionChanged
streamUnsupported
accurateSeekUnsupported
downloadURLExpired
rangeUnsupported
insufficientStorage
checksumMismatch
cueMalformed
cueReferencedFileMissing
cuePathViolation
audioStreamUnavailable
cancelled
```

要求：

- 第三方错误在 Adapter 内映射，不直接传到 UI。
- retryable 和 requiresUserAction 分开。
- 同步、下载和播放准备使用 operation ID 关联日志。
- 日志不含 URL、文件绝对路径、Token、Cookie、完整 external ID 或 CUE 原始路径。
- UI 区分“没有登录”“暂时限流”“资源已删除”“需要先下载”和“格式不支持”。

## 23. 测试策略

### 23.1 Core 契约测试

每个 Provider 运行同一套 `MediaSourceContractTests`：

- source instance ID 稳定且多账号不冲突。
- 分页无遗漏、无重复。
- 全量同步中断不误删除。
- 增量游标只在事务提交后前移。
- content revision 更新使旧缓存 stale。
- auth 过期分类正确且只受控刷新一次。
- Remote access 不可编码且诊断脱敏。
- Provider 不支持的能力不会被声明。

### 23.2 Album/Track 匹配测试

- 同一发行版跨三个 Provider 合并。
- 标准版与 Deluxe 不合并。
- 同名不同艺人专辑不合并。
- 一方分轨、一方整轨 CUE 能映射到同一 LogicalTrack。
- 低置信度保留重复并等待用户确认。
- 用户手动 merge/split 后后续同步不反转。

### 23.3 CUE fixtures

至少包含：

- UTF-8 单文件 FLAC + CUE。
- 中文编码 CUE。
- 多 FILE CUE。
- `INDEX 00/01`、PREGAP 和 POSTGAP。
- 缺失音频文件。
- 文件名大小写不一致。
- Windows 路径分隔符。
- 越界 `..` 和绝对路径攻击样本。
- 时间倒退、重复 Track、无 INDEX 01。
- CUE 修改但音频 revision 未变化。
- 音频变化导致全部引用 Track 重新验证。

### 23.4 文件夹导入 fixtures

- 普通单专辑 + `cover.jpg`。
- 内嵌封面与 folder cover 优先级。
- 多个候选 cover 的确定性选择。
- 一个父目录含多张独立专辑。
- 多碟目录。
- Various Artists compilation。
- Box Set 子专辑结构。
- 大图、损坏图片和 decompression bomb 限制。
- 中断、回滚和重新导入。

### 23.5 播放测试

- whole file。
- CUE segment 起点、终点、seek、上一曲、下一曲和 repeat-one。
- Resume position 为逻辑时间。
- segment end 只推进一次队列。
- 容器音轨选择、首选流失效和 fallback。
- 缓存命中、stream、download-before-play。
- 当前 Variant 失败后选择下一 Variant。
- 相邻 Track 共享同一资产。

### 23.6 下载测试

- 同一资产并发请求只下载一次。
- CUE 多 Track 共享一个缓存记录。
- Range resume、无 Range 重启。
- signed URL 过期刷新。
- checksum、长度和 revision mismatch。
- cancel、App 重启恢复、低磁盘。
- pinned 不淘汰，LRU 只淘汰完整且未使用资产。
- 清理缓存不删除 LogicalTrack、歌单或远端文件。

### 23.7 真机与真实账号验收

- 真实 DSM 版本矩阵和脱敏 fixture。
- Google Drive / OneDrive 测试账号的 OAuth、前后台和 Token 过期。
- Wi-Fi、蜂窝、断网、网络切换和低速下载。
- 锁屏、后台音频、耳机控制、Now Playing。
- 大型 CUE 整轨、无损音频 Seek 和连续播放。
- App 终止后队列、同步和下载恢复。

## 24. 分阶段实施

### 24.1 两个工作包的边界

| 工作包 | 交付目标 | 明确包含 | 明确延后 |
| --- | --- | --- | --- |
| A：本地媒体能力升级 | 在没有任何远程来源时形成完整、可发布的本地音乐库 | 领域模型迁移、Folder Bundle、Cover、Sidecar、CUE、多文件、多碟、Compilation、Box Set、容器多音轨 | OAuth、DSM Session、远程 Catalog、远程下载缓存、Provider 设置 UI、跨 Provider 合并 |
| B：远程数据源逐个接入 | 在稳定本地模型上，每次完成一个 Provider 的浏览、同步、播放和必要下载闭环 | 当前 Provider 所需的认证、Catalog、内容交付、封面、匹配、缓存和错误恢复 | 尚未进入当前阶段的其他 Provider Adapter 及其专有依赖 |

工作包 A 的代码实现完成后设置 `Local Media vNext` 基线。工作包 B 只消费该基线，不得为了接入远程来源回头改变 CUE 时间语义、资产共享关系或队列身份；如果确实需要改变，必须先作为独立 schema/契约变更评审。

章节与工作包的主要对应关系：

| 工作包 | 主要章节 |
| --- | --- |
| A：本地 | 第 5 至 7、11 至 15、18 至 20、23 章中的本地部分 |
| B：远程 | 第 8 至 10、15 至 23 章中的远程部分 |

### 24.2 工作包 A：本地媒体能力升级

#### Phase L0：本地领域模型与迁移基线（已完成）

交付：

- 本文档和 `MODULE_INTERFACES.md` 已同步到 live implementation，不再把本地模型标记为拟议扩展。
- 定义 LogicalTrack、TrackVariant、MediaAsset、PlaybackSelection 和发行层级。
- 为内置本地来源使用稳定的 Local `MediaSourceID`；暂不实现动态来源、认证、远程 Catalog 和下载协议。
- 锁定 schema migration fixture、兼容读模型和回滚策略。

门禁：

- Core 编译和新旧模型映射测试通过。
- Architecture check 无反向依赖。
- 空库、现有库和损坏记录迁移可重复、可恢复。

#### Phase L1：普通本地文件适配新模型（已完成）

交付：

- 每个现有 Track 形成 LogicalTrack + TrackVariant + MediaAsset。
- PlaybackCoordinator 按 `Track.assetID.mediaItemID` 解析物理资产，并将 CUE/容器的 `PlaybackSelection` 交给 `PlaybackItem`；远程 Variant 选择服务延后到工作包 B。
- 队列、歌单、收藏、统计和恢复状态迁移到 LogicalTrack 身份。
- 普通单文件、单音轨的导入、播放和删除行为保持不变。

门禁：

- Core/Infrastructure/App iOS Simulator 测试、App BVT 和 App UI 回归通过；按当前范围本阶段验收关闭，真实设备验证不在本轮要求内。
- 迁移前后 Track、Album、歌单、收藏和统计数量核对通过。
- 普通文件播放、Seek、后台和冷启动恢复不回归。

#### Phase L2：文件夹 Bundle 与专辑结构（实现、Simulator 和 App UI 测试完成；本轮验收关闭）

交付：

- FolderImportBundleAnalyzer 和 analyze/execute 两阶段导入。
- 音频、CUE、cover、歌词和其他 sidecar 分类。
- 文件夹封面优先级、损坏资源隔离和导入原子性。
- 多文件专辑、Compilation、多碟、普通父文件夹和 Box Set 识别。

门禁：

- 文件夹导入 fixtures 已在 iOS Simulator 执行并通过；覆盖重复导入幂等、中断后恢复、封面选择、Disc 顺序和 Various Artists 归类。
- 实际 App UI 操作和预置文件夹 fixture 已通过；真机文件授权和正式发布验证不在本轮范围。

#### Phase L3：CUE 与容器多音轨（实现、Simulator 和 App UI 回归完成；本轮验收关闭）

交付：

- 单文件 CUE、多文件 CUE、共享 MediaAsset 和 segment playback。
- CUE 编码、FILE 引用、INDEX、PREGAP 和逻辑时长规则。
- 容器音轨发现、持久化选择和播放 fallback。
- 相邻 CUE Track 共享同一资产，但队列、收藏和统计仍以 LogicalTrack 为单位。

门禁：

- CUE 与多音轨 fixtures 已在 Infrastructure/VLCKit iOS Simulator 测试中执行并通过。
- App BVT、播放器截图、队列、手势和重启恢复回归通过；本轮不要求真机 CUE/容器媒体验收。
- CUE 起止边界、Seek、上一曲、下一曲、repeat-one、后台和连续播放的自动化契约已由 Simulator 测试覆盖；真实设备验证作为后续独立门禁。
- 共享资产删除、引用计数、重新导入、中文路径、中文 CUE 编码和跨多个音频文件均已有 Simulator 测试覆盖。

#### Phase L4：本地能力收口与发布基线（Simulator 验收完成；正式发布门禁另行）

交付：

- 完成本地大资料库、低存储、损坏文件和导入恢复验证。
- 用真实格式样本核对 VLCKit 的原始播放能力。
- 转码仅作为独立能力 Spike：保留原文件，不把全库统一转成 AAC；只有真实格式兼容性证据证明必要时，才进入后续按需派生版本设计。
- 冻结 `Local Media vNext` schema、接口和迁移文档。

门禁：

- 未配置任何远程来源时，App 的资料库、播放、队列、歌单和设置均完整可用。
- 本地能力不依赖 Keychain 远程凭据、网络或 Provider Adapter。
- 本地自动化、App BVT 和 App UI Simulator 回归达到本轮功能验收要求。
- 真机媒体矩阵、手工播放回归和正式发布验证不作为当前功能的阻塞项，另行纳入发布门禁。

### 24.3 工作包 B：远程数据源逐个接入

远程阶段不单独建设一个长期悬空的“通用远程框架”。第一个 Provider 需要什么，就在其纵向实现中加入最小共享能力；出现第二个真实实现后再确认哪些抽象值得复用。

每个 Provider 固定执行以下闭环：

1. 协议、认证、分页、revision、内容 URL、Range、限流和合规探针。
2. 保存脱敏 fixtures，定义 Provider capability matrix 和契约测试。
3. 实现当前 Provider Adapter 及其所需的最小共享服务。
4. 完成 Catalog、标准化、Album/Track 匹配、封面和播放；需要下载的 Provider 同时完成下载恢复和缓存。
5. 使用真实账号和真机验证前后台、Token/session 过期、网络切换和错误恢复。
6. 更新 live 接口与文档，关闭当前 Provider 门禁后才进入下一个 Provider。

#### Phase R1：DS Audio + 最小远程基础设施

交付：

- 先完成 DSM / Audio Station 版本探针；第三方 `synology-api` 只作协议参考。
- 随 DS Audio 落地 Source Configuration、Keychain 凭据引用、MediaSourceManager、CatalogSyncCoordinator 的最小实现。
- 完成 Catalog、封面、内容访问、session refresh、流播放和来源失效恢复。
- 首次启用来源快照、跨来源 Album/Track 匹配、Variant 选择和 fallback。
- CUE 和离线下载只在真实接口暴露对应资源且通过验收时启用；否则明确显示为不支持能力。

门禁：

- 至少一个真实 NAS 完成全量同步和重复同步幂等验证。
- 真机播放、Seek、换曲、锁屏、前后台和 session 过期通过。
- 同一专辑的本地副本与 DS Audio 副本只展示一次，手动来源选择和自动 fallback 正确。
- 不支持能力明确降级，不静默丢 Track、Disc 或元数据。

#### Phase R2：Google Drive

交付：

- OAuth、Catalog、changes、sidecar discovery 和 download-before-play。
- 随 Provider 实现 DownloadCacheAdapter、MediaDownloadCoordinator、partial/resume、校验、淘汰和 pinned cache。
- 验证本地、DS Audio 与 Google Drive 的同专辑合并和副本选择。
- 下载后的 CUE 按本地 Phase L3 语义解析并共享一个 MediaAsset 缓存记录。

门禁：

- 多 Provider 同专辑与普通分轨/CUE 混合 fixtures 通过。
- 真机后台下载、URL 过期、Token refresh、断网恢复和低存储通过。
- 清理缓存不删除 LogicalTrack、歌单、收藏或远端文件。

#### Phase R3：OneDrive

复用已经由 Google Drive 验证的 OAuth、delta 和下载上层边界，但仍需独立完成 Microsoft Graph 探针、Provider fixtures、真实账号、下载重定向、Token refresh 和真机验收。R3 完成前不启动 R4。

#### Phase R4：百度网盘

独立完成 direct-vs-gateway 决策、登录合规、目录和 revision、下载限速/重定向、Range、真实账号和 App Store 风险评估。不得把阿里、123 或天翼放入同一实现 Phase。

#### Phase R5：阿里云盘

在 R4 门禁关闭后单独启动，重新验证官方能力、授权方式、下载 URL 生命周期、限流和合规性；只复用已经由至少两个 Provider 证明稳定的上层契约。

#### Phase R6：123 云盘

单独执行协议探针、direct-vs-gateway 决策、Adapter、fixtures、真实账号和真机验收，不与其他国内网盘共享完成状态。

#### Phase R7：天翼云盘

作为独立 Provider Phase 完成相同闭环。即使使用网关，也必须验证网关会话、远端 revision、下载恢复、错误映射、隐私和部署维护边界。

任何 Provider 因官方能力、合规或维护成本无法继续时，应将该 Phase 明确标记为 paused/rejected 并记录证据；这不阻塞已完成 Provider 的发布，但不能把未完成 Provider 计入支持列表。

## 25. 实施门禁与完成定义

任何 Phase 只有同时满足以下条件才可标记完成：

- 源码已实现。
- 对应 schema 和迁移已实现。
- 契约、fixture 和回归测试通过。
- Architecture check 通过。
- 敏感信息脱敏检查通过。
- 文档接口与 live source 一致。
- 需要真实设备或账号的能力才必须完成对应的真实环境验收；当前本地能力不依赖真实设备，按 Simulator 结果验收，未纳入本轮范围的门禁需明确标记 deferred/open。
- 不把 build success、Simulator success 或 fixture success 表述为真实 Provider 已验证。

工作包级门禁：

- 工作包 A 的完成不以任何远程账号或网络能力为前提；其结果必须可以先行发布。
- 工作包 A 未冻结 `Local Media vNext` 基线前，不开始正式 Provider 实现。
- 工作包 B 中一个 Provider 对应一个独立 Phase、capability matrix、测试证据和完成状态。
- 当前 Provider 未完成或未明确标记 paused/rejected 前，不开始下一个 Provider 的正式实现。
- 后续 Provider 可以复用共享服务，但不得以复用为理由跳过当前 Provider 的真实协议和真机验收。

最终产品级验收：

- 用户可配置多个同类型来源账号。
- 同一 AlbumRelease 只显示一次并展示来源摘要。
- 同一 LogicalTrack 可在分轨文件、CUE 片段和容器音轨间选择。
- 离线时自动选择有效缓存，在线失败时可解释地 fallback。
- 文件夹封面、Compilation、多碟和 Box Set 归类稳定。
- CUE 下载按共享 MediaAsset 去重，进度和删除行为正确。
- 来源失效不会破坏用户歌单、收藏和历史。
- App、队列和数据库中不存在持久化远程 URL、Token、Cookie 或 Header。

## 26. 实现前仍需用真实证据锁定的事项

以下内容不能仅靠架构推断，必须在对应 Phase 开始前验证：

- 不同 DSM / Audio Station 版本的实际 API、分页、封面、流和 session 行为。
- DS Audio 是否暴露原始 CUE/文件夹 sidecar，还是只暴露服务端逻辑 Track。
- VLCKit 对本地和远程资源的 segment end 精度，以及音频流稳定 ID 能力。
- Google Drive、OneDrive 当前 OAuth、changes/delta 和下载重定向要求。
- 百度、阿里、123、天翼的官方能力、登录方式、限流和 App Store 合规性。
- 中文 CUE 编码样本和 pregap 的期望产品行为。
- 大型资料库迁移和 Album/Track matching 的性能阈值。

这些事项未验证前可以保留 Adapter 扩展点，但不得把猜测写成已经支持的能力。
