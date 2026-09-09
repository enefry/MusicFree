# 专辑封面、批量删除及滚动位置修复

验证日期：2026-09-08（America/New_York）。

## 结论与证据

`medias/mp4` 中的 13 个 MP4 各有不同的专辑标签，均包含 H.264 视频、AAC 音频及字幕，没有 attached picture；13 张同名 JPG 的 SHA-256 也各不相同。原资源不是重复封面。

原导入实现只接受 cover/front/folder/album 等目录封面或目录里的唯一图片，不识别媒体同名 JPG。在多图片、多专辑目录中，这些同名图片无法被正确选中。VLCMetadataReader 原先直接消费 VLC 的 artwork；其底层实现通过 artworkURL 读文件，不保证来自当前视频内嵌图片，也没有逐视频画面提取路径。未能读取录屏，因此无法进一步判定录屏中的同图是 VLC 回退图片还是 UI 占位图。

单个删除完成后，控制器再次主动刷新专辑及首页，同时资料库提交事件也触发刷新。LibraryViewModel 在请求开始时清空专辑数组，并在结果到达时再次清空再合并。空快照收缩 UICollectionView，造成可见列表闪动和回顶。重载只查询第一页也会丢弃已加载的后续页。

## 实现

- FolderArtworkResolver 优先匹配同目录、同文件名主体的图片；混合专辑根目录同样允许这种精确匹配。其他媒体的同名图片不会被当成当前媒体的唯一目录封面。保留原有命名目录封面规则和图片解码、尺寸限制。
- 系统可读取的本地视频优先读取文件内封面；没有内封面时，从自身首帧生成最大 1024 像素的 JPEG，处理画面方向。VLC 正常解析路径及 AVFoundation 解析回退路径均接入。视频提取失败返回无封面，不继续拿 VLC 的邻近图片作为视频封面。
- 专辑页新增“选择”，网格与列表均显示选择标记和数量，点击可切换选中状态；删除前确认所选专辑及全部歌曲。
- 全部分页歌曲先解析并去重，再调用一次 LibraryServing.delete，沿用现有事务、文件移除和队列协调逻辑。删除控制器不再额外发起全量刷新。
- 专辑重载保留旧数据，重新加载至原已加载数量或末页后一次替换；快照更新以仍存在的可见专辑作为锚点，并在内容不足时把位置限制在有效滚动范围。用户正在拖动或减速时不强行移动滚动位置。

## 验证

复用 `.noindex/DerivedData/MusicPlayer`，iPhone 17 Pro / iOS 26.5 模拟器。

- 构建测试通过，最终 xcodebuild test 返回 TEST SUCCEEDED。
- MusicFreeUIFeatureTests：165 项通过，包括多页替换期间不发布空数组、批量删除跨页去重只提交一次，以及真实 UICollectionView 网格和列表滚动锚点与选择状态验证。
- LocalMediaAdapterInitialTests：110 项通过，包括混合目录同名封面匹配、避免串用其他媒体的图片，以及现有导入测试。
- VLCDirectMediaProbeTests：3 项执行通过，1 项需要显式外部样本环境变量的测试跳过。真实 13 个 MP4 通过 VLCMetadataReader 产生 13 份不同且可解码的封面；独立红/蓝视频夹具校验像素颜色，防止仅有不同字节但图片不对。原 ALAC 解析测试也通过。
- 架构检查和 git diff --check 通过。

首次扩大回归发现以下两项现有测试失败，最终验证明确排除，没有修改其断言：

1. `differentExplicitAlbumArtistsFormSeparateAlbums()`：相同专辑标题、不同 album artist 被规划为一个专辑，但测试要求两个。
2. `cueSourceSnapshotsUseFinalAggregatedAlbumMetadata()`：规划器返回 albumType=nil，测试要求 compilation。

这两项调用未修改的专辑规划路径，测试输入不经过本次视频提帧或同名图片分支；本次没有单独检出基线复跑，因此不把整个工程测试宣称为全绿。

证据文件：

- `.noindex/artifacts/album-deletion-artwork/media-inventory.json`
- `.noindex/logs/album-fixes-build.log`
- `.noindex/logs/album-fixes-tests.log`（包含最初两项归组失败）
- `.noindex/logs/album-fixes-tests-verified.log`（最终通过，278 项执行通过、1 项跳过）

## 已有资料库与未验证部分

普通媒体导入记录没有可信的原始封面快照，已有非空封面无法安全地判定为错误导入或用户编辑。此次没有自动覆盖已有封面；单纯重新导入已有文件还会受去重保护。要纠正这些已有专辑，请在更新后用“选择”移除相应专辑，再从保留的原资源目录重新导入。此操作沿用原删除语义，不保留被删除歌曲的歌单关系等资料库记录。

本次没有修改 `medias/mp4` 原资源。Downloads 录屏受 macOS 隐私权限限制，提权读取仍返回 Operation not permitted，未能观看。模拟器验证不能替代用户设备、原资料库和录屏场景的最终验收。

## 追加修复：长按删除成功但专辑仍显示

用户实际反馈暴露了上一轮测试覆盖的遗漏：RootViewController 创建共享 LibraryViewModel 时默认 selection 为 tracks，而 LibraryCollectionsViewController 加载专辑页时没有同步 selection。删除事件进入 invalidateOrReload(.albums) 后因此只设置 idle、保留旧数组，没有查询；上一轮删除逻辑又只主动移除了歌曲。

本轮修复：

- 专辑等集合控制器在 viewDidLoad、viewWillAppear 同步当前 section，首次进入及从其他分区返回均可正确响应资料库变化。
- deleteAlbums 在删除服务成功返回后，立即从 albums、recentAlbums、searchAlbums 移除对应项；失败保留显示数据，最后一个专辑删除后进入 empty。
- 如果还有删除之前发起的专辑查询，取消并使其 token 失效，再用已有的非清空方式重查，防止迟到结果恢复旧项。
- 保留之前的可见专辑锚点与分页窗口逻辑。

验证：先新增用例并在修复前实际复现两个失败（成功删除后旧专辑仍在；实际导航默认 selection=tracks）。修复后 MusicFreeUIFeatureTests **168 项通过**。覆盖无通知时立即更新、删除失败、删除最后一个专辑、旧请求迟到、从其他分区返回，以及网格／列表收到删除通知后的真实单元格数量、可见单元格移除和滚动位置。测试替身改为多订阅者广播，避免集合控制器的辅助订阅挤掉 ViewModel 订阅。架构检查与 diff 检查通过，尚未在用户真机复验。

日志：`.noindex/logs/album-delete-ui-repro.log`、`.noindex/logs/album-delete-ui-verified.log`。
