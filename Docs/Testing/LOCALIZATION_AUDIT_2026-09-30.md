# 本地化核查（2026-09-30）

## 核查结论

按 App 当前可选择的六种语言（en、zh-Hans、fr、de、es、ja），应用自有界面文案、固定错误提示已补齐主表引用及翻译。`Localizable.xcstrings` 当前有 1356 个唯一 key，所有 key 的六种语言均有非空且标记为 `translated` 的译文。静态核查未发现遗漏的直接字面量查询 key、动态插值查询 key、格式参数不一致或异常转义。

系统应用名和权限提示使用 Apple 专用的 `App/InfoPlist.xcstrings`；它的 4 个 key 同样已补齐六语。系统权限弹窗按 iOS 的语言设置显示，与应用内部语言选择机制不同。

## 发现及修复

- 原主表 1219 个唯一 key 中，138 个条目缺少德语、西班牙语、法语、日语，共补齐 552 份译文。
- 补入 6 个遗漏的界面 key：正在验证、取消收藏专辑、收藏专辑、更多选项、收藏的歌曲和专辑会显示在这里、无法播放。
- 补入并接入 5 个 Debug 抓包界面文案，以及 2 个 Documents 扫描错误提示。
- 补入 117 个应用自有固定错误理由及 7 个在线试听错误理由，共 124 个 key；界面展示边界调用 `L(...)`，不改变 Core 的错误类型和依赖结构。
- 将隐私撤销提示的来源名和在线试听提示的歌曲数改为 `%@`、`%d` 参数，替换原先无法命中的 Swift 插值 key，并修正六种译文。
- 清除重复的、不完整的“已暂停”条目，保留已有完整翻译。
- 完成 InfoPlist 中音乐目录访问、本地网络访问权限及内部 bundle 名的翻译。

主表新增 137 个 key，共新增 1374 份译文；现有六份 zh-Hant 译文保留原样。

## 验证

- `python3 Scripts/check_localization.py`：扫描 298 个 Swift 源文件、1851 处直接字面量本地化引用，检查两个 catalog 的支持语言完整度、重复 key、格式参数、转义及固定错误理由；问题数 0。脚本还覆盖当前歌单界面使用的两项条件查询 key。
- `xcrun xcstringstool compile`：主表与 InfoPlist 表均成功编译；逐项核对编译产物，8136 份主表译文和 24 份 InfoPlist 译文全部匹配。
- iOS Simulator 的 MusicFree Debug 构建成功，复用 `.noindex/DerivedData`。
- iOS 26.5 的现有 MusicFree Regression 模拟器：3 个 Swift Testing 测试函数通过，共 13 个用例（1 个既有测试，加两组各 6 个语言用例），验证标签、错误理由和参数替换。首次无括号筛选未匹配用例，已通过枚举标识后按完整函数签名重跑；结论以实际执行的结果为准。
- 未启用的 MusicFreeDebugSupport 新增 DesignSystem 依赖，`swift package dump-package` 通过；该可选包未进行完整构建。
- `git diff --check` 通过。

日志保存在 `.noindex/logs/localization-audit-build.log` 与 `.noindex/logs/localization-audit-tests.log`。

## 范围与边界

- App 当前不提供繁体中文语言选项；主表历史上有 6 份 zh-Hant 译文，其余 key 未覆盖 zh-Hant。本次“完整”指 App 当前支持的六种语言。
- 语言选择器使用各语言自称，品牌名、协议名、编码名称、纯数字、符号、文件名、内部标识和日志不要求翻译。
- `SettingsFeature/Resources/GOOGLE_DRIVE_OAUTH_GUIDE.html` 与 `PRIVACY_POLICY_LRCLIB.html` 是独立的内置 HTML 文档，不在主表中。本次未将这些文档迁入 xcstrings 或扩展到六语。
- 用户歌曲元数据、歌词、远端服务返回的文本、系统 NSError 和第三方组件文案不由主表完整控制。系统错误未命中主表时仍保留原始系统描述。
- 静态检查及资源解析测试不能证明每个页面、每种异常分支的最终布局和展示效果；未做逐页真机验收，也未做母语人工审校。
- 保留当前工作区已有改动，未提交或推送。
