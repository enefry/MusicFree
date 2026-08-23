# MusicFreeCore

路径：`Packages/MusicFreeCore`

`MusicFreeCore` 定义业务稳定边界。它不实现具体文件访问、SwiftData、Apple 系统服务或 VLCKit，而是提供领域模型、公开协议和跨功能协调服务。

## Targets

| Target | 功能 |
| --- | --- |
| `MusicDomain` | Track、Album、Artist、Playlist、Lyrics、Artwork、播放统计、媒体身份和本地媒体图等领域模型。 |
| `MediaSourceAPI` | 媒体导入、探测、元数据读取、Artwork 写入、播放资源和媒体源注册协议。 |
| `LibraryAPI` | 资料库查询、分页、排序、事务、歌单、播放历史、元数据覆盖和 enrichment 记录协议。 |
| `PlaybackAPI` | 播放引擎、播放项、队列、播放能力、速度、音效和队列持久化协议。 |
| `SystemIntegrationAPI` | 音频会话、Now Playing、远程控制和系统集成能力协议。 |
| `SettingsAPI` | 应用、导入、歌词/元数据 Provider、播放、睡眠定时器、存储和隐私设置模型。 |
| `AppServices` | Import、Library、Playback、Playlist、Settings、Lyrics、Artwork、Metadata Enrichment 和 Storage Maintenance 协调器。 |
| `MusicTestSupport` | Fake source、Fake importer、Fake playback engine、内存 Repository、测试时钟和 fixture 工具。 |

## 关键职责

- 维护跨模块共享的稳定 ID 和用户意图，不把临时 URL、Header 或第三方对象泄漏到持久化模型。
- 通过 AppServices 串行化导入、删除、封面维护和其他相互影响的写操作。
- 将“能力未声明”作为硬边界，UI 不能调用播放引擎未声明的功能。
- 为本地歌词、可选在线 Provider、元数据覆盖和播放队列提供可测试的契约。

## 非职责

- 不直接读写文件、调用 MusicKit/Discogs/LRCLIB、访问 SwiftData 或创建 SwiftUI 页面。
- 不假设远程 Provider 已经实现；远程来源仍必须通过独立 Adapter、fixture、真实账号和真机门禁。
