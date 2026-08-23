# MusicFree 文档索引

本文档目录按读者要解决的问题组织。代码和测试是实现状态的最终依据，文档中的“已验证”必须注明验证环境；Simulator、fixture 或编译通过不等同于真机或真实服务验收通过。

## 推荐阅读顺序

1. [工程结构](Architecture/PROJECT_STRUCTURE.md)：了解 App、Swift Package、target 和依赖方向。
2. [模块功能说明](Modules/README.md)：按模块查看职责和边界。
3. [版本功能需求](Versions/README.md)：查看 1.0.0 和 1.1.0 的产品范围与验收条件。
4. [问题及修复](Issues/ISSUES_AND_FIXES.md)：查看当前问题、修复结果和未关闭验收门槛。
5. [测试与验证](Testing/README.md)：执行手工验收和检查媒体/VLCKit能力边界。

## 文档分类

| 分类 | 入口 | 内容 |
| --- | --- | --- |
| 架构 | [`Architecture/`](Architecture/PROJECT_STRUCTURE.md) | 工程结构、接口基线和多数据源路线图 |
| 模块 | [`Modules/`](Modules/README.md) | Core、Infrastructure、VLCKit Adapter、UI 和 App 的功能描述 |
| 版本 | [`Versions/`](Versions/README.md) | 1.0.0 与 1.1.0 功能需求 |
| 问题 | [`Issues/`](Issues/ISSUES_AND_FIXES.md) | 问题、修复、验证边界和历史 Review |
| 功能 | [`Features/`](Features/NOW_PLAYING_QUEUE_HISTORY.md) | 已落地功能的交互约定和回归约束 |
| 测试 | [`Testing/`](Testing/README.md) | 手工用例、能力矩阵和格式验证矩阵 |
| 发布 | [`Release/`](Release/APP_STORE_SUBMISSION.md) | App Store 材料与发布检查清单 |
| 集成 | [`Integrations/`](Integrations/music-metadata-server-api/API.md) | Metadata Server 等外部服务的接口约定 |

## 当前保留的根级文档

- [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md)：稳定隐私政策入口，指向当前版本。
- [`PRIVACY_POLICY_v1.1.0.md`](PRIVACY_POLICY_v1.1.0.md)：1.1.0 隐私政策。
- [`PRIVACY_POLICY_LRCLIB.md`](PRIVACY_POLICY_LRCLIB.md)：应用提供的 LRCLIB Provider disclosure。

第三方许可证与归属信息不与产品文档混放，见 [`../ThirdPartyNotices/`](../ThirdPartyNotices/)。App Store 截图资产说明保留在 [`../Design/AppStore/`](../Design/AppStore/)。

## 整理规则

- 长期基线、模块职责、版本需求、问题修复和验收资料进入上述分类。
- 临时交接、一次性聊天摘要、已经被当前实现取代且没有独立现行约束的计划不作为长期文档保留。
- 外部厂商原文不复制进仓库；只保留项目实际使用的接口、配置、归属和验证信息。
- 文档移动后必须同步更新 README、代码注释和相对链接；版本化文档不通过覆盖旧文件来伪造历史状态。
