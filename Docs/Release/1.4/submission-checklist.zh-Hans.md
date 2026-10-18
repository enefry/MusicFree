# 1.4 截图、隐私与审核访问

本文件供发布人使用，不粘贴到 App Review Notes。包身份与验证状态见[提审主文档](../APP_STORE_SUBMISSION_1.4.md)。

## 截图与视频

本轮检查了本地 PNG 的尺寸/透明通道，并查看 `6.9-inch/03-settings.png`。旧设置图显示旧式外观、播放与导入表单，与 1.4 当前分类、插件及过渡入口不一致，需要替换。其他页面未逐张完成视觉比对。

| 已有资产 | 本次动作 |
| --- | --- |
| `Design/AppStore/6.9-inch/03-settings.png` | 已确认过期；替换为最终包设置界面 |
| `Design/AppStore/iPhone-6.5-inch/05-settings.png`、`iPad-12.9-inch/02-settings.png` | 旧设置素材；按最终原生界面重拍 |
| `iPhone-6.5-inch/06-equalizer.png`、`iPad-12.9-inch/03-equalizer.png`、旧 provider-list 与 sleep-timer 图 | 设置导航/表单已调整，逐项对照，画面不一致则替换 |
| Library / Songs / Now Playing / Playlist detail | 用最终包对照布局、入口与文案，再决定复用；不默认全部通过 |
| `Design/AppStore/AppPreviews/03-settings-equalizer.mp4` | 旧设置操作需重录或从本次素材移除；其余视频逐一核对 |

建议每个实际提交的设备组展示：资料库 → 正在播放 → 歌单 → 歌曲过渡 → 插件/音效设置。可选标题：`Your music, organized` / `你的音乐，井然有序`；`Transitions your way` / `按你的方式衔接歌曲`；`Fine-tune your sound` / `细调你的声音`。标题只描述真实画面。

当前本地资产：6.9-inch 4 张，1320×2868、无 Alpha；6.5-inch 8 张，1284×2778，其中 7 张含 Alpha；iPad 12.9-inch 5 张，2048×2732，均含 Alpha。重新上传时按 ASC 当前设备组/尺寸要求导出，去掉透明通道；这不代表已被 ASC 接受的历史素材一定有问题。

只使用有权展示的测试音频、封面与歌词，移除测试标记、个人账号和服务器地址。新截图和视频本轮尚未生成。

## 审核访问与说明组装

1. 复制[英文审核主体](review-notes.en-US.txt)。路径名称基于当前源码；最终英文设备需逐步走一遍，修正名称差异。
2. 当前本地候选 `2026101706` 的 Google Drive 开关是 `YES`，追加[Google Drive 段落](review-notes-google-drive.en-US.txt)。如最终另选关闭该服务的包，则不追加；同时删除现有商店介绍中不再适用的服务承诺。
3. DS Audio 开放给审核时，提供外网可达、低权限、仅含授权测试音频的 DSM/Audio Station 账号，验证浏览、试听和导入。
4. Google Drive 开放给审核时，确认生产 OAuth 配置、发布状态、审核账号授权和音频导入可用。包内 `YES` 只证明开关，不证明登录能成功。
5. 在 ASC 私密字段填写联系人、账号及操作所需信息；任何临时密码/验证码处理方案需实际可用。仓库不保存账号密码、token 或私有 endpoint。

本地播放器无需账号，但在线功能的账号访问仍需提供。演示视频只能辅助说明，不能替代可操作账号或服务。

审核账号字段待发布人私密填写：联系人姓名、邮箱、电话；DS Audio endpoint/用户名/密码及验证方式；Google 审核账号/密码及可操作授权方式。不得把这份内部字段清单直接当成已完成的审核访问证明。

## 隐私与功能范围

| 项目 | 当前证据 / 发布时动作 |
| --- | --- |
| 本地音乐、资料库和音效 | 导入与播放无需在线源；过渡/DSP 设置变化本身不表示新增网络数据收集 |
| 歌曲信息、封面与歌词 | 可选服务仍需应用政策、服务同意及适用插件许可；按最终启用的服务复核查询字段、第三方处理及撤权后的行为 |
| DS Audio / Google Drive | 配置、凭证、请求信息与第三方处理需与最终服务披露一致；不能把“可选”当成隐私问卷免填理由 |
| 网易云音乐 / QQ 音乐 | 源码注册了歌词/元数据插件，默认抑制显示；未作为可下载音乐目录宣传。显示抑制不等同于从二进制移除或撤销历史授权，升级偏好与最终可达性仍需确认 |
| Metadata Server | 仓库默认 `METADATA_SERVER_DISABLED`；未验证为可用服务，不作公开承诺 |
| 当前应用隐私清单 | 源码及 `2026101706` 包均声明 `OtherDataTypes`、App Functionality、非关联、非追踪；required-reason API 数组为空。不能直接复制为 ASC 的最终填写结论 |
| 依赖隐私清单 | 最新包另带 Kingfisher/CocoaLumberjack 清单；最终 Archive 隐私报告需覆盖应用与依赖实际 API 用途 |

现有隐私政策为 [v1.2.0](../../PRIVACY_POLICY_v1.2.0.md)，URL：`https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.2.0.md`。该文档含历史版本和 VLC 用语，元数据/歌词的数据字段说明另见 [v1.1.0](../../PRIVACY_POLICY_v1.1.0.md)。提交前复核当前公开政策是否完整覆盖最终可达服务及插件授权行为；如有缺漏，更新正式政策和应用内同意版本，再发布到公开地址。不要仅替换 URL 中的版本号或直接沿用“No Data Collected”。本轮没有发布或改写正式隐私政策。

## 最终提交核对

- [ ] 记录最终 IPA / ASC build 与源码对应关系，包括尚未提交的文件名修复。
- [ ] 完成最终包全新安装、线上版本升级和资料库/歌单/历史保留检查。
- [ ] 完成实际歌曲听音、过渡回退、后台/锁屏、蓝牙/AirPlay 和中断恢复检查。
- [ ] 审核账号、服务权限、政策与商店描述一致；任何关闭的服务都不承诺可用。
- [ ] 对照最终依赖核查 About / ThirdPartyNotices、FFmpeg/LGPL 的源码和必要分发材料；移除已不存在的依赖声明。
- [ ] 根据最终包隐私报告和实际处理完成 App Privacy，并确认公开政策无需登录可访问。
- [ ] 核对出口合规、内容权利、年龄分级及 ASC 对该 build 的必填问题；不从源码猜测账号中的现有答案。
- [ ] 截图、视频和审核说明实际走通；公开文本无占位符、日志或凭证。
- [ ] ASC 确认 build 处理完成、TestFlight 验收后，选择同一 build 提交。
