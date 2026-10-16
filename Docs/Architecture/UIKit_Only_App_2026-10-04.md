# 全应用 UIKit 迁移记录

日期：2026-10-04；分支：`feature/1.4.0_dev`。

## 实现

应用入口、根导航、资料库、播放、歌单、在线源和设置全部由 UIKit 控制器呈现。此次替换剩余的设置 SwiftUI 子页及插件、Debug 网络抓包页面，删除 Hosting/Representable 桥接与旧 SwiftUI 设计组件。

- `AppSettingsViewController` 负责应用设置组合，`SettingsViewController` 负责根页、分类和原生控件；`SettingsDetailPages` 实现均衡器、定时器、元数据、在线源可用性、隐私详情、关于/许可和诊断。
- 图标、转码、设置加载、隐私和存储支持保留原有服务与状态模型；`Observation` 用于观察状态，页面呈现使用 UIKit。
- 原生表单复用稳定行与控件，滑杆在手势结束后保存；分类切换收起嵌套页。定时器刷新避免重复设置正在操作的时间控件。
- 隐私授权继续区分应用、Provider、插件和源实例；元数据/歌词取消过滤旧进度，保留终止摘要。
- 插件配置保留凭证引用，校验失败或保存失败保留输入；插件和源实例管理继续调用既有服务。
- Debug 抓包使用原生请求列表、搜索和请求/响应详情；移除 `PulseUI` 产品依赖，保留 `Pulse` 记录能力。
- `Scripts/check_architecture.sh` 对 `App/`、`Packages/` 禁止 SwiftUI 导入及 Hosting/Representable。`thirdpart/` 是非应用 target 的参考项目。

## 验证

构建和测试复用 `.noindex/DerivedData/MusicPlayer`，日志位于 `.noindex/logs/uikit-migration-*.log`。

| 范围 | 结果 |
| --- | --- |
| 应用 Debug / iOS Simulator | 编译通过，最终设置控件调整已再次编译 |
| 应用 Release / generic iOS | `CODE_SIGNING_ALLOWED=NO` 编译通过 |
| 可选 DebugSupport / iOS Simulator | 独立验证工程编译通过，包含 Pulse 原生浏览页面 |
| MusicFreeUI feature 包 | 209 项 Swift Testing 测试通过 |
| 最终原生设置重点复测 | 7 项通过：控件身份、手势保存、分类返回、定时计划、隐私撤销和取消后的进度 |
| 最终插件配置复测 | 2 项通过：保存失败保留草稿/凭证引用，非法数值阻止保存 |
| iPhone 设置 UI | 控件/持久化测试和原生子页导航测试通过 |
| iPad 设置 UI | 分类切换、嵌套子页及返回测试通过，最终源码复测通过 |
| 架构检查、源码扫描、diff 空白检查 | 通过；第一方源码没有 SwiftUI 导入或 Hosting/Representable |

iPad 的既有 `testRegularWidthUsesThreeColumnNavigationShell` 修正旧资料库定位后，资料库三栏导航与播放选择通过，随后失败于 Mini Player 进度控件断言（`player.mini.progress`）。当前 `PlayerMiniPlayerViewController` 无此控件，本次未改动该播放器文件；此项不能计为通过。

迁移完成的是应用页面与第一方源码。Release 二进制的 `otool -L` 仍包含 SwiftUI 和 PhotosUI 的 SwiftUI overlay，`nm` 可见第三方 Kingfisher 自带的 `KFImage` 扩展。应用图像加载仅使用 `KingfisherManager`，没有调用这些 SwiftUI 页面/API；本次没有分叉第三方库或修改 Apple SDK，因此不能声称二进制完全不链接 SwiftUI 系统框架。

真机交互、音频路由/实际听感及签名 Archive 未验证。Simulator 测试和无签名编译不代替这些验收。
