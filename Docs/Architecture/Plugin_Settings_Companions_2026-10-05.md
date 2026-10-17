# 插件设置页面与宿主边界

## 已落实的结构

`MusicFreePluginAPI` 和 Runtime 保持平台无关。新增独立产品 `MusicFreePluginSettingsUIKitAPI`，插件的 iOS 设置伴随模块可通过 `PluginSettingsPageRegistration` 提供完整 `UIViewController`。配置 schema 继续用于类型、范围、必填项和版本校验，不承担复杂页面的布局或交互表达。

宿主通过 `PluginSettingsPageHost` 消费注册表，统一入口、导航、可见性、构建可用性和持久化。页面工厂只在点击入口时执行；未启用或禁止加载不会直接禁用设置入口；授权操作继续遵守应用许可、插件许可和各自的加载条件。隐藏插件的分类入口隐藏，插件管理页仍可访问。

临时屏蔽展示由 `PluginDisplaySettings.defaultSuppressedPluginIDs` 提供默认列表，通过 `UserDefaults.standard` 的 `musicfree.plugins.suppressedPluginIDs` 字符串数组覆盖。覆盖值替换整份默认列表；空数组取消全部屏蔽，删除该键恢复默认列表，页面下次刷新时生效。共用设置模型统一筛选，包含“管理隐藏插件”，不修改插件能力、加载、入口可见性或已有配置。当前默认屏蔽爆音抑制（`builtin.dsp.declick`），以及网易云／QQ 音乐的歌词和元数据插件（`builtin.lyrics.netEase`、`builtin.metadata.netEase`、`builtin.lyrics.qqMusic`、`builtin.metadata.qqMusic`）。

每个入口包含插件 ID、命名空间内的稳定页面 ID、标题、SF Symbol、位置、顺序和页面用途。完整配置页替代 schema 表单，账户页替代通用来源编辑器；补充页保留这些默认入口，避免新增一个授权页就丢失账户设置能力。可放到播放、导入分类，或仅放到插件详情；分类入口和详情使用相同工厂。同序按 ID 排序。页面入口使用独立的行标识命名空间，插件的 configuration/visible 等页面名称不会撞上宿主通用控件。均衡器沿用旧入口的辅助功能标识，避免影响现有导航和自动化。

设置列表同时根据 Runtime 快照自动发现已启用、可见且构建可用的插件：DSP 进入播放偏好，歌词和元数据插件集中在“元数据填充”子菜单的“插件”分组，按插件 ID 稳定排序。在线源由独立 Tab 提供设置，不在设置分类重复生成入口，显式注册的在线源分类页面也不显示；插件管理中的页面工厂保持可用。显式注册到导入分类的数据插件页面也归入“元数据填充”，避免根列表重复展示。已有显式分类页面不重复生成入口，并保留停用时也可提前配置的原有行为。自动入口复用完整配置／账户伴随页；没有伴随页但存在普通 schema 字段时直接打开通用配置表单；只有补充页或没有配置字段时进入插件详情，保留许可、账户和高级设置。启用、停用和隐藏的变化通过共享插件模型刷新列表，不要求每个新插件再次注册分类页面。

`PluginSettingsContext` 只暴露当前插件的偏好读取、配置保存、凭据写入/删除和许可变更。在线源还获得插件作用域的 `PluginSourceSettingsContext`，支持多账户实例的读取、保存、删除和独立凭据；拒绝修改其他 provider 的来源。配置保存进入共享插件修改队列，基于执行时的最新设置重写对应插件记录，并使用保存后归一化的设置更新 Runtime。凭据使用插件 ID 和 Runtime 的 `default` 实例作用域；设置仅保存引用。校验失败和持久化失败分别返回错误。进入队列前检查取消；已经提交的用户保存不会因导航返回而被撤销。

## 现有能力接入

| 能力 | 页面所有者与路径 |
| --- | --- |
| 均衡器 | `BuiltinPluginSettings/EqualizerPluginSettingsViewController`。播放分类和插件详情共用；保留前级、全部频段、完整预设菜单、快捷预设、双击恢复和 VoiceOver。通过仅暴露均衡器操作的 `EqualizerSettingsContext` 复用已有保存模型 |
| DS Audio、Google Drive | 完整原生来源 UI 迁至 `BuiltinPluginSettings`。注册页面按 provider 过滤账户和添加菜单，保留账户维护、密码登录、OTP、OAuth、恢复授权、来源许可和删除凭据。Google 设置指南资源一并迁移；插件详情不会打开 `nativeSource` JSON 表单 |
| 元数据服务 | 插件伴随模块提供服务状态和 MusicKit 系统授权页；宿主提供单个 provider 的授权适配器，允许停用时准备权限 |
| 简单/参考插件 | 未提供页面时继续使用 schema 表单和通用来源编辑器；自定义页面可承载动态表单、列表、异步操作和下级页面，不受 schema 控件类型限制 |
| 扫描、批量预下载、下载任务、跨插件排序 | 宿主保留协调页面。已有元数据与隐私入口继续读取同一偏好，作为兼容入口，不建立第二份配置 |

内置 UI 伴随模块作为 MusicFreeUI 包的独立 `BuiltinPluginSettings` 产品发布，依赖宿主提供的窄适配器和通用 UIKit 表单组件；纯 DSP/数据插件包没有 UIKit 依赖。第三方原生页面仅需设置 UIKit SDK，宿主不增加其布局分支。

## 页面交互约定

- 页面自行管理输入草稿、子页、登录、任务和错误展示。通用 `PluginSettingsFormViewController` 是可选组件，保留单元格、滑杆手势和滚动位置；插件也可返回任意控制器。
- 异步认证应阻止重复提交；页面的观察和临时任务由页面在离开/释放时取消，长期扫描或下载由宿主服务管理。原生账户页观察循环不再跨整个流强持有控制器。
- 写入凭据后保存配置失败时，插件页面应删除新引用；替换成功后删除旧引用。凭据引用、schema 值和服务许可分别处理，插件许可不自动授予应用联网许可。
- 提供可访问的控件标题与稳定标识，页面文案使用 DesignSystem 本地化。空配置不生成无内容的表单入口。

## 设置交互补充

- 均衡器完整预设继续由插件页面提供，快捷区展示引擎返回的全部预设，使用两列多行，末行单项保留半行宽度。预设菜单和自定义频段编辑保持同步。
- 元数据来源优先级是跨插件的宿主设置。使用 UITableView 原生编辑模式的拖动手柄；只允许移动来源行，扫描/系统授权操作使用独立分组。移动时更新 diffable snapshot，再由共享设置模型提交，隐藏来源保持原有槽位。
- 设置根页的应用图标使用当前所选预览图和名称，返回页面时重新读取系统选择。语言、配色、默认速度、重复内容使用 SF Symbols。
- 存储状态改为独立子页，容量和待删除状态不占用设置根列表；维护继续位于状态页的下一级。每次进入状态页重新读取容量；无容量数据时保留“暂不可用”提示。
- 重复内容提供可执行的“跳过已有内容 / 报告重复内容”。`ImportCoordinator` 在每次开始时读取偏好，统一应用于文件选择器及 Documents 导入，在线导入显式使用 report 的结果统计保持有效。新增 `reportExisting` 持久化值；历史 `replaceExisting`、`keepBoth` 保留并标明暂不支持，不把它们伪装成已实现的替换/副本操作。
- 内置元数据、歌词和均衡器的默认启用意图来自原偏好，已保存的插件停用/撤回优先。内置在线源适配器默认可用，应用的在线源总开关仍默认关闭，每个账户还需独立启用及同意。启用能力、允许加载和联网同意分别控制不同条件。
- 插件页负责能力、加载、入口和配置；隐私页集中管理应用/服务/来源同意与撤回，读取同一份偏好。原生账户页已有独立来源许可，插件详情不再重复生成第二套服务许可/撤销按钮；通用第三方插件继续使用宿主许可入口。

## 验证

复用 `.noindex/DerivedData/MusicPlayer` 和 MusicFree Regression 模拟器。

2026-10-16 自动插件入口验证：17 项插件设置测试通过，涵盖四种插件类型归类、启用／隐藏后的列表刷新、构建不可用过滤、伴随页懒创建和显式入口去重（`.noindex/logs/plugin-settings-discovery-tests.log`）。新构建应用的 2 项 Simulator UI 回归通过，实际启用爆音抑制／声道均衡并从主列表进入通用／专用配置页，验证停用移除、恢复原偏好以及均衡器完整页面（`.noindex/logs/plugin-settings-discovery-ui-tests.log`）。架构检查和 `git diff --check` 通过；未进行真机验证或发布。

数据插件归入“元数据填充”后，18 项插件设置测试与 1 项新构建应用的 Simulator UI 回归通过，覆盖紧凑／分类布局中根列表无重复、元数据／歌词插件的子菜单入口与停用刷新、显式导入入口归类，以及 MusicBrainz 设置页在子菜单中的实际点击跳转（`.noindex/logs/plugin-settings-metadata-submenu-tests.log`）。架构检查与 `git diff --check` 通过。

移除在线源插件的重复分类入口后，19 项插件设置测试通过，包含在线源自动／显式入口过滤、混合能力插件归类以及插件管理页面工厂仍可访问（`.noindex/logs/plugin-settings-online-tab-tests.log`）。应用随测试构建成功，架构检查与 `git diff --check` 通过；本次未重新运行应用 UI 自动化。

本轮七项设置交互补充：

- 234 项 UI 功能测试通过，包含完整双列预设、原生排序的跨组限制/隐藏来源、根页图标、重复选项，以及存储子页重进时刷新容量：`.noindex/logs/settings-seven-items-final-verification.log`。
- 31 项插件桥接测试通过，包含内置默认状态、旧意图迁移、已保存的停用/撤回优先、应用与服务许可独立：`.noindex/logs/settings-seven-items-final.log`。该日志中的第一轮 UI 失败已由以下专项复验关闭。
- 两项导入测试各实际执行 1 项并通过，验证偏好到导入请求的传递和实际重复统计：`.noindex/logs/settings-seven-items-ui-recovery.log`。Swift Testing 过滤器使用带 `()` 的完整函数名，未把此前未执行的过滤运行作为成功证据。
- 五项不同的 Simulator UI 回归通过：均衡器自定义/预设恢复、图标展示/竖向滑杆、原生元数据排序/重复切换重启保存/存储子页、均衡器插件完整页、原生账户页。最终证据分别在 `settings-seven-items-ui-verified.log`（前两项）、`settings-seven-items-final-verification.log`（第三项）和 `settings-seven-items-final.log`（后两项），均位于 `.noindex/logs/`。
- 架构检查和 `git diff --check` 通过。测试滑动定位同时排除导航栏、Mini Player 和 tab bar 遮挡，并支持向上返回已滚过的控件；必要时仅重新安装测试 Runner，不清除应用数据或整个 DerivedData。

以下为页面注册接入阶段的验证记录：

- Debug 模拟器应用编译通过：`.noindex/logs/plugin-settings-companions-build.log`。
- 页面注册接入时完整 MusicFreeUI 功能测试 231 项通过：`.noindex/logs/plugin-settings-companions-entries-final.log`。新增覆盖注册校验/排序/懒工厂、页面用途与默认表单并存、控件 ID 隔离、插件配置/凭据作用域、多账户实例隔离，以及均衡器加载和保存失败重试。
- 10 项 Simulator UI 回归通过：`.noindex/logs/plugin-settings-companions-verified.log`，涵盖 7 项插件测试、2 项均衡器交互和完整在线源账户/许可/目录/搜索/导入流程。最终页面标识调整后，受影响的 3 项插件入口复测全部通过，见 `plugin-settings-companions-entries-final.log`。
- 在线源 BVT 的隐私导航辅助方法已修正：按实际隐私页控件判断当前位置；撤销操作使用原生单元格，确认按钮有稳定标识。
- 架构检查和 `git diff --check` 通过：`.noindex/logs/plugin-settings-companions-architecture.log`。
- 上述登录/导入回归使用模拟器 BVT fixture；真实 OAuth、DS Audio 设备登录、音频听感和 Release Archive 不在本轮验证证据内。
