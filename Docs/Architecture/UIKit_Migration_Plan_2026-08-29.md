# MusicFree UIKit 迁移规划

日期：2026-08-29
分支：`codex/uikit-planning-development`
基线分支：`feature/1.2.0_dev`
状态：UIKit 根壳已落地并成为唯一生产入口；Library、Player、Playlist、Online Sources 的生产页面使用 UIKit；Settings 继续由 SwiftUI 宿主承载；旧 SwiftUI RootScene、运行时切换参数和 SwiftUI 回滚入口已移除。模拟器运行态截图仍受 CoreSimulator 环境影响，需恢复后继续做视觉验收。

## 1. 结论先行

本项目不建议做一次性“全部 UI 推倒重写”。建议采用以下目标架构：

```text
UIKit App Shell
├── UIKit TabBar / SplitView / Navigation / Sheet
├── UIKit LibraryFeature
├── UIKit PlayerFeature
├── UIKit PlaylistFeature
├── UIKit Online Sources
└── SwiftUI SettingsFeature（通过 UIHostingController 嵌入）
```

结论分为三点：

1. **去掉 SwiftUI 页面壳是必要且可行的**：迁移前的 `RootScene` 同时承担启动状态、Tab、三栏导航、Sheet、Mini Player、状态观察和服务启动，导致布局/生命周期/系统 Sheet 之间存在额外耦合。现在这些职责已移到 UIKit 控制器层，减少了 SwiftUI 状态树重建和 UIKit/SwiftUI 交互边界。
2. **不需要去掉 SettingsFeature 的 SwiftUI**：设置页主要是表单、Picker、Toggle、Sheet 和动态配置，保留 SwiftUI 的收益大于迁移收益。只将 Settings 作为 UIKit 导航栈中的一个 `UIHostingController` 页面。
3. **此前 94～144 人日的估算不适用于当前仓库**：那是接近“全量重建 + 数据层/设计系统/测试从零补齐”的上限估算。当前已有 UIKit 列表、播放器控件、视觉基线、ViewModel 和服务协议，按保留数据层、分阶段迁移页面计算，合理范围是：
   - 实现型迁移：约 **32～45 人日**；
   - 达到可发布标准（包含截图一致性、真机回归、稳定性和清理旧路径）：约 **45～62 人日**；
   - 以上是工程人日，不是 Codex 运行时间；每个阶段完成后都必须根据实测重新估算下一阶段。

## 2. 本次规划的目标和非目标

### 2.1 目标

- UIKit 成为 App 的根容器、导航、页面生命周期和主要交互的所有者。
- Library、Player、Playlist、Online Sources 页面改为 UIKit 原生 ViewController/View/Cell。
- Settings 页面继续使用现有 SwiftUI 实现，通过 UIKit 导航和呈现。
- 保留现有 `MusicFreeCore`、`MusicFreeInfrastructure`、VLCKit、服务协议、Repository、持久化和 ViewModel 行为。
- 保留现有可访问性标识符和用户可见交互，减少迁移期间产品行为变化。
- 每个阶段都能单独编译、运行、截图对比和回归；失败通过代码修复或 Git 提交回退处理，不提供 SwiftUI 运行时回滚路径。
- 后续 UI 修改遵循“Figma 状态基线 → DesignSystem token/component → UIKit/SwiftUI 实现 → 截图验收”的闭环。

### 2.2 非目标

- 不在本轮重写 `MusicFreeCore`、`AppServices`、SwiftData、媒体导入、播放引擎或在线源协议。
- 不借迁移之机改变播放策略、在线源产品规则、隐私同意规则或设置语义。
- 不把动态数据、授权信息、短期 URL、队列状态写成 Figma 的固定业务数据。
- 不为了“纯 UIKit”把 Settings、Safari/WebView、系统音频路由等已经合理的系统组件强行重写。
- 不把 Simulator 截图通过等同于真机性能和发布验收。

## 3. 当前架构盘点

### 3.1 App 入口和根容器

当前入口位于：

- `App/MusicFreeApp.swift`
- `App/SceneDelegate.swift`
- `App/RootViewController.swift`
- `App/AppRouter.swift`
- `App/AppContainer.swift`

迁移前的 `RootScene` 曾同时负责：

- `AppContainer` 组合、启动、重试、降级和恢复状态；
- `NavigationSplitView` 三栏布局；
- 紧凑宽度下的 `TabView`；
- `NavigationStack` 页面路径；
- Player Sheet、透明 presentation background 和交互下拉；
- Mini Player 安全区插入；
- 播放快照、在线源选择、设置选择和资料库选择的状态同步；
- scenePhase、文档扫描、在线试听停止和后台生命周期。

这说明迁移的第一风险不是单个页面，而是**根容器状态和系统生命周期的所有权**。应先把根容器从 SwiftUI View 拆成 UIKit 控制器，再逐页替换。

### 3.2 Feature 规模和复杂度证据

当前 Swift 源码行数为近似盘点值，包含 View、ViewModel、加载器和支持代码：

| Feature | 近似源码行数 | 迁移判断 |
| --- | ---: | --- |
| `LibraryFeature` | 9,811 | 最高复杂度；已有 UIKit collection 基础，可分列表/详情迁移 |
| `PlayerFeature` | 5,588 | 交互和视觉敏感；已有 UIKit 滑杆、音频路由、Sheet 观察桥接 |
| `PlaylistFeature` | 2,451 | 中等复杂度；列表/详情/编辑/添加歌曲需要迁移 |
| `SettingsFeature` | 8,596 | 保留 SwiftUI，不纳入页面重写；只做宿主桥接 |
| `DesignSystem` | 911 | 作为 UIKit/SwiftUI 双端 token 和组件基础 |

### 3.3 已有 UIKit 边界

当前已经存在的 UIKit 能力：

- `LibraryFeature/NativeLibraryCollectionView.swift`
  - `UICollectionViewDiffableDataSource`；
  - Compositional Layout；
  - UIKit 多选和双指选择；
  - 长按菜单、分享和无障碍属性。
- `LibraryFeature/NativeTrackCollectionView.swift`
  - 原生曲目列表、多选、队列操作和上下文菜单。
- `PlayerFeature/CompactPlayerSlider.swift`
  - UIKit 滑杆桥接。
- `PlayerFeature/SystemAudioRoutePicker.swift`
  - `AVRoutePickerView` 的系统控件桥接。
- `PlayerFeature/NowPlayingView.swift`
  - 已通过 `UIViewControllerRepresentable` 观察 UIKit Sheet presentation 生命周期。
- `SettingsFeature/PrivacySettingsView.swift`
  - Safari/WebView 已经是 UIKit/系统控制器桥接。
- 多个 Artwork Loader 已经在 UIKit 图片加载任务和 SwiftUI 显示之间做了边界处理。

需要特别注意：现有原生 CollectionView 的 cell 内容仍通过 `UIHostingConfiguration` 渲染 SwiftUI。它是迁移的有利起点，但不能作为最终“非 Settings 页面完全 UIKit”的完成状态。最终需要用原生 `UICollectionViewCell` 内容配置替换这些 Hosting Cell。

### 3.4 数据和服务边界

现有模块边界已经适合迁移：

- `MusicFreeCore`：Domain、API、AppServices、协调器；
- `MusicFreeInfrastructure`：本地媒体、资料库持久化、在线源实现；
- `MusicFreeVLCKitAdapter`：播放适配器；
- `MusicFreeUI`：当前页面和 ViewModel；
- `App`：组合依赖、启动和根导航。

迁移时保持以下边界不变：

- UIKit 不直接访问 SwiftData、文件系统、URLSession 或 VLCKit；
- ViewController 只调用现有 `Serving`/Feature Store/Coordinator；
- `MediaItemID`、`PlaylistID`、`SourceObjectID` 等 ID 语义不改变；
- AsyncStream、Task 取消、generation、分页和 optimistic save 规则不改变；
- 迁移只替换呈现层和导航层，不替换业务状态机。

## 4. 目标架构设计

### 4.1 App 生命周期

将 App 入口从 SwiftUI `App` 迁移为 UIKit 生命周期：

- `MusicFreeAppDelegate`：创建共享 `AppContainer`、配置 Debug fixture、处理 application 级初始化；
- `MusicFreeSceneDelegate`：创建 `UIWindow`，安装 `RootViewController`，处理 scene active/background/disconnect；
- `RootViewController`：订阅启动状态，显示启动动画/恢复/降级/主内容；
- `AppContainer`：继续拥有服务组合和跨场景服务生命周期，不下沉到页面控制器。

不保留 `SwiftUI RootScene` 作为回滚实现，也不增加编译期或 Debug 运行时 UI 实现选择开关。UIKit 根壳是唯一生产根入口；Settings 是唯一允许通过 `UIHostingController` 承载 SwiftUI 的功能。

当前已移除开关和旧根路径；后续每次只改动一个 Feature 并独立验收，不能用旧 SwiftUI 页面替代验收结果。

### 4.2 紧凑宽度导航

使用 UIKit 组合：

```text
UITabBarController
├── UINavigationController(LibraryViewController)
├── UINavigationController(PlaylistViewController)
├── UINavigationController(OnlineSourcesViewController)
└── UINavigationController(SettingsHostingController)
```

- Tab 顺序和 SF Symbol 名称沿用 `AppRouter.Route.allCases`；
- 重新点击当前 Online Sources Tab 时 pop 到来源列表；
- Mini Player 使用自定义 `UIView`/`UIViewController`，挂在 TabBar 上方，不再使用 SwiftUI `safeAreaInset`；
- Player 使用 UIKit `UISheetPresentationController` 或兼容的自定义 presentation controller；
- 现有 `AppRouter` 继续作为路由值模型，UIKit Controller 负责执行导航。

### 4.3 Regular 宽度导航

使用 `UISplitViewController(style: .tripleColumn)`：

```text
UISplitViewController
├── primary: RouteSidebarViewController
├── supplementary: FeatureSecondaryViewController
└── secondary: FeatureDetailViewController
```

- Library：primary 为 App 路由，supplementary 为资料库分区，secondary 为列表/详情；
- Playlist：primary 为 App 路由，supplementary 为歌单列表，secondary 为歌单详情；
- Online Sources：primary 为 App 路由，supplementary 为来源列表，secondary 为目录/文件夹/队列；
- Settings：primary 为 App 路由，supplementary 为 `SettingsSecondaryColumn` 的 UIKit 宿主或原生列表，secondary 为 `UIHostingController<SettingsScene>`；
- 选择、列可见性和 collapse 行为由 `RootViewController`/协调器管理，不再由 SwiftUI `@State` 分散管理。

### 4.4 SwiftUI 与 UIKit 的唯一保留边界

Settings 保留如下方式：

- `SettingsHostingController` 持有 `SettingsScene`；
- 通过初始化参数注入现有 `SettingsSceneModel`、`SettingsViewModel` 所需 serving；
- UIKit 只负责导航、presentation、生命周期和系统颜色/语言环境；
- Settings 内部的 `Form`、Picker、Toggle、Sheet、ConfirmationDialog、WebView 逻辑先不动；
- 不允许 Settings SwiftUI 状态向 Core 反向暴露 SwiftUI 类型。

如果后续 Settings 也需要 UIKit 化，应作为独立项目，不作为本次迁移的隐含工作量。

## 5. UI 层分层和代码组织

建议在 `Packages/MusicFreeUI/Sources` 中增加 UIKit 子目录，不立即删除现有 SwiftUI 文件：

```text
DesignSystem/
├── Tokens/                         # 现有 token，保持值不变
├── UIKit/                          # UIColor/UIFont/layout/token adapter
└── Components/UIKit/               # 原生 cell、button、state view

LibraryFeature/
├── UIKit/LibraryViewController.swift
├── UIKit/LibrarySidebarViewController.swift
├── UIKit/LibraryListViewController.swift
├── UIKit/LibraryDetailViewController.swift
├── UIKit/LibraryCollectionCells.swift
└── UIKit/LibraryNavigationCoordinator.swift

PlayerFeature/
├── UIKit/PlayerViewController.swift
├── UIKit/MiniPlayerView.swift
├── UIKit/QueueViewController.swift
├── UIKit/LyricsViewController.swift
└── UIKit/PlayerPresentationController.swift

PlaylistFeature/
├── UIKit/PlaylistViewController.swift
├── UIKit/PlaylistListViewController.swift
├── UIKit/PlaylistDetailViewController.swift
└── UIKit/PlaylistEditorViewController.swift

SettingsFeature/
└── SettingsHostingController.swift      # UIKit 宿主，页面内容仍 SwiftUI
```

推荐保留现有 ViewModel 名称和业务方法，新增 UIKit 层的 `ViewState`/`Snapshot` 转换，不把 UIKit 组件塞回 `AppServices`。

## 6. 分阶段实施路线

### Phase 0：基线和冻结

**目标**：在任何页面迁移前，固定行为和视觉证据。

工作项：

- 固定当前分支和工作区状态；不覆盖现有未提交改动；
- 把现有启动、Tab、三栏、Player Sheet、Mini Player、Settings 作为回归基线；
- 记录所有稳定 accessibility identifier；
- 记录 iPhone 紧凑宽度和 regular-width 的关键截图；
- 固定 UIKit 根壳为唯一生产路径，不增加 UIKit/SwiftUI 实现选择点；
- 固定 Figma `07 Visual QA` 的 30 个运行态基线和当前对比目录。

验收：

- 原有 App target、Core、Infrastructure、UI tests 可编译；
- 关键 BVT 和截图测试结果可定位；
- 后续问题通过定位、修复和提交级回退处理，不切回 SwiftUI 根壳。

估算：**2～3 人日**；串行前置。

### Phase 1：UIKit 根壳、生命周期和 Settings 宿主

**目标**：替换 `RootScene` 的容器职责，并让除 Settings 外的生产页面全部由 UIKit 承载。

工作项：

- 新建 AppDelegate/SceneDelegate/RootViewController；
- 将 `AppContainer` 的启动、重试、降级和服务生命周期接入 UIKit；
- 实现 compact `UITabBarController`；
- 实现 regular `UISplitViewController` 三栏壳；
- 实现 Settings 的 `UIHostingController` 宿主；
- 实现 UIKit Mini Player 容器，但初期可以嵌入现有 Mini Player 作为过渡；
- 不保留 `RootScene` 或任何 SwiftUI 根壳回滚路径；
- 处理 appearance、locale、scenePhase、后台试听停止和文档扫描触发。

验收：

- 不迁移业务页面也能由 UIKit 壳启动；
- compact/regular 两种宽度路由一致；
- Settings 可从四个入口进入，重进后状态不丢；
- App 启动失败/降级/重试路径不回归；
- 可在不改 Core 的情况下切换新旧壳。

当前落地（本工作区）：

- `MusicFreeAppDelegate`、`MusicFreeSceneDelegate` 和 `RootViewController` 已接入；默认创建 UIKit 根壳。
- `MusicFreeAppDelegate` 始终创建 `RootViewController`；不存在 `--use-legacy-swiftui-root`、`musicfree.useLegacySwiftUIRoot` 或其他 UIKit/SwiftUI 切换参数。
- `App/Info.plist` 已声明 `UIApplicationSceneManifest`，确保 UIKit `SceneDelegate` 在真实启动时能接管窗口。
- Settings 已通过 `SettingsHostingController` 嵌入；Library、Playlist、Online Sources 暂以 UIKit 迁移占位承载。
- Mini Player 已由 UIKit 根壳负责挂载、显示隐藏和安全区占位，内容暂复用现有 `MiniPlayerView`；Player Sheet 已由 UIKit `pageSheet` 呈现，业务页面仍列为后续垂直切片，不能把本阶段误判为全量 UIKit 完成。
- regular 宽度已使用三栏 `UISplitViewController` 壳；compact 宽度保留 `UITabBarController`，重复点击 Online Sources 会回到根列表。
- `xcodebuild ... build-for-testing` 已在 `.noindex/DerivedData/MusicPlayer` 通过；后续截图应直接从默认 UIKit 启动路径采集，不再使用或记录 SwiftUI 回滚参数。

估算：**4～6 人日**；依赖 Phase 0。

### Phase 2：UIKit DesignSystem 和通用容器

**目标**：把后续页面需要的视觉和交互基础固定下来，避免每个页面各写一套。

工作项：

- 为 `ColorTokens` 增加 `UIColor`/动态色适配；
- 为 `TypographyTokens` 增加 UIKit 字体适配；
- 为 spacing/layout metrics 增加 `NSDirectionalEdgeInsets`、尺寸和圆角常量；
- 原生实现 ArtworkView、MediaRow、SectionHeader、Empty/Error/Loading State；
- 原生实现播放控制按钮、Pill Action、Mini Player 基础布局；
- 固定 44pt 最小点击目标、暗色/浅色动态颜色和 SF Symbols 名称；
- 统一 cell 的 accessibility label/value/hint/identifier；
- 统一异步图片加载的取消、复用和占位策略。

验收：

- DesignSystem 单元测试覆盖 token 映射；
- UIKit 组件在 iPhone 和 regular-width 容器中无约束冲突；
- Figma `00 Foundations`/`01 Components` 与 token/组件几何一致；
- 不引入页面级硬编码颜色和间距。

估算：**3～5 人日**；可与 Phase 1 后半段并行，但组件 API 需先冻结。

当前落地（2026-08-29）：

- 新增 `DesignSystem/UIKit` UIKit token adapter：`UIColor` 动态语义色、`UIFont` 动态字体、`NSDirectionalEdgeInsets`、最小点击区域、compact/regular artwork 尺寸。
- 新增原生组件：`MusicFreeUIKitArtworkView`、`MusicFreeUIKitMediaRowView`、`MusicFreeUIKitSectionHeaderView`、空态/错误态/加载态、播放控制按钮、Pill Action 和 Mini Player 基础布局。
- 组件统一处理复用前可更新的图片/占位/加载状态、44pt 触控目标、动态系统颜色和 accessibility label/value/hint/traits；未修改既有 SwiftUI token 与组件 API。
- 新增 token/组件契约测试至 `MusicFreeUITests/DesignSystemTests.swift`，便于后续业务页只组合组件而不复制页面级颜色和间距。
- `DesignSystem` 编译通过；`MusicFreeUITests` build-for-testing 通过；iPhone 17 Pro Simulator 上 UIKit DesignSystem 测试 1/1 通过。
- 整 App `MusicFree` build-for-testing 通过；现有 SwiftUI 页面、UIKit 根壳和新增 UIKit DesignSystem 可同时链接。
- 完整 `MusicFreeUITests` 当前为 143/144 通过，唯一失败为既有 `cancellingFolderImportCancelsEveryActiveImport()` 的导入取消时序断言，与本阶段 UIKit 改动无关；需另行修复，不能作为 Phase 2 通过的新增回归。

### Phase 3：LibraryFeature

**目标**：优先迁移资料库，利用现有 UIKit CollectionView 代码验证完整迁移模式。

迁移顺序：

1. Library Home 和分区入口；
2. Tracks/Favorites/Recent 列表；
3. Albums/Artists/Genres/Folders CollectionView；
4. 搜索、分页、刷新、空态、失败重试；
5. Album/Artist/Genre/Folder/Track 详情；
6. 导入进度、导入失败确认、删除确认、加入歌单、队列操作；
7. compact NavigationController 和 regular 三栏选择同步。

关键实现要求：

- 将 `NativeLibraryCollectionView` 和 `NativeTrackCollectionView` 的 `UIHostingConfiguration` cell 内容替换成原生 Cell；
- 继续使用 Diffable Data Source，禁止通过 `reloadData` 破坏滚动位置和双指多选；
- 将 `LibraryViewModel` 的分页、搜索 generation、导入 Task、收藏 mutation 和 change stream 作为唯一状态来源；
- 详情页通过 navigation coordinator 推送，不让业务 ViewModel 直接持有 UIViewController；
- 保留现有 `library.*` accessibility identifier；
- 保留现有 collection context menu、双指选择和批量队列操作；
- Artwork cell 必须在复用时取消旧任务并校验 item ID，避免错图。

验收：

- Library 10 个 Figma 运行态基线逐页截图对比；
- 资料库空态、加载、失败、刷新、编辑、多选、详情和导入流通过；
- compact 和 regular 之间切换不丢 section/详情路径；
- 长列表滚动 FPS、内存和主线程耗时不劣于迁移前；
- Library 生产路由已由 UIKit 控制器承载；旧 SwiftUI Library 页面不属于 App 生产入口。

估算：**7～10 人日**；依赖 Phase 1、2；建议作为第一批业务迁移。

当前执行进度（2026-08-29）：

- 已新增 `LibraryFeature/UIKit/LibraryHomeViewController.swift`，将资料库入口、分区入口和最近添加专辑网格改为原生 UIKit `UICollectionViewDiffableDataSource` + Compositional Layout。
- 已接入 UIKit DesignSystem 的颜色、字体、间距、Artwork、Section Header、空态/错误态/加载态组件；Artwork 加载在 cell 复用时取消并校验 album ID。
- `RootViewController` 的 UIKit shell 已在 compact Tab 和 regular Split 的 Library route 使用该控制器；Playlist、Online Sources 仍是迁移占位，Settings 仍为 SwiftUI HostingController。
- Library 首页 UIKit 导航栏已恢复与运行基线一致的 `+ / …` ControlGroup；`…` 菜单保留刷新入口，`+` 使用原生 `UIDocumentPickerViewController` 触发本地媒体导入。
- 已修复 Swift 6 `@MainActor` 控制器 `deinit` 访问 `AnyCancellable` 的编译错误，并接入 `LibraryViewModel.startObservingChanges()`。
- 已新增 `LibraryFeature/UIKit/LibraryTracksViewController.swift`，覆盖 Tracks/Favorites/Recent 的原生 UIKit 列表、分组、Artwork 复用取消、加载/空态/失败重试、下拉刷新、分页、艺人名补充和播放回调。
- 已新增独立 `MusicFreeBVTUITests/testUIKitShellLibrarySongsSlicePlaysSeededTrack()`，通过历史兼容参数 `--uikit-shell --bvt-seed-audio` 验证 UIKit 根壳、Songs 导航、原生 collection view、种子歌曲和 Mini Player，不改变现有 SwiftUI BVT 的启动参数；当前 UIKit 已是默认根路径。
- 已新增 `LibraryFeature/UIKit/LibraryCollectionsViewController.swift`，覆盖 Albums/Artists/Genres/Folders：Albums 使用原生网格；Artists/Genres/Folders 使用与现有 SwiftUI 一致的字母分组列表；加载、空态、失败重试、下拉刷新、分页、Artwork 复用取消和可访问性标识均由 UIKit 原生实现。
- `RootViewController` 已将 Albums/Artists/Genres/Folders 从迁移占位切换到该原生控制器。
- 已新增 `LibraryFeature/UIKit/LibraryCollectionDetailViewController.swift`，将 Album/Artist/Genre/Folder 详情的集合头部、过滤后的曲目、播放/随机播放、异步 Artwork 和加载/空态/失败状态改为原生 UIKit。
- 集合详情第一批动作已接入：原生长按菜单支持播放、收藏/取消收藏、分享、删除确认、下一首播放、加入队列和添加到播放列表；导航栏集合菜单支持对整组歌曲执行下一首播放、加入队列和添加到播放列表。现有 SwiftUI 播放列表页面通过 `LibraryAddToPlaylistViewController` 作为 UIKit sheet 宿主复用。
- 集合详情已补充显式选择模式：`选择`/`完成` 导航操作、选中态指示器和批量删除确认；删除后通过 diffable snapshot 保留当前详情状态。
- Library 首页最近添加专辑已从迁移占位切换到真实 UIKit 集合详情；新增 `testUIKitShellLibraryCollectionDetailExposesNativeActions()`，已在 iPhone 17 Pro Simulator 通过。
- 新增 `LibraryFeature/UIKit/LibraryTrackDetailViewController.swift`，集合详情点击歌曲进入原生 UIKit 歌曲详情；包含 Artwork、艺人/专辑/时长、歌词、播放、收藏、删除和添加到播放列表，新增 `testUIKitShellLibraryTrackDetailRendersNativeSurface()`，已在 iPhone 17 Pro Simulator 通过。
- `xcodebuild ... build-for-testing` 已通过（DerivedData：`.noindex/DerivedData/uikit-planning-development`）。
- 已在 iPhone 17 Pro Simulator 和 iPad Pro Simulator 以 `--uikit-shell`（历史兼容参数）实际启动并截图：`.noindex/artifacts/uikit-library-home-iphone17pro.png`、`.noindex/artifacts/uikit-library-home.png`。截图仅证明当前运行时布局和数据渲染，不替代真机验收。

Songs 垂直切片已完成运行时门禁：`MusicFreeBVTUITests/testUIKitShellLibrarySongsSlicePlaysSeededTrack()` 使用 `--uikit-shell --bvt-seed-uikit-songs`（历史兼容参数）通过（1/1，约 18.9 秒），并已保存 `.noindex/artifacts/uikit-songs-20260829-v9/BVT.xcresult` 及截图附件。截图时机已调整为歌曲标题和艺人副标题均出现之后。

Songs 与 Figma 基线 `.noindex/tmp/visual-compare-20260828/current-v5/figma-songs.png` 的 393×852 对比为 AE 84679（25.29%）、RMSE 0.1302；剩余差异主要来自 Simulator 状态栏、系统抗锯齿和少量原生控件渲染，不能据此宣称像素级完全一致，也不替代真机性能验收。

下一小步：在 Simulator 恢复后执行 browse/detail focused BVT；Library 稳定后进入 PlayerFeature 迁移。

### Phase 4：PlayerFeature

**目标**：迁移高交互、高视觉敏感的播放器页面。

迁移范围：

- `PlayerScene` → `PlayerViewController`；
- `MiniPlayerView` → UIKit Mini Player；
- `NowPlayingView` → UIKit artwork/transport/header/content layout；
- `QueueView` → `QueueViewController`；
- `LyricsView` → `LyricsViewController` 或 Player 内部 child controller；
- 播放进度、拖动、播放/暂停、前后曲、循环/随机、收藏、队列编辑、历史、歌词；
- Player Sheet 的透明背景、下拉关闭、暗色控制和 presenting page 暴露效果。

关键实现要求：

- `PlayerViewModel` 继续是播放快照和命令的唯一来源；
- UIKit 订阅快照时只更新受影响的 label/button/progress，不重建整棵视图树；
- 保留现有 `PlaybackSessionSnapshot`、generation 和取消语义；
- 将当前 `NowPlayingPresentationObserverViewController` 的 Sheet 观察逻辑改为 presentation controller delegate/transition coordinator；
- 播放器背景 Artwork 使用独立可复用的 UIKit layer，避免 Sheet 移动时产生固定黑色遮罩；
- Queue/Lyrics 采用 child ViewController，避免多个 ScrollView 嵌套竞争手势；
- 系统音频路由和远程控制仍由现有服务层负责，Controller 只映射 UI 命令。

验收：

- Player 9 个 Figma 基线状态逐一截图对比；
- 首帧、播放、暂停、缓冲、队列、历史、歌词和关闭 Sheet 无明显跳动；
- Mini Player 在四个 Tab 之间保持同一播放快照；
- 真机验证锁屏/后台/耳机路由/中断后 UI 和服务状态一致；
- 记录主线程刷新耗时、图片解码耗时和长时间播放内存曲线。

当前执行进度（2026-08-29）：

- 已新增 `PlayerFeature/UIKit/PlayerMiniPlayerViewController.swift`，Mini Player 改为 UIKit 原生布局，继续复用 `PlayerViewModel`/`PlaybackServing`，并修正内部 metadata stack 抢占点击命中的问题。
- 已新增 `PlayerFeature/UIKit/PlayerNowPlayingViewController.swift`，覆盖封面、标题/艺人、收藏、更多、进度拖动、播放控制、音量、AirPlay、歌词和队列入口；快照更新只刷新受影响的 UIKit 控件，不重建页面树。
- `RootViewController.presentPlayer()` 已切换到 UIKit Now Playing；Queue 已替换为原生 `PlayerQueueViewController`，覆盖历史、继续播放、播放模式、删除、清空和编辑排序；Lyrics 已替换为原生 `PlayerLyricsViewController` sheet，支持加载/重试、定时歌词跟随播放位置和偏移设置。
- 已增加 `testUIKitShellNowPlayingSliceRendersNativePlayerControls()`，并完成 `build-for-testing`。前几轮运行已证明 Mini Player 点击事件可到达 UIKit 回调；随后 CoreSimulator 服务在连续 UI Test 后失联，当前无法完成新的弹层层级/截图复验，不能把 Now Playing 运行态门禁标为通过。

下一小步：恢复 CoreSimulator 后先复验 Now Playing、Queue、Lyrics 的 modal 层级和截图；随后补齐 Queue/歌词的运行态 BVT，再进入 PlaylistFeature UIKit 迁移。

估算：**7～10 人日**；建议在 Library 完成并稳定后开始。

### Phase 5：PlaylistFeature

**目标**：迁移歌单列表、详情和编辑流。

工作项：

- Playlist list ViewController 和 diffable snapshot；
- Playlist detail、歌曲排序/移动/删除；
- 创建、编辑、删除歌单；
- Add To Playlist sheet 改为 UIKit sheet；
- 与 Library 的加入歌单入口共享 action model；
- compact push 与 regular detail column 两种路径；
- 复用现有 `PlaylistListViewModel`、`PlaylistDetailViewModel` 和 candidate loader。

验收：

- Playlists 5 个 Figma 基线状态截图对比；
- 创建/修改/删除/批量添加歌曲、空态和失败重试通过；
- 播放/下一首播放命令与迁移前一致；
- list selection 在横竖屏/compact/regular 切换不丢失。

当前执行进度（2026-08-29）：

- 新增 `PlaylistFeature/UIKit/PlaylistListViewController.swift`：原生 UITableView、加载/空态/失败重试、下拉刷新、创建/重命名/删除和上下文菜单；复用 `PlaylistListViewModel`。
- 新增 `PlaylistFeature/UIKit/PlaylistDetailViewController.swift`：原生歌单头部、播放/随机播放、歌曲列表、编辑排序、移除歌曲、单曲播放和失败提示；复用 `PlaylistDetailViewModel`。
- 新增 `PlaylistFeature/UIKit/PlaylistAddTracksViewController.swift`：UIKit modal 添加歌曲，复用 `PlaylistTrackCandidateLoader` 和 `PlaylistDetailViewModel.addTracks`。
- `RootViewController` 的 compact Tab 与 regular detail navigation 已将 Playlist 从 migration placeholder 切换为上述 UIKit 控制器；保留 Online Sources 独立占位边界，不改变 Settings SwiftUI 宿主。
- App build 与 build-for-testing 已通过（DerivedData：`.noindex/DerivedData/uikit-main`）；CoreSimulatorService 当前不可用，尚未完成 Playlist 运行态截图和 Figma 像素对比。

下一小步：恢复 Simulator 后补 Playlist 五组 Figma 状态截图、compact/regular 导航和 CRUD BVT，再进入 Online Sources 原生列表迁移。

估算：**4～6 人日**；依赖 Phase 2，建议在 Library 后进行。

### Phase 6：Online Sources

**目标**：将目前位于 `SettingsFeature/OnlineSourceScene.swift` 的在线源页面独立为 UIKit 迁移域。

迁移范围：

- 来源列表、应用隐私协议和来源隐私协议；
- DS Audio/Google Drive 等来源配置和授权表单；
- 目录根页、文件夹浏览、搜索结果；
- 试听、下载队列、导入进度和失败重试；

当前执行进度（2026-08-29）：

- 新增 `SettingsFeature/UIKit/OnlineSourcesHostingController.swift`，将现有 `OnlineSourcesScene` 作为 UIKit 根壳中的临时功能宿主，恢复完整在线源列表、授权、目录、队列和隐私流程；根壳不再显示迁移占位。
- `RootViewController` 缓存并注入 `OnlineSourcesSceneModel`，沿用现有 DS Audio/Google Drive 授权闭包、BVT fixture 和凭据清理路径。
- 该适配仅是功能连续性边界，不计入“非 Settings 页面完全 UIKit”完成度；下一阶段需先迁移来源列表/应用隐私/添加来源，再迁移目录与下载队列，最后移除 `OnlineSourcesScene` 宿主。
- 来源开关、移除来源、二次验证码和授权失败提示；
- compact NavigationController 和 regular secondary/detail 两种布局。

### 2026-08-30 重启后复验

- 复用 `.noindex/DerivedData/uikit-planning-development` 完成 App build 与 build-for-testing。
- `MusicFreeFeatureLoadingUITests` 的 Library/Playlist/Settings 三个截图用例均为 `Success`，结果包为 `.noindex/tmp/visual-compare-20260830/followup-v2.xcresult`。
- Settings 滚动后的“当前 Tab 圆形气泡 + Mini Player 标题/主操作”已确认是 iOS 26 collapsed Tab Bar 的 inline accessory 状态；展开态仍保留封面、副标题和下一首操作。
- 视觉回归中 Mini Player 背景保持不透明，Library 最近添加卡片继续使用两列固定几何；未发现需要回退 `contentScrollView` 转发的证据。
- 本次复验后 CoreSimulatorService 再次失联，因此后续新的运行态截图需在服务恢复后补采；已有 `followup-v2.xcresult` 不受该失联影响。

关键实现要求：

- `OnlineSourcesSceneModel` 的 snapshot、audition snapshot、download/import snapshot 和错误字段保持不变；
- UI 只消费 `OnlineSourceServing`/`OnlineAuditionServing`，不直接处理凭据和短期 URL；
- 将下载队列和目录浏览拆成独立 child Controller，避免一个页面承担所有异步状态；
- 保留隐私协议的系统/本地 HTML 展示边界；
- 目录 cell 使用 provider/object ID 作为稳定 diffable identifier；
- 试听不进入正式播放队列、不写播放历史的规则保持不变。

验收：

- Online Sources 2 个现有关键 Figma 基线加上授权/错误/队列状态逐一截图；
- 成功 BVT 的隐私、多源、目录、搜索、导入流程继续通过；
- 真实 Provider/真机验证单独记录，不能用 Fake BVT 代替；
- Online Sources 关闭或撤销隐私后，所有网络操作即时停止。

估算：**5～8 人日**；依赖 Phase 2，可与 Playlist 后半段并行，但根壳集成必须串行。

### Phase 7：UIKit 壳正式切换、旧路径收口

**目标**：完成从迁移过渡代码到“UIKit 主路径”的收口。

工作项：

- 默认路由切换为 UIKit 主路径；
- Settings 通过 `SettingsHostingController` 接入所有 compact/regular 入口；
- 删除迁移期间仅用于过渡的 UIHostingConfiguration cell；
- 删除旧 Feature Scene 的生产路由，仅保留需要的 SwiftUI Settings 文件；
- 移除旧 `RootScene`、旧 SwiftUI Tab/Split/Sheet 壳和所有 Debug 切换开关；
- 更新 `Scripts/check_architecture.sh`，禁止非 Settings 生产页面重新依赖 SwiftUI；
- 更新模块文档和 Figma 映射文档。

验收：

- `rg` 结果显示非 Settings 页面不再依赖 SwiftUI 页面壳；
- App 只创建一个 UIKit 根导航树；
- Settings SwiftUI 仍能加载、保存、重置、打开隐私和诊断页面；
- 全量单元测试、App 集成测试、BVT、截图和真机回归完成。

估算：**3～4 人日**；依赖 Phase 3～6 全部完成。

### Phase 8：发布前稳定性和视觉验收

**目标**：把“能跑”提升为“可以发布”。

工作项：

- iPhone 紧凑宽度、iPad/regular-width、横竖屏和动态字体矩阵；
- 暗色/浅色、英文/中文、空数据/大数据、导入中/失败、网络不可用；
- Screenshot attachment、side-by-side、diff 和人工 Figma Desktop 复核；
- 启动首帧、Tab 切换、列表滚动、图片解码、Sheet 转场性能；
- 真机音频后台、耳机路由、系统中断、锁屏和长时间播放；
- 内存泄漏、Controller retain cycle、Task 未取消和重复观察者；
- 发布门禁记录和回滚包。

估算：**6～9 人日**；必须串行于主要实现完成后，但部分自动化可提前并行。

## 7. 工作量和并行关系

| 阶段 | 估算人日 | 依赖 | 可并行内容 |
| --- | ---: | --- | --- |
| Phase 0 基线 | 2～3 | 无 | 无，作为统一前置 |
| Phase 1 UIKit 根壳 | 4～6 | Phase 0 | 与 Phase 2 的 token 适配部分并行 |
| Phase 2 DesignSystem UIKit | 3～5 | Phase 0 | 可与 Phase 1 后半段并行 |
| Phase 3 Library | 7～10 | Phase 1/2 | 详情和组件可拆分并行 |
| Phase 4 Player | 7～10 | Phase 1/2 | Queue/Lyrics 可拆分，但 Player 壳集成串行 |
| Phase 5 Playlist | 4～6 | Phase 2 | 可与 Player 后半段并行 |
| Phase 6 Online Sources | 5～8 | Phase 1/2 | 目录、队列、授权表单可拆分 |
| Phase 7 收口 | 3～4 | Phase 3～6 | 基本串行 |
| Phase 8 稳定性 | 6～9 | 主要实现完成 | 自动化测试和人工真机可部分并行 |
| **总计** | **41～61** |  | 并行后实际日历时间会缩短 |

按发布质量增加约 10%～15% 的未知量，建议对外承诺时按 **45～62 人日**管理，而不是承诺一次性固定总工期。

### 7.1 为什么不是 94～144 人日

该上限估算隐含了以下工作，但当前仓库已经不需要全部重新做：

- 从零重建 Domain、Repository、服务协议和播放层；
- 从零重建设计系统和 Figma 基线；
- 把 Settings 也完整 UIKit 化；
- 从零实现原生列表、多选、播放器滑杆、音频路由和 WebView；
- 重新设计所有交互和测试数据。

当前仓库已经有：

- 已冻结的 Core/Infrastructure/UI 模块接口；
- 已有 Library/Track UIKit CollectionView 基础；
- 已有播放器 UIKit 桥接和 Sheet 观察代码；
- 30 个运行态 Figma Visual QA 基线；
- 已有 ViewModel、BVT、集成测试和截图测试；
- 用户已明确 Settings 保留 SwiftUI。

因此合理做法是按增量迁移计算，且每阶段用真实构建、截图和真机结果重新修正后续工作量。

## 8. 状态管理和并发方案

### 8.1 ViewModel 保持业务唯一性

UIKit Controller 不复制业务状态，只保存视图生命周期状态：

- 业务状态：现有 `LibraryViewModel`、`PlayerViewModel`、`Playlist*ViewModel`、`SettingsViewModel`、`OnlineSourcesSceneModel`；
- 视图状态：当前可见 section、selection、loading indicator、cell snapshot、presented controller；
- 导航状态：由 App/Feature Navigation Coordinator 统一持有；
- Task：由 ViewModel 或 Feature Coordinator 持有，Controller 消失时只取消属于视图的订阅/任务。

### 8.2 Observation/Combine 适配

现有代码同时使用 `ObservableObject`/Combine 和 `@Observable`/Observation。迁移阶段采用双适配，不把框架类型下沉到 Core：

- `ObservableObject`：Controller 持有 cancellable，接收 `objectWillChange` 后在主线程刷新指定区域；
- `@Observable`：增加一个 UIKit 侧 `ObservationBinder`，使用 `withObservationTracking` 重新触发快照更新；
- 所有绑定均在 `@MainActor` 执行；
- Controller 重建或复用时先取消旧观察，再订阅新模型；
- 不在每一帧发布布局状态，尤其是 Player Sheet 拖动和进度更新。

### 8.3 生命周期

- `viewDidAppear`：开始页面需要的 observation/初次加载；
- `viewWillDisappear`：取消页面级一次性任务和图片预取；
- `deinit`：断言 cancellable、Task 和 child controller 已释放；
- App 生命周期仍由 `AppContainer`/`AppLifecycleCoordinator` 管理，Controller 不直接 stop 全局服务；
- Online audition 继续在 scene 非 active 时停止，避免迁移后行为漂移。

## 9. 视觉一致性和 Figma 闭环

### 9.1 设计基线

现有资料：

- Figma 文件：`DfZ9E3D6LfZZdQS6fPqT7s`；
- `Docs/Design/MusicFreeUI-FigmaMap.md`；
- `Docs/Design/VisualQA-2026-08-28.md`；
- `.noindex/tmp/visual-compare-20260828/`；
- `07 Visual QA` 已有 30 个运行态基线：Library 10、Playlists 5、Settings 4、Player 9、Online Sources 2。

### 9.2 变更顺序

任何后续 UI 修改必须按以下顺序：

1. 在 Figma 中修改对应 token/component/state；
2. 在 `DesignSystem/Tokens` 或 UIKit/SwiftUI 适配层修改同一语义 token；
3. 修改 UIKit/Settings SwiftUI 页面；
4. 用同一 fixture、同一设备尺寸生成运行截图；
5. 生成 side-by-side/diff，确认结构、尺寸、颜色、文字和层级；
6. 将确认后的状态和差异记录回 `VisualQA`；
7. 通过代码审查和发布门禁后合并。

Figma 中使用系统颜色/语义变量，不在页面中复制硬编码 hex；SF Symbols 以 `systemName` 记录；动态队列、下载快照和用户数据只用代表性样例及状态变体表达。

### 9.3 验收层级

必须分开记录：

- 源码编译通过；
- 单元/集成测试通过；
- Simulator UI/BVT 通过；
- Figma 截图结构和像素对比通过；
- Figma Desktop 字体/SF Symbols 人工复核通过；
- 真机性能和音频稳定性通过。

任何一层未验证，都不能写成“设计稿和实际完全一致”或“真机性能已解决”。

## 10. 测试策略

### 10.1 保留并复用现有测试

- `Packages/MusicFreeCore/Tests`：服务和状态机测试不改语义；
- `Packages/MusicFreeUI/Tests/MusicFreeUITests`：ViewModel、loader、队列、设置和页面契约测试继续保留；
- `AppTests/MusicFreeAppIntegrationTests.swift`：启动、组合和服务生命周期继续覆盖；
- `AppUITests/MusicFreeBVTUITests.swift`：主流程、regular-width、在线源、播放器和播放列表继续作为黑盒门禁；
- `AppUITests/MusicFreeFeatureLoadingUITests.swift`：配置加载、设置、截图和播放器视觉基线继续使用。

### 10.2 新增 UIKit 测试

每个迁移 Feature 至少增加：

- Controller 创建和依赖注入测试；
- loading/empty/failed/loaded 状态测试；
- navigation push/pop、split selection、tab reselection；
- diffable snapshot 稳定性和 selection 恢复；
- Controller 消失后 Task/cancellable 取消测试；
- accessibility identifier、label、traits 测试；
- 关键页面截图测试。

### 10.3 性能门禁

每阶段至少记录：

- 启动到首个可交互画面的时间；
- Tab 切换主线程阻塞时间；
- 长列表首屏和滚动期间主线程耗时；
- Artwork 解码峰值和缓存命中率；
- Player Sheet 首次展示和下拉转场帧率；
- Controller/Task/图片任务是否释放。

Simulator 只能用于回归和截图，真机数据单独记录。

## 11. 风险、依赖和回滚

### 11.1 主要风险

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| UIKit 壳与现有未提交改动重叠 | 高 | 每阶段小提交；不 reset/clean；先保存 diff 和基线 |
| `@Observable` 与 UIKit 观察桥接错误 | 高 | 统一 ObservationBinder；增加生命周期/重复订阅测试 |
| `UIHostingConfiguration` 残留导致性能收益不明显 | 中高 | 最终页面禁止非 Settings Hosting Cell；逐页清理 |
| regular/compact 两套导航状态漂移 | 高 | Navigation Coordinator 单一状态源；每阶段双宽度验收 |
| Player Sheet 透明背景和交互下拉回归 | 高 | 先锁定 presentation controller 行为，再迁移内容布局 |
| 动态图片/队列/网络状态截图不稳定 | 中 | 使用固定 fixture；动态数据只做状态变体，不固定真实网络结果 |
| 系统字体/Tab Bar/SF Symbols 像素差异 | 中 | Simulator 数值对比 + Figma Desktop 人工复核分开记录 |
| UIKit 导航迁移中改变业务规则 | 高 | Controller 只调用现有 serving；不修改 Core 协议和状态机 |

### 11.2 处理方式

- Phase 1～6：问题按 Feature 定位并修复，必要时回退对应 Git 提交；不切回 SwiftUI 页面或根壳；
- Phase 7：删除过渡代码后继续以 UIKit 作为唯一生产路径。

禁止使用 `git reset --hard`、`git clean` 或覆盖用户未提交改动来制造“干净环境”。构建统一复用：

```text
.noindex/DerivedData
.noindex/tmp
.noindex/artifacts
```

## 12. 完成定义和发布门禁

### 12.1 单 Feature 完成定义

- 页面由目标 UIKit Controller/UIView/Cell 渲染；
- 非 Settings 页面不再依赖 `UIHostingConfiguration` 作为业务 cell 内容；
- compact 和 regular 两种布局都可用；
- loaded/empty/loading/failed/editing/disabled 状态覆盖；
- 现有业务 ViewModel 和服务行为没有改变；
- 现有 accessibility identifier 保持或有明确兼容映射；
- 单元测试、BVT 和截图对比有结果文件；
- 至少一个真实设备回归关键交互；
- 不存在旧 SwiftUI 路由回滚；问题通过 UIKit 修复和提交级回退处理。

### 12.2 全量迁移完成定义

- UIKit 是 App 根壳和 Library/Player/Playlist/Online Sources 主路径；
- Settings 仍由 SwiftUI `UIHostingController` 承载且行为完整；
- 旧 `RootScene`、旧 SwiftUI Tab/Split/Player 页面生产路径已移除；
- `Scripts/check_architecture.sh` 能阻止非 Settings 页面重新引入 SwiftUI 壳；
- 30 个已有视觉基线及新增异常态全部有截图证据；
- Simulator、单元、集成、BVT、真机性能和音频矩阵分别通过；
- 启动、滚动、Player Sheet、后台播放和在线源稳定性不低于迁移前；
- 有 UIKit 构建、发布说明和问题修复记录；不提供 SwiftUI 回滚构建。

## 13. 建议的实际执行顺序

不建议从 Player 直接开始，也不建议先删除 SwiftUI。推荐顺序：

```text
Phase 0 基线
  ↓
Phase 1 UIKit 根壳 + Settings 宿主
  ↓
Phase 2 UIKit DesignSystem
  ↓
Phase 3 Library（验证列表、导航、状态和视觉闭环）
  ↓
Phase 4 Player（验证 Sheet、动画、音频和高频更新）
  ↓
Phase 5 Playlist
  ↓
Phase 6 Online Sources
  ↓
Phase 7 切换主路径并删除过渡代码
  ↓
Phase 8 发布前真机/视觉/性能门禁
```

当前执行顺序以 UIKit 根壳为唯一入口：先完成 UIKit DesignSystem，再按 Library、Player、Playlist、Online Sources 逐模块收口；Settings 保持 SwiftUI 宿主，不引入任何根壳回滚开关。
