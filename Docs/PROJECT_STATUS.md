# MusicFree 当前项目状态

> 快照日期：2026-08-23
>
> 代码、工程配置和测试结果是最终依据；本文只汇总当前 checkout 的入口、
> 能力边界和未关闭门禁，不替代历史 Review 或版本需求。

## 1. 当前构建身份

| 项目 | 当前值 | 来源 |
| --- | --- | --- |
| 工程/Bundle 名 | `MusicFree` / `win.tools4me.music` | `project.yml` |
| 用户可见名称 | `MyMusic` | `basic_config.xcconfig` |
| Marketing Version | `1.1.100` | `basic_config.xcconfig` |
| Build | `2026082301` | `basic_config.xcconfig` |
| 最低系统 | iOS / iPadOS 26.0 | `project.yml` |
| 设备 | iPhone + iPad | `TARGETED_DEVICE_FAMILY = 1,2` |
| VLCKit | `4.0.0-audio.20260814.3` | `Packages/MusicFreeVLCKitAdapter/Package.swift` |

## 2. 已接通的生产入口

- 从 Files 和共享 Documents 导入本地音频；启动或回到前台时可补扫 Documents。
- 资料库支持歌曲、收藏、播放历史、专辑、艺人、流派、文件夹、搜索、分页、刷新和技术详情。
- 支持歌单创建/编辑/删除、歌曲添加/移除、排序，以及歌曲/收藏列表批量操作。
- 播放支持队列、随机/重复、seek、音量/静音、播放速度、睡眠定时器、运行时 EQ、后台音频、Now Playing 和远程控制入口。
- 支持内嵌歌词、`.lrc`、歌词编辑、元数据覆盖和封面维护。
- MusicKit、MusicBrainz、Discogs、LRCLIB 和 Metadata Server 有独立 Provider 边界；Provider 受设置和隐私同意控制。

## 3. 当前配置下的限制

- `METADATA_SERVER_FEATURE_FLAG = METADATA_SERVER_DISABLED`：Metadata Server 当前构建不可用，不应写入发布文案或验收结论。
- `App/MusicFree.entitlements` 当前没有 MusicKit capability；MusicKit 元数据补充仍需签名配置、真机授权和真实 catalog 验收。
- ReplayGain、gapless、crossfade、可视化、云同步、远程网盘、播客、电台、CarPlay、Siri 和视频不属于当前产品能力。
- “代码已实现”“自动化测试通过”“Simulator 运行通过”“真机/真实服务通过”必须分别记录。

## 4. 工程验证入口

```sh
xcodegen generate --spec project.yml
Scripts/check_architecture.sh
xcodebuild -list -project MusicFree.xcodeproj
```

Package 测试和 App UI/BVT 测试应使用当前可用的 iOS Simulator UDID，避免使用无法解析的设备名称。真实媒体格式、后台/锁屏、音频路由、中断、长时间播放和 MusicKit 必须另行在真机验收。

当前 checkout 的静态测试声明约 518 个（不含构建产物目录）；该数字不是一次测试运行的通过数，正式结果必须引用对应 `.xcresult`。

## 5. 当前发布门禁

- [ ] 生成并检查 `1.1.100 (2026082301)` 的最终签名 Archive/IPA。
- [ ] 在最终包中确认 Bundle ID、版本、构建号、entitlements 和第三方 notices。
- [ ] 完成 MusicKit capability/profile、真机授权、catalog 匹配和封面下载验证，或收窄商店文案范围。
- [ ] 完成真机媒体格式、后台/锁屏、路由、中断和长时间播放验收。
- [ ] 用最终 Release 包重新确认截图、App Preview、隐私问卷和出口合规。

详细执行入口：[`Testing/README.md`](Testing/README.md)、[`Issues/ISSUES_AND_FIXES.md`](Issues/ISSUES_AND_FIXES.md) 和 [`Release/APP_STORE_SUBMISSION_1.1.md`](Release/APP_STORE_SUBMISSION_1.1.md)。
