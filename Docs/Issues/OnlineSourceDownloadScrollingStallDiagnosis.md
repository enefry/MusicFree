# 在线源下载时全 App 卡顿：排查记录

- 日期：2026-09-28
- 检查版本：`23f4c6492a096fa3b37896fe207b2ef2f3df5cd9`，分支 `codex/ffmpeg-bvt-verification`
- 范围：在线源下载、单曲/目录导入、下载状态发布、UIKit 在线目录刷新及资料库入库。
- 状态：已完成代码排查和 Mac 合成基准；尚未在用户设备和实际在线源上录制性能轨迹。未修改业务实现。

## 结论

下载状态变化会触发大量主线程工作。最明显的放大因素是：离屏目录控制器继续接收状态并计算列表签名；列表签名计算包含重复线性查找；下载队列同步排序、编码、保存完整历史。

这些问题足以造成滚动掉帧，Debug 构建尤其明显。用户现场各因素的占比还需要真机 Time Profiler / Hangs 轨迹确认，不能将下面的 Mac 数字当成设备实测。

## 1. 离屏目录控制器仍然处理下载状态

位置：`Packages/MusicFreeUI/Sources/SettingsFeature/UIKit/OnlineSourcesViewController.swift`

- `viewDidLoad` 第 1750 行启动 `observeModel()`。
- 第 1863、1877、1906 行创建三个观察任务。任务虽然捕获 `[weak self]`，但在进入长时间运行的 `for await` 之前执行 `guard let self`，因此整个订阅生命周期都强持有控制器。
- 控制器持有任务，任务持有控制器。第 3071 行仅在 `deinit` 取消任务，无法靠这段代码打破自身引用循环。
- 没有在 `viewDidDisappear` 停止这些订阅；第 2074 行只判断 `isViewLoaded`，没有判断是否可见。
- 第 1909 行订阅整个下载队列，每个事件都调用 `render`。其他目录、其他在线源的任务更新也会触发当前目录页计算。

因此，导航栈中的父目录、已切换到其他 Tab 的目录页，以及因订阅持有而无法释放的旧页面，都可能持续计算。即使页面内容未变，也会先完整计算内容签名才返回。这是“下载时整个 App 都卡”的一个直接解释。

独立 Swift 生命周期复现沿用上述任务持有方式，输出如下：

```text
Retained after external owner released: true
Received/rendered subsequent event: true
Released after explicit task cancellation: true
```

该复现验证引用持有模式，没有直接实例化 UIKit 控制器。

## 2. 列表刷新存在平方级计算

位置：同文件第 2073 行 `render`、第 2211 行 `catalogContentSignature`、第 2222 行 `catalogRowSignature`。

- `catalogContentSignature` 遍历所有行。
- 每行的 `catalogRowSignature` 在第 2227 行执行 `items.first { $0.id == itemID }`，一次全表签名需要约 `n(n+1)/2` 次 ID 比较。
- 当内容改变时，第 2106 行检查需要 reload 的行，第 2113 行重建签名字典，再重复计算签名。稳定行集合下最多约三轮全表签名计算。
- 第 2107 行的 `currentIdentifiers.contains($0)` 也是数组线性查找，进一步增加平方级工作。
- 第 2120 行随后提交整个 diffable snapshot。状态按钮更新也会走这条路径。

Mac arm64、macOS 26.6.2，7 次取中位数：

| 目录行数 | Debug 单轮签名 | Debug 三轮签名 | 优化构建三轮签名 |
| --- | ---: | ---: | ---: |
| 100 | 1.15 ms | 2.79 ms | 1.09 ms |
| 500 | 11.62 ms | 34.42 ms | 3.56 ms |
| 1,000 | 44.38 ms | 133.26 ms | 8.08 ms |
| 2,000 | 175.91 ms | 580.29 ms | 22.75 ms |

探针从当前源码提取未改写的 `catalogRowSignature`，提供合成的歌曲/状态依赖。三轮是内容发生变化时的计算量近似；内容不变的离屏页面仍承担首轮。未计入 `currentIdentifiers.contains`、真实标题处理、UIKit snapshot apply、单元格创建和布局。

60 Hz 每帧约 16.67 ms，120 Hz 约 8.33 ms。Debug 下 1,000 行的签名计算就能阻塞多个显示帧；离屏页面会叠加这笔开销。

## 3. 下载状态在主线程同步保存完整历史

位置：

- `Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift:192`：队列整体为 `@MainActor`。
- 第 1298 行 `publish` 在广播状态前调用 `persist()`。
- 第 1304 行 `persist` 排序所有下载、目录导入和待处理请求，再调用持久化端口。
- `Packages/MusicFreeInfrastructure/Sources/PreferencesPersistenceAdapter/UserDefaultsOnlineDownloadQueueStore.swift:38`：同步 `JSONEncoder.encode`，随后 `UserDefaults.set`。

完成历史在启动时恢复，当前实现只有移除源时筛掉该源历史，没有完成历史条数上限。随着已下载歌曲累积，每次状态变化的保存成本增加。

目录导入每首歌至少发布下载中、导入中、完成、目录计数更新四个快照。目录流程每个任务最多并行三首，但多次单曲启动和多个目录任务没有共享的全局并发限制。

使用真实生产快照类型、真实排序和 JSON 编码的合成测量：

| 下载历史条数 | Debug 排序+编码 | 优化构建排序+编码 | JSON 大小 |
| --- | ---: | ---: | ---: |
| 1,000 | 5.00 ms | 3.05 ms | 135,311 bytes |
| 5,000 | 24.44 ms | 13.96 ms | 683,314 bytes |
| 10,000 | 50.03 ms | 28.64 ms | 1,368,314 bytes |

测量未调用 `UserDefaults.set`，没有读取或修改用户的偏好数据；数字仅代表排序与编码的成本。

## 已确认的其他路径

- 真实 DS Audio、Google Drive 使用 `URLSession.download(for:)` 等异步下载。当前队列发布阶段状态，没有每个网络数据块都刷新 UI 的进度回调。
- `FFmpegMediaProbe` 和 `FFmpegMetadataReader` 的同步 FFmpeg 操作已经放在 `.utility` 后台队列。
- `AppContainer.makePersistenceStore` 已通过 detached task 创建 SwiftData context，不能把旧的主线程初始化问题作为当前结论。
- 下载队列仍在主线程同步创建、移动和移除导入临时文件，可一并挪到文件工作器，但没有证据表明同卷文件移动是主要耗时。

## 建议修复顺序

1. 将目录观察限定到可见生命周期，离屏时取消；避免在整个订阅循环外强持有控制器。重新出现时读取最新快照，保留 App 级下载任务的生命周期。
2. 为目录项建立 ID 字典、为当前行建立 ID 集合；只对受影响行更新状态。合并短时间内状态变化，避免一个按钮变化重复重建全表签名和 snapshot。
3. 将队列编码与保存移到有序后台工作器，合并保存请求，保持最新状态顺序及中断恢复能力；单独设计完成历史的存储/缓存策略。不能直接丢弃待处理任务。
4. 将文件整理移出主线程，并评估所有入口共享并发上限。

建议先处理前两项，再在真机验证其占比。验证应覆盖下载时滚动在线目录和资料库、进入多层目录后切换 Tab、退出目录后的控制器释放、取消/重试、回到目录后的状态同步，以及进程重启后的任务恢复。

## 复现材料

稳定目录：`.noindex/artifacts/download-stall-probe/`

- `run.mjs` / `Probe.swift`：从当前源码提取快照与签名方法，分别测量 `-O` 和 `-Onone`。
- `release.txt` / `debug.txt`：本次测量结果。
- `Lifecycle.swift` / `lifecycle.txt`：订阅持有模式及释放验证。
- 生成的 Swift 合并文件和执行程序已清理；复用工程内 `.noindex/ModuleCache`，未创建 DerivedData 或系统临时工程。

```sh
node .noindex/artifacts/download-stall-probe/run.mjs
```

设备查询时已登记的物理设备均为 `unavailable`，无法采集这次现场卡顿轨迹。尚未得到用户在线源、设备型号以及安装包构建配置，因此现场归因保持上述边界。
