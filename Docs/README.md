# MusicFree 文档索引

本文档目录按读者要解决的问题组织。代码和测试是实现状态的最终依据，文档中的“已验证”必须注明验证环境；Simulator、fixture 或编译通过不等同于真机或真实服务验收通过。

## 推荐阅读顺序

1. [当前项目状态](PROJECT_STATUS.md)：确认版本、当前开关、已接通能力和发布门禁。
2. [工程结构](Architecture/PROJECT_STRUCTURE.md)：了解 App、Swift Package、target 和依赖方向。
3. [模块功能说明](Modules/README.md)：按模块查看职责和边界。
4. [版本功能需求](Versions/README.md)：查看各版本范围与验收条件，以及 1.4 双支线待确认计划。
5. [问题及修复](Issues/ISSUES_AND_FIXES.md)：查看当前问题、修复结果和未关闭验收门槛。
6. [测试与验证](Testing/README.md)：执行自动化/手工验收和检查媒体/VLCKit能力边界。

## 文档分类

| 分类 | 入口 | 内容 |
| --- | --- | --- |
| 架构 | [`Architecture/`](Architecture/PROJECT_STRUCTURE.md) | 工程结构、接口基线和多数据源路线图 |
| 1.4 插件系统 | [当前迁移与验证](Testing/1.4_BUILTIN_PLUGIN_MIGRATION_2026-10-03.md)、[详细计划](Architecture/BUILT_IN_PLUGIN_SYSTEM_1.4_PLAN.md) | 现有歌词/歌曲信息、DS Audio/Google Drive、双位置 EQ 已接入 Runtime；原实现保留，UI 插件与 MusicLyricsAPI 暂缓 |
| 1.4 播放规划 | [`平滑播放详细计划`](Architecture/PLAYBACK_TRANSITIONS_1.4_PLAN.md) | 时长可调/可关闭/最长 3 s，gapless、crossfade、轨道调度与异常处理；待确认 |
| 状态 | [`PROJECT_STATUS.md`](PROJECT_STATUS.md) | 当前构建身份、生产入口、限制和发布门禁 |
| 模块 | [`Modules/`](Modules/README.md) | Core、Infrastructure、VLCKit Adapter、UI 和 App 的功能描述 |
| 版本 | [`Versions/`](Versions/README.md) | 历史版本需求与 1.4 独立双支线的职责划分及确认门槛 |
| 问题 | [`Issues/`](Issues/ISSUES_AND_FIXES.md) | 问题、修复、验证边界和历史 Review |
| 功能 | [`Features/`](Features/NOW_PLAYING_QUEUE_HISTORY.md) | 已落地功能的交互约定和回归约束 |
| 测试 | [`Testing/`](Testing/README.md) | 手工用例、能力矩阵和格式验证矩阵 |
| 发布 | [`Release/APP_STORE_SUBMISSION_1.3.md`](Release/APP_STORE_SUBMISSION_1.3.md) | 当前 1.3.x App Store 文案、审核说明、截图准备与提交检查；[历史 1.1.x 资料](Release/APP_STORE_SUBMISSION_1.1.md) |
| 集成 | [`Integrations/`](Integrations/music-metadata-server-api/API.md) | Metadata Server 等外部服务的接口约定 |

## 当前保留的根级文档

- [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md)：稳定隐私政策入口，指向当前版本。
- [`PRIVACY_POLICY_v1.1.0.md`](PRIVACY_POLICY_v1.1.0.md)：1.1.0 隐私政策。
- [`PRIVACY_POLICY_v1.2.0.md`](PRIVACY_POLICY_v1.2.0.md)：1.2.0 隐私政策，包含 DS Audio 和 Google Drive 在线源边界。
- [`PRIVACY_POLICY_LRCLIB.md`](PRIVACY_POLICY_LRCLIB.md)：应用提供的 LRCLIB Provider disclosure。

第三方许可证与归属信息不与产品文档混放，见 [`../ThirdPartyNotices/`](../ThirdPartyNotices/)。App Store 截图资产说明保留在 [`../Design/AppStore/`](../Design/AppStore/)。

## 整理规则

- 长期基线、模块职责、版本需求、问题修复和验收资料进入上述分类。
- 临时交接、一次性聊天摘要、已经被当前实现取代且没有独立现行约束的计划不作为长期文档保留。
- 外部厂商原文不复制进仓库；只保留项目实际使用的接口、配置、归属和验证信息。
- 文档移动后必须同步更新 README、代码注释和相对链接；版本化文档不通过覆盖旧文件来伪造历史状态。
