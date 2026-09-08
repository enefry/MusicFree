# MusicFree UI → Figma 基线

> 这份文档记录代码与 Figma 的对应关系。后续 UI 修改先更新 Figma 的变量、组件或状态，再同步代码；不要只在单个页面里写新的颜色、间距或控件样式。

## 设计源

- Figma：`DfZ9E3D6LfZZdQS6fPqT7s`（目标文件）
- 工程：`MusicFree.xcodeproj` / `Packages/MusicFreeUI`
- UI 框架现状：UIKit 根壳和 Library、Player、Playlist、Online Sources 生产页面已接管；Settings 继续 SwiftUI，旧 SwiftUI 根壳和运行时回滚路径已移除
- 产品字体：iOS 系统字体（SF Pro / SF Pro Rounded）；图标使用 SF Symbols

## 路由与 Figma 页面

| Figma 页面 | 代码入口 | 设计范围 |
| --- | --- | --- |
| `00 Foundations` | `DesignSystem/Tokens/*`, `DesignSystem/UIKit/UIKitTokens.swift` | 颜色、排版、间距、圆角、点击目标、Artwork 尺寸、明暗模式 |
| `01 Components` | `DesignSystem/Components/*`, `DesignSystem/UIKit/UIKit*.swift` | Artwork、Media Row、Section Header、Pill Action、Playback Control、空态/错误/加载态、Mini Player、Tab/导航 |
| `02 Library` | `LibraryFeature/UIKit/*ViewController` | 本地资料库、浏览、详情、搜索、导入和删除状态 |
| `03 Player` | `PlayerFeature/UIKit/*ViewController` | Mini Player、Now Playing、队列、歌词、播放/暂停/加载/错误状态 |
| `04 Playlists` | `PlaylistFeature/UIKit/*ViewController` | 歌单列表、详情、编辑、添加歌曲、空态和删除确认 |
| `05 Online Sources` | `SettingsFeature/UIKit/OnlineSourcesViewController` 及子控制器 | 在线源列表、目录、试听、下载/导入队列、授权和隐私状态 |
| `06 Settings` | `SettingsScene` 与 `SettingsFeature/*` | 设置分类及 General、Playback、Import、Storage、Privacy、About 子页面 |

## 当前运行态校准状态

- `07 Visual QA` 已建立 31 张 `393 × 852` 运行态基线：Library 10 张、Playlists 5 张、Settings 4 张、Player 9 张、Online Sources 3 张；均对应 iPhone 17 Pro / iOS Simulator 26.5。Player 节点为 `152:3`–`152:11`；Online Sources 列表根页为 `379:2`，来源详情根目录与文件夹为 `154:2`–`154:3`。
- 2026-08-28 的 v4/v5 版本已把主要图标从 Material Symbols 代理替换成系统 `Image(systemName:)` 渲染资源；业务 SwiftUI/数据代码未改动。
- v4 基础页证据位于 `.noindex/tmp/visual-compare-20260828/comparison-v4/`；v5 七页补齐证据位于 `.noindex/tmp/visual-compare-20260828/comparison-v5/`。后续页面沿用同一 fixture、尺寸和对比命名规则。
- v5 针对 Artist Detail 和 Track Detail 做了 Figma-only 几何/图层校准，不改变 App 业务 UI 源码。
- Player 本轮从 `player-v4.xcresult` 恢复了 9 个运行截图，并在 Figma 建立 Songs、Mini Player、Now Playing 默认/队列/历史/歌词、Queue、Queue History、Queue Sorting 状态基线；对应对比产物位于 `.noindex/tmp/visual-compare-20260828/comparison-player/`。
- Player 基线的 Frame、名称和位置可编辑；运行截图作为像素验收层保留在 Frame 内，避免把动态队列/历史内容错误固化为业务数据。
- Online Sources 已保存来源列表根页、DS Audio 根目录和文件夹三个状态，在 Figma 建立节点 `379:2`、`154:2`、`154:3`；详情页对比产物位于 `.noindex/tmp/visual-compare-20260828/comparison-online/`，列表根页运行截图位于 `.noindex/artifacts/uikit-runtime-2026-08-30/current-normalized/20-online-sources-root.png`。外部网络导入流程不作为静态设计稿数据固化。
- Figma MCP 当前仍无法提供可渲染的 SF Pro/SF Symbols 字体，因此文字和系统 Tab Bar 仍需在 Figma Desktop 做最终像素验收。

## 代码 Token 基线

### Colors

- `backgroundPrimary` → `UIColor.systemBackground`
- `backgroundSecondary` → `UIColor.secondarySystemBackground`
- `backgroundGrouped` → `UIColor.systemGroupedBackground`
- `surfaceElevated` / `playerSurface` → `UIColor.tertiarySystemBackground` / secondary background
- `foregroundPrimary` / `Secondary` / `Tertiary` → label / secondaryLabel / tertiaryLabel
- `accent` → system pink；`accentSoft` → system pink 14% opacity
- `positive` / `warning` / `destructive` → system green / orange / red
- `separator` → system separator

### Spacing / geometry

| Token | Value |
| --- | ---: |
| hairline | 1 |
| xSmall | 4 |
| small | 8 |
| medium | 12 |
| large / contentInset | 16 |
| xLarge | 24 |
| xxLarge | 32 |
| minimumHitTarget | 44 |
| compactArtworkDimension | 52 |
| regularArtworkDimension | 64 |
| compactRowMinimumHeight | 68 |
| regularRowMinimumHeight | 80 |
| artworkCornerRadius | 8 |
| controlCornerRadius | 22 |

### Typography

- Screen title: `.title`, semibold
- Section title: `.headline`
- Row title/body: `.body`
- Row subtitle/secondary: `.subheadline`
- Caption: `.caption`
- Monospaced metadata/license text: system footnote monospaced

## 状态矩阵

所有主要页面至少保留以下设计状态：`loaded`、`empty`、`loading`、`refreshing`、`failed/retry`、`editing/selection`、`disabled`。播放器额外包含 `idle`、`playing`、`paused`、`buffering`、`lyrics available/unavailable`、`queue empty`。

## 设计约束

1. 明暗模式使用同一语义变量集合切换；不要在页面里新增硬编码颜色。
2. 相关内容使用 Auto Layout；只有真正重叠的装饰才使用绝对位置。
3. `44pt` 是最小可交互目标；列表行和 Artwork 尺寸以代码 token 为准。
4. SF Symbols 通过名称记录，不保存手工 codepoint。
5. Settings 保留 SwiftUI 作为实现候选；Library、Player、Playlist、Online Sources 的页面设计与组件先按 UIKit 可落地结构整理。
6. 动态数据不全部复制成静态稿：使用代表性样例 + 状态/变体表达可变内容。
