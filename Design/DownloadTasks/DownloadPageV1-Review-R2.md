# 下载任务 V1 第二轮 Review

日期：2026-09-29。范围：当前未提交的下载队列、任务汇总、下载页面、目录页面、HTTP 进度、持久化及相关测试。审阅时未修改业务实现；后续修复与验证见文末。以下问题描述与行号对应修复前代码。

## P1：目录展开仍在 MainActor 执行平方级文件查找

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:1428-1437`。

目录扫描完成后，为目录内每个音频调用 `items.firstIndex(where:)`，从全局已发现文件数组线性查找其位置。一个包含 N 个音频的目录产生 O(N²) 次比较；这些比较在 `@MainActor` 队列上连续执行，中间没有挂起点。此前将任务汇总移到后台的修复没有覆盖目录发现路径。

复现：使用现有最新 Debug 核心库，模拟 Provider 按每页 500 条返回单目录音频，同时启动每 1 ms 唤醒的 MainActor 心跳。1,000 / 5,000 / 10,000 条记录的最大 MainActor 调度间隔分别约 150 / 2,494 / 9,496 ms。10,000 条仍在当前支持的上限内；下载开始前整个界面就会停顿。这是同机 Mac Debug 复现，不是 Release 真机帧率。

建议：维护文件 ID 到数组位置的索引，或一次按 ID 合并附属文件关联；将大批量目录数据处理移到后台或分段处理。性能验收需覆盖目录展开，不能仅测 `snapshot.tasks`。

## P1：单文件取消标记污染后续新建任务

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:669-674`、`:615`、`:961`、`:1475`。

`cancelledFileIDs` 是整个队列共享的远端文件 ID 集合。取消批量任务中的一个文件后，其 ID 一直留在集合中。新建目录任务只在 `enqueueImport` 中清理该任务已经拥有的文件；由于新的任务 ID 尚无文件，不会清理旧取消标记。发现同一音频时，新任务直接把文件标成取消，随后下载前检查又抛出取消错误。

复现：任务 A 下载 `Track.m4a` 时取消该文件，等待 A 失败；新建同目录任务 B。B 最终为 `failed`、文件为 `cancelled`，Provider 的下载调用总数仍为 1，B 没有实际下载。新任务的独立 UUID 没有实现取消状态的隔离。

建议：取消状态按任务和本次执行保存，而不是单独按远端文件 ID 保存；新任务独立初始化，恢复仅重置原任务的取消状态。

## P2：有目录任务时，恢复单曲会新建批量任务

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:474-480`、`:537-541`。

`resumeTask` 对单曲调用 `startDownload`。只要同来源还有任意目录任务（包括排队），`startDownload` 就转调 `startBatchImport`，生成新的 `__selection_UUID`。因此原任务不会恢复，成功结果属于另一条任务，原失败记录继续留在待恢复区。

复现：单曲因网络错误失败，随后排队一个不包含该音频的目录任务，再恢复单曲。恢复前两个任务变成三个；目录与新批量任务均完成，原单曲任务仍为 `failed`。本复现没有使用文件取消，独立于上一项。

建议：分开新建操作与恢复操作；恢复单曲时保留原任务 ID，并仅排队其执行，不进入创建批量任务的分支。

## P2：再次下载同一单曲仍覆盖原任务历史

位置：`Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:590-599`、`:544-563`。

普通单曲操作仍以远端 `itemID` 同时作为文件 ID 和任务 ID。没有其他目录任务、该音频尚未转入批量归档时，完成后再次调用 `startImport` 会覆盖同一个下载记录；`createdAt` 也继承第一次时间。目录和选中批量已有独立任务身份，普通单曲尚未做到一致。

复现：对同一无附属文件音频连续执行两次单曲导入，Provider 调用次数为 2，最终 `snapshot.tasks.count` 为 1，第一次任务历史消失。

建议：所有新的用户下载操作都使用独立任务 ID；远端文件 ID 只用于 Provider 请求和文件关联。恢复才保留已有任务 ID。

## 证据与验证范围

- 四项均由独立探针复现，进程退出码为 0；输出是错误行为的复现证据，不表示产品验收通过。
- 探针：`.noindex/tmp/DownloadRereviewProbe.swift`。
- 最终日志：`.noindex/logs/download-rereview-probe-final.log`。
- 复用 `.noindex/swift-core/debug` 最新核心库，库生成时间晚于当前 `OnlineDownloadQueue.swift` 修改时间；没有新建 DerivedData。
- 本轮 `git diff --check` 通过。
- 本轮未重跑完整 Xcode、UI、基础设施测试，未做真实账号或 Release 真机性能测量。上一轮通过的测试没有覆盖这里的新场景。
- 仅新增审阅文档和 `.noindex` 内的探针及证据；未修改业务代码，也未提交。

## 第二轮修复结果

日期：2026-09-29。上述四项已修复，修改保留在工作区，尚未提交。

| 原问题 | 修复 |
| --- | --- |
| P1：目录展开阻塞 MainActor | 用文件 ID 到数组位置的字典替代逐文件线性查找；封面、歌词关联使用 `@concurrent` 在后台执行；最终注册每批最多 500 个文件，检查取消并让出执行机会 |
| P1：文件取消污染新任务 | 取消标记按任务 ID 保存；恢复只重置该任务；文件行传入所属任务 ID，取消同文件的排队单曲不会取消先前正在执行的操作 |
| P2：恢复单曲新建任务 | 单曲统一使用现有批量执行器，恢复沿用原任务 ID 和请求；旧版持久化单曲请求迁移到同一执行器，保留原 ID 和元数据提示 |
| P2：重复单曲覆盖历史 | 每次新建单曲都有独立 `__download_UUID`；`startImport` 返回整次任务 ID；单曲标识与请求可持久化，任务汇总保留单曲图标 |

另修复取消竞态：子文件已成功、但父任务尚未消费其结果时，取消父任务仍保留该文件的成功状态。单曲完成反馈继续使用单曲与重复入库文案。

### 性能复测

同机 Mac Debug、相同 Provider 分页和 MainActor 心跳探针：

| 音频文件数 | 修复前最大 MainActor 调度间隔 | 修复后最大 MainActor 调度间隔 | 修复后发现总耗时 |
| --- | --- | --- | --- |
| 1,000 | 约 150 ms | 4.61 ms | 52.11 ms |
| 5,000 | 约 2,494 ms | 9.26 ms | 191.61 ms |
| 10,000 | 约 9,496 ms | 17.84 ms | 535.48 ms |

10,000 文件的发现总耗时由约 9,634 ms 降到约 535 ms。该数据验证目录发现路径，不代表 Release 真机帧率，也未覆盖真实账号的大规模网络下载。

原四项探针复测：取消文件后新目录任务完成且下载调用达到 2 次；排队目录期间恢复单曲仍为原任务且总任务数保持 2；同单曲两次新操作保留 2 条完成历史。

### 回归与证据

- 核心队列 26 项测试通过。新增覆盖取消隔离、排队单曲恢复身份、重复单曲历史、同文件排队取消、旧版单曲恢复元数据、10,000 文件分页发现；JSON 往返覆盖新增单曲请求。
- 3 项原生下载页交互通过：取消排队目录、取消/恢复/清理历史、深色总览。同轮 5 项场景测试通过。
- 最终后台关联优化后，重跑核心 26 项和场景 5 项，全部通过；3 项 UI 交互未在该优化后重复执行。
- 架构检查与 `git diff --check` 通过。复用 `.noindex/DerivedData` 与 `.noindex/swift-core`。
- 核心日志：`.noindex/logs/download-r2-fix-core.log`。
- 探针日志：`.noindex/logs/download-r2-fix-probe.log`；探针源：`.noindex/tmp/DownloadRereviewProbe.swift`。
- UI 与场景日志：`.noindex/logs/download-r2-fix-ui-final.log`；结果：`.noindex/artifacts/download-r2-fix-final.xcresult`。
- 最终场景日志：`.noindex/logs/download-r2-fix-scenes.log`；结果：`.noindex/artifacts/download-r2-fix-scenes.xcresult`。
