# 在线源添加与页面内恢复流程改造计划

状态：已实施；目标 BVT 待模拟器/XCTest 稳定后复验  
日期：2026-09-09

## 1. 背景

当前在线源流程存在两个相互关联的问题：

1. Google Drive 添加表单沿用了通用在线源表单，展示了“服务地址（可选）”。但当前 Google Drive Adapter 不读取来源配置中的 `endpoint`，Drive API 固定使用 `https://www.googleapis.com/drive/v3`，OAuth 授权地址、Token 地址和回调地址也来自应用构建配置。这个字段对用户没有实际作用，容易让人误以为可以配置 Google Drive 服务地址或代理地址。
2. 来源已经由用户手工添加后，仍可能因为应用隐私协议、在线源总开关、来源隐私协议、来源开关或 Google OAuth 授权缺失而不可用。当前详情页只显示“请在设置中同意协议并启用来源”，要求用户离开在线源页，在设置中的多个入口之间往返操作，接入链路被人为拆断。

本次改造将“添加来源”和“让来源可用”视为一条连续流程。设置页继续保留集中管理、关闭、撤销协议和移除授权等能力，但不再是首次添加或恢复来源的必经路径。

## 2. 已确认决策

### 2.1 本次实施

- Google Drive 使用 Provider 专属添加界面，只收集显示名称，不显示服务地址。
- Google Drive 使用应用内置 OAuth 配置。用户只选择 Google 账号并授权。
- DS Audio 继续使用现有专属添加界面，保留 DSM 地址、账号、密码和二次验证码。
- 新增统一的在线源可用性判定，明确指出当前缺失的是哪一个条件。
- 在线源列表中的已配置来源始终可进入详情页，不再因为关闭状态而变成无响应行。
- 详情页直接提供同意隐私协议、开启在线源服务、开启当前来源、连接或重新连接 Google Drive 等操作。
- 每完成一步后立即重新判定状态；所有条件满足后自动加载目录，不要求用户手工返回或刷新。
- 设置页继续作为集中管理入口，但页面内恢复和设置页必须使用同一套可用性判定规则。

### 2.2 本次明确不做

- 不支持用户自定义 Google OAuth `Client ID`。
- 不支持用户自定义 Google OAuth `Redirect URI`、URL Scheme 或 `REVERSED_CLIENT_ID`。
- 不支持用户自定义 Google Drive API 服务地址、OAuth 授权地址或 Token 地址。
- 不在来源配置、设置文件或日志中保存 Google OAuth Token；Token 继续只存放在系统 Keychain。
- 不删除通用 `OnlineSourceConfiguration.endpoint` 字段。该字段仍用于 DS Audio 和未来确实需要自定义服务地址的 Provider。
- 不把“撤销应用隐私协议”“撤销来源隐私协议”“批量关闭所有来源”等破坏性管理操作搬到目录页。
- 不改变已导入到本地媒体库的文件和本地播放链路。

### 2.3 后续扩展边界

如果未来要支持自定义 Google OAuth，必须作为完整 OAuth Profile 设计，至少同时解决 Client ID、Redirect URI、URL Scheme 注册、回调校验、构建配置隔离和迁移策略，不能只增加一个 Client ID 文本框。本计划不为该能力预留半成品用户入口。

## 3. “服务地址”的定义

“服务地址”只应在 Provider 的服务器地址确实由用户决定时出现。

| Provider | 是否展示服务地址 | 原因 |
| --- | --- | --- |
| DS Audio | 是，必填 | 用户需要连接自己的 DSM/NAS 地址。 |
| Google Drive | 否 | Drive API 和 OAuth 端点由应用内置实现决定。 |
| 未来自建网关 | 是，按 Provider 规则校验 | 网关部署地址由用户或组织决定。 |
| 未来官方 OAuth 网盘 | 默认否 | 官方 API 地址通常固定；账号通过 OAuth 选择。 |

通用领域模型继续允许 `endpoint == nil`。Provider 专属表单负责决定是否展示、是否必填以及如何校验，不再由一个通用弹窗猜测所有 Provider 的输入字段。

## 4. 目标用户流程

### 4.1 首次进入在线源

1. 用户进入“在线源”。
2. 如果尚未同意应用隐私协议，展示应用隐私说明。
3. 用户同意后留在在线源页面；取消则仍可查看已配置来源，但不发起网络请求。
4. 页面不自动开启任何被用户关闭的开关。

### 4.2 添加 Google Drive

1. 用户点击右上角添加按钮并选择 Google Drive。
2. 如果应用隐私协议未同意，先展示应用隐私说明；同意后自动继续，不需要再次点击添加。
3. 展示 Google Drive 专属添加页：
   - 显示名称，默认值为“Google Drive”，允许修改。
   - 说明“使用应用内置 Google OAuth 连接账号”。
   - 不展示服务地址、Client ID、Redirect URI 或任何高级 OAuth 参数。
4. 用户点击“添加并继续”。
5. 保存来源配置，`endpoint` 固定为 `nil`，`credentialRecordID` 使用该来源的稳定 `sourceID`。
6. 自动进入刚创建的来源详情页。
7. 详情页按阻塞优先级逐步显示本地恢复操作：
   - 同意来源隐私协议。
   - 开启在线源服务总开关。
   - 开启当前来源开关。
   - 连接 Google Drive。
8. Google OAuth 成功后自动加载根目录。

用户取消来源协议、拒绝开启开关或取消 Google OAuth 时，来源配置保留，详情页停留在对应状态并提供再次操作入口。不会把用户强制送往设置页，也不会循环弹窗。

### 4.3 添加 DS Audio

1. 继续使用现有 DS Audio 专属添加页。
2. 输入 DSM 地址、账号、密码，可选输入二次验证码。
3. 连接验证成功后再保存凭据引用和来源配置。
4. 自动进入新来源详情页。
5. 来源隐私、总开关和来源开关使用与 Google Drive 相同的页面内恢复流程。
6. DSM 要求二次验证时继续在当前添加流程完成，不跳转设置。

### 4.4 打开已有但不可用的来源

在线源列表中的来源行始终可以点击：

- 未同意来源协议：进入详情页并显示“查看并同意”按钮。
- 在线源服务关闭：进入详情页并显示“启用在线源服务”开关。
- 当前来源关闭：进入详情页并显示“启用此来源”开关。
- Google 授权缺失或过期：进入详情页并显示“连接 Google Drive”或“重新连接”按钮。
- Provider 在当前版本不可用：进入详情页显示不可恢复原因，不提供无效开关。
- 来源已被删除：详情页显示来源不存在，并允许返回来源列表。

### 4.5 设置页的定位

设置中的“在线源可用性”和“隐私与联网服务”继续保留，负责：

- 查看和调整在线源总开关。
- 批量查看所有来源开关。
- 主动关闭某个来源。
- 查看或撤销来源隐私协议。
- 撤销应用隐私协议。
- 执行调试重置或集中管理。

首次添加、正常恢复和重新授权不依赖这些设置入口。

## 5. 可用性状态模型

### 5.1 静态可用性问题

在 AppServices 或其公共契约中增加统一判定类型，避免列表、详情页和设置页分别拼接布尔值：

```swift
public enum OnlineSourceAvailabilityIssue: Equatable, Sendable {
    case sourceNotConfigured
    case providerUnavailable
    case applicationPrivacyRequired
    case sourcePrivacyRequired(policyVersion: String)
    case globalServiceDisabled
    case sourceDisabled
    case capabilityUnsupported(OnlineSourceCapabilities)
}
```

由单一 Evaluator 按固定优先级返回第一个阻塞问题：

1. 来源配置不存在。
2. Provider/Adapter 在当前构建中不可用。
3. 应用隐私协议未同意。
4. 来源隐私协议未同意或版本不匹配。
5. 在线源服务总开关关闭。
6. 当前来源开关关闭。
7. 当前页面要求的能力不受支持。
8. 没有问题，允许执行网络操作。

建议接口：

```swift
public enum OnlineSourceAvailabilityEvaluator {
    public static func issue(
        in snapshot: OnlineSourceSnapshot,
        sourceID: MediaSourceID,
        requiring capability: OnlineSourceCapabilities? = nil
    ) -> OnlineSourceAvailabilityIssue?
}
```

`isRuntimeEnabled` 可以暂时保留以兼容现有调用，但 UI 不再只根据这个合并布尔值生成“已关闭”。所有新页面状态和操作必须从 Evaluator 得到具体原因。

### 5.2 Provider 连接问题

静态开关全部满足后，Provider 仍可能因为凭据或 OAuth 会话不可用而失败。该状态不能继续伪装成通用“目录加载失败”。

AppServices 增加协议中立错误：

```swift
public enum OnlineSourceServingError {
    // existing cases...
    case authenticationRequired(MediaSourceID)
    case authenticationFailed(MediaSourceID)
}
```

`OnlineSourceCoordinator` 将 Adapter 层的授权错误转换为 AppServices 错误，UI 不直接依赖 `MusicFreeInfrastructure`：

- `OnlineSourceAdapterError.authorizationRequired` -> `authenticationRequired`。
- Google Drive 的 `invalidCredential`、刷新 Token 被拒绝等不可恢复凭据问题 -> `authenticationRequired`，并清理无效会话时由 OAuth 层负责。
- 普通 HTTP、解析、超时和服务器错误仍属于目录加载失败，显示重试而不是要求重新授权。
- DS Audio 已有自动重登能力；只有自动恢复最终失败时才进入 Provider 重新登录状态。

详情页维护来源级的瞬时连接问题。成功授权、来源状态变化或成功加载目录后清除；不同来源、目录和搜索请求之间不得串状态。

### 5.3 Google OAuth 构建配置不可用

`isGoogleDriveOAuthConfigured == false` 是应用构建能力缺失，不是用户可以通过输入服务地址解决的问题：

- 添加菜单不展示 Google Drive。
- 已有 Google Drive 配置仍保留并可进入详情。
- 详情显示“此版本未配置 Google Drive 连接能力”。
- 不展示 Client ID 或 Redirect URI 输入框。
- 不提供会失败的“授权”按钮。

## 6. 详情页恢复界面

### 6.1 展示原则

目录页在不可用时不再只显示一张无操作状态卡。改为一个紧凑的“完成连接”状态区，每次突出当前第一个阻塞条件。

| 问题 | 标题 | 说明 | 页面内操作 |
| --- | --- | --- | --- |
| 应用隐私未同意 | 需要同意应用隐私协议 | 在线源发起网络请求前需要应用级许可 | “查看并同意”按钮 |
| 来源隐私未同意 | 需要同意来源隐私协议 | 展示当前 Provider、数据和用途 | “查看并同意”按钮 |
| 总开关关闭 | 在线源服务已关闭 | 开启后才允许已授权来源联网 | `UISwitch`，标签“启用在线源服务” |
| 来源关闭 | 此来源已关闭 | 只开启当前来源，不影响其他来源 | `UISwitch`，标签“启用此来源” |
| Google 未授权 | 尚未连接 Google Drive | 需要选择 Google 账号并授权应用所需的 Drive 文件访问权限 | “连接 Google Drive”按钮 |
| Google 授权失效 | Google Drive 授权已失效 | Token 无法刷新，需要重新登录 | “重新连接”按钮 |
| Provider 不可用 | 此版本不支持该来源 | 当前构建没有可用 Adapter 或 OAuth 配置 | 无操作；保留返回、重命名和删除管理入口 |
| 能力不支持 | 此来源不支持浏览 | Provider 不提供当前页面要求的能力 | 无操作 |

二进制设置使用系统开关，隐私和授权使用明确按钮。不要用一个“去设置”按钮替代本地操作。

### 6.2 单步恢复和刷新

- 页面只执行用户明确触发的操作，不静默打开总开关或来源开关。
- 操作进行中禁用对应控件并显示局部进度，避免重复提交。
- 操作成功后立即刷新共享 Snapshot，并重新运行 Evaluator。
- 下一个问题在同一位置出现，导航栈和滚动位置不变。
- 所有静态问题消失后，Google Drive 如果尚未授权则展示连接按钮。
- 授权成功后自动调用一次根目录加载；不要求用户再点刷新。
- 用户取消协议或 OAuth 时不显示全局错误弹窗，保持当前恢复状态并允许重试。
- 真正的网络或服务器失败继续显示“目录加载失败”和“重试”。

### 6.3 列表页行为

- 移除“来源关闭时整行不可点击”的逻辑。
- 不使用列表行右侧的一次性开启开关作为唯一恢复入口。
- 行状态文案显示具体状态，例如“需要同意来源协议”“在线源服务已关闭”“需要连接 Google Drive”“可用”。
- 行点击统一进入来源详情；只有来源配置不存在时阻止进入。
- 长按重命名等现有管理操作保持不变。

## 7. Provider 专属添加界面

### 7.1 Google Drive 添加页

新增 `GoogleDriveAddSourceViewController`，不再使用通用 `UIAlertController`：

- 导航标题：“添加 Google Drive”。
- Google Drive 图标和简短用途说明。
- 显示名称输入框，默认“Google Drive”。
- 只读说明：“账号连接使用应用内置 Google OAuth 配置；文件访问权限由 Google 授权页确认。”
- 主按钮：“添加并继续”。
- 取消按钮使用系统导航关闭。
- 显示名称为空时主按钮禁用。
- 提交期间禁用输入和按钮。
- 保存失败在当前页显示，不丢失输入。

建议自动化标识：

- `onlineSources.googleDrive.add.sheet`
- `onlineSources.googleDrive.add.displayName`
- `onlineSources.googleDrive.add.submit`
- `onlineSources.googleDrive.add.cancel`

### 7.2 DS Audio 添加页

保留当前专属页面和二次验证码页面，统一以下行为：

- 应用隐私协议同意后自动恢复添加流程。
- 连接成功后自动进入来源详情。
- 保存后的来源不需要到设置中手工启用。
- 如果总开关因用户操作处于关闭状态，在详情页提供本地开关，不自动修改。

### 7.3 创建 API 拆分

逐步移除 UI 对通用 `addSource(... endpointText:account:password:)` 的依赖，改成 Provider 语义明确的调用：

```swift
func addGoogleDriveSource(
    sourceID: MediaSourceID,
    displayName: String
) async -> OnlineSourceCreationResult

func addDSAudioSource(
    request: DSAudioSourceAuthorizationRequest
) async -> OnlineSourceCreationResult
```

Google 创建方法内部始终传 `endpoint: nil`。这样未来新增 Provider 时必须显式定义自己的配置表单和验证规则，不会再次把无意义字段暴露给用户。

## 8. 数据与开关语义

### 8.1 新来源默认值

- 新创建来源保持 `isEnabled: true`，表示用户刚刚明确选择了添加并准备使用该来源。
- 在来源协议未同意前，`isRuntimeEnabled` 仍必须为 `false`，不能发起网络请求。
- 来源协议同意后，如果总开关已开启，来源可以直接继续连接或浏览。
- 如果总开关关闭，只展示页面内开关，不自动改写用户设置。

### 8.2 不覆盖用户选择

- 已存在且 `isEnabled == false` 的来源不能因为进入详情、刷新或重新授权被自动开启。
- `isGloballyEnabled == false` 时不能因为添加了新来源被自动开启。
- 只有用户操作页面内开关或设置页开关时才写入对应值。
- 同意隐私协议只写协议版本，不隐式修改无关开关。
- 撤销来源协议继续关闭该来源并停止下载、试听和目录请求。

### 8.3 并发和幂等

- 同一来源同一恢复操作只允许一个 Task 在执行。
- Snapshot 更新后以最新状态重新判定，避免旧异步结果把已关闭来源重新标记为可用。
- Google OAuth 回调必须核对当前来源 ID 和授权会话；用户离开页面后可以完成授权，但不得向已删除来源写入 UI 状态。
- 自动目录加载使用现有 request key 去重，授权成功和 Snapshot 更新同时到达时只发起一次请求。

## 9. 代码改造范围

### 9.1 Core / AppServices

文件：

- `Packages/MusicFreeCore/Sources/AppServices/FeatureServices.swift`
- `Packages/MusicFreeCore/Sources/AppServices/OnlineSourceCoordinator.swift`
- 必要时新增 `Packages/MusicFreeCore/Sources/AppServices/OnlineSourceAvailability.swift`

改动：

- 增加 `OnlineSourceAvailabilityIssue` 和统一 Evaluator。
- 增加协议中立的来源认证错误。
- 将 Adapter 授权失败转换到 AppServices 边界。
- 保留现有网络操作的最终权限校验，UI 恢复逻辑不能替代服务层安全门禁。

### 9.2 SettingsFeature Scene Model

文件：

- `Packages/MusicFreeUI/Sources/SettingsFeature/OnlineSourceScene.swift`

改动：

- 增加 `availabilityIssue(for:requiring:)` 查询。
- 拆分 Google Drive 和 DS Audio 的创建 API。
- 增加页面内恢复动作的执行状态，按来源隔离。
- 记录并清理来源级认证问题。
- Google 授权成功后触发 Snapshot 刷新和目录自动加载信号。
- 保留现有 optimistic Snapshot，但统一调用 Evaluator，避免继续复制布尔表达式。

### 9.3 UIKit 在线源页面

文件：

- `Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/OnlineSourcesViewController.swift`
- 建议新增 `Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/GoogleDriveAddSourceViewController.swift`
- 建议新增 `Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/OnlineSourceRecoveryView.swift`

改动：

- Google Drive 菜单进入专属添加页。
- 删除 Google Drive 的“服务地址（可选）”输入。
- 来源列表所有已配置行可进入详情。
- 目录数据源增加结构化恢复行，不再使用单一 `sourceUnavailable` 字符串状态。
- 恢复行根据 action 类型渲染 `UISwitch` 或按钮。
- 状态改变后自动重新渲染和按需加载目录。
- Google 授权错误显示重新连接，不与普通目录错误混合。

### 9.4 Settings 页面

文件：

- `Packages/MusicFreeUI/Sources/SettingsFeature/OnlineSourceAvailabilitySettingsView.swift`
- `Packages/MusicFreeUI/Sources/SettingsFeature/PrivacySettingsView.swift`

改动：

- 复用 Evaluator 生成状态说明。
- 保留集中开关和撤销协议能力。
- 移除暗示“必须在设置中完成首次启用”的文案。
- 不在设置页增加 Google Client ID、Redirect URI 或服务地址配置。

### 9.5 Google Drive Infrastructure

文件：

- `Packages/MusicFreeInfrastructure/Sources/OnlineSourceAdapter/OnlineSourceFactory.swift`
- `Packages/MusicFreeInfrastructure/Sources/OnlineSourceAdapter/GoogleDriveHTTPTransport.swift`
- `Packages/MusicFreeInfrastructure/Sources/OnlineSourceAdapter/GoogleDriveOAuth.swift`

本次原则：

- Google Drive Source 继续忽略通用来源 `endpoint`。
- Drive API、OAuth URL 和 Token URL 继续使用实现内置值。
- OAuth Client ID 和 Redirect URI 继续来自应用 Bundle/XCConfig 构建配置。
- 不新增来源级 OAuth Profile 持久化。
- 仅补充必要的错误映射和无效 Token 清理，不扩大 OAuth 配置能力。

### 9.6 App 组合根

文件：

- `App/RootViewController.swift`

改动：

- 保持从 `GoogleDriveOAuthConfiguration.fromMainBundle()` 创建 OAuth Client。
- 将“构建是否配置 Google OAuth”继续作为能力注入 Scene Model。
- BVT fixture 继续使用测试 Authorizer，不依赖真实 Google 登录。

## 10. 测试计划

### 10.1 单元测试

Core/AppServices：

- 每个可用性问题的优先级。
- 应用隐私未同意时，即使其他开关开启也不可运行。
- 来源协议版本不匹配时返回来源协议问题。
- 总开关和来源开关分别返回不同问题。
- Provider 未注册和能力不支持不会被错误归类为“已关闭”。
- Adapter `authorizationRequired` 被转换为协议中立认证错误。
- UI 触发恢复后，服务层仍执行最终权限检查。

SettingsFeature：

- Google Drive 创建结果的 `endpoint == nil`。
- Google Drive 添加 API 不接受 endpoint、Client ID 或 Redirect URI 参数。
- 新来源保存为启用意图，但协议未同意前 runtime 不可用。
- 同意来源协议不会自动打开用户关闭的总开关。
- 开启总开关不会自动开启用户关闭的来源。
- Google 授权取消后保留来源并允许重试。
- Google 授权成功后清除认证问题并只触发一次目录加载。
- 一个来源的授权失败不会污染另一个来源。

### 10.2 UIKit / BVT

更新 `AppUITests/MusicFreeBVTUITests.swift`，将当前跨 Tab 开关流程改为页面内恢复流程：

1. 首次进入在线源，取消应用隐私后不发起网络请求。
2. 选择 Google Drive，同意应用隐私后自动继续到 Google 专属添加页。
3. Google 添加页只有显示名称，没有 `onlineSources.add.endpoint`。
4. 添加后自动进入新来源详情。
5. 在详情页同意来源协议。
6. 在详情页开启总开关和来源开关，不进入设置 Tab。
7. 在详情页完成测试 Google 授权。
8. 授权成功后自动出现目录内容。
9. 关闭总开关后再次进入来源，详情页提供本地开启开关。
10. 撤销来源协议后再次进入，详情页提供本地同意按钮。
11. Google 授权失效 fixture 显示“重新连接”，普通网络失败只显示“重试”。
12. DS Audio 使用同一套页面内协议和开关恢复流程。

设置页 BVT 继续覆盖集中管理和撤销行为，但不再作为首次接入的必经步骤。

建议新增自动化标识：

- `onlineSources.detail.<sourceID>.recovery`
- `onlineSources.detail.<sourceID>.applicationPrivacy.accept`
- `onlineSources.detail.<sourceID>.sourcePrivacy.accept`
- `onlineSources.detail.<sourceID>.globalEnabled`
- `onlineSources.detail.<sourceID>.sourceEnabled`
- `onlineSources.detail.<sourceID>.authenticate`
- `onlineSources.detail.<sourceID>.authentication.retry`

### 10.3 验证命令和产物

- 复用工程 `.noindex/DerivedData/MusicPlayer`，不创建随机 DerivedData。
- 先运行相关 Swift package / 单元测试。
- 再运行在线源目标 BVT。
- 执行无签名 iOS build 或 `build-for-testing`。
- 执行 `Scripts/check_architecture.sh` 和 `git diff --check`。
- 模拟器或 Xcode 缓存权限失败必须与代码测试失败分开记录。

## 11. 迁移与兼容

- 现有 Google Drive 配置中的非空 `endpoint` 继续可解码，但运行时忽略；UI 不再展示或编辑该值。
- 本次不强制重写持久化配置，避免仅为清理无效字段制造迁移风险。
- 新增或重新保存 Google Drive 时写入 `endpoint: nil`。
- 现有 DS Audio endpoint 和凭据记录保持不变。
- 现有来源 ID 继续作为 Google Keychain Token 的记录 ID，多 Google Drive 实例互不覆盖。
- 已有但当前构建未配置 Google OAuth 的来源不会被删除，只显示明确的构建能力缺失状态。

## 12. 分阶段实施

### Phase 1：统一状态判定

- 引入 `OnlineSourceAvailabilityIssue` 和 Evaluator。
- 替换列表、目录和设置页中的重复布尔判断。
- 保证服务层权限门禁行为不变。

完成标准：同一来源在列表、详情和设置中显示相同的具体不可用原因。

### Phase 2：页面内恢复

- 已配置来源始终可进入详情。
- 增加隐私按钮、总开关和来源开关。
- 操作成功后在原页面继续，不跳设置。
- 条件全部满足后自动加载目录。

完成标准：DS Audio 和 Google Drive 的静态门禁都可以在来源详情页解除。

### Phase 3：Google 专属添加和连接

- 新增 Google Drive 添加页。
- 删除无效服务地址字段。
- 添加后自动进入详情并完成授权。
- 将授权缺失与普通目录错误分开。

完成标准：从点击“添加 Google Drive”到看到根目录，全程不进入设置 Tab，也不输入任何 OAuth 配置参数。

### Phase 4：回归与文案清理

- 更新单元测试和 BVT。
- 清理“请在设置中同意协议并启用来源”等死路文案。
- 验证取消、失败、重试、删除、撤销协议和多个来源实例。
- 验证深色模式、大字体、VoiceOver 和 iPhone/iPad 导航。

## 13. 最终验收标准

- Google Drive 添加界面不出现服务地址、Client ID 或 Redirect URI。
- Google Drive 新配置的 `endpoint` 为 `nil`，Adapter 继续使用内置 Drive API 地址。
- 用户手工添加来源后，不需要进入设置页才能完成首次使用。
- 不可用详情页明确指出唯一的当前阻塞条件，并提供可执行的本地操作。
- 隐私使用按钮确认，开关使用系统 Toggle/Switch，Google 连接使用授权按钮。
- 用户显式关闭的总开关或来源开关不会被进入页面、添加来源或重新授权静默开启。
- Google OAuth 取消或失败不会删除来源，也不会陷入不可恢复状态。
- 授权缺失、Provider 不可用、能力不支持和普通网络错误使用不同文案与操作。
- 设置页仍可集中关闭来源和撤销协议，但不再是接入主流程的一部分。
- 多个 Google Drive 和 DS Audio 实例保持独立来源 ID、凭据和状态。
- 单元测试、目标 BVT、iOS 构建、架构检查和 diff 检查完成；环境阻塞与代码失败分别记录。

## 14. 实施时需要特别保护的现有行为

- DS Audio 二次验证码流程和凭据安全存储。
- Google OAuth PKCE、Keychain Token 和按来源 ID 隔离。
- 隐私撤销后立即停止对应目录、下载和试听操作。
- 在线源下载任务离开详情页后继续执行的生命周期。
- 试听与正式播放器互斥、来源关闭后终止试听。
- 现有目录分页、搜索、排序、下拉刷新和错误作用域。
- 当前工作区中的未提交修改，实施时不得通过格式化或回退覆盖。

## 15. 实施结果（2026-09-09）

### 15.1 已完成

- 在 AppServices 增加 `OnlineSourceAvailabilityIssue` 与统一 Evaluator；目录页、详情页和相关状态说明使用相同的阻塞优先级。
- 将 Adapter 的授权缺失映射为协议中立的 `OnlineSourceServingError.authenticationRequired` 或 `authenticationFailed`，与普通目录请求失败分开处理。
- Google Drive 改为专属添加页，只收集显示名称；新建配置固定写入 `endpoint: nil`，未增加 Client ID、Redirect URI、服务地址或 Token 持久化入口。
- 新增 Google Drive 和 DS Audio 后自动进入对应来源详情页；已配置但暂不可用的来源仍可点击进入。
- 详情页按当前阻塞条件提供来源协议确认、在线源总开关、来源开关和 Google 授权/重新授权操作；状态改变后在当前页面继续并自动尝试加载目录。
- 增加可用性判定、Google 配置持久化和页面内恢复的单元测试，并将 BVT 改为验证页面内恢复，不再通过设置 Tab 完成首次接入。

### 15.2 验证结果

- `xcodebuild build-for-testing` 已通过，复用 `.noindex/DerivedData/MusicPlayer`。
- `Scripts/check_architecture.sh` 与 `git diff --check` 已通过。
- 目标 BVT 已更新为页面内恢复流程，并实际通过 Google 专属添加、详情页来源协议、总开关、来源开关、DS Audio 目录浏览和目录内搜索入口。
- BVT 未完成：在后续的既有试听交互断言中失败。交互式关闭试听 Sheet 后，`player.onlineAudition.surface` 未按测试预期继续保留；失败位置为 `MusicFreeBVTUITests.swift:1170`。该行为位于试听 UI，和本次在线源添加/恢复改造没有直接耦合，因此未在本次范围内扩展修复。
- iOS 26.5 模拟器此前也出现过 XCTest 动画服务异常。后续应先单独处理试听交互回归，再用第 10.3 节的定向命令重新执行完整目标 BVT。
