# MusicFree 问题及修复

> 状态基线：2026-08-23
>
> 本文档是当前问题的汇总入口。历史细节和原始验证数字保留在带日期的记录中；“代码已实现”“自动化已验证”“真机/真实服务已验证”三种状态不合并。

## 1. 状态定义

| 状态 | 含义 |
| --- | --- |
| 已修复 | 源码已经包含修复，且没有已知的同类阻断。 |
| 自动化已验证 | 在明确的 Package/App Simulator 或 fixture 环境中通过。 |
| 真机待验收 | 代码和自动化路径完成，但需要真实 iPhone/iPad、真实媒体或系统服务。 |
| 暂未实现 | 已知需求尚未进入实现，不应写成产品已支持。 |
| 设计中 | 只完成架构/产品设计，尚未进入实现门禁。 |

## 2. 当前问题与修复结果

| 问题 | 修复/当前行为 | 状态 | 证据 |
| --- | --- | --- | --- |
| 播放器输出路由入口曾是占位按钮 | 使用系统音频路由入口，保留控制中心能力；不实现自定义 AirPlay 协议。 | 已修复；真机待验收 | `App/`、`AppleSystemAdapter`、历史 Review |
| 歌曲/收藏列表缺少批量管理 | 支持选择、取消选择、当前已加载项全选和批量删除；播放历史继续使用清空历史语义。 | 已修复；回归已覆盖 | [`LOCAL_PLAYER_FEATURE_REVIEW_2026-08-15.md`](LOCAL_PLAYER_FEATURE_REVIEW_2026-08-15.md) |
| 元数据事务和 artwork 文件可能产生孤儿或错误复用 | 资料库写操作、封面写入/回收、导入和 pending removal 共享维护边界；复用前校验内容哈希，事务失败回滚本轮未引用文件。 | 自动化已验证 | 同上历史 Review、Core/Infrastructure tests |
| LRC 首行 BOM、负时间戳和同步偏移边界 | 解析前去除 UTF-8 BOM；负时间戳忽略，持久化非法时间戳拒绝，合法全局 offset 保留。 | 自动化已验证；真机媒体待验收 | 同上历史 Review、歌词测试 |
| 技术详情展示缺失或误导字段 | 只显示探针实际提供的字段；码率保留一位小数，容器格式未被探针稳定提供时不宣称支持。 | 已修复；真机媒体待验收 | [`../Testing/VLCKIT_FORMAT_MATRIX.md`](../Testing/VLCKIT_FORMAT_MATRIX.md) |
| Now Playing 队列、历史和 Sheet 关闭手势互相争抢 | 采用系统 Sheet + 单一连续滚动区域；当前播放默认锚定，历史向上排列，操作区分立即播放和插入下一首。 | 已实现；截图/真机交互持续验收 | [`../Features/NOW_PLAYING_QUEUE_HISTORY.md`](../Features/NOW_PLAYING_QUEUE_HISTORY.md) |
| 歌曲菜单中的删除语义容易误删对象 | 歌曲、播放历史、歌单关系和集合分别使用不同操作语义；原生 context menu 与行内 `...` 共享动作模型。 | 已实现；双指多选仍需手动验收 | [`../Features/COLLECTION_CONTEXT_MENU.md`](../Features/COLLECTION_CONTEXT_MENU.md) |
| MusicKit 元数据补充可能被误认为在线歌词功能 | 1.1.0 需求明确 MusicKit 只负责元数据和封面；本地歌词链路保持不变，Provider 默认关闭并需同意。 | 已实现；真机授权/服务待验收 | [`../Versions/1.1.0_FEATURE_REQUIREMENTS.md`](../Versions/1.1.0_FEATURE_REQUIREMENTS.md) |

## 3. 当前开放门槛

- 当前源码配置已经切换到 `1.1.100 (2026082301)`；此前提审草稿中的 `1.1.1`、`1.1.10 / 2026082207` 不再是当前构建身份。
- `METADATA_SERVER_FEATURE_FLAG = METADATA_SERVER_DISABLED`，当前包不得把 Metadata Server 宣称为可用线上能力。
- `App/MusicFree.entitlements` 尚无 MusicKit capability；MusicKit 相关代码和 UI 不能替代签名包、授权和真实 catalog 验收。
- `Scripts/check_architecture.sh` 在包含 `thirdpart/` vendored/reference 源码的 checkout 中会扫描到外部代码的 VLCKit/MediaPlayer import；应先区分扫描范围问题，不能直接把它当成 MusicFree App 架构违规。
- 真实设备上的 AirPlay、蓝牙、后台播放、输出切换、中断恢复和长时间播放。
- 固定 VLCKit 二进制的真实媒体格式矩阵；Simulator 或探针通过不能替代真机播放。
- MusicKit entitlement/profile、授权、地区/订阅可用性、catalog 搜索和远程封面下载。
- Now Playing 在不同屏幕尺寸、大字体、真实封面和重复 Sheet 转场下的截图/手动验收。
- 原生 UIKit 双指多选的真实手势覆盖；自动化测试不能完全模拟该手势时，必须标记为手动证据。

## 4. 暂未实现但不是当前缺陷

- ReplayGain、gapless、crossfade。
- 撤销/最近删除、文件重命名/移动/整理。
- M3U 导入/导出、队列保存为歌单、资料库备份/恢复。
- 云同步、远程 Provider、播客、电台、CarPlay、Siri 和视频界面。

这些项目只有在进入对应版本需求后才建立实现问题，不应混入当前发布回归结论。

## 5. 记录要求

每个新问题至少记录：复现入口、设备/系统、App 版本和 commit、输入媒体或 fixture、实际结果、预期结果、修复文件、自动化结果以及仍需真机/真实服务验证的部分。禁止只写“已修复”而没有环境和证据。
