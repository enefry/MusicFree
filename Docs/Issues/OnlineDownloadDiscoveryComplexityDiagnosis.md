# 在线下载目录发现的重复扫描：专项排查

日期：2026-09-29。范围：当前下载页面重构及历次修复后的工作区。按“先排查”的要求，本轮只更新诊断探针与本记录，未修改业务代码。

后续实施方案见 [在线下载完整链路修复方案](OnlineDownloadRepairPlan.md)。

## 结论

多次修复覆盖了多个局部热点，但没有统一目录发现的数据复用边界，也没有以“每次操作对每个目录最多扫描一遍”作为验证条件。当前批量选歌曲仍把原来用于单曲的完整父目录扫描放在逐曲循环里；同时，附属文件匹配仍逐曲遍历全部候选文件。这两种重复工作都尚未消除。

此前将目录内文件位置查找改成字典、将附属文件关联移到后台，解决了特定主线程阻塞；不能据此判定所有入口的发现耗时和请求数量已经解决。此前验收范围过窄，是连续遗漏这些路径的原因。

## 1. 当前调用链与根因

```text
目录页多选歌曲
  → downloadSelectedItems
  → startBatchImport
  → startImport(selectedItems: ...)
  → enqueueImport / performBatchImport
  → discoverImportItems
      ├─ 直接选中的歌曲：逐首 discoverSupportingItems
      │    → 从第一页开始，完整分页 browse 父目录
      │    → 筛选封面、歌词，再按这首歌的名字匹配
      └─ 选中的文件夹：按目录遍历并分页 browse
           → associateSupportingFiles
  → 全部发现完成后，才启动音频下载
```

关键位置：

- `Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/OnlineSourcesViewController.swift:3666`：将选中歌曲或文件夹作为同一 selection 提交。
- `Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:1188-1192`：对每首直接选中音频调用 `discoverSupportingItems`。
- 同文件 `:1376-1398`：每次调用都重新初始化分页 token 和游标集合，从第一页扫描到最后一页。
- 同文件 `:1213`：递归文件夹有另一套分页循环，无法复用前一个分支已经取得的父目录结果。
- 同文件 `:1023`：执行器等待完整发现结果后，才开始派发音频下载；其他整次操作还要等待当前操作结束。

若选中 S 首歌，父目录包含 M 个目录项，每页最多 B 项，请求量为 **S × ceil(M/B)**。当选中数量与目录规模一起增加时，形成平方级增长。固定同一目录、只增加选中数量时，请求量随 S 线性增加；并非所有目录下载入口都具有平方级网络请求。

目前各项去重的范围不同，均不能阻止上述请求：

| 现有措施 | 实际作用 | 未覆盖的工作 |
| --- | --- | --- |
| `itemIndexes` | 按 ID 找到已发现音频的位置 | 父目录网络扫描 |
| `visitedContainers` | 递归遍历时避免重复进入目录 | 直接选中歌曲的父目录扫描 |
| `visitedCursors` | 检测一次分页循环内的重复游标 | 下一首歌曲再次从第一页开始 |
| `supportingTransfers` | 同次操作共享封面文件的下载 | 发现封面的目录列表请求 |
| `@concurrent` | 把附属文件关联计算放到后台 | 减少算法本身的遍历次数 |

`HEAD` 版本的 `discoverSupportingItems` 原本用于单曲导入，一次单曲操作调用一次。当前重构增加了直接选择歌曲的循环，却保留了这个函数“每次完整扫描父目录”的工作粒度。

## 2. 请求计数对照

使用当前 Debug 核心库，同一个不含封面、歌词的目录，1,001 首歌、每页 500 项。Provider 为内存 fixture，记录每个 `(parentID, pageToken)` 的调用次数；没有注入网络错误或重试。

| 操作 | 首个音频下载前 browse 次数 | 不同页面数 | 每页最多被请求几次 |
| --- | ---: | ---: | ---: |
| 整目录下载 | 3 | 3 | 1 |
| 选择 1 首 | 3 | 3 | 1 |
| 选择 100 首 | 300 | 3 | 100 |
| 选择 501 首 | 1,503 | 3 | 501 |
| 选择 1,001 首 | 3,003 | 3 | 1,001 |
| 取消上项后恢复 | 再次 3,003 | 3 | 1,001 |
| 同时选择该文件夹与其中 2 首歌 | 9 | 3 | 3 |

同次测量中，整目录发现约 41 ms，全选歌曲约 11.8 s。这里没有真实网络延迟，时间包含反复筛选目录项的本地工作，不可当成真实 NAS/Google Drive 的耗时预测。请求数量已经足以说明放大路径。

### Provider 层是否会抵消重复请求

- `OnlineSourceCoordinator.browse`（`:100-123`）逐次检查权限并调用 source，没有目录结果缓存。
- `GoogleDriveHTTPTransport.browse`（`:21-64`）每次调用 `get`，后者调用 `httpClient.data(for:)`（`:117-127`）。
- `DSAudioHTTPTransport.browse`（`:179-265`）每次构建目录 list 参数并调用 `performJSON`；已有 session/API 信息缓存不等于目录结果缓存。

因此应用层没有合并这批重复 browse。实际 HTTP 出网次数还取决于 URLSession 缓存策略、服务端响应头及认证过程；本轮没有真实账号抓包，不将 fixture 的 browse 计数直接说成真实网络包数。

## 3. 附属文件关联还存在独立的平方级计算

`associateSupportingFiles`（`:1330-1337`）逐音频调用 `supportingItems`；后者（`:1353-1368`）逐候选构造 URL、提取扩展名和文件名进行匹配。A 首音频、L 个附属文件需要 O(A × L) 次候选检查。每首歌有一个歌词文件时，两者同时增长。

当前这段处理在后台，所以主线程调度间隔较小，但首个音频仍要等整个发现阶段完成。

| 整目录内容 | browse 次数 | 发现总耗时 | 最大 MainActor 心跳间隔 |
| --- | ---: | ---: | ---: |
| 100 首音频 + 100 个同名歌词 | 1 | 137 ms | 2.39 ms |
| 500 首音频 + 500 个同名歌词 | 2 | 3,337 ms | 8.29 ms |
| 1,000 首音频 + 1,000 个同名歌词 | 4 | 13,008 ms | 7.28 ms |
| 1,000 首音频，无歌词 | 2 | 29 ms | 5.28 ms |

500 → 1,000 首带歌词的目录，发现耗时约增加到 3.9 倍。上述测量覆盖整个发现阶段，未单独计时某个函数；O(A × L) 候选检查由当前源码直接确认。它与重复网络扫描是两个需要同时处理的问题。

## 4. 为什么前几轮没有覆盖

| 阶段 | 修复/验证对象 | 留下的缺口 |
| --- | --- | --- |
| 最初卡顿排查与页面实施 | 列表签名重复查找、离屏订阅、同步持久化等 | 未建立完整的目录发现请求预算 |
| 第一轮 Review 修复 | 任务汇总逐任务扫描全部文件 | 只验证历史汇总的规模成本 |
| 第二轮 Review 修复 | 递归目录完成后 `items.firstIndex` 的平方级查找 | 大目录探针是“选一个文件夹”，且全部是音频、没有歌词 |
| 第三轮 Review | 多选直接音频的父目录扫描 | 首次统计此入口的 browse 次数，暴露 3,003 次请求 |

测试代码核对：

- `OnlineDownloadQueueTests.swift:676` 的 10,000 文件测试调用 `startImport(item: root)`，走递归文件夹分支；检查文件数、归属和展开状态，没有断言 browse 次数。
- 同文件 `:247` 的直接音频多选测试只有两首歌，fixture 没有对应父目录内容；主要验证取消与恢复。
- fixture `browse`（`:726` 附近）未记录请求次数，因此“结果正确但重复扫描”仍然通过。
- `MusicFreeBVTUITests.swift:1121` 附近的深色批量交互选择的是两个文件夹，没有覆盖同目录歌曲多选。
- 上一轮“9.5 秒 → 18 毫秒”是无歌词大目录的最大 MainActor 调度间隔；不是整个下载流程耗时，也没有证明多选或歌词关联的复杂度。

## 5. 后续修复应覆盖的边界

建议按整个发现流程组织修复：

1. 为一次执行建立目录发现上下文。以来源、规范化父目录和浏览参数为键，分页结果只读取一次；直接音频、递归文件夹、混合选择共用它。
2. 将目录读取与单曲匹配分开。目录索引一次提取、规范化文件名；歌词按名称索引，公共封面排序一次，按歌曲查询关联结果。
3. 取消或新一轮恢复建立新的执行上下文，避免把上次不完整分页或过期目录长期缓存；同一轮恢复内部仍遵守每个目录只扫描一遍。
4. 对已成功音频优先判定跳过，避免无用的附属文件关联；需要重新发现的远端目录保持明确的一次扫描语义。
5. 为各入口增加请求预算断言：单曲、同目录多选、跨目录多选、目录与歌曲混选、递归目录、恢复。无错误条件下，每个目录的请求量应等于实际分页数，与选中歌曲数量无关。
6. 用带同名歌词的规模样本验证关联成本，同时记录发现总耗时、MainActor 调度间隔和首个下载时间，避免只看主线程指标。

仅改成并发扫描会保留请求放大，甚至更容易触发限流；仅转移后台也会保留首个下载前的长等待。修复验收需要同时看请求预算和数据处理工作量。

## 6. 从请求到下载、入库、UI 刷新的验证边界

针对“从请求到下载到 UI 刷新整个链路都确认了么”的补查：**当前源码连接点已经追到资料库刷新，但没有完成同一次大批量下载的端到端性能实测。** 目录请求探针、真实 URLSession 的本地 HTTP 测试、队列测试和 UIKit 功能测试分别覆盖不同环节，不能合并成“真实 Provider 下载时整个 App 不再卡”的结论。

```text
目录页下载操作
  → OnlineSourceScene.startBatchImport / startImport
  → OnlineDownloadQueue 目录发现、附属文件关联
  → OnlineSourceCoordinator.download → Provider transport → URLSession
      ├─ 字节回调（约 200 ms 节流）
      │    → MainActor 更新单文件进度 → 独立 progress stream
      │    → 下载页匹配的可见文件行
      └─ 下载回执 → 后台移动音频、复制附属文件
           → ImportCoordinator.start → LocalMediaImporter
           → 哈希、媒体解析、托管文件、资料库事务
                ├─ SwiftData 保存 → LibraryChange
                │    → LibraryViewModel 查询、合并或重载
                │    → UIKit 排序、分组、diffable snapshot
                └─ persisting 事件 → 可选元数据填充队列
                     → 查找/补充元数据 → 进一步的资料库变更
           → completed 事件 → 下载/整次任务状态 → queue state stream
                → Scene 状态与反馈、在线目录行、下载页任务/文件列表
                → 下载队列恢复状态持久化
```

App 的依赖连接已核对：`AppContainer.swift:457` 创建 `SwiftDataLibraryRepository`，`:499` 将其注入 `LocalMediaImporter`；`AppServiceContainer.swift:147-154` 将 `ImportCoordinator` 注入下载队列。资料库 UI 通过 `LibraryCoordinator.makeChangeStream`（`:1012`）消费同一 repository 的变更，未发现下载成功与资料库刷新之间缺少连接的问题。

| 环节 | 已确认的证据 | 仍未确认 |
| --- | --- | --- |
| 目录请求、附属关联 | 当前核心库探针测到 3,003 次 browse；带歌词目录发现约 13 s；调用已追到 Provider transport | 真实账号的 HTTP 出网次数、延迟、重试与限流 |
| 音频/附属下载、字节进度 | transport 使用进度 overload；本地 HTTP + 真 URLSession 验证中间进度与取消；音频工作槽上限为 3 | 真实网络与大文件下的总吞吐、回调量、磁盘成本；音频工作槽同时承担下载和入库，不能当成始终有 3 个网络传输 |
| 队列状态、恢复持久化 | 当前 26 个队列相关测试、5 个 Scene 测试通过；合并保存/flush/重开/清理测试通过 | 每次阶段变化构造全量状态的主线程累计成本；第三轮已复现的共享附属文件等待取消等问题仍未修复 |
| 入库、资料库通知 | 源码确认真实 importer 提交事务后发布 typed `LibraryChange`；基础设施功能测试通过 | 大库下逐曲事务成本、与页面查询的排队、可选元数据填充带来的后续工作 |
| 下载页、目录页、资料库 UI | 字节与阶段分流；任务汇总在后台；下载页离屏取消订阅；3 个 UIKit 功能测试通过（早于最后一次附属关联优化） | 同一次大批量真实下载中的 UI 刷新次数、主线程长任务、滚动卡顿/掉帧；不能把上述交互测试当成性能测试 |

### 本次补查确认的剩余工作量

以下是源码可见的工作量，**尚未测量其对实际卡顿的贡献**：

- `OnlineDownloadQueue.snapshot`（`:282-286`）将独立进度投影回全量下载字典。`persist`（`:1537-1546`）在 MainActor 构造全部文件、整次任务和恢复请求数组，之后才交给后台保存。JSON 编码已经移出主线程，并不表示状态构造成本也消失了。
- `OnlineSourceScene.applyDownloadQueueSnapshot`（`:1308`）在每次阶段状态事件时扫描下载与整次任务；下载页 `applyRender`（`:145`）仍在 MainActor 筛选 section、配置可见行及重建 header。字节进度不会直接触发这批完整工作，但阶段变化会。
- 每首音频通过 `downloadAndImportItem`（`:835`）单独启动一次 import。`LibraryPersistenceStore.apply`（`:1684-1685`）每次读取完整资料库和本地媒体图，随后校验、保存并于 `:2181` 发布变更。Store 是独立 actor，不可把该工作直接说成同步主线程阻塞；它与页面的资料库查询共享串行 Store，可能造成查询等待。
- `LibraryViewModel.applyLibraryChange`（`:1112`）已使用 typed IDs，歌曲变更合并窗口为 30 ms，概览为 200 ms；新入库歌曲仍会使已加载歌曲 section 重查。`LibraryTracksViewController.renderSnapshot`（`:491`）在 MainActor 对当前加载歌曲排序、分组、重建 diffable snapshot（`:512-592`）。其 `viewDidDisappear`（`:220`）没有取消 Combine 列表订阅；已加载并保留的控制器在离屏时仍可能处理模型变化。
- `ImportCoordinator.consume`（`:120-121`）收到 `persisting` 后调用元数据填充的 `enqueue`；开启且依赖可用时，后台队列继续查询并补充资料库（`MetadataEnrichmentCoordinator.swift:256,530,918`）。下载任务的 completed 不代表所有后续资料库工作已结束。原发现探针没有覆盖此分支。

### 已核对的测试记录与下一次测量要求

- `.noindex/logs/download-progress-delegate-tests.log`：真实 URLSession 本地 HTTP 进度/取消，以及持久化测试，2/2 通过。较早的 `download-progress-http-tests.log` 构建被中断，不能作为成功证据。
- `.noindex/logs/download-page-acceptance-tests.log`：基础设施 233/233 通过，含真实 importer/persistence 的功能测试；这不是 233 次在线下载或 UI 性能验证。
- `.noindex/logs/download-r2-fix-core.log`：26/26；`download-r2-fix-scenes.log`：5/5；`download-r2-fix-ui-final.log`：3 个 UIKit 交互测试和 5 个 Scene 测试通过。它们均没有给出大批量滚动帧率或整个执行过程的关联时间线。

性能闭环需要为同一次操作关联 taskID、文件 ID 和 importID，记录目录请求计数、首个音频开始时间、下载与进度回调、附属文件等待、每次入库/Store 查询耗时、阶段发布及持久化次数、各页面 render/apply 次数，并在持续滚动时测主线程长任务/掉帧。样本至少覆盖同目录歌曲多选、递归文件夹、目录与歌曲混选、歌词/封面、大资料库、取消后恢复，以及离开下载页后滚动资料库。当前没有这份联合运行记录，因此尚不能确认整个 App 卡顿问题已经收敛。

## 证据与限制

- 探针：`.noindex/tmp/DownloadReviewR3Probe.swift`，参数 `--discovery-matrix`。
- 日志：`.noindex/logs/download-discovery-matrix.log`，最终进程退出码 0。
- 初次矩阵使用原有 10 秒轮询上限，在较慢场景超时；随后加入逐场景即时日志并放宽测量窗口，完整取得上述结果。
- 源文件 `OnlineDownloadQueue.swift` 修改时间 `2026-09-29 01:20:23`，链接的 `AppServices.o` 为 `01:20:31`；本轮没有修改业务代码。
- 复用 `.noindex/swift-core/debug` 和 `.noindex/DerivedData/ModuleCache.noindex`，未新建 DerivedData。
- 数据来自同机 Mac Debug 与内存 Provider，无真实网络延迟；没有做 Release 真机帧率或网络抓包验证。
- 本轮没有重跑 Xcode/UI 全套测试。相关历史结果见 [第二轮记录](../../Design/DownloadTasks/DownloadPageV1-Review-R2.md)、[第三轮记录](../../Design/DownloadTasks/DownloadPageV1-Review-R3.md)。
