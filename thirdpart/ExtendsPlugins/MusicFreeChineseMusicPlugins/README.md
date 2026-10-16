# QQ 音乐与网易云音乐扩展插件

独立 SwiftPM 包，提供四个歌词/歌曲信息插件，保持原模块名、PluginID 和授权行为。宿主通过 `MusicFreePluginHostBridge` 依赖本包，并由 `BuiltinDataPluginRegistrationProvider` 注册工厂。

| Product | PluginID | 能力 |
| --- | --- | --- |
| NetEaseLyricsPlugin | builtin.lyrics.netEase | 网易云歌词、翻译、YRC 逐字时间 |
| NetEaseMetadataPlugin | builtin.metadata.netEase | 网易云歌曲信息、封面 |
| QQMusicLyricsPlugin | builtin.lyrics.qqMusic | QQ 普通 LRC 歌词、翻译 |
| QQMusicMetadataPlugin | builtin.metadata.qqMusic | QQ 歌曲信息、封面 |

`ChineseMusicCatalogSupport` 共享两家服务的协议、配置和传输实现。依赖根目录下的 `Packages/MusicFreePluginAPI`，并复用 `Packages/MusicFreeBuiltinDataPlugins` 导出的 `DataPluginSupport` 目录匹配与文本处理工具；不依赖宿主业务模块。

四个新增插件默认关闭。在设置的插件管理中分别启用能力、允许加载并授予服务许可；需要登录时进入该插件的「Cookie 配置」。Cookie 存于按插件隔离的 Keychain 记录，不写入普通配置，不发送给封面服务器。LYRICS_DISABLED 同样禁用两个新增歌词插件。ReferencePluginRegistrationProvider、测试音频生成和参考音频工厂只在 DEBUG 编译。

协议参考 `thirdpart/163MusicLyrics-master`：网易云采用双层 AES-CBC 与公开 RSA 协议参数，并处理海外搜索结果解码；QQ 使用同一搜索服务的移动方法及字符串参数，兼容当前响应结构（桌面方法在实测中返回 2001）。QQ 歌词采用普通 Base64 LRC 接口，不包含 QRC 解密。元数据包含服务返回的标题、艺人、专辑、年份、曲号、碟号和封面；只返回调用方请求的补全字段，匹配证据始终保留。

2026-10-10 匿名实测：QQ 的歌词、年份、曲号和封面经 Swift 插件完整查询成功；网易云搜索返回 50000005，需要配置有效登录 Cookie。请求失败会保留为错误，不伪装成无匹配。网易云登录后的真实查询尚未验证。来源及许可证见 [第三方声明](../../../ThirdPartyNotices/163MusicLyrics-Apache-2.0.txt)。

从工程根目录运行离线测试：

```sh
swift test --package-path thirdpart/ExtendsPlugins/MusicFreeChineseMusicPlugins --scratch-path .noindex/PluginSystem/ChineseMusic
```

可选 QQ 实网回归（不使用 Cookie）：

```sh
MUSICFREE_LIVE_CATALOG_CHECK=1 swift test --package-path thirdpart/ExtendsPlugins/MusicFreeChineseMusicPlugins --scratch-path .noindex/PluginSystem/ChineseMusic
```
