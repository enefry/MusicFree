# FFmpegAudioKit

独立、可依赖、与业务解耦的 **audio-only ffmpeg** 封装。iOS App 可通过 SwiftPM 依赖本仓库的包做音频**解码 / 探测 / 元数据读取**。

- 从 ffmpeg 源码交叉编译，**不复用任何第三方（如 VLC）已编译产物** —— 真正独立。
- 只保留音频能力：视频、网络、滤镜、命令行工具全部关闭，体积最小化。
- C wrapper 不外泄任何 ffmpeg 类型；Swift API 只暴露格式中立的通用结构体。
- **不含播放器**：解出非交错（planar）Float32 PCM 后，AVAudioEngine 播放逻辑由使用方自行实现。

## 结构

```
Scripts/build-ffmpeg.sh            从源码 audio-only 交叉编译 → xcframework
Artifacts/FFmpegAudio.xcframework  本地构建产物（不入 git；缺省时从 GitHub Release 下载）
.github/workflows/release.yml      构建并发布 Release
Sources/CFFmpegAudio/              C wrapper：decode / seek / probe / metadata
Sources/FFmpegAudioKit/            通用 Swift API（零业务依赖）
    FFmpegAudioDecoder             解码：PCM → AVAudioPCMBuffer（非交错 planar Float32）
    FFmpegProbe                    探测：流信息 / 容器 / 时长 / 是否含视频
    FFmpegMetadataReader           元数据：标签 + 内嵌封面
```

## 依赖

MusicFree 通过 `Packages/MusicFreeFFmpegAdapter/Package.swift` 中的本地路径依赖该包：

```swift
.package(path: "../FFmpegAudioKit")
```

该包的 C/Swift 源码和构建脚本保存在当前仓库；单独使用时可将整个包目录复制到自己的工程，再用本地路径依赖。

预编译的 `FFmpegAudio.xcframework.zip` 随 [GitHub Release](https://github.com/enefry/FFmpegAudioKit/releases)
发布，`Package.swift` 中固定了对应版本的下载地址与 checksum，使用方无需本地编译 ffmpeg。
即使本地存在 `Artifacts/FFmpegAudio.xcframework`，默认构建仍使用清单固定的 Release。
调试本地框架时显式设置 `FFMPEG_AUDIO_USE_LOCAL_BINARY=1`，并重新解析包依赖；
本地覆盖产物不受 Release checksum 约束，不应作为 App Store 分发构建。

## 单独发布 SDK

包内 `.github/workflows/release.yml` 是独立仓库的发布流程；放在 MusicFree 的 `Packages/` 下不会自动运行。若单独维护 SDK 仓库，可在 GitHub Actions 手动运行 **Release** workflow 并填写版本号（如 `1.0.0`）。流程会从源码构建
xcframework、跑测试、打包 zip、改写 `Package.swift` 的 URL/checksum 并提交，再打 tag 发布 Release，
最后删除本地产物、从 Release 下载校验一遍。

ffmpeg 头文件（`Sources/CFFmpegAudio/ffmpeg`）随源码提交；升级 `FFMPEG_VERSION` 时需本地重跑构建脚本并
提交新的头文件，否则 Release 流程会因头文件与产物不一致而失败。

## 构建 xcframework

`Artifacts/FFmpegAudio.xcframework` 不入 git；需要修改或调试 ffmpeg 时本地生成：

```sh
./Scripts/build-ffmpeg.sh
```

脚本会：

1. 下载 pinned 版本 ffmpeg 源码（默认 `8.1.2`，缓存于 `.build-ffmpeg/`，不入 git）。
2. audio-only configure，交叉编译三片：`arm64-iphoneos`、`arm64-iphonesimulator`、`x86_64-iphonesimulator`（部署目标 iOS 17.0）。
3. 合并静态库并 `xcodebuild -create-xcframework`，产出 `ios-arm64` + `ios-arm64_x86_64-simulator`，每片为一个**动态** `FFmpegAudio.framework`。
4. 同步头文件到 `Sources/CFFmpegAudio/ffmpeg`（C wrapper 编译用的私有 include 拷贝，随源码提交）。

可通过环境变量覆盖：`FFMPEG_VERSION`、`FFMPEG_URL`、`DEPLOY_TARGET`。

依赖：Xcode 命令行工具（`xcrun`/`clang`/`libtool`/`lipo`）、`curl`、`tar`。

## 许可证（LGPL）

本项目仅编译 ffmpeg 的 **LGPL** 子集（未开启 `--enable-gpl` 及任何 GPL 组件），
并以**动态 framework** 形式分发，使用方可替换/重链该 framework，因此接入的 App
无需开源自身代码。使用时仍需履行 LGPL 义务：随附 LGPL 许可证全文与 FFmpeg 归属
声明，并提供所用 ffmpeg 源码（本仓库固定 `FFMPEG_VERSION`，可复现构建）。

## 用法

```swift
import FFmpegAudioKit

// 解码
let decoder = try FFmpegAudioDecoder(localFileURL: url)
while let buffer = try decoder.nextBuffer() {
    // buffer 为非交错（planar）Float32 的 AVAudioPCMBuffer
}
try decoder.seek(to: .seconds(30))

// 探测
let probe = try FFmpegProbe.probe(localFileURL: url)
print(probe.container, probe.duration, probe.tracks)

// 元数据
let meta = try FFmpegMetadataReader.read(localFileURL: url)
print(meta.title, meta.artist, meta.artworks.count)
```
