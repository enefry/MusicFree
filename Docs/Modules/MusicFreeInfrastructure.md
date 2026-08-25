# MusicFreeInfrastructure

路径：`Packages/MusicFreeInfrastructure`

`MusicFreeInfrastructure` 把 Core 的协议接到本地文件、SwiftData、UserDefaults 和 Apple 系统服务。它可以依赖 Core，但不应把实现细节反向带入 Core 或 UI。

当前构建配置中 Metadata Server 通过 `METADATA_SERVER_DISABLED` 关闭；MusicKit、MusicBrainz、Discogs 和 LRCLIB 的源码适配器仍由 App 组装，但是否请求取决于 Provider 设置、隐私同意和运行时能力。

## Targets

| Target | 功能 |
| --- | --- |
| `LocalMediaAdapter` | Documents/文件夹导入、staging、内容哈希、媒体探测、元数据/封面读取、本地歌词、CUE、文件管理、存储维护和可选 Metadata Provider。 |
| `LibraryPersistenceAdapter` | SwiftData 资料库、播放历史、播放队列、歌单和 `MetadataEnrichmentRecord` 的持久化与迁移。 |
| `AppleSystemAdapter` | AVAudioSession 路由/中断、Now Playing 发布、远程控制、系统能力探测和诊断。 |
| `PreferencesPersistenceAdapter` | UserDefaults 设置 Envelope、版本迁移、变更流和设置 Repository。 |

## Provider 边界

本地适配器可包含 MusicKit、MusicBrainz、Discogs、LRCLIB 和 Metadata Server 的具体实现，但 Provider 是否启用、是否发送请求和是否需要用户同意由设置与 AppServices 协调。Provider 不得上传音频文件、绝对路径、凭据或完整本地资料库。

## 文件与事务原则

- 导入先写 staging，完成哈希、探测和资料库事务后才进入可播放状态。
- App 托管媒体和共享 Documents 原文件有不同的所有权，删除语义不能混用。
- Artwork、歌词 sidecar、pending removal 和存储清理必须遵循资料库引用关系，并在失败时保留可诊断状态。
- 资料库、导入和维护之间的生命周期协调由 Core 的 AppServices 负责，Adapter 不自行改变用户可见状态。
