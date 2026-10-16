# 内置歌词与歌曲信息插件

按服务提供六个独立 SwiftPM plugin product/target，只依赖 MusicFreePluginAPI 和包内支持模块。MusicKit 使用系统 MusicKit；HTTP 服务保留响应解码、封面延迟获取、匹配和错误分类。插件无需导入 MusicFreeCore、LocalMediaAdapter、Runtime 或宿主 UI。

| Product | PluginID | 能力 |
| --- | --- | --- |
| LRCLIBLyricsPlugin | builtin.lyrics.lrclib | 歌词 |
| MetadataServerLyricsPlugin | builtin.lyrics.metadataServer | 歌词 |
| MusicKitMetadataPlugin | builtin.metadata.musicKit | 歌曲信息、封面 |
| MusicBrainzMetadataPlugin | builtin.metadata.musicBrainz | 歌曲信息、封面 |
| MetadataServerMetadataPlugin | builtin.metadata.metadataServer | 歌曲信息、封面 |
| DiscogsMetadataPlugin | builtin.metadata.discogs | 歌曲信息、封面 |

应用通过 HostBridge 的 BuiltinDataPluginRegistrationProvider 注册工厂，授权后才创建客户端。配置沿用原 Info.plist 服务地址、超时、User-Agent 和可选 Discogs token；缺少配置的服务保留描述并显示不可用。LYRICS_DISABLED / METADATA_SERVER_DISABLED 在组合根控制对应注册。

生产组合根结合 [QQ 音乐与网易云音乐扩展包](../../thirdpart/ExtendsPlugins/MusicFreeChineseMusicPlugins/README.md) 注册十个插件 Provider；本包提供其中六个，旧 LocalMediaAdapter 实现继续保留。原有描述符的 dataProviderID 沿用原 Provider ID，旧设置、排序、服务同意与记录可以继续使用；首次载入迁移旧偏好并持久化，已有插件禁用、加载阻止或撤权保持有效。应用隐私、服务同意与插件执行授权分别检查。迁移详情见 [验证记录](../../Docs/Testing/1.4_BUILTIN_PLUGIN_MIGRATION_2026-10-03.md)。

歌词只返回 SDK 原文 DTO，宿主保留原 LRC 解析、offset 和本地歌词优先逻辑。歌曲信息返回请求字段的 patch 和封面引用，宿主继续使用既有目录匹配与补全事务，保留用户编辑。MusicKit 的系统授权状态和请求经 MetadataPlugin 契约传递；网络/限流/HTTP 错误保持代码、状态和重试时间。插件不接收媒体路径或库对象；Metadata Server 的可选本地时长 probe 由宿主适配器执行后加入 DTO，插件不接触媒体路径。系统授权检查可在 Provider 启用前通过 Runtime 的独立授权回调进行，不构造数据客户端；加载许可和隐私授权仍有效。

包内实现从旧 Provider 提取；原代码暂时保留，后续协议修复需要明确同步范围。DataPluginSupport 中的目录 query/matcher 和文本修复作为 library product 供扩展插件复用，不属于公共 SDK 契约。

离线测试：

```sh
swift test --package-path Packages/MusicFreeBuiltinDataPlugins --scratch-path .noindex/PluginSystem/BuiltinData
```
