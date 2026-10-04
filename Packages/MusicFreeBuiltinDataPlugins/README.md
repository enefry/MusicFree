# 内置歌词与歌曲信息插件

按服务提供六个独立 SwiftPM product/target，全部只依赖 MusicFreePluginAPI 和包内 DataPluginSupport。MusicKit 使用系统 MusicKit；HTTP 服务保留原有响应解码、请求节流、封面缓存、匹配和错误分类。插件无需导入 MusicFreeCore、LocalMediaAdapter、Runtime 或宿主 UI。

| Product | PluginID | 能力 |
| --- | --- | --- |
| LRCLIBLyricsPlugin | builtin.lyrics.lrclib | 歌词 |
| MetadataServerLyricsPlugin | builtin.lyrics.metadataServer | 歌词 |
| MusicKitMetadataPlugin | builtin.metadata.musicKit | 歌曲信息、封面 |
| MusicBrainzMetadataPlugin | builtin.metadata.musicBrainz | 歌曲信息、封面 |
| MetadataServerMetadataPlugin | builtin.metadata.metadataServer | 歌曲信息、封面 |
| DiscogsMetadataPlugin | builtin.metadata.discogs | 歌曲信息、封面 |

应用通过 HostBridge 的 BuiltinDataPluginRegistrationProvider 注册工厂，授权后才创建客户端。配置沿用原 Info.plist 服务地址、超时、User-Agent 和可选 Discogs token；缺少配置的服务保留描述并显示不可用。LYRICS_DISABLED / METADATA_SERVER_DISABLED 在组合根控制对应注册。

本阶段保留 LocalMediaAdapter 内的六个旧 Provider、原设置和旧调用入口。新 PluginID 与旧 ProviderID 分开，默认关闭且不允许加载，不自动迁移旧同意或偏好。启用步骤：在设置的插件管理中启用插件、允许加载并授权，同时单独接受应用隐私政策。验证同一服务的新路径时可关闭旧 Provider，避免旧链优先返回。

歌词只返回 SDK 原文 DTO，宿主保留原 LRC 解析、offset 和本地歌词优先逻辑。歌曲信息返回请求字段的 patch 和封面引用，宿主继续使用既有目录匹配与补全事务，保留用户编辑。MusicKit 的系统授权状态和请求经 MetadataPlugin 契约传递；网络/限流/HTTP 错误保持代码、状态和重试时间。插件不接收媒体路径或库对象；Metadata Server 插件使用查询中已有时长，旧 Provider 的可选本地文件重新 probe 仍仅保留在旧路径。

包内实现从旧 Provider 提取；原代码暂时保留，后续协议修复需要明确同步范围。DataPluginSupport 中的目录 query/matcher 和文本修复是包内实现支持，不属于公共 SDK 契约。

离线测试：

```sh
swift test --package-path Packages/MusicFreeBuiltinDataPlugins --scratch-path .noindex/swiftpm/BuiltinDataPlugins
```
