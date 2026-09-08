# App 应用组装模块

路径：`App`

App 目录是 composition root：负责把具体 Infrastructure、VLCKit Adapter、Core AppServices 和 UI 功能组装成可运行的 iOS 应用。

## 主要职责

| 组件 | 功能 |
| --- | --- |
| `MusicFreeAppDelegate` / `MusicFreeSceneDelegate` | UIKit 应用与场景入口，创建并持有应用容器及窗口。 |
| `AppContainer` | 组装 Settings、Library、Media、Apple System、VLCKit 和 AppServices 实例。 |
| `RootViewController` / `AppRouter` | UIKit 根页面、主导航、Mini Player / Now Playing 展示和路由状态；Settings 通过独立宿主保留 SwiftUI。 |
| `AppLifecycleCoordinator` | 前后台、启动恢复和生命周期事件分发。 |
| `AppDocumentsScanner` | Documents 目录补扫、快照恢复和导入任务调度。 |
| `AppStartupState` | 启动中、可用、降级和错误状态，提供重试/诊断入口。 |
| `AppDiagnosticsExporter` / `AppReleaseInfoProvider` | 导出脱敏诊断和展示版本/构建信息。 |
| `AppAlternateIconProvider` | 应用图标切换能力。 |

## 测试入口

- `AppTests`：AppContainer、启动、生命周期、诊断和组合层测试。
- `AppUITests`：真实 App 入口的导航、BVT、Now Playing、设置、导入和持久化验收。
- Package 测试仍是 Core、Infrastructure、UI 和 VLCKit 契约的主要验证位置。
