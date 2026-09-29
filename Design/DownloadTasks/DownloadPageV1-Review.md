# 下载任务 V1 Review

日期：2026-09-28。范围：主仓库当前未提交的下载页面、队列、网络进度、持久化与相关测试修改。首次 review 未修改业务实现；后续修复与验证记录在文末。

以下发现与行号记录首次 review 时的代码。用户要求修复后，前三项按 P1 处理；修复结果见文末。

## 发现

### P1：任务汇总随历史规模放大主线程开销

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadTaskSummary.swift:25`、`:60`。

`tasks` 为每个任务调用 `files(for:)`，后者每次遍历全部 `downloads`。已经建立的 `groups` 只用于单文件任务，目录任务仍进行重复遍历。`OnlineDownloadTasksViewController.render()` 在主线程随状态变化调用汇总，详情还重复排序文件并重建表头。

复现：链接当前已有 Debug 核心库，在同一台 Mac 上构造 10,000 条文件记录；一次 `snapshot.tasks` 计算，1 个任务约 16 ms、100 个任务约 99 ms、500 个任务约 446 ms。该数字是 Debug 本机测量，不是 Release 真机帧率。算法本身的全量重复遍历在两种构建下都存在。

建议：一次按任务分组，复用分组与归档明细；状态发布和界面刷新只重算受影响的任务。补充大历史规模下的性能验证。

### P1：历史成功记录导致后续入库遗漏封面或歌词

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:1044`、`:1076`。

若附属文件已有成功记录且当前没有 `supportingTransfers`，代码直接跳过。前一次任务收尾已清理临时文件，因此成功记录不能替代当前入库所需的实际文件。依次下载同一目录里的两首单曲，第二首不会包含共享封面。批量任务部分成功后恢复，也会受这个逻辑影响。

复现输出：第一首入库文件为 `[First.m4a, cover.jpg]`；第二首只有 `[Second.m4a]`；下载 ID 为 `[first, cover, second]`。

建议：去重仅限拥有有效临时文件的当前操作；跨操作或恢复时重新取得附属文件，并归入本次任务。

### P1：新建目录任务误用恢复逻辑

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:933`、`:1434`。

`startImport` 与 `resumeTask` 复用目录的 `rootItemID` 及成功明细，未区分一次新操作和恢复原操作。目录页的“再次导入当前目录”因此直接跳过上次成功的文件，旧任务也被覆盖。远端相同 ID 的内容更新，或本地已删除音乐后再次导入，均无法按新操作重新下载。

复现：连续调用两次 `startImport` 并等待完成，下载 ID 只有 `[first]`，最终任务数为 1。

建议：新操作生成独立任务 ID，另存目录根 ID；恢复才复用原任务及成功明细。

### P2：目录页无法取消排队任务

位置：`Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/OnlineSourcesViewController.swift:3731`。

`updateDirectoryImportButton` 对 `.waiting` 显示取消按钮，但 `importCurrentDirectory()` 的取消判断只包含 discovering/downloading/importing。当前有其他任务执行、目录任务正在排队时，点击取消会再次调用 `startImport`，随后被已有任务保护直接返回，任务继续排队。

建议：取消判断加入 `.waiting`，覆盖“任务 A 执行中，任务 B 在目录页排队并取消”的交互测试。

## 首次 Review 验证与范围

- 审阅了下载队列、页面、网络进度、持久化及相关测试修改，包含新增未跟踪的实现和测试文件。
- 定向探针：`.noindex/tmp/DownloadReviewProbe.swift`，链接 `.noindex/swift-core/debug` 已有核心库，复现遗漏封面、重复目录操作及任务汇总耗时。
- `git diff --check` 通过。
- 本轮未重新执行完整 Xcode/模拟器测试，未进行 Release 真机性能测量。
- 保留当前业务修改，仅增加本审阅记录与 `.noindex` 下的复现产物。

## 修复结果

- 已修复：任务汇总一次分组；归档仅在文件归属变化时保存，不再随每个文件状态变化重建所有历史。下载页汇总和详情排序在后台计算，旧页面计算取消后不能覆盖新页面状态，详情表头复用已计算的文件列表。
- 已修复：跨操作重新取得附属文件；同一次操作的共享封面仍只下载一次。恢复成功音频时跳过音频，恢复失败音频时重新取得所需封面和歌词。保存原所属任务明细，避免重用封面覆盖历史。
- 已修复：新目录任务生成 `__import_UUID`，另存 Provider 目录对象；恢复保留原任务 ID 和成功记录。新旧持久化请求均可恢复。目录页取消/失败后的重试调用恢复，完成后的再次导入创建新任务。
- 已修复：目录页取消判断覆盖 `.waiting`。
- 已通过：20 项核心队列测试，其中新增 7 项覆盖上述边界、持久化兼容及 500 个任务/10,000 条文件的汇总正确性；架构检查通过。
- 本机同样 Debug 探针：500 个任务/10,000 条文件的汇总从约 446 ms 降到约 18 ms；100 个任务从约 99 ms 降到约 17 ms。页面已将这段计算移出主线程。该数字不代表 Release 真机帧率。
- 原遗漏封面复现已变为两次入库均包含 `cover.jpg`；两次目录导入已变为两次实际下载、两个独立任务。
- 最终 390 点模拟器的 3 项交互测试通过：浅色取消/恢复/清理、深色批量下载、目录排队取消及恢复保持原任务；4 项在线源入库场景测试通过，Xcode 返回 `TEST SUCCEEDED`。首轮排队取消的唯一失败为测试将英文 `Retry available` 误断言成中文，已修正。

修复探针日志：`.noindex/logs/download-review-fix-probe.log`；核心测试日志：`.noindex/logs/download-review-fix-core.log`。

最终模拟器结果：`.noindex/artifacts/download-review-fix-final.xcresult`；日志：`.noindex/logs/download-review-fix-ui-final.log`。本次未重跑未改动的整个基础设施测试集，未进行 Release 真机大规模下载帧率测量。修复仍保留在工作区。

最终浅色总览、深色详情截图已复核：内容正常渲染，文本、进度和底部播放器没有重叠。截图与 manifest 位于 `.noindex/artifacts/download-review-fix-screenshots/`。最终 `git diff --check` 通过。
