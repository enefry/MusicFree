# MyMusic: Local Player 1.3.x App Store 提审资料

准备日期：2026-09-30（America/New_York）。范围：当前 `feature/1.3.0_dev` 工作区的 1.3 功能，包含尚未提交的音频转换调度改动。

英文商店名沿用现有资料；中文文案作为对照或新增中文本地化的候选。以下文案可复制到 App Store Connect（ASC），但版本与 build 必须按最终提交包填写。此文档准备不代表已归档、上传或提交审核。

## 1. 版本与应用信息

| 字段 | 当前核对结果 | 提交时使用 |
| --- | --- | --- |
| App Name | `MyMusic: Local Player` | 沿用现有 ASC 名称 |
| Display Name | `MyMusic` | 来自应用配置 |
| Bundle ID | `win.tools4me.music` | 正式包；不要选择 `.debug` 包 |
| Category | `Music` | Secondary Category 沿用 ASC |
| Supported Devices | iPhone、iPad | 源码及最新本地 IPA 均为 `1,2` |
| Minimum OS | iOS/iPadOS 17.1 | 已核对工程和最新本地 IPA；不是旧资料的 26.0 |
| 当前源码配置 | `1.3.2 (2026093002)` | 表示当前配置，不是已上传 build |
| 最新本地导出 IPA | `1.3.1 (2026093001)` | `dist/MusicFree-20260930-131727.ipa`；只是候选包 |
| ASC Version / Build | 尚未核对 ASC | 与最终选中的 build 的版本一致 |
| Storefront Language | 现有素材说明为 English (U.S.) | 保留现有本地化；中文内容可按需新增 |
| 价格、地区、年龄分级 | 不从源码推断 | 核对现有 ASC 设置和本版内容问卷 |
| Review Contact | 本地资料没有联系人信息 | 在 ASC 保留或补齐真实姓名、电话和邮箱 |

归档 scheme 的 pre-action 推进 build number，post-action 推进 patch version。归档后配置文件可能已经显示下一版本；用包内 `CFBundleShortVersionString` / `CFBundleVersion` 记录本次产物。不要为了提审文案把版本固定为 `1.3.0`，也不要从 IPA 文件名推断包内版本。

最新本地候选包已核对：Google Drive OAuth 为 `YES`，嵌入动态框架为 `FFmpegAudio.framework`，第三方声明列出 FFmpeg 8.1.2 / FFmpegAudioKit 0.0.4，`ITSAppUsesNonExemptEncryption = false`。这些只证明该 IPA 的配置与资源，不证明它包含当前全部未提交改动、签名有效、可分发或已在 ASC 处理完成。

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

可直接复制文件：[`1.3/promotional-text.en-US.txt`](1.3/promotional-text.en-US.txt)。

```text
Make your music library your own: play local audio, edit song details, convert supported lossless files to AAC or ALAC, and switch Chinese lyrics between scripts.
```

### Description

可直接复制文件：[`1.3/description.en-US.txt`](1.3/description.en-US.txt)。

```text
MyMusic: Local Player helps you enjoy and organize the audio files you own on iPhone and iPad.

Import music from Files or Finder file sharing. Browse songs, albums, artists, genres, folders, favorites, playlists, and playback history. Local importing and playback work without an account.

LISTEN YOUR WAY
- Play common audio formats, including MP3, AAC, FLAC, ALAC, WAV, and AIFF
- Play individual tracks from CUE albums
- Build a queue with play next, shuffle, and repeat
- Keep listening in the background and control playback from the Lock Screen
- Adjust playback speed, use the equalizer, and set a sleep timer

ORGANIZE YOUR LIBRARY
- View audio format, sample rate, bit depth, and other file details
- Edit song, album, and artist information, artwork, and lyrics in your local library
- Browse artists with an alphabetical index
- Convert saved Chinese lyrics between Simplified and Traditional Chinese

CONVERT SUPPORTED LOSSLESS AUDIO
- Choose AAC-LC at 128, 160, 192, 256, or 320 kbps, or lossless ALAC, saved as M4A
- Enable optional conversion when importing supported lossless files
- Convert eligible audio already in your library, with progress and task controls
- Conversion runs while music is playing and pauses when playback pauses, stops, or buffers

OPTIONAL ONLINE SERVICES
Connect your own DS Audio server to browse, preview, and import music. Connect Google Drive to browse and import audio files after authorization. Google Drive does not provide online preview playback.

You can also enable supported metadata, artwork, and lyrics providers. Online features require the app privacy policy and the relevant provider or source disclosure to be accepted. Already imported music remains available offline when online services are disabled.

MyMusic does not supply a music catalog. Bring audio you have the right to use and enjoy your personal library.
```

上述 Google Drive 段落适用于已核对的最新本地 IPA。若最终提交 build 关闭该服务，将该段的 Google Drive 两句删除，并同步调整 Review Notes 和截图。MusicKit 元数据能力仅在最终签名包具备对应 capability 且实测可用时才可单独宣称；本版文案不依赖该能力。

### Keywords

```text
music,player,local,offline,audio,flac,alac,aac,cue,lyrics,playlist,equalizer,converter
```

### What's New in This Version

可直接复制文件：[`1.3/whats-new.en-US.txt`](1.3/whats-new.en-US.txt)。文案不嵌入 patch number，适用于本次最终选定的 1.3.x build。

```text
- Updated the audio playback engine, with improvements to playback controls and CUE album playback.
- Added optional conversion of supported lossless audio to AAC-LC or ALAC, during import or for eligible music already in your library.
- Expanded song, album, and artist details and editing options.
- Added saved lyrics conversion between Simplified and Traditional Chinese.
- Added an alphabetical artist index and improved playback history ordering.
- Improved download and import handling, plus pause, sleep timer, and Lock Screen playback state synchronization.
```

## 3. 中文更新说明

可直接复制文件：[`1.3/whats-new.zh-Hans.txt`](1.3/whats-new.zh-Hans.txt)。

```text
本次更新带来播放与资料库体验改进：

• 更新音频播放内核，改进播放控制与 CUE 整轨专辑分段播放。
• 新增音频转换：支持将符合条件的无损音频转换为 AAC-LC 或 ALAC，可用于导入时转换及已有资料库转换。
• 丰富歌曲、专辑和艺人的详情信息与编辑功能。
• 新增歌词简体、繁体转换，转换结果保存到资料库。
• 新增艺人字母索引，优化播放历史排序。
• 改进下载与导入处理，以及暂停、睡眠定时和锁屏播放状态同步。
```

产品表述保持具体：AAC 属于有损压缩；ALAC 适用于支持的无损输入。不要宣称将 MP3 等有损文件转换为无损音质，也不要承诺所有格式、永不失败、无限后台转换或未经本版测量的包体积降幅。详情编辑和歌词转换保存到 App 资料库，不承诺改写原文件标签。

## 4. App Review Information

### Review Notes（English）

可直接复制文件：[`1.3/review-notes.en-US.txt`](1.3/review-notes.en-US.txt)。

```text
MyMusic: Local Player is a personal music player for audio files supplied by the user. No app account or login is required for local import, library management, or playback. The app does not supply a music catalog.

Local review flow:
1. Open Library and use the add/import action to choose an audio file from Files. Finder file sharing is also supported.
2. Open Songs and play the imported track. Open the mini-player to test playback controls, seeking, queue, equalizer, and sleep timer.
3. Background the app or lock the device while music is playing, then test the system playback controls.
4. Open a song's details and editing actions. Album and artist pages also provide information and editing actions. Edits are saved to the app library.

Audio conversion in this update:
1. Import a supported lossless file such as a 16-bit or 24-bit WAV or FLAC. Include another playable track for listening during conversion.
2. Open the import settings in Settings, then choose Audio Conversion. Choose AAC-LC or ALAC. Enable Import Conversion to convert supported lossless audio on subsequent imports, or choose Convert Existing Library to convert eligible audio already imported.
3. For existing-library conversion, review the eligible files and confirm the operation. Start music playback to allow conversion to run and inspect its progress.
4. Pausing, stopping, or buffering playback also pauses conversion; conversion resumes when music playback resumes. In the background, conversion concurrency is limited to one task while playback is active. Conversion does not play silent audio to keep the app running.
5. AAC-LC is lossy compression; ALAC is lossless for supported inputs. Unsupported or ineligible inputs are not presented as successful conversions. Library metadata edits do not rewrite the original source file's tags.

Chinese lyrics conversion:
For a song with saved Chinese lyrics, open the lyrics action menu and choose conversion to Simplified or Traditional Chinese. The converted lyrics are saved in the local library.

Optional online services:
DS Audio requires a user's own DSM/Audio Station server and account. It supports browsing, temporary audio preview, and import into the local library. Google Drive uses the user's Google OAuth authorization for browsing and importing audio files; it does not support online preview playback.

Online services require acceptance of the app privacy policy and the relevant provider/source disclosure. The complete local player remains usable without enabling these services. Source credentials and OAuth tokens must not be sent in review attachments.
```

### 审核访问与附件

| 项目 | 准备内容 |
| --- | --- |
| Sign-in required | 本地功能不需要；如审核需要访问配置后的在线源，在 ASC 的审核专用字段提供所需访问方式 |
| Demo account | 本地流程无需账号。若需要审核 DS Audio，提供可持续访问、只读、无私人媒体的审核专用服务与账号；不要在仓库记录密码 |
| Google Drive | 使用审核员自己的 Google 授权；最终发布 OAuth 配置应允许目标用户访问，不依赖开发者账号或私有测试用户白名单 |
| Review attachment | 建议使用有使用权的短 WAV/FLAC 和中文 `.lrc`，附本地导入、转换入口、转换进度的演示；确认 ASC 支持附件格式后上传，必要时提供公开下载链接 |
| Contact | ASC 中真实联系人的姓名、电话、邮箱；本地未提供，不填虚构值 |

审核说明按当前工作区行为编写，尤其是播放与转码联动。最终选中的 build 必须实测一致。不能仅因本地功能无需账号就忽略审核员对已发布在线功能的访问需求。

## 5. URLs、隐私、权限与许可证

| 字段 | 候选提交值 | 状态 |
| --- | --- | --- |
| Support URL | `https://github.com/enefry/MusicFree/issues` | 沿用既有资料；公网检查结果见准备记录 |
| Marketing URL | `https://github.com/enefry/MusicFree` | 可选；沿用既有资料 |
| Privacy Policy URL | `https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.2.0.md` | 与当前 App 内链接一致；v1.2 政策注明适用于自 1.2.0 开始的版本 |
| Copyright | `(c) 2026 enefry` | 沿用候选值，发布人确认主体 |

本次本地转换和详情编辑不要求仅为版本号更换隐私政策链接。现行政策涵盖本地处理和在线源；提交前检查实际处理有无变化。历史政策中的 VLC 名称不代表当前包继续嵌入 VLC，最终二进制与许可证应以 FFmpeg 为准。

### App Privacy 工作底稿

| 处理范围 | 当前依据 | 提交前核对 |
| --- | --- | --- |
| 本地导入、转换、歌词与详情编辑 | 本地处理、资料库持久化 | 核对最终包没有将媒体或完整资料库发送到服务端 |
| DS Audio | 用户指定 DSM 服务，认证、目录、搜索、试听、下载请求 | 按真实服务和数据处理回答，演示不含个人内容 |
| Google Drive | 最新本地 IPA 启用 OAuth；已提交配置默认 NO，但本地 override 为 YES | 以最终包的配置、授权 scope 和 Google 实际处理为准 |
| 元数据、封面、歌词 Provider | 用户启用和同意后发出匹配请求 | 核对本版启用的服务、发送字段及第三方日志处理 |
| Metadata Server | 当前 `METADATA_SERVER_DISABLED` | 不在本版文案或审核步骤中宣称可用 |
| App 隐私清单 | `OtherDataTypes` / App Functionality；Linked=false、Tracking=false；AccessedAPITypes 为空 | 覆盖最终 App 和依赖；生成并检查 Archive 的 privacy report，核对实际 required-reason API 使用 |

不要仅凭本地播放器定位或 `NSPrivacyTracking = false` 直接填写 `No Data Collected`。ASC 问卷应按 App 和已集成第三方的实际收集、留存、关联与用途回答；隐私清单不替代问卷。

- [ ] 完成最终 build 的 App Privacy、年龄分级、内容权利和出口合规问卷。
- [ ] 核对最终包 `ITSAppUsesNonExemptEncryption = false` 与实际依赖、HTTPS/认证行为一致；处理 ASC Missing Compliance。
- [ ] 保留 `ThirdPartyNotices` 中 Kingfisher、CocoaLumberjack、FFmpeg 的对应许可证与归属。
- [ ] 确认 FFmpeg 8.1.2 / SDK 0.0.4 的源码、构建配置、修改及重新链接材料满足实际分发要求；已有 LGPL 文本不等于分发审查完成。
- [ ] 确认商店截图、App Preview、演示音频与歌词具有使用权。

## 6. 截图与 App Preview 准备

本轮已读取 PNG IHDR 核对实际尺寸及色彩类型。现有素材是旧 Simulator Debug 版本的候选资产，不能当作最终 1.3 截图验收。

| 现有目录 | 数量 / 尺寸 | 准备结论 |
| --- | --- | --- |
| `Design/AppStore/iPhone-6.5-inch` | 8 张，1284 × 2778 | 部分 PNG 为 RGBA，含 Alpha 通道；上传前须重新导出无 Alpha 并核对内容 |
| `Design/AppStore/iPad-12.9-inch` | 5 张，2048 × 2732 | PNG 为 RGBA，含 Alpha 通道；须重新导出无 Alpha 并核对内容 |
| `Design/AppStore/6.9-inch` | 4 张，1320 × 2868，RGB | 历史素材；尺寸已核对，内容仍需更新 |
| `Design/AppStore/AppPreviews` | 3 个历史 MP4 | 现有说明记录 886 × 1920、H.264 / AAC-LC；本轮未重新校验视频或生成新视频 |

建议更新主设备截图后再在 ASC Media Manager 检查当前设备组和尺寸要求；不要沿用旧资料对某个 slot 的永久适配结论。每组准备以下 6 张（英文标题候选），iPad 展示对应的实际布局：

| 顺序 | 画面 | 标题候选 | 拍摄要点 |
| --- | --- | --- | --- |
| 01 | Library / Songs | `Your music, organized` | 使用自有演示媒体，真实资料库与 mini-player |
| 02 | Now Playing / Queue | `Listen your way` | 展示播放控制和队列，无调试 overlay |
| 03 | Song / Album / Artist details | `Make every detail yours` | 展示本版信息和编辑入口 |
| 04 | Audio Conversion 设置 | `Choose AAC or lossless ALAC` | 明确 AAC 与 ALAC 区别 |
| 05 | 资料库转换任务 | `Convert your local library` | 音乐正在播放，展示真实任务状态和进度 |
| 06 | Lyrics | `Simplified or Traditional lyrics` | 使用有使用权的中文歌词，展示实际转换菜单 |

- [ ] 用最终发布候选运行内容拍摄，去除 BVT 参数、测试路径、真实账号、token、NAS 地址和私有内容。
- [ ] 最终 PNG 无 Alpha 通道，尺寸、方向和语言符合 ASC 对应 slot。
- [ ] 所展示功能在选中的 build 中可用；不展示关闭的 Metadata Server 或不可用的 MusicKit 功能。
- [ ] App Preview 为可选；若旧视频内容与本版不符，应更新或移除，录制时展示真实 App 行为。

## 7. 最终包与提交记录

### 发布前核对

- [ ] 冻结当前 1.3 改动，确认最终源码包含所需的播放/转换调度修复；单独审计未提交改动。
- [ ] 用最终 Release 候选完成全新安装、从已上线 1.2.x 升级、资料库/歌单/收藏/历史保留测试。
- [ ] 完成本地播放、CUE、后台/锁屏、导入、AAC/ALAC 转换、暂停/恢复/取消和重启恢复的最终包冒烟测试。
- [ ] 最终包 Google Drive OAuth 登录与导入可用；DS Audio 真机浏览、试听、下载可用；如保留功能则提供审核访问条件。
- [ ] 转码与真实音乐播放联动符合 Review Notes，锁屏后按并发限制运行；不以静音音频维持后台执行。
- [ ] 核对 Archive/IPA 的版本、build、Bundle ID、最低系统、签名、entitlements、隐私报告和嵌入依赖。
- [ ] TestFlight 安装和升级通过，在 ASC 选择对应 build 并完成各项问卷，再提交审核。

已有需求记录在 2026-09-30 确认人工真机听音、中断行为、后台和锁屏控制符合预期；这项历史验收不用重新标记为“从未验收”。真实 DS Audio 真机验收及转换长任务/性能仍需要与最终候选包对应的结果。物理耳机和蓝牙连接/断开保留为发布冒烟建议。

### 本地归档参考（本轮未执行）

复用当前 checkout 的稳定缓存。该仓库有多个 worktree，下例使用当前目录名 `MusicPlayer` 隔离 DerivedData；若该 checkout 已确定专用缓存，继续复用它。

```sh
PROJECT_ROOT=/Users/chenrenwei/developer/MusicPlayer
mkdir -p "$PROJECT_ROOT/.noindex/artifacts/app-store-1.3"
xcodebuild -project "$PROJECT_ROOT/MusicFree.xcodeproj" \
  -scheme MusicFree -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$PROJECT_ROOT/.noindex/DerivedData/MusicPlayer" \
  -archivePath "$PROJECT_ROOT/.noindex/artifacts/app-store-1.3/MusicFree.xcarchive" \
  archive
```

命令只归档；随后通过 Organizer 导出或上传。再次使用该固定 Archive 路径前，先保存需要保留的交付产物，避免覆盖。现有 `publish_tf.sh --no-upload` 也可归档和导出，但会创建新的输出子目录，使用后需清理确定不再需要的重复产物。两种路径的 Archive hook 均会修改版本配置；本轮没有执行归档或导出。

### 提交结果记录

| 项目 | 结果 |
| --- | --- |
| 最终源码 commit / dirty scope | 待记录 |
| Archive / IPA 路径 | 待记录 |
| 包内 version / build / Bundle ID | 待记录 |
| IPA SHA-256 | 待记录 |
| ASC build ID / processing result | 待记录 |
| 最终包真机与升级冒烟 | 待记录 |
| OAuth / DS Audio 验收及审核访问 | 待记录 |
| Screenshot / Preview 集 | 待记录 |
| 隐私 / 出口合规 / 内容问卷 | 待记录 |
| Review Contact | 在 ASC 填写；不在仓库保存私人信息 |
| 提交时间 / 发布方式 | 待记录；沿用发布人选择 |

## 8. 准备记录与资料来源

本轮完成：当前版本配置与候选 IPA 元数据核对、第三方声明核对、英文与中文更新文案、英文描述和审核说明、现有截图数量/尺寸/Alpha 通道检查。未在本轮构建、重跑测试、生成新截图、上传或提交审核；已有测试仅作为功能资料来源。

公网 URL 检查：2026-09-30 以无认证 HTTP 请求检查上述 Support、Marketing 和 Privacy Policy URL，三者均返回 HTTP 200，无登录重定向；本轮未检查 Apple 参考页面的最新内容。

- [`../Versions/1.3.0_FEATURE_REQUIREMENTS.md`](../Versions/1.3.0_FEATURE_REQUIREMENTS.md)：FFmpeg 替换及真机/模拟器验收记录。
- [`../Features/DETAIL_METADATA.md`](../Features/DETAIL_METADATA.md)：详情编辑字段、持久化和验证。
- [`../Architecture/Import_AAC_LC_Transcoding_Plan_2026-09-29.md`](../Architecture/Import_AAC_LC_Transcoding_Plan_2026-09-29.md)：转换范围和验证；当前调度行为以源码为准。
- [`../PRIVACY_POLICY_v1.2.0.md`](../PRIVACY_POLICY_v1.2.0.md)：当前 App 引用的隐私政策。
- [`../../ThirdPartyNotices/FFmpegAudio.md`](../../ThirdPartyNotices/FFmpegAudio.md)：FFmpeg 归属、源码与许可证。
- [`../../Design/AppStore/README.md`](../../Design/AppStore/README.md)：历史素材来源。
- [`../../basic_config.xcconfig`](../../basic_config.xcconfig)、[`../../project.yml`](../../project.yml)、[`../../App/PrivacyInfo.xcprivacy`](../../App/PrivacyInfo.xcprivacy)：当前工程配置。
- [Apple：版本资料字段](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- [Apple：App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [Apple：Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Apple：选择提交 build](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit)

商店字段长度已按既有 ASC 常见限制做本地检查；ASC 实际设置、当前规格和审核结果仍以发布时页面为准。
