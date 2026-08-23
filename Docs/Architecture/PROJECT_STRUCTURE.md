# MusicFree 工程结构

> 状态：当前结构基线
>
> 适用平台：iOS / iPadOS 26.0 及以上

## 1. 工程分层

```text
MusicFree/
├── App/                              # 应用组装、生命周期、路由和发布配置
├── Packages/
│   ├── MusicFreeCore/                # 领域模型、公开协议和 AppServices
│   ├── MusicFreeInfrastructure/     # 本地媒体、持久化和 Apple 系统适配器
│   ├── MusicFreeVLCKitAdapter/      # VLCKit 播放引擎适配器
│   └── MusicFreeUI/                 # DesignSystem 和 SwiftUI 功能模块
├── AppTests/                         # App 级单元/集成测试
├── AppUITests/                       # 真实 App 入口 UI/BVT 测试
├── Scripts/                          # 架构检查、BVT 和归档版本脚本
├── Docs/                             # 工程、产品、问题、测试和发布文档
├── ThirdPartyNotices/                # 第三方许可证和归属材料
├── project.yml                       # XcodeGen 工程与 target 定义
└── basic_config.xcconfig             # 版本、构建号和应用配置
```

## 2. 依赖方向

```text
MusicFreeUI ───────────────┐
MusicFreeInfrastructure ───┼──> MusicFreeCore
MusicFreeVLCKitAdapter ────┘       │
                                   └──> 领域/API 契约

App ──> UI + Infrastructure + VLCKit Adapter + Core API
```

依赖规则：

- `MusicFreeCore` 不依赖 SwiftUI、SwiftData、VLCKit、MediaPlayer、AVFAudio 或具体文件系统实现。
- `MusicFreeUI` 只依赖 Core 暴露的领域/API 和 AppServices，不直接创建持久化或播放器实现。
- `MusicFreeInfrastructure` 实现 Core 的媒体源、Repository、设置和系统集成协议。
- `MusicFreeVLCKitAdapter` 只负责把 VLCKit 能力映射到 `PlaybackAPI`、`MediaSourceAPI` 和领域模型。
- `App` 是 composition root，负责组装具体实现并将服务注入 UI。

详细的 public API、并发、错误、持久化和删除事务边界见 [`MODULE_INTERFACES.md`](MODULE_INTERFACES.md)。

## 3. Package 与 target

| Package | Targets / Products | 主要职责 |
| --- | --- | --- |
| `MusicFreeCore` | `MusicDomain`, `MediaSourceAPI`, `LibraryAPI`, `PlaybackAPI`, `SystemIntegrationAPI`, `SettingsAPI`, `AppServices`, `MusicTestSupport` | 稳定契约、领域状态和跨功能协调 |
| `MusicFreeInfrastructure` | `LocalMediaAdapter`, `LibraryPersistenceAdapter`, `AppleSystemAdapter`, `PreferencesPersistenceAdapter` | 外部系统和存储实现 |
| `MusicFreeVLCKitAdapter` | `VLCKitPlaybackAdapter` | 音频探测、播放、能力和诊断 |
| `MusicFreeUI` | `DesignSystem`, `LibraryFeature`, `PlayerFeature`, `PlaylistFeature`, `SettingsFeature` | UI 组件、页面和用户操作 |

## 4. App 运行链路

1. `MusicFreeApp` 创建 `AppContainer`，组装持久化、媒体、系统和播放实现。
2. `AppLifecycleCoordinator`、`AppDocumentsScanner` 和启动状态处理启动恢复、Documents 补扫及启动错误。
3. `RootScene` 通过 `AppRouter` 展示 Library、Player、Playlist 和 Settings 功能。
4. UI 通过 `AppServices` 发起导入、查询、编辑、播放、队列、存储维护和设置变更。
5. `AppServices` 调用 Infrastructure / VLCKit Adapter，并把状态快照回传给 UI。

## 5. 验证边界

- Package 测试验证契约、状态机、持久化和适配器行为。
- App UI/BVT 验证从真实 App 入口出发的导航、持久化和关键交互。
- AirPlay、蓝牙、长时间播放、媒体格式和 MusicKit 授权必须在真实设备/真实服务上单独验收。
- 任何文档不得把编译成功或 Simulator 测试通过写成完整发布通过。
