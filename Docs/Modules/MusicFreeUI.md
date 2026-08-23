# MusicFreeUI

路径：`Packages/MusicFreeUI`

`MusicFreeUI` 提供 SwiftUI 页面、UIKit 原生集合交互、设计系统、可访问性标识和用户操作到 AppServices 的映射。

## Targets

| Target | 功能 |
| --- | --- |
| `DesignSystem` | 颜色、字体、布局、图标、共享组件、预览支持、本地化资源和通用状态视图。 |
| `LibraryFeature` | Songs、Favorites、Albums、Artists、Genres、Folders、搜索、导入进度、详情页、元数据编辑和集合/歌曲菜单。 |
| `PlayerFeature` | Mini Player、Now Playing、播放控制、队列、历史、歌词、进度、速度、音量、均衡器和音频路由入口。 |
| `PlaylistFeature` | 歌单列表、创建/重命名/删除、详情、添加/移除歌曲和排序。 |
| `SettingsFeature` | 播放、导入、元数据/歌词 Provider、隐私、存储维护、外观、语言、图标、诊断和版本信息。 |

## UI 约束

- 页面只消费 AppServices 和 Core API，不直接创建 SwiftData、文件系统或 VLCKit 实例。
- 空值或没有内容的媒体字段按确定性优先级省略，不显示误导性占位信息。
- 删除、移除历史、移除歌单关系和删除本地媒体必须使用各自的服务语义。
- Now Playing 的系统 Sheet、内部滚动和关闭手势保持单一状态机；集合菜单优先使用 UIKit 原生 context menu / multi-select。
- 每个需要自动化或辅助功能定位的入口提供稳定 accessibility identifier。
