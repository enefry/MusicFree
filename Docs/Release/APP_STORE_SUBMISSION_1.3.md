# MyMusic: Local Player 1.3.x App Store 提审资料

初次准备：2026-09-30；范围修订：2026-10-01（America/New_York）。

本次主要变化是内部播放、媒体探测与元数据读取从 VLCKit 迁移到 FFmpeg，主要界面和使用流程延续既有版本。按这个范围更新提审资料，现有商店页面不需要整体重做。

## 1. 本次需要更新的内容

| 内容 | 本次动作 |
| --- | --- |
| Version / Build | 填写最终提交版本，并在 ASC 选择对应 build；以包内版本和 ASC 为准 |
| What's New | 使用下方简短更新说明，突出播放内核与播放状态同步改进 |
| Review Notes | 补充 VLCKit → FFmpeg 内部迁移说明，保留本地导入、播放、CUE、后台/锁屏测试路径 |
| 第三方声明与分发材料 | 使用实际 FFmpeg 版本、许可证、源码和构建/重新链接材料；核对最终包不再带已移除的 VLCKit 声明 |
| App Privacy / 出口合规 | 针对替换后的依赖和最终包重新核对；只有实际数据处理或加密情况变化时才调整对应回答 |
| 截图 / App Preview | 对照最终包检查现有已上线素材；只替换画面或功能已不一致的部分 |

App 名称、副标题、关键词、宣传文本、完整描述、Support/Marketing URL 和审核联系人可以沿用 ASC 现有内容，前提是仍准确有效。VLC → FFmpeg 内部替换本身不要求修改这些字段。隐私政策 URL 也不因版本号变化而自动更换。

## 2. What's New

不在文案中写 patch number，便于匹配最终选定的 1.3.x build。用户侧无需了解 VLC 或 FFmpeg 名称；审核说明记录具体实现变化。

### English (U.S.)

直接复制：[`1.3/whats-new.en-US.txt`](1.3/whats-new.en-US.txt)。

```text
- Updated the audio playback engine.
- Improved playback state synchronization for pause, background audio, and Lock Screen controls.
- Fixed playback and import issues.
```

### 简体中文

直接复制：[`1.3/whats-new.zh-Hans.txt`](1.3/whats-new.zh-Hans.txt)。

```text
• 更新音频播放内核。
• 优化暂停、后台播放与锁屏控制的状态同步。
• 修复若干播放与导入问题。
```

上轮准备的综合候选文案仍保存在 [`1.3/description.en-US.txt`](1.3/description.en-US.txt) 和 [`1.3/promotional-text.en-US.txt`](1.3/promotional-text.en-US.txt)，仅在主动更新产品介绍时使用；它们不是本次提审的必改项。音频转换、详情编辑、歌词繁简转换等功能也不要求全部变成截图或商店主卖点。

## 3. App Review Notes

直接复制：[`1.3/review-notes.en-US.txt`](1.3/review-notes.en-US.txt)。

```text
This update primarily replaces the internal audio playback, media probing, and metadata-reading implementation from VLCKit with an FFmpeg-based audio implementation. The main local-player interface and review workflow remain substantially the same.

MyMusic: Local Player plays audio files supplied by the user. No app account or login is required for local import and playback. The app does not supply a music catalog.

Review flow:
1. Open Library and import an audio file from Files, or use Finder file sharing.
2. Open Songs, play the imported track, and use the mini-player to open playback controls.
3. Test play/pause, seeking, queue, playback speed, and equalizer. CUE albums can be imported with their referenced audio files to test individual track playback.
4. Background the app or lock the device while music is playing, then test the system playback controls.

DS Audio and Google Drive remain optional user-configured sources. Local playback does not require either service. DS Audio requires a DSM/Audio Station server and account; Google Drive uses Google OAuth for browsing and importing audio, without online preview playback. Online requests require the app privacy policy and the relevant provider/source disclosure to be accepted.
```

若审核需要访问已发布的 DS Audio 功能，在 ASC 审核专用字段提供可访问的审核服务及账号，不在仓库记录密码。Google Drive 的发布 OAuth 配置应允许目标用户授权。最终 build 的服务开关与审核说明必须一致。

若最终 build 包含音频转换入口，可在审核员需要了解该功能时补充：转换针对符合条件的无损输入，输出 AAC-LC 或 ALAC；当前实现仅在音乐播放期间运行，暂停、停止或缓冲时转码也会暂停，恢复播放后继续，后台并发为一个任务。该补充以最终包实际行为为准。

## 4. 第三方声明与隐私核对

- 核对最终依赖中的 FFmpeg 版本、SDK 版本及实际构建配置，App 内 About / ThirdPartyNotices 与包内依赖一致。
- 从当前分发材料中清除已移除的 VLCKit 依赖声明；历史版本文档和 Git 历史可以保留。
- 保留 FFmpeg 对应的 LGPL 文本、源码获取方式、构建配置和必要的重新链接材料。许可证文本随包附带不替代实际分发义务核对。
- 核对最终 Archive 的隐私报告、依赖隐私清单和 required-reason API 使用；ASC 隐私问卷按实际数据收集情况填写。
- 核对最终包的加密声明并处理 ASC Missing Compliance；不因为使用 FFmpeg 就默认改变出口合规答案。

现有 Privacy Policy URL：`https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.2.0.md`。它注明适用于自 1.2.0 开始的版本；本次内部迁移没有改变数据处理时可以继续使用。

## 5. 截图与 App Preview

主要界面没有明显变化时，继续沿用已上线的素材。逐张对照最终包，只有操作入口、布局、显示内容或功能承诺不一致时才替换；无需为 FFmpeg 内部变化录制一套新画面。

2026-09-30 对本地候选资产的检查记录：

| 目录 | 数量 / 尺寸 | 复用时注意 |
| --- | --- | --- |
| `Design/AppStore/iPhone-6.5-inch` | 8 张，1284 × 2778 | 部分本地 PNG 含 Alpha 通道；若重新上传这些文件，先导出无 Alpha 版本 |
| `Design/AppStore/iPad-12.9-inch` | 5 张，2048 × 2732 | 本地 PNG 含 Alpha 通道；若重新上传这些文件，先导出无 Alpha 版本 |
| `Design/AppStore/6.9-inch` | 4 张，1320 × 2868，RGB | 检查画面与最终包一致即可 |
| `Design/AppStore/AppPreviews` | 3 个历史 MP4 | 若仍准确展示产品行为，可以沿用；本轮未重新检查视频 |

本地候选文件的 Alpha 检查不等于 ASC 已上线图片有问题；不因此要求重新上传已被接受且仍准确的素材。重新上传时再按 ASC 当前设备组、尺寸和格式要求检查。

## 6. 最终提交检查

- [ ] 在 ASC 填写版本、选择对应 build，核对包内版本、Bundle ID、签名和嵌入框架。
- [ ] 使用最终候选完成本地导入、播放/暂停、seek、CUE、均衡器、后台/锁屏与在线试听回归。
- [ ] 确认从已上线版本升级后资料库、歌单、收藏和播放历史保留。
- [ ] 更新 What's New 和 Review Notes；确认现有截图、描述及审核访问方式仍准确。
- [ ] 核对 FFmpeg 分发材料、隐私及出口合规回答，处理 ASC 对该 build 的必填项。
- [ ] TestFlight 安装/升级验收后提交审核。

## 7. 构建身份与既有证据

以下是 2026-09-30 的核对记录，不作为 2026-10-01 的最新构建状态：

| 项目 | 当时结果 |
| --- | --- |
| 源码配置 | `1.3.2 (2026093002)` |
| 本地候选 IPA | `dist/MusicFree-20260930-131727.ipa`，包内 `1.3.1 (2026093001)` |
| Bundle ID / 最低系统 | `win.tools4me.music` / iOS 17.1，iPhone 与 iPad |
| 候选包依赖 | `FFmpegAudio.framework`；声明 FFmpeg 8.1.2 / FFmpegAudioKit 0.0.4 |
| 候选包 Google Drive | OAuth 启用 |
| 加密声明 | `ITSAppUsesNonExemptEncryption = false` |
| 公网 URL | Support、Marketing、Privacy Policy 三个无认证请求均返回 HTTP 200 |

归档 scheme 的 pre-action 推进 build number，post-action 推进 patch version。归档后配置可能显示下一版本；最终版本与 build 以包内值和 ASC 为准。

已有需求记录在 2026-09-30 确认人工真机听音、中断行为、后台和锁屏控制符合预期。最终候选仍需对应验收；此文档修订未构建、上传或提交审核。

## 8. 资料来源

- [`../Versions/1.3.0_FEATURE_REQUIREMENTS.md`](../Versions/1.3.0_FEATURE_REQUIREMENTS.md)：FFmpeg 替换及验收记录。
- [`../../ThirdPartyNotices/FFmpegAudio.md`](../../ThirdPartyNotices/FFmpegAudio.md)：FFmpeg 归属、源码与许可证。
- [`../PRIVACY_POLICY_v1.2.0.md`](../PRIVACY_POLICY_v1.2.0.md)：当前隐私政策。
- [`../../Design/AppStore/README.md`](../../Design/AppStore/README.md)：既有素材来源。
- [`../../basic_config.xcconfig`](../../basic_config.xcconfig)、[`../../project.yml`](../../project.yml)、[`../../App/PrivacyInfo.xcprivacy`](../../App/PrivacyInfo.xcprivacy)：工程配置。
