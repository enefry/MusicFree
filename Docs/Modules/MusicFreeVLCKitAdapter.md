# MusicFreeVLCKitAdapter

路径：`Packages/MusicFreeVLCKitAdapter`

`MusicFreeVLCKitAdapter` 将固定版本的 `MusicFreeVLCKit` 映射为 MusicFree 的 `PlaybackAPI`、`MediaSourceAPI` 和领域模型能力。它只处理媒体解析、音频流选择、播放、音效、诊断和能力报告。

## 当前依赖

- 外部 Package：`https://github.com/enefry/MusicFreeVLCKit`
- 版本：`4.0.0-audio.20260814.3`
- 生产入口：`VLCKitPlaybackAdapter`

## 主要组件

- `VLCPlaybackEngine`：播放、暂停、seek、速度、音量、事件和生命周期。
- `VLCMediaProbe` / `VLCMetadataReader`：媒体探测、音频轨和元数据读取。
- `VLCAudioStreamMatcher` / `VLCCapabilityResolver`：音频轨选择和能力映射。
- `VLCAudioEffectsMapper`：运行时均衡器和 VLCKit 原生预设映射。
- `VLCPlaybackDebouncer` / delegate bridge：播放状态变化节流、事件转换和并发边界。

## 明确边界

- 不把 VLCKit 对象、临时 URL、请求 Header 或 Provider 凭据持久化到 Core 模型。
- 不因为 VLCKit 能解析某格式就自动宣称真机可播放；格式矩阵和长时间播放必须单独验证。
- 未声明的 ReplayGain、gapless、crossfade、视频和其他模块不出现在产品能力中。

验证状态见 [`../Testing/VLCKIT_CAPABILITY_MATRIX.md`](../Testing/VLCKIT_CAPABILITY_MATRIX.md) 和 [`../Testing/VLCKIT_FORMAT_MATRIX.md`](../Testing/VLCKIT_FORMAT_MATRIX.md)。
