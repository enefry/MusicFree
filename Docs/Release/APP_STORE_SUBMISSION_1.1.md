# MyMusic: Local Player 1.1.x App Store 提审资料

> 生成日期：2026-08-23
>
> 目标版本：`1.1.10`
>
> 当前源码构建配置：`1.1.10 (2026082207)`
>
> 当前状态：资料已生成，但尚未达到可提交状态。最终 Archive、签名 entitlement、真机验收和 App Store Connect questionnaire 必须完成后才能提交。

## 0. 提交前结论

当前 checkout 可以作为 1.1.x 提审资料来源，但不能直接把现有 `dist/` 中的旧产物当作本次提交包：

| 项目 | 当前证据 | 结论 |
| --- | --- | --- |
| 源码版本 | `basic_config.xcconfig`：`APP_VERSION = 1.1.10` | 目标版本为 1.1.10 |
| 源码构建号 | `BUILD_VERSION = 2026082207` | 仅是当前配置，尚未证明已有对应 Archive/IPA |
| 最近归档 | `1.1.6 (2026082203)` | 旧包，不得用于 1.1.10 提审 |
| 最近 IPA | `1.1.9 (2026082206)` | 旧包，不得用于 1.1.10 提审 |
| MusicKit entitlement | 当前 `App/MusicFree.entitlements` 为空 | 必须在最终签名包中确认 capability/profile 后才能宣称 1.1 MusicKit 可用 |
| Metadata Server | 当前配置为 `METADATA_SERVER_DISABLED` | 提审说明不得把 Metadata Server 写成已启用服务 |
| 隐私政策 | `Docs/PRIVACY_POLICY_v1.1.0.md`，App 内 URL 已指向该版本 | 发布前确认公网 URL 无需登录即可访问 |
| App Store 截图 | iPhone 6.5-inch、iPad 12.9-inch、3 个 App Preview 已存在 | 必须使用最终 Release 包重新确认，不直接复用旧 Debug 证据 |

### 0.1 硬门禁

- [ ] 用当前源码生成 `1.1.10 (2026082207)` 的 signed Release Archive 和 IPA。
- [ ] 检查 Archive 的 `CFBundleShortVersionString`、`CFBundleVersion`、Bundle ID 和签名 entitlement。
- [ ] 如果本版本要宣称 MusicKit 元数据补充，最终包必须包含已批准的 MusicKit capability/profile，并完成真机授权、catalog 搜索和封面下载验证。
- [ ] 若 MusicKit entitlement 尚未准备好，不能提交包含该功能承诺的 1.1 版本；应先修复签名配置或收窄版本范围。
- [ ] 在 App Store Connect 完成 App Privacy questionnaire；不要沿用旧资料中的 “No Data Collected” 结论。当前源码包含可选 Provider 网络请求，且隐私清单声明了 `OtherDataTypes` / App Functionality。
- [ ] 完成出口合规问卷。`Info.plist` 中的 `ITSAppUsesNonExemptEncryption = false` 只能作为源码证据，不能替代 App Store Connect 最终判断。
- [ ] 用最终 Release 包重新录制/确认截图和 App Preview，确认没有 BVT、测试歌单名、测试文件名或未经授权的媒体信息。
- [ ] 完成 TestFlight 安装、升级、全新安装、首次启动和回滚/恢复验证。

## 1. App Store Connect 基本信息

| 字段 | 提交值 | 备注 |
| --- | --- | --- |
| App Name | `MyMusic: Local Player` | English (U.S.)；沿用现有商店命名 |
| Subtitle | `Import and play your music` | English (U.S.) |
| Bundle ID | `win.tools4me.music` | 来自 `project.yml` |
| Primary Category | `Music` | `public.app-category.music` |
| Secondary Category | 留空，除非发布人确认 | 不从源码推断 |
| Version | `1.1.10` | 来自当前 `APP_VERSION` |
| Build | `2026082207` | 目标构建号；最终 Archive 后重新核对 |
| Minimum OS | `iOS/iPadOS 26.0+` | 来自工程 deployment target |
| Supported Devices | `iPhone and iPad` | `TARGETED_DEVICE_FAMILY = 1,2`；无 Apple Watch target |
| Price / Availability | 待发布人填写 | 不由源码决定 |
| In-App Purchases | `None planned` | 提交前在 ASC 再确认 |
| SKU | 待发布人填写 | 一旦确定应保持稳定 |

## 2. English (U.S.) 商店文案

### Name

```text
MyMusic: Local Player
```

### Subtitle

```text
Import and play your music
```

### Promotional Text

```text
A focused local music player with optional metadata, artwork, and lyrics providers.
```

### Description

```text
MyMusic: Local Player is a focused player for the audio files you already own.

Import audio files from Files or Finder file sharing, then browse your library by songs, artists, albums, genres, folders, favorites, playlists, and playback history.

Make listening your own:

- Create and manage playlists
- Build a queue with play next, add to queue, shuffle, and repeat
- Continue listening with background audio and Lock Screen controls
- Seek through tracks and adjust playback speed
- Tune playback with an equalizer
- Edit metadata, lyrics, and artwork as local library overrides
- Optionally enrich missing metadata and artwork through user-enabled Providers
- Choose light, dark, or system appearance
- Switch between available app icon styles

MyMusic: Local Player is designed for a personal, local library. Basic importing and playback do not require an account or online service. Optional metadata and lyrics Providers are disabled by default and require the app privacy policy and the relevant Provider disclosure to be accepted before they can send matching information.

The app does not provide a streaming catalog, cloud sync, podcasts, radio, CarPlay, Siri, or an account-based music service.
```

### Keywords

```text
local,music,player,audio,offline,metadata,artwork,lyrics,playlist,equalizer
```

### What's New in This Version

```text
Version 1.1 adds optional metadata and artwork enrichment for your local library.

- Enrich missing song metadata and artwork after import or through a manual scan
- Keep existing metadata, user edits, favorites, and playback history unchanged
- Review and accept the app privacy policy and each Provider disclosure before online requests
- See clearer Provider status, scan progress, cancellation, retry, and failure results
- Continue using local import, playback, lyrics editing, playlists, and background audio without an account

MusicKit is used for catalog metadata and artwork only; it does not provide lyric text in this release.
```

如果最终签名包没有 MusicKit entitlement，提交前必须删除最后一段的 MusicKit 宣称，并同步调整 1.1 版本范围；推荐先完成 entitlement 和真机门禁再使用这版文案。

## 3. App Review Information

### 3.1 Review Notes

```text
MyMusic: Local Player is a local music player for audio files supplied by the reviewer. No account, login, server account, or demo credentials are required.

Main local flow:
1. Launch the app and open Library.
2. Tap the add/import action and choose an audio file from Files, or place an audio file in the app's Documents folder through Finder file sharing.
3. Open Songs and tap the imported track to play it.
4. Use the mini-player to open Now Playing. Test play/pause, seeking, queue, favorite, playback speed, and the equalizer.
5. Open Playlists to create a playlist and add the imported track.
6. Open Settings to review appearance, app icons, storage, privacy, and Provider controls.

Version 1.1 optional Provider flow, if the submitted signed build includes the corresponding capability and the service is available:
1. Open Settings > Metadata Enrichment.
2. Read and accept the app privacy policy only if you want to test an online Provider.
3. Enable the Provider disclosure for the selected Provider.
4. Enable the Provider and use Scan and Enrich on a local track with missing metadata.
5. Confirm that the scan can be cancelled and that existing user metadata is not overwritten.

All Providers are disabled by default. Online Provider failures must not prevent local import or offline playback. MusicKit is used for metadata and artwork only, not for lyric text. The app does not upload audio files, complete local file paths, or the full music library.

If online Provider access is unavailable in the review environment, please review the complete local import and playback flow; the app remains usable without any online Provider.
```

### 3.2 App Review Contact

| 字段 | 填写值 |
| --- | --- |
| First name / Last name | 发布人填写 |
| Phone | 发布人填写 |
| Email | 发布人填写 |
| Review attachment | 最终 Release build、必要时附一份无版权争议的 demo media 说明 |
| Demo account | `Not required` |
| Special hardware | `None required for the local flow` |

### 3.3 Review 说明边界

- 不要向审核员承诺当前被 `METADATA_SERVER_DISABLED` 隐藏的 Metadata Server。
- 不要把 LRCLIB 或其他 Provider 描述为 Apple Music 服务。
- 不要把本地歌词编辑、`.lrc` 导入和在线歌词 Provider 混写成“Apple Music 歌词”。
- 不要把 Simulator、旧 Archive 或旧 IPA 写成当前提交包的验收证据。

## 4. URLs、隐私与权利

| 字段 | 提交值 | 状态 |
| --- | --- | --- |
| Support URL | `https://github.com/enefry/MusicFree/issues` | 确认页面可公开访问，并包含实际联系渠道 |
| Marketing URL | `https://github.com/enefry/MusicFree` | 可选；发布前确认仓库对外可读 |
| Privacy Policy URL | `https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.1.0.md` | 与 App 内 `PrivacyPolicyURLs.app` 一致 |
| LRCLIB disclosure | App 内本地资源 `PRIVACY_POLICY_LRCLIB.html`；仓库说明见 [`../PRIVACY_POLICY_LRCLIB.md`](../PRIVACY_POLICY_LRCLIB.md) | 不是 LRCLIB 官方隐私政策 |
| Copyright | `(c) 2026 enefry` | 发布人确认权利主体和年份 |

### 4.1 App Privacy questionnaire 工作底稿

Apple 要求 App Store Connect 的隐私回答覆盖 App 自身和集成的第三方代码/服务。当前项目的实际网络范围包括：

| 处理方 | 触发条件 | 可能发送的信息 | 当前产品控制 |
| --- | --- | --- | --- |
| MusicKit / Apple Music | 用户开启 MusicKit Provider，且最终包具备对应 capability | 歌曲名称、艺人和目录匹配信息 | 默认关闭；需应用隐私政策和 Provider disclosure 同意 |
| MusicBrainz / Cover Art Archive | 用户开启对应 metadata Provider | 歌曲名称、艺人、匹配后的 release 信息 | 默认关闭；需 Provider 同意 |
| Discogs | 用户开启对应 metadata Provider，且构建配置提供 token | 歌曲名称、艺人；token 仅发给 Discogs | 默认关闭；需 Provider 同意 |
| LRCLIB | 用户开启 lyrics Provider，播放页按需获取或预下载 | 歌曲名称、艺人，以及可用时的专辑和时长 | 默认关闭；需 Provider disclosure 同意 |
| Metadata Server | 仅在构建没有 `METADATA_SERVER_DISABLED` 时可见/可用 | 由 Metadata Server 合约定义的歌曲匹配信息 | 当前构建配置禁用 |

提交人必须在 ASC 逐项确认：

- [ ] 是否有 App 或第三方 Provider 从 App 收集数据。
- [ ] 收集的数据类型、是否与用户关联、是否用于跟踪。
- [ ] 请求 IP、User-Agent、Provider 日志和第三方合作方处理方式是否需要在 questionnaire 中反映。
- [ ] 本地音频、完整路径、完整资料库和本地诊断是否始终不离开设备。
- [ ] 最终 Release 包中的第三方框架、隐私清单和网络配置与上述回答一致。
- [ ] 发布后如果 Provider 范围或数据处理改变，及时更新 ASC 隐私回答和版本隐私政策。

不要直接复制历史提审草稿中的 `No Data Collected`。Apple 官方说明要求隐私回答包含集成第三方代码/合作方的实际数据处理，并要求回答保持准确、及时更新。

### 4.2 出口合规

- [ ] 在 App Store Connect 对当前 build 完成 Export Compliance 问卷。
- [ ] 核对 `ITSAppUsesNonExemptEncryption = false` 与最终二进制和依赖实际行为一致。
- [ ] 如果 Apple 要求文档，先完成 Encryption 页面审查，再把批准信息关联到 build。

### 4.3 内容和第三方权利

- [ ] App icon、截图中的歌曲名/艺人名/专辑信息和 demo audio 有可证明的使用权。
- [ ] `ThirdPartyNotices/`、MusicFreeVLCKit 源码/重新链接材料和许可证文本已随发布材料准备。
- [ ] 商店文案不暗示 Apple Music 订阅、Apple Music 歌词或流媒体目录能力。

## 5. 截图与 App Preview

### 5.1 当前仓库资产

| 目标 | 资产位置 | 当前数量 | 提交前动作 |
| --- | --- | ---: | --- |
| iPhone 6.5-inch | [`../../Design/AppStore/iPhone-6.5-inch/`](../../Design/AppStore/iPhone-6.5-inch/) | 7 张 PNG | 用最终 1.1.10 Release 包重新确认 |
| iPad 12.9-inch | [`../../Design/AppStore/iPad-12.9-inch/`](../../Design/AppStore/iPad-12.9-inch/) | 5 张 PNG | 用最终 Release 包重新确认 |
| iPhone App Preview | [`../../Design/AppStore/AppPreviews/`](../../Design/AppStore/AppPreviews/) | 3 个 MP4 | 确认内容与 1.1.10 功能一致 |
| 6.9-inch historical | [`../../Design/AppStore/6.9-inch/`](../../Design/AppStore/6.9-inch/) | 4 张 PNG | 仅作历史参考，不作为当前集 |

当前素材包含 1.0/本地播放器场景，未证明已经覆盖 1.1 Provider 同意、扫描进度和元数据补充结果。若商店要突出 1.1 功能，应新增至少一张不含真实个人资料的 Provider 设置/扫描完成场景截图，并用最终 Release build 重新生成。

### 5.2 截图门禁

- [ ] 图片无透明通道、无 BVT 标记、无测试歌单/文件名、无调试 overlay。
- [ ] iPhone 使用 Apple 当前接受的目标尺寸；现有 6.5-inch 资产为 `1284 x 2778` portrait，提交前在 Media Manager 确认适配当前设备组。
- [ ] iPad 资产尺寸和方向与 App Store Connect 当前 slot 一致。
- [ ] 每种设备上传 1 到 10 张截图，顺序先展示核心本地播放，再展示 1.1 亮点。
- [ ] App Preview 只展示最终产品行为，时长、方向、编码和音频/版权材料符合 App Store Connect 要求。

推荐顺序：

1. Library / local import
2. Songs / metadata and collection actions
3. Now Playing / queue and background controls
4. Metadata Enrichment / Provider consent and scan
5. Settings / privacy and playback controls
6. Playlist or equalizer

## 6. 最终构建与上传流程

### 6.1 生成构建

在确认 `basic_config.xcconfig` 的版本和构建号后运行：

```sh
PUBLISH_TF_NO_UPLOAD=1 ./publish_tf.sh
```

上传前必须从新生成的 Archive/IPA 中读取并记录：

```text
CFBundleShortVersionString = 1.1.10
CFBundleVersion            = 2026082207 或归档脚本生成的新 build number
CFBundleIdentifier         = win.tools4me.music
CFBundleDisplayName        = MyMusic
```

如果 Archive hook 自动推进了 `basic_config.xcconfig` 的 build/version，先保存本次 Archive 的实际值，再决定是否提交配置文件变化；不要把“下一版配置”误写成“已上传 build”。

### 6.2 归档后证据

- [ ] `MusicFree.xcarchive/Info.plist` 与 App 内 `Info.plist` 版本一致。
- [ ] `codesign` entitlement 与预期 capability 一致，特别是 MusicKit。
- [ ] 最终 IPA 可安装、可启动、可升级，并且不是 BVT 注入构建。
- [ ] App Store Connect 中上传后选择唯一目标 build；不要把旧 `1.1.6`、`1.1.7`、`1.1.8` 或 `1.1.9` 误关联到本次版本。
- [ ] Build 的 Missing Compliance 状态已处理。
- [ ] TestFlight internal test 通过后，再提交 App Review。

### 6.3 上传结果记录

| 项目 | 结果 |
| --- | --- |
| Archive path | 发布人填写 |
| IPA path | 发布人填写 |
| Archive version/build | 发布人填写 |
| SHA-256 | 发布人填写 |
| Upload time | 发布人填写 |
| App Store Connect build ID | 发布人填写 |
| Export compliance result | 发布人填写 |
| TestFlight install result | 发布人填写 |
| Review submission time | 发布人填写 |

## 7. 资料来源

- [`../Versions/1.1.0_FEATURE_REQUIREMENTS.md`](../Versions/1.1.0_FEATURE_REQUIREMENTS.md)：1.1 功能范围、隐私边界和验收条件。
- [`../PRIVACY_POLICY_v1.1.0.md`](../PRIVACY_POLICY_v1.1.0.md)：应用隐私政策。
- [`../PRIVACY_POLICY_LRCLIB.md`](../PRIVACY_POLICY_LRCLIB.md)：LRCLIB Provider disclosure。
- [`../Testing/MANUAL_TEST_CASES.md`](../Testing/MANUAL_TEST_CASES.md)：真实设备和 Release 验收门槛。
- [`../Issues/ISSUES_AND_FIXES.md`](../Issues/ISSUES_AND_FIXES.md)：当前开放问题和修复状态。
- [`../../basic_config.xcconfig`](../../basic_config.xcconfig)：版本、构建号、服务开关和应用元数据。
- [`../../App/MusicFree.entitlements`](../../App/MusicFree.entitlements)：当前 capability 配置。
- [`../../App/PrivacyInfo.xcprivacy`](../../App/PrivacyInfo.xcprivacy)：当前隐私清单。
- [Apple App Store Connect platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Apple App Store Connect manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [Apple App Store Connect screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Apple App Store Connect overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Apple App Store Connect choose a build to submit](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit)
