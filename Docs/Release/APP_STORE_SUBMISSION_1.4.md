# MyMusic 1.4 提审资料

核对时间：2026-10-17 23:36 EDT（America/New_York）。资料针对当前 1.4.8；文案不写 patch/build，便于最终选包。

## 可直接填写的内容

| ASC 字段 | 资料 / 填写方式 |
| --- | --- |
| App Name | `MyMusic: Local Player`，沿用现有商店名称 |
| Subtitle | 可沿用 `Import and play your music`；本轮未读取 ASC 现值 |
| Version | 当前候选 `1.4.8`，最终与选中的 build 一致 |
| Bundle ID | `win.tools4me.music` |
| What's New | [英语](1.4/whats-new.en-US.txt)、[简体中文](1.4/whats-new.zh-Hans.txt)、[法语](1.4/whats-new.fr-FR.txt)、[德语](1.4/whats-new.de-DE.txt)、[西班牙语](1.4/whats-new.es-ES.txt)、[日语](1.4/whats-new.ja.txt) |
| Promotional Text | [英语](1.4/promotional-text.en-US.txt)、[简体中文](1.4/promotional-text.zh-Hans.txt)，可选更新 |
| Description | [英语](1.4/description.en-US.txt)、[简体中文](1.4/description.zh-Hans.txt)，可替换旧版介绍 |
| Review Notes | [英文主体](1.4/review-notes.en-US.txt)，Google Drive 启用时再追加[该段](1.4/review-notes-google-drive.en-US.txt) |
| Screenshots / App Preview | 按[截图与隐私、审核访问清单](1.4/submission-checklist.zh-Hans.md)更新 |
| Keywords / Category / URLs | 现有内容准确时保留；公开 URL 的可访问性本轮未验证 |
| Contact / Demo Account | 发布人在 ASC 私密字段填写；不把凭证写入仓库 |

六语言更新说明对应应用已支持的语言；不代表 ASC 已建立全部语言条目。只填入实际使用的商店语言。本轮没有改名称、定价、年龄分级或地区。

## 本次用户可见变化

- 歌曲过渡支持淡入淡出、无缝播放和最长 12 秒交叉淡化；智能交叉渐变与首尾静音跳过为可选功能。
- 智能过渡适用于满足条件的完整本地歌曲，分析不可靠时回退；不宣传所有音频都能对拍或无缝切换。
- 原生界面与设置重新整理；内置插件在设置中集中管理，并在相关分类提供入口。
- 完善六语言界面、暂停时 seek 和导入行为。刚修复的旧来源文件名恢复问题计入导入修复。

不把默认抑制显示的网易云音乐、QQ 音乐数据插件或 declick 写成公开新功能；不把插件机制描述成外部插件商店或可下载代码。

## 当前包身份与边界

准备资料期间出现了新的本地 IPA。下表取自包内 `Info.plist`，不是根据文件名推断：

| 项目 | 实测值 |
| --- | --- |
| 最新本地 IPA | `dist/MusicFree-20261017-233448.ipa` |
| 包内版本 / build | `1.4.8 (2026101706)` |
| Bundle ID / 最低系统 | `win.tools4me.music` / iOS 17.1 |
| GoogleDriveOAuthEnabled | `YES`；应追加 Google Drive 审核段落，并确认可用账号/OAuth 发布状态 |
| ITSAppUsesNonExemptEncryption | `false`；仍以该 build 的 ASC 合规要求为准 |
| SHA-256 | `5c6af6167df6c2dc6cedabe4a8d32bf0026ad16a5ceba8c10cfe71e0d4add027` |
| 当前源码配置 | `1.4.8 (2026101707)`，读取时点值；归档动作可能继续推进 build |
| Git 基线 | `e986fa4`，工作区含本次 Infrastructure 修复及原有独立修改；不是完整干净提交身份 |

旧 `dist/MusicFree-20261017-223311.ipa` 为 `1.4.8 (2026101705)`，早于本次修复，不能当作修复后的提交包。新 `2026101706` 生成时间晚于最终测试，但本轮只读了包信息，尚未核对它与修复源码的构建关联，也未做该包真机验收。确认包含修复后可选用；无法确认则从修复后源码重新归档。不要仅按配置中的 `2026101707` 在 ASC 猜选 build。

本轮没有执行 Archive、上传或提交。既有 Apple 状态文件仍指向 `1.4.5 (2026101202)`；先前 API 查询返回 401，不能据此确认 1.4.8 已在 Apple 处理完成。

## 已有验证与最终待办

Infrastructure 遗留项已核清：12 项过期用例、1 项真实文件名回归，均已修复。完整 Simulator 测试 **249 项通过，0 失败、0 跳过**；架构检查通过。见[修复记录](../../.noindex/artifacts/infrastructure-fix-summary.md)。这关闭了原先“13 项失败未核清”的问题。

另有 [1.4 检查记录](../../.noindex/artifacts/final-1.4-review.md)、[六语言检查](../Testing/LOCALIZATION_AUDIT_2026-10-17.md)和[节拍匹配验证](../Testing/Beat_Matching_Validation_2026-10-15.md)。这些来自不同时间的源码/设备测试，不合并成“最终 IPA 全量验收”。`.noindex` 中的日志和结果包仅是本机证据，不随此资料包发布。

- [ ] 确认最终包包含 Infrastructure 修复，记录最终版本、build 与源码身份。
- [ ] 在 ASC 确认同一 build 已处理完成；完成 TestFlight 安装/从线上版本升级验收。
- [ ] 使用最终包验证导入、暂停 seek、转换、CUE、过渡、EQ、后台/锁屏及常用音频路由。
- [ ] 替换已过期的设置素材，对照最终包复核其他截图。
- [ ] 按[清单](1.4/submission-checklist.zh-Hans.md)核对审核访问、隐私、第三方声明和 ASC 必填项。
- [ ] 填入文案，最终复核后由发布人提交审核。

## 事实来源

- [歌曲过渡实现说明](../Architecture/Smart_Crossfade_2026-10-12.md)
- [插件迁移记录](../Testing/1.4_BUILTIN_PLUGIN_MIGRATION_2026-10-03.md)
- [设置入口](../../Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/SettingsViewController.swift)与[默认显示策略](../../Packages/MusicFreeUI/Sources/SettingsFeature/PluginDisplaySettings.swift)
- [源码配置](../../basic_config.xcconfig)、[隐私清单](../../App/PrivacyInfo.xcprivacy)、最终包内信息

公开复制文本与内部发布清单分别保存，避免把版本差异、测试日志或待填项一起粘贴到商店。
