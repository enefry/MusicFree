# 下载任务 V1 第三轮 Review

日期：2026-09-29。范围：当前工作区的下载队列、任务汇总、下载页面、目录页面、HTTP 进度、持久化及相关测试。以下行号对应本轮审阅时的当前代码。本轮未修改业务实现。

## P1：同目录批量选择仍产生平方级远端目录请求

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:1188-1192`。

对直接选中的每首歌曲，发现流程串行调用 `discoverSupportingItems`。该方法每次从第一页遍历整个父目录；相同父目录没有本次任务内的分页结果缓存。所有扫描完成后才开始下载音频。选中 N 首同目录歌曲、父目录有 P 页时，首个下载前需要 N × P 次目录请求。

复现：同目录 1,001 首歌曲、每页 500 项，全选后首个音频下载前发生 **3,003 次 browse 请求**。该目录只需要扫描 3 页。实际 NAS 或云端请求的延迟会逐次累积，并可能触发限流；整次任务占用串行队列期间，其他下载任务也不能开始。

建议：按父目录分组，在一次任务内只扫描每个父目录一次，再给各音频关联封面与同名歌词；不要按歌曲重复完整分页。

## P2：取消等待附属文件的音频后，仍阻塞整个任务队列

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:920-924`，关联 `:665-674`。

附属文件使用可共享的独立 `Task`。单文件取消只取消音频执行任务，音频执行任务正在 `await transfer.value` 时不会因自身取消而立即退出；取消检查位于等待完成之后。父任务因此仍等待这个子任务，即便该音频已经显示为已取消，而且没有其他音频需要该附属文件。

复现：目录仅含一首音频和 `cover.jpg`；封面下载挂起后取消音频。250 ms 后音频为 `cancelled`，整次任务仍为 `downloading`，`canResumeTask` 为 false，随后排队的单曲仍为 `waiting`。只有封面完成/失败或额外取消整次任务，队列才能释放。慢速持续返回数据的封面可以长时间占用队列。

建议：让每个音频对共享附属文件的等待响应取消；按消费者管理共享传输，仅在没有其他消费者时取消底层请求，保留其他音频的共享下载。

## P2：远端删除失败文件后，恢复产生无法清理的已完成任务

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:1267-1271`，关联 `:1124-1134`、`:484` 和 `OnlineDownloadTaskSummary.swift:36`。

恢复重新扫描目录，但保留已经不在扫描结果中的旧文件记录。执行器仅按本次扫描结果统计终态；任务汇总却同时统计旧文件记录。两者使用不同的文件范围，造成执行器标记完成、页面仍显示部分失败。

复现：目录中 Track 下载失败、Other 成功；远端删除 Track 后恢复原任务。原始 import phase 为 `completed`，汇总 task phase 为 `partialFailure`，失败文件仍为 1。调用 `clearCompletedTasks` 后该任务仍在，因为清理依据汇总状态；继续恢复也无法处理已经不存在的文件。

建议：恢复发现完成后核对旧记录与当前目录范围，对消失文件明确记录跳过或失败，并让执行终态、汇总与清理使用一致的结果口径。

## P2：旧单曲被其他任务归档后，恢复丢失原始元数据

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:1319-1322`。

其他任务覆盖旧单曲的全局文件条目时，`archiveTaskFiles` 将 `resumableDownloads` 转为 `resumableImports`，但只重新构造含 title/artist/album 的 `selectedItems`，遗漏 duration，也没有保存原始 `singleDownload` 请求。之后 `resumeTask` 优先使用这个新请求，无法再取得原有精确元数据提示。

复现：恢复一个旧版失败单曲，其提示为 `displayName=Original Display`、`duration=42s`；先新建包含该单曲的目录任务并完成，再恢复旧单曲。最终入库提示变成 `displayName=Track.m4a`、`duration=nil`，与原始提示不等。原任务 ID 虽保留，元数据仍丢失；旧任务还缺少单曲标识。

建议：归档迁移时完整保存原来的 `OnlineDownloadQueueDownloadTask`，并标记为单曲；直接恢复和先归档再恢复应使用相同请求。

## 复现与验证范围

- 四项均使用当前 Debug 核心库的独立探针场景确认；进程退出码 0 表示探针正常执行，不表示产品验收通过。
- 探针：`.noindex/tmp/DownloadReviewR3Probe.swift`；二进制：`.noindex/tmp/download-review-r3-probe`。
- 日志：`.noindex/logs/download-review-r3-probe.log`。
- 核心源文件修改时间为 `2026-09-29 01:20:23`，所链接的 `AppServices.o` 为 `01:20:31`，晚于源文件；复用了现有构建产物与 `.noindex/DerivedData/ModuleCache.noindex`。
- 编译探针时因 Swift 宏插件的沙箱限制使用了授权的构建权限；没有新建 DerivedData。
- `git diff --check` 通过。没有重跑完整 Xcode/UI 测试，未使用真实账号，也未做 Release 真机性能测量。
- 本轮只新增审阅文档与 `.noindex` 内的探针证据，没有提交。

```text
SELECTION: selected=1001, browseBeforeFirstDownload=3003
DELETED ON RESUME: importPhase=completed, taskPhase=partialFailure, failedFiles=1, tasksAfterClear=1
ARCHIVED LEGACY: hintEqual=false, display=Track.m4a, duration=nil
CANCEL AUDIO WAITING SIDECAR: audio=cancelled, task=downloading, canResume=false, nextTask=waiting
```
