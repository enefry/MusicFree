# 音频转换规划：导入、已有资料库、AAC-LC / ALAC 与并发

日期：2026-09-29

状态：已在 `feature/1.3.0_dev` 实施；核心自动化测试和 iOS Simulator 构建已通过，实机性能与后台行为仍待验收。

依据：当前 MusicPlayer 工作区源码、聚焦单元测试与真实 AudioToolbox 编码测试。

修订：已纳入并实现用户补充的 ALAC 输出档、已有资料库转换与并发支持；第 9 节记录实际完成情况与验证边界。

## 1. 目标与建议默认值

在现有导入流程中增加可选的无损音频转换，并提供已有资料库的转换命令。输出共六档：`ALAC（无损） / AAC-LC 320k / 256k / 192k / 160k / 128k`，两种编码均封装为 `.m4a`。

| 项目 | 建议行为 |
| --- | --- |
| 设置位置 | 设置 → 导入与资料库 → 音频转码 |
| 自动转码开关 | 默认关闭；开启后，对符合条件的新增无损音频转码 |
| 默认输出档 | AAC-LC 256 kbps；可选择 ALAC 或五档 AAC-LC |
| 输出 | AAC-LC + M4A 或 ALAC + M4A；AAC 禁止隐式改成 HE-AAC / HE-AAC v2 |
| 生效范围 | 文件选择器、文件夹导入、Documents 自动导入、在线源下载后的本地导入，以及用户主动发起的已有资料库转换 |
| 原文件 | 外部文件、Documents 文件、NAS/网盘文件保留；成功后清理 App 自己的暂存副本 |
| App 管理区 | 新增导入只保存通过验证的目标文件；存量转换先保留旧文件，验证并提交成功后清理无引用旧文件 |
| 已有资料库 | 支持歌曲多选、专辑和全库范围转换；修改设置不会自动改写已有文件 |
| 转码失败 | 当前项失败，提供原因与重试；存量转换保留原文件与原记录 |
| 并发 | 设置支持 1 / 2 / 3 / 4 个，建议默认 2；导入与存量转换共用全 App 上限，下载并发维持既有策略 |

这里的“码率调整”是选择编码目标值。`320k` 对应 `320_000 bit/s`，五档均为整条音频流的目标码率，不是每声道码率；实际文件平均码率还受编码器与封装影响，界面区分目标值和实测值。

ALAC 是独立编码模式，没有固定码率；选择 ALAC 时不显示 AAC 码率参数，实际码率由音频内容决定。ALAC 的目标是保留支持范围内的 PCM 样本、采样率和位深，不能套用 AAC 的重采样规则。

以上默认开关、默认输出档、并发范围和失败策略为实施建议。ALAC、已有资料库转换、并发三项已确认为本轮需求，不再列为可选扩展。

## 2. 已确认的现有结构

| 位置 | 当前职责与影响 |
| --- | --- |
| `App/AppContainer.swift` | 组合 `FFmpegMediaProbe`、`FFmpegMetadataReader`、`LocalMediaImporter`；适合注入转码实现 |
| `App/AppDocumentsScanner.swift` | 通过 `ImportServing.start` 导入 Documents，成功后记录目录快照 |
| `Packages/MusicFreeCore/Sources/AppServices/ImportCoordinator.swift` | 导入用例入口、状态广播、取消；目前没有读取转码设置的逻辑 |
| `Packages/MusicFreeCore/Sources/AppServices/OnlineDownloadQueue.swift` | 下载文件及附件后创建 `MediaImportRequest`；目前消费结果事件，忽略多数中间事件 |
| `Packages/MusicFreeInfrastructure/Sources/LocalMediaAdapter/LocalMediaImporter.swift` | 单文件与 bundle 两条处理路径；复制、哈希、探测、元数据读取、去重、事务提交和清理 |
| 同目录 `LocalMediaBundlePlanner.swift` | CUE 逻辑分轨、专辑/碟片结构；CUE 身份计算使用物理资源身份 |
| 同目录 `MetadataNormalizer.swift` | 支持显式指定 `itemID`、`assetID`；可承接来源身份与输出资源身份分离 |
| 同目录 `ManagedMediaStore.swift` | 管理物理文件、共享引用、删除回滚与恢复；文件名的 SHA-256 必须对应实际文件字节 |
| `Packages/MusicFreeCore/Sources/MusicDomain/LocalMediaGraph.swift` | 已有 `MediaAsset`、`TrackVariant`、`PlaybackSelection`，可表达逻辑歌曲和物理资源分离 |
| `Packages/MusicFreeCore/Sources/LibraryAPI/LibraryTransaction.swift` | 支持资源/variant upsert、原子数据库事务、`expectedRevision`；尚无完整文件替换事务或播放资源占用协议 |
| `Packages/MusicFreeCore/Sources/SettingsAPI/ImportPreferences.swift` | 导入设置值类型、复制方法、旧设置解码迁移 |
| `Packages/MusicFreeUI/Sources/SettingsFeature/ImportSettingsView.swift` | 导入设置当前使用 SwiftUI，仍由 `App/SettingsHostingController.swift` 承载 |
| `Packages/FFmpegAudioKit` | 当前实际依赖的本地 C/Swift wrapper，默认二进制来自 0.0.4 Release；现有解码接口只输出 Float32 PCM，没有编码接口 |

当前 `MusicFreeFFmpegAdapter/Package.swift` 依赖 `../FFmpegAudioKit`。`thirdpart/FFmpegAudioKit` 和早期远程 SwiftPM 接入记录不能作为本次实际依赖入口。

当前 FFmpeg 构建脚本使用 `--disable-everything`，仅启用相关 decoder、demuxer 和 parser，没有启用 AAC/ALAC encoder 或 M4A muxer。因此不能直接在 App 内调用一条 `ffmpeg` 命令完成转换。

## 3. 技术方案

### 3.1 推荐：FFmpeg 解码 + Apple 编码

```text
导入设置快照
    ↓
枚举 / 复制到 ImportStaging / 计算原始哈希
    ↓
来源去重与现有文件完整性检查
    ↓
探测原文件 / 读取原元数据与附件 / 规划 CUE 范围
    ↓
符合无损转码条件？
    ├─ 否：沿用原文件导入
    └─ 是：FFmpeg 解码 → 分块 PCM → AudioToolbox AAC-LC / ALAC → M4A
               ↓
          关闭编码器、完成封装 / 验证输出 / 计算输出哈希
    ↓
生成资料库数据 / 文件移入管理区 / 提交现有事务
    ↓
成功或回滚清理 / 发布结果
```

推荐在 `FFmpegPlaybackAdapter` target 增加 `AppleAudioMediaTranscoder`，由 `AudioToolbox` 的 `ExtAudioFile` / `AudioConverter` 写入 M4A。AAC 路线可复用 `FFmpegAudioDecoder.nextBuffer()`；ALAC 路线需要增加精确保留整数 PCM 的分块解码接口。转换过程独立于播放引擎，不启动 `AVAudioEngine`，不改变 `AVAudioSession`。

AAC 输出格式明确指定 `kAudioFormatMPEG4AAC`，设置目标码率前查询当前采样率、声道数下的编码器能力。首个技术验证必须确认编码 profile 为 LC，不能仅凭 `.m4a` 扩展名或格式 ID 宣称合格。

ALAC 指定 `kAudioFormatAppleLossless` 并使用源位深、源采样率和声道布局。现有 Float32 中间格式不能保证所有 32-bit 整数样本精确可逆；不能把“输出是 ALAC”作为无损证据。规划新增整数 PCM 输出及有效位深描述，通过逐样本一致性验证后再开放对应输入规格，保留现有播放用 Float32 API。

| 方案 | 判断 |
| --- | --- |
| FFmpeg PCM + Apple AudioToolbox | 推荐；系统承担 AAC/ALAC 编码，SDK 扩展整数 PCM 桥接；是否需更新二进制依实际所需符号验证 |
| 启用 FFmpeg AAC/ALAC encoder + muxer | 备选；需要扩展 SDK、重新构建和发布二进制，再验证封装、精度、进度、取消 |
| `AVAssetExportSession` 音质 preset | 不能单独承担核心编码；preset 不足以保证五档目标码率，也不能覆盖 APE 等全部输入 |

实现依据第一个编码验证的结果收敛。若系统编码器不能满足五档 AAC-LC 或 ALAC 样本一致性要求，再采用第二条路线。两条路线均需明确支持的位深/声道/采样率矩阵。

### 3.2 输入识别和输出参数

- 按探测到的 codec 判断，不能只按扩展名。选择 AAC 时 ALAC M4A 需要转换；选择 ALAC 时已有合格 ALAC 原样导入/跳过。AAC M4A 保持原样；WAV/AIFF/CAF 只有确认 PCM 等符合条件的编码才进入转换。
- 首版明确覆盖：FLAC、ALAC、APE、PCM，以及现有解码器支持的 TTA、TAK、WavPack lossless、WMA Lossless、ALS。WavPack 需要区分 lossless 与 hybrid/lossy，必要时扩展只读 probe 信息；识别不确定时保留原格式并报告未转码原因。
- 导入自动转换只处理无损输入。已有资料库转换默认同样筛选无损输入；MP3、AAC、Vorbis、Opus、WMA 有损音频显示为不适用，转 ALAC 不能恢复其已丢失的音质。DSD/DSF 等涉及 DSD → PCM 的独立处理，列为后续能力，首版原样导入/跳过并说明原因。
- 单声道保留单声道，双声道保留双声道；首版多声道原样导入并报告未转码原因，不自动混成双声道。
- AAC：44.1 / 48 kHz 保持原采样率；高采样率按家族重采样到 44.1 / 48 kHz。其他输入采样率依据编码器能力选择，并记录实际输出参数。
- ALAC：保持整数 PCM 的原采样率、有效位深、声道顺序与样本数；不重采样、不归一化、不抖动。16/24-bit 是基础验收，其他整数位深必须单独证明系统编码与解码可逆。不支持的规格明确失败/跳过，不能静默降为 24-bit；浮点 PCM 首版不宣称可无损转 ALAC。
- 单声道等参数组合若编码器不支持用户所选码率，明确失败；不暗中换档、不通过复制声道来凑码率。
- 采用分块解码和编码，内存不随整首音频长度增长；不做额外响度归一化。

### 3.3 元数据与 CUE

原文件的元数据、歌词、封面、来源 metadata hint 和 CUE 信息在转码前读取。资料库的标题、艺人、专辑、曲号、碟号、年份、歌词和封面沿用原始读取结果；技术信息、文件大小和输出文件扩展名使用转码结果。原文件名作为来源信息保存，不能把暂存 UUID 当歌名。

资料库元数据保留是首版必验项；M4A 内嵌常用标签与封面可以通过 Apple 原生元数据写入/无重编码封装补齐，先做能力验证。若需要独立导出 M4A 仍完整保留所有标签，应作为明确扩展要求，不能仅靠数据库保留来宣称文件标签完整。

CUE 按每个实际音频文件转码一次，逻辑曲目继续共享同一个输出资源，使用原有范围播放。CUE 身份和逻辑边界在原始资源上规划，再映射到输出；不能用输出文件哈希重新生成 CUE 曲目身份。映射后重建输出音轨选择，不能沿用原流编号。

AAC 的编码延迟和末尾 padding 必须通过容器时间信息正确处理。验收检查第一轨、相邻轨边界、最后一轨和 seek；无法保持原时间线的组合应失败并给出原因。CUE 验证是发布门槛，不可用“普通 FLAC 已转成功”替代。

ALAC 的 CUE 同样按物理资源共享输出，必须保持总样本数和原时间线。已有资料库转换使用当前数据库元数据保留用户修改，不能用文件中的旧标签覆盖已编辑的歌名、封面、歌词或专辑关系。

## 4. 去重、资源身份与兼容

这是本功能的主要数据风险：现有导入默认将“原始哈希、歌曲 ID、资源 ID、托管文件哈希”视为同一件事。编码后这些值必须分开。

建议维持物理资源的内容寻址约定：

| 值 | 用途 |
| --- | --- |
| `sourceHash` | 原始字节的 SHA-256，用于来源去重与普通单曲身份 |
| `managedHash` | 最终 M4A 全部字节的 SHA-256，用于 `MediaAssetID`、文件命名、完整性校验和恢复 |
| `MediaItemID` / `TrackVariant.id` | 普通单曲保留原始 `sha256-sourceHash`；CUE 保留现有来源身份算法 |
| `MediaAsset.id` | 转码时为 `sha256-managedHash`；不转码时与原始身份一致 |
| 转码来源记录 | 保存原始哈希、原格式、目标编码、AAC 可选目标码率、实际输出参数与转换版本，不保存外部绝对路径或凭据 |

利用现有 `Track.assetID` / `TrackVariant.assetID` 关系定位实际文件。`LocalMediaImporter` 的现有单文件查询不能继续直接拿歌曲 `itemID.externalID` 查物理文件。`PreparedLocalMediaAsset` 和 Normalizer 需明确输入来源信息与输出资源信息。

在 `MediaAsset` 增加可选的转码来源记录，并兼容旧 payload：旧文件来源哈希等于托管哈希。新增字段须同步所有复制构造、持久化 mapper 与 repair 路径，避免后续元数据修复丢失来源记录。优先保持当前 SwiftData record 结构，以可选 payload 字段演进；编码兼容仍须测试。

对已经转换过的资源再次做 ALAC → AAC 等转换时，保留最初的来源身份，另记本次输入资源哈希与当前转换参数；不能用中间文件哈希覆盖原始来源哈希，否则原文件重导会失去去重关联。

- 同一原文件重导，无论开关或码率如何变化，现有健康记录均跳过，不隐式替换原来的无损/AAC 文件。
- 资料库已有无损内容时，开启开关再导入不会自动改写已有文件；用户通过第 5 节的存量转换命令主动处理。
- 若托管文件缺失且可取得原来源，使用已有转换记录中的参数修复；重新编码可能得到不同输出文件哈希，应事务更新资源关系并清理无引用旧资源，不能要求容器字节一致。原来源不可取得时明确缺失，不假定已转成 AAC 的内容能够恢复为原无损音频。
- 同一来源并发导入，先获得来源锁、重新检查去重，再进入编码；输出资源提交沿用托管资源锁与引用保护。bundle 的锁按稳定顺序获取，避免嵌套锁死锁。
- AAC/ALAC 成品单独再次导入只能按其自身字节去重，不能推定它与某个无损来源是同一首歌；ALAC 无损验收使用 PCM 一致性，不能要求不同容器哈希相同。
- 删除、回滚和异常恢复仍根据物理文件的真实哈希校验，不使用原始哈希校验转换文件。

## 5. 已有资料库转换

### 5.1 入口与范围

- 资料库歌曲多选菜单、专辑菜单增加“转换音频”；设置 → 音频转码增加“转换已有资料库”入口，支持全库和筛选后范围。
- 操作页先选择六档输出之一，预检后展示歌曲数、实际物理文件数、预计空间变化、跳过/不支持项及共享资源影响，再由“开始转换”发起任务。
- 范围只包括本地托管、可读且符合转换条件的资源。在线源尚未下载的项目不自动下载，不在 NAS/网盘原位置写回。
- 同一物理文件只转换一次。多首 CUE 曲目或其他共享 variant 指向同一 asset 时，将所有引用列入影响范围并一起更新；不在未提示的情况下只转换其中一条引用。
- 已是目标 ALAC 的资源跳过；默认无损筛选下已有 AAC 不再编码。批次显示转换完成、跳过、失败、取消数量，允许仅重试失败项。
- 默认成功后替换 App 管理区旧资源以释放空间。ALAC 可能比原 FLAC/APE 更大，空间预估应允许负收益，不使用“节省空间”作为所有档位的固定承诺。

### 5.2 每个物理资源的提交流程

```text
分页读取范围并按 assetID 合并
    ↓
保存任务与输出参数快照 / 校验输入 / 保留输入资源读租约
    ↓
在既有 staging 下生成新文件，原文件和原数据库关系继续可用
    ↓
验证 codec、时长、CUE、哈希；ALAC 增加 PCM 一致性校验
    ↓
记录恢复 journal / 将新文件放入内容寻址管理区
    ↓
短提交阶段：重读当前关系与元数据，确认旧 asset 和曲目未被删除/替换
    ↓
原子更新所有受影响 Track / TrackVariant 的资源映射与技术信息
    ↓
通知 UI 与播放队列刷新；旧资源无引用且无读租约后清理
```

不使用“删除歌曲再重新导入”实现替换。保留 `MediaItemID`、`LogicalTrackID`、variant ID、歌单成员、收藏、播放统计、专辑/合集关系与用户编辑元数据；只更新物理资源关系、输出技术信息和音轨选择。纯 graph 数据继续保持 graph-only。

复用 `LibraryTransaction.expectedRevision`，提交前读取最新状态并构造窄更新。遇到无关元数据修改可重读后重试；歌曲已删除或物理资源已被另一任务替换时停止该项，不能重建已删除歌曲或覆盖新资源。普通原文件重导与存量转换共用来源/资源协调机制。

每个物理资源及其全部引用作为一个提交单元，批次允许部分成功。文件系统与数据库不能作为同一个 ACID 事务：新增持久化转换 journal，覆盖新文件准备、数据库提交、旧文件清理三个边界。数据库提交前取消/失败保留原映射并清理未引用新文件；提交后取消只停止后续任务，不撤销已经完成的转换。

重启恢复先读取数据库实际引用：未提交输出可清理/重试，已提交输出完成剩余清理；旧文件直到引用和读租约都释放才可删除。旧资源清理采用资源级操作，不能对同一歌曲再调用“删除歌曲”流程。

### 5.3 播放和其他操作

- 为播放器、转换输入、删除与维护增加共享资源读租约/写入协调。当前播放及已预加载的旧文件继续有效；新一轮资源解析使用新 asset。
- 当前曲目不因转换完成被强制暂停、重启或跳转。播放自然结束或播放器明确释放资源后再清理旧文件，重试 seek 也要能继续读取原资源。
- 播放队列与历史保留歌曲 ID，失效的是预解析的资源/技术缓存；更新范围包含 CUE 共享文件的全部受影响曲目。
- 转换过程中编辑元数据仍可进行；删除/清空/维护与提交阶段协调，先检查任务和资源状态，不能删除正在编码的输入或未完成 journal。
- 首版包含持久化任务记录与中断重试：重启后恢复待处理队列，未完成单文件重新开始编码；不承诺跨强杀保存编码器内部位置。

## 6. 并发调度

设置增加“同时转换数量”，选择 `1 / 2 / 3 / 4`，默认建议 `2`。这是导入自动转换和已有资料库转换共享的全 App 编码上限，不能让每个导入批次各自获得 4 个 worker。

规划一个共享 `MediaConversionScheduler`：

- 使用有界 worker 池；每个任务独立持有 decoder、encoder、PCM buffer 和输出文件，不在 worker 间共享有状态句柄。
- `LocalMediaImporter` 当前单文件/bundle 循环不能仅加 semaphore 后继续串行执行；需按上限派发可独立处理的物理资源。bundle 先规划完整 CUE/结构信息，编码并发，汇总后按现有事务边界提交。
- 存量转换按物理 asset 建队列；多个批次命中同一 asset 时共享任务或显示已在转换，不重复编码。同一资源的不同目标请求首版禁止同时执行，待当前任务结束后重新预检。
- 下载和编码是不同阶段，下载完成即可进入受控队列；限制待编码暂存总量，达到磁盘预算时对下载/暂存施加背压。
- FIFO 与批次轮转兼顾新导入、后台扫描和存量批次，不让全库任务长期占满所有名额。暂停某批次只停止其后续派发，当前项允许完成；取消则中断该批次当前项并清理。
- 限额降低时允许已运行任务完成，停止新派发直到占用降到限额内；提高时唤醒等待任务。热状态 serious 时降低后续并发到 1，critical 时暂停新编码；热约束解除后按设置恢复。
- 同时预留各任务的输出磁盘预算，不能让多个 worker 各自通过空间预检后共同耗尽空间。内存上界按 worker 数与固定 buffer 大小计算。
- 编码期间不持有全库写锁。文件提交、引用替换、删除清理和维护采用短临界区，并统一锁顺序；当前 `ImportMaintenanceGate` 与 pruning 规则需扩展为覆盖转换暂存、读租约和 journal。
- 一个 worker 失败不取消无关项目；进度按物理任务统计，并映射到每个受影响歌曲。CUE 多首共享资源不会虚增编码并发。

并发设置可动态调整，输出格式/码率仍使用各批次开始时的固定快照。性能调度只改变同时运行数量，不暗中修改音质参数。

## 7. 模块改动与设置传递

| 模块 | 规划改动 |
| --- | --- |
| `MediaSourceAPI` | 新增 `MediaTranscoding`、`MediaConversionScheduling`、编码目标 `aacLC(bitRate)` / `alac`、请求/结果/进度/错误值类型；导入请求增加参数，事件增加转换阶段与进度；定义托管资源转换与读租约端口 |
| `SettingsAPI` | 新增开关、六档输出与并发限额，默认关闭/AAC 256 kbps/2 个；旧设置缺字段时使用默认值，所有 `setting...` 方法保留新字段 |
| `AppServices` | `ImportCoordinator` 和在线批次产生固定输出快照；新增 `LibraryConversionServing`、转换 coordinator、全局 scheduler、批次暂停/取消/重试与恢复 |
| `MusicDomain` | `MediaAsset` 可选转码来源记录；逻辑歌曲、来源身份和输出资源身份分离 |
| `FFmpegAudioKit` | 保留现有 Float32 播放接口，增加整数 PCM 分块解码、有效位深描述及无损格式识别；不引入 App 任务或资料库逻辑 |
| `FFmpegPlaybackAdapter` | 实现 `AppleAudioMediaTranscoder`，连接 FFmpeg PCM 与系统 AAC/ALAC 编码器；播放器参与读租约与资源缓存刷新 |
| `LocalMediaAdapter` | 注入编码协议和共享调度；实现托管资源输出准备、提交/回滚、转换 journal 与孤立旧资源清理；覆盖 importer/source/remover/maintenance 共用协调 |
| `LibraryAPI` / `LibraryPersistenceAdapter` | 资源映射的窄事务更新、最新元数据合并、graph-only 兼容、共享引用查询、revision 检查与新字段持久化 |
| `PreferencesPersistenceAdapter` | 转换任务持久化存储，仅保存稳定 ID、目标快照和任务状态；文件操作 journal 属于 LocalMediaAdapter |
| `SettingsFeature` | `AudioTranscodingSettingsView` 使用 Toggle、六档 Picker/menu、并发 stepper/menu，并提供已有资料库转换入口 |
| `LibraryFeature` / 在线下载页 | 歌曲多选/专辑转换命令、预检与任务列表、单项和批次进度、暂停/取消/失败重试；在线队列消费转换中间事件 |
| App | `AppContainer` 注入转码器、共享 scheduler、资料库转换服务及任务存储；Documents 复用设置策略；生命周期启动恢复与有限后台处理 |

`MediaSourceAPI` 的转码值类型保持 Foundation / MusicDomain 依赖，不能依赖 `SettingsAPI`。由 SettingsAPI/AppServices 映射用户设置，避免反向依赖环。`LocalMediaAdapter` 不依赖 FFmpeg 实现，只依赖 Core 协议；跨 adapter 的组合在 App 完成。

共享 scheduler 的能力通过 `MediaConversionScheduling` 注入 LocalMediaAdapter；实现放在 AppServices，Adapter 不反向依赖 AppServices。播放用读租约协议同样位于 Core，具体资源生命周期由 LocalMediaAdapter 管理。

每个任务使用固定输出参数快照，中途修改格式或码率只影响下一个任务。在线批次和已有资料库转换批次均保存参数快照；旧在线队列记录的迁移规则显式定义为保持原格式，避免升级后自动改变已排队任务的行为。并发限额由全局 scheduler 实时读取。

## 8. 运行状态、取消与磁盘

- 增加 `waitingForTranscoding`、`transcoding`、`validating` 状态，传播到 Core 状态模型、Library UI 和在线下载子任务；保留既有终态统计。
- 已知时长时，以已处理 PCM 时长计算进度；未知时长显示不定进度。完成封装和验证后才能宣称转码成功，任务提交后才能宣称导入成功。
- 取消检查覆盖等待队列、解码循环、重采样、编码、完成封装和入库前。编码器独占自己的串行执行上下文，不跨线程复用 decoder。
- 新导入文件在既有 `configuration.stagingRoot/<importID>/` 下，存量转换使用该 root 的可识别任务子目录；提交前不会被当成可播放歌曲。转换 journal 和任务记录保存在 App Support 的稳定目录，缓存被系统清除时据此恢复状态。
- 磁盘预检考虑所有并行任务输入、输出、原文件保留与安全余量；ALAC 估算采用未压缩 PCM 大小加封装余量的保守预算。写入过程继续捕获空间不足，提交后才可把旧资源空间计为释放。
- 外部原文件始终保留，所以 Documents 内的无损文件仍占空间；减少的是 App 托管资源占用，ALAC 则未必减小文件。
- 支持离开页面继续执行和存量批次中断后重试。首版不承诺 iOS 长时间后台执行或跨强杀恢复编码器内部位置；进入后台仅利用系统允许的有限时间，到期停止新派发，未提交项取消并记录可重试状态。
- 开启转码后，Documents 自动导入可能更耗时；不让启动界面等待整个编码任务，保留现有可用资料库与播放操作。
- 日志只记录阶段、编码目标、AAC 可选码率、并发数、大小与错误码；不记录完整用户路径、在线 token 或下载临时 URL。

## 9. 实施状态与验收

### 9.1 已实施

| 范围 | 当前实现 |
| --- | --- |
| 编码 | `AppleAudioMediaTranscoder` 使用 FFmpeg 分块解码和 AudioToolbox 编码；支持 ALAC 与 AAC-LC 320/256/192/160/128 kbps，输出 M4A；AAC 设置码率后回读编码器属性，不接受静默换档 |
| 无损校验 | FFmpegAudioKit 增加整数 PCM 分块读取；ALAC 完成后逐帧比较输入和输出的整数 PCM，并校验声道、采样率和样本数 |
| 导入 | 文件、文件夹和 Documents 导入统一读取转换设置；仅符合条件的无损资源转换，文件夹准备阶段最多保留 4 个在途任务，实际编码受共享 scheduler 限制 |
| 设置 | 自动转换开关、六档输出选择、全局并发 1/2/3/4，默认并发 2；设置变化通过事件流实时更新共享 scheduler，单个任务保留目标快照 |
| 已有资料库 | 提供预检、目标选择、批次启动、进度、暂停、继续、取消和失败重试；物理资源替换保持歌曲关系及资料库元数据，旧资源由读租约保护后清理 |
| 并发 | 导入与资料库转换共用 `MediaConversionScheduler`；FIFO 等待、动态升降限额和等待项取消均有覆盖 |
| 恢复 | 批次记录与资源替换 journal 持久化；启动时恢复可重试任务，崩溃前处于取消中的批次恢复为已取消，不重新编码剩余项目 |
| UI | “导入与资料库”页只保留“音频转换”入口；独立子页面提供启用开关、输出格式和并发设置，并以独立 Section 放置“转换已有资料库”；已有资料库转换页展示预检、任务状态及对应控制操作 |

暂停期间不再派发新的等待项，已经进入编码的任务允许完成并汇总结果；继续后再派发剩余项目。存在待处理资源时，批次不会误记为完成。终态批次在当前异步处理链内落盘，减少终止窗口。

### 9.2 已完成的自动化验证

- `MediaConversionSchedulerTests`：并发上限、动态降低上限、等待项取消共 3 条通过。
- `AudioTranscodingTests`：五档 AAC-LC 参数化编码，以及 16-bit AIFF、24-bit WAV 转 ALAC 后整数 PCM 一致性，共 7 次运行通过。
- coordinator 转发、App 启动恢复与动态并发设置、SwiftData 共享资源替换分别通过聚焦测试。
- `LocalMediaLibraryConverterTests` 共 4 条通过，覆盖批次执行、暂停/继续与取消中断恢复。
- 文件夹原子导入/幂等测试通过；转码测试产物使用 `.noindex/tmp/audio-transcoding-tests` 并在结束后清理。
- `git diff --check` 与本地化 JSON 语法检查通过。

上述结果证明当前实现的聚焦合同和 Simulator 编码路径；不等同于真实设备的性能、温控、音频路由或长期后台验收。

### 9.3 原实施顺序

#### 阶段 A：验证编码路线

使用现有 FLAC、ALAC、24-bit PCM fixture，验证五档 AAC-LC、ALAC 编码、M4A 可读性、声道、取消和分块内存。新增整数 PCM 精度样本，ALAC 对解码后的整数样本、样本数、位深与采样率做一致性检查；高采样率不降采样。补充 CUE 连续边界、32-bit/floating PCM 不支持路径和 2/4 worker 编码验证，失败时先修正路线。

#### 阶段 B：设置、来源身份与公共导入

完成 Core 协议和旧数据兼容、六档输出与并发设置、参数快照、来源与物理资源身份分离、转码器/全局 scheduler 注入及事务清理。普通文件和 bundle 共用转换步骤并真正派发有界并发任务。

#### 阶段 C：完整入口与 CUE

接入在线队列进度和恢复、Documents 扫描、CUE 共享资源与时间线映射；保持既有元数据修复、收藏、统计、歌单引用和资源删除行为。

#### 阶段 D：已有资料库转换

完成完整分页预检、asset 合并、任务持久化、资源替换 journal、revision 校验、读租约、引用更新与孤立资源清理。接入歌曲/专辑/全库操作页、进度、暂停/取消和失败重试，验证元数据编辑、播放、删除与转换并行。

#### 阶段 E：回归与实机

| 场景 | 验收要求 |
| --- | --- |
| 五档码率 | 5 档均传入正确 bit/s，编码 profile 为 LC，实际码率符合编码器合同与合理偏差；不暗中换档 |
| ALAC 无损 | ALAC 无固定码率参数；16/24-bit 及已声明支持规格 PCM 样本完全一致，保持位深、采样率和样本数，浮点/不支持规格明确处理 |
| 格式识别 | ALAC M4A 按所选目标转换或跳过，AAC 原样；PCM 容器按 codec 判断；WavPack hybrid 不误判 |
| 声道/采样率 | AAC 重采样正确，ALAC 原采样率保留；不支持的组合有明确结果 |
| 元数据 | 标签、歌词、封面、曲碟顺序正确，文件技术信息来自输出，无暂存 UUID 歌名 |
| CUE | 首尾、相邻轨、seek 正确，每个物理音频仅编码一次，曲目身份不随输出哈希变化 |
| 去重与兼容 | 开关/码率改变后重导仍跳过；旧库无迁移丢失；来源与资源 ID 分离后能播放和删除 |
| 并发与设置 | 1/2/3/4 限额真实生效，跨导入/存量批次总量受控，同 asset 不重复编码；改变限额无丢任务/死锁，批次音质快照一致 |
| 存量范围 | 多选、专辑、全库分页完整，graph-only 和 CUE 共享引用均覆盖，预检数与实际物理任务数一致 |
| 存量替换 | 歌曲/逻辑/variant ID、歌单、收藏、统计、用户元数据保留；转换期间删除不会复活歌曲，编辑不会被旧快照覆盖 |
| 恢复 journal | 在输出准备、文件入库、数据库提交、旧文件清理边界模拟中断，恢复后无缺失映射/误删，未完成编码可重新开始 |
| 播放协调 | 当前播放、预加载、seek 不中断，旧资源在读租约释放后才清理；新播放使用新资源 |
| 失败与取消 | 等待、编码、封装、验证、入库等阶段取消/失败均正确清理；空间不足与数据库失败可重试 |
| 修复与回滚 | 输出文件缺失/损坏、共享 CUE 文件、删除回滚和重启恢复均按实际资源哈希处理 |
| 在线下载 | 单曲、批量、附件场景可见转码阶段，转码失败不能显示为下载并导入成功 |
| 生命周期 | 离开页面继续，启动可用性不受整个批次阻塞；系统后台到期没有悬挂任务 |
| 实机 | 一边播放一边 AAC/ALAC 并发转换，测量 1/2/4 worker CPU/内存/耗时/温度和磁盘峰值，验证热降并发与锁屏/后台 |

测试覆盖现有 `SettingsAPIInitialTests`、`PreferencesPersistenceAdapterInitialTests`、`LocalMediaAdapterInitialTests`、`LibraryPersistenceAdapterInitialTests`、在线下载队列测试以及 Settings/Library 进度测试；新增转换 coordinator/scheduler/恢复测试，真实编码与 ALAC 样本一致性测试集中在 SDK / FFmpeg adapter。

验收产物保存在工程 `.noindex/artifacts/` 和 `.noindex/logs/`。Xcode 使用工程稳定的 `.noindex/DerivedData`；若存在多个 worktree，使用 `.noindex/DerivedData/<worktree-name>` 并复用。构建遇到沙箱权限问题时按实际错误处理，不能将环境失败当成源码失败。

## 10. 尚未完成或仍需实机确认

1. 在真实设备上测量 1/2/4 worker 的 CPU、内存、耗时、温度和磁盘峰值，并验证播放并行时的音频路由、锁屏及系统中断行为。
2. 当前动态降低并发会等待已运行任务自然结束；尚未实现按热状态自动降并发或主动中止运行中的编码。
3. 当前只依赖系统允许的有限后台时间，未接入可保证长批次持续执行的后台调度；强杀后从未提交项目重新开始，不恢复编码器内部帧位置。
4. M4A 内嵌标签没有覆盖所有来源格式的完整映射；资料库中的歌名、专辑、艺人、封面和歌词由数据库关系保留。
5. 多声道、DSD、浮点 PCM、未验证位深和有损音频重编码仍不在首版支持范围。
6. CUE、在线下载与 Documents 的核心导入链已经复用转换服务，但仍需补齐真实长音频、边界 seek、在线失败展示和后台到期的端到端验收。

默认开关关闭、默认输出 AAC-LC 256 kbps、并发范围 1–4 且默认 2 已作为本轮实现值落地。后续若扩展上述范围，应沿用第 4–8 节的数据安全、资源生命周期和恢复约束。
