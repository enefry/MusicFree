# MusicFree 自定义音频版 VLCKit 构建与接入计划

状态：Implementation in progress；r5 音频模块裁剪候选已生成，运行时与发布门禁仍开放

日期：2026-08-14

实施状态：已创建并修改 `MusicFreeVLCKit` 构建仓库，已生成并保留 iOS Device/Simulator XCFramework；尚未替换 MusicFree 生产依赖，也未宣称可发布

后续维护：VLCKit/libVLC 上游升级、补丁重放、主线冲突处理和升级交接模板统一维护在 `../MusicFreeVLCKit/Documentation/MUSICFREE_UPSTREAM_UPGRADE_GUIDE.md`。后续 agent 应先读取该指南，再创建独立 upgrade worktree；不要直接在已知良好分支上 merge/rebase。

当前候选：

- XCFramework：`MusicFreeVLCKit/build-audio-ios-20260814-r5/iOS/VLCKit.xcframework`，117,546,306 bytes（约 112.1 MiB）
- SwiftPM ZIP：`MusicFreeVLCKit/build-audio-ios-20260814-r5/release/MusicFreeVLCKit-audio-ios-20260814-r5.xcframework.zip`，43,627,677 bytes（约 41.6 MiB）
- Device Mach-O：5,789,208 bytes；当前官方同口径 Device Mach-O：44,920,432 bytes，候选减少 87.11%
- SHA-256 / SwiftPM checksum：`873b6c4a9840565cad530ea7278b70fb3748b2136fa647abb52666ce418f6565`
- Manifest：`MusicFreeVLCKit/build-audio-ios-20260814-r5/release/build-manifest.json`

当前门禁：

- 已通过：三架构布局、dSYM UUID、静态模块禁止清单、FFmpeg 视频组件、最终 Mach-O 导出符号面、iOS 系统框架依赖、公开头文件、SwiftPM consumer checksum/import/link、SBOM/许可证材料生成、Device Mach-O 同口径体积对比。
- r5 已生成但标记为 blocked/not-run：11 类音频格式矩阵、HTTP/HTTPS/SMB2/3/FTP/FTPS/FTPES/NFS 协议矩阵、无 grant 零联网证据、真机播放、二次干净构建一致性；详细机器可读证据在 `MusicFreeVLCKit/build-audio-ios-20260814-r5/release/`。
- 静态审计仍失败：最终动态 framework 没有 VideoToolbox/OpenGLES/AVKit 依赖，也没有导出视频符号；但底层 libVLC core 仍保留播放器兼容路径、音频容器共享解析代码和视频 codec 描述符号。当前不能表述为“视频代码完全删除”，若该要求是硬门槛，必须继续做 libVLC 源码级裁剪并重新构建底层静态库。
- 构建复现注意：r5 使用了 dirty VLCKit/libVLC worktree，尚未完成一次从干净 checkout/cache 的完整底层重编译；LGPL 对应源码、可重新链接对象和法律 Review 仍开放。

## 1. 目标

为 MusicFree 构建、发布并接入一个面向 iOS 的裁剪版 VLCKit：

- 只保留音频播放、音频解码、音频元数据和当前播放控制所需能力。
- 本地文件播放、扫描、探测、元数据和封面读取默认不触发网络。
- 仅在调用方显式创建一次性网络授权并发起播放时，允许主动连接远端资源。
- 保留 HTTP/HTTPS、SMB2/3、FTP/FTPS/FTPES、NFS 的直链文件播放。
- 移除视频输出、视频滤镜、视频解码、投屏、服务发现、目录浏览、流媒体输出等无关能力。
- 产物可重复构建、可审计、可通过 SwiftPM 固定版本使用，并满足 VLCKit/libVLC 及其 contrib 依赖的许可证义务。

这里的“显式使用网络”定义为：只有用户动作或上层业务明确构造了一个合法、未过期的 `NetworkPlaybackGrant`，VLCKit 适配层才可以创建网络 `VLCMedia`。仅仅保留网络 access 模块，不构成允许后台或隐式联网。

## 2. 已锁定范围

### 2.1 源码基线

| 项目 | 固定值 |
| --- | --- |
| 自建公开仓库 | `https://github.com/enefry/MusicFreeVLCKit` |
| VLCKit commit | `e3774eb25c62c902e9066ba267e6416d82e83382` |
| libVLC commit | `2cd8705589d3b125f236d1af695c3961fdcf6ca4` |
| iOS Device 架构 | `arm64` |
| iOS Simulator 架构 | `arm64`、`x86_64` |
| 分发形式 | 带版本的 XCFramework ZIP + SwiftPM binary target |
| 目录存放 | 和MusicFree 同层级的 MusicFreeVLCKit |

构建仓库必须同时固定 contrib 依赖的源码版本和校验值。VLCKit、libVLC 或 contrib 任一来源不得使用浮动 branch、`latest` 或未校验下载地址。

### 2.2 音频格式

必须维持 MusicFree 当前格式矩阵中的能力，不因裁剪主动丢失以下格式：

- MP3
- AAC、HE-AAC
- ALAC
- FLAC
- Opus
- Vorbis
- WAV、PCM
- AIFF
- APE
- WavPack
- Musepack

“保留”最终以真实样本在目标设备上的导入、探测、首播、Seek 和连续播放结果为准，不能只以扩展名、链接成功或模块名称推断。

### 2.3 网络协议白名单

| 协议 | 保留范围 | 明确不包含 |
| --- | --- | --- |
| HTTP/HTTPS | 单个音频文件直链、Range/Seek、受控重定向、受控 Header 和认证 | HLS、DASH、网络播放列表、网页解析、目录索引 |
| SMB | SMB2/3 单个文件直链、用户名/密码、可选 Domain | SMB1、NetBIOS/服务器发现、共享目录浏览 |
| FTP | FTP、隐式 FTPS、显式 FTPES 单个文件直链；匿名或用户名/密码/可选 Account | 目录浏览、主动模式监听、站点管理 |
| NFS | 单个文件直链 | 服务发现、导出目录浏览、凭据管理 |

SFTP/SSH 不保留。其他未列入白名单的网络输入同样不保留，包括 RTP、RTSP、UDP、SRT、RIST、UPnP、SAP、Bonjour/mDNS、Chromecast 和云服务插件。

FTP 默认只使用客户端发起的 PASV/EPSV 数据连接，不开放 PORT/EPRT 入站监听。HTTPS、FTPS 和 FTPES 不允许关闭证书校验。

### 2.4 直链边界

第一阶段只接受指向具体文件的 URL：

- URL 必须包含合法 scheme、host 和非空文件路径。
- 拒绝根路径、目录路径以及已知播放列表或清单后缀，例如 `.m3u`、`.m3u8`、`.pls`、`.xspf`、`.mpd`。
- HTTP 响应如果明确返回目录、HTML、HLS/DASH 或播放列表内容类型，播放必须失败，不能继续解析其中链接。
- 不提供服务器账户管理、连接收藏、服务器/共享/导出列表、目录枚举、远端媒体库同步。
- 本计划允许协议握手和访问给定文件所必需的最小查询；这不等价于允许浏览服务器。

## 3. 当前基线与判断依据

当前 MusicFree 使用 `VLCKit-SPM 4.0.0-alpha.20260805.1123`。已审计的官方 iOS Device 二进制约为 43 MiB，并包含明显超出 MusicFree 需求的能力：38 个 access 模块、22 个 video output、19 个 video filter，以及视频、发现、投屏和多种流媒体协议相关代码。

上游 Apple 构建流程允许在静态模块表生成前配置 `VLC_MODULE_REMOVAL_LIST`。因此本方案以“收缩 contrib 能力 + 收缩 libVLC configure 能力 + 模块删除列表 + 产物反向审计”四层方式裁剪，而不是只依赖链接器 dead-strip。

MusicFree 当前还有两个重要边界：

- `VLCKit` import 已隔离在 `VLCKitPlaybackAdapter` 内，后续必须保持这个依赖方向。
- 本地 parser 使用 `VLCMediaParsingOptions(rawValue: 1)`，即本地解析且不请求网络元数据。裁剪接入后必须保留该语义，并用命名封装替代散落的 magic value。

现有生产 composition 只注册本地媒体源；当前 HTTP resource 是尚未投入生产的协议中立扩展。接入工作不应顺带增加服务器 UI、远端媒体库或自动同步。

## 4. 总体控制模型

网络控制采用三道门：

1. **二进制门**：仅编译协议白名单中的网络 access 模块，发现、浏览、播放列表和其他协议模块不存在于静态模块表。
2. **类型门**：`PlaybackResource` 的网络分支只能携带类型化、不可持久化的 `NetworkPlaybackGrant`，不再接收一般化 URL + 任意 VLC options。
3. **调用门**：只有明确的用户播放动作或业务播放请求可签发 grant；本地扫描、后台预取、恢复队列、元数据和封面流程没有签发权限。

预期调用链：

```text
显式播放动作
  -> 创建类型化 NetworkPlaybackGrant
  -> 校验协议、直链、认证、Header、重定向和有效期
  -> VLCKitPlaybackAdapter 创建一次 VLCMedia
  -> 对应白名单 access 模块发起连接

本地导入/扫描/探测/元数据/封面
  -> PlaybackResource.localFile
  -> local-only parser
  -> 不存在网络 grant，也不能降级为网络 URL
```

## 5. 网络授权与敏感信息设计

### 5.1 类型化授权

在 `MediaSourceAPI` 定义协议中立的网络授权类型，类型名可在实现时微调，但能力边界固定：

```swift
public enum NetworkPlaybackGrant: Sendable {
    case http(HTTPPlaybackGrant)
    case smb(SMBPlaybackGrant)
    case ftp(FTPPlaybackGrant)
    case nfs(NFSPlaybackGrant)
}
```

每个 grant 至少包含：

- 完整但敏感的目标 URL。
- 签发时间、过期时间和一次播放用途标识。
- 协议专属认证，不使用通用 `[String: String]` 表示凭据。
- 明确的传输安全模式。
- 只供当前播放/重连使用的生命周期约束。

grant 和其中的 secret：

- 不实现 `Codable`、`RawRepresentable` 或可持久化协议。
- `description`、`debugDescription`、Mirror、错误和诊断始终返回脱敏值。
- 不进入队列快照、SwiftData、UserDefaults、日志、埋点、崩溃附件或剪贴板。
- 停止、换曲、失败或释放播放器时立即释放引用；Swift/Objective-C 字符串无法承诺物理内存清零，因此文档和实现不得宣称已安全 zeroize。
- 过期后禁止新建连接和重连；已经建立的连接是否允许完成由协议会话策略明确记录，默认在停止或换曲时关闭。

远端 URL 的 query 可能本身包含签名或 token，因此整个 URL 按敏感信息处理。URL 的 `user` 和 `password` 必须为空，禁止 `scheme://user:password@host/...`。需要恢复远端队列时，只能恢复稳定的非敏感 source/item ID，不能自动恢复网络连接；必须重新获取 grant。

### 5.2 HTTP/HTTPS

HTTP grant 支持：

- 过滤后的自定义 Header。
- Basic 认证。
- Bearer token。
- Cookie。
- User-Agent。
- Referer。

Header 策略：

- 名称和值必须通过 token、长度、CR/LF/NUL 校验。
- `Authorization` 只能由 Basic/Bearer 类型生成，不能走自定义 Header。
- 禁止调用方覆盖 `Host`、`Content-Length`、`Transfer-Encoding`、`Connection`、`Range`、`Proxy-Authorization` 等传输层 Header。
- 自定义 Header 采用显式 allowlist；若上游 VLCKit/libVLC 没有安全 API，则在自建 access 层补充受控接口，不能暴露任意 `addOption` 给业务层。
- Cookie 优先使用 VLCKit 的 cookie store API；不得把 Cookie 或 token 写入可观察日志。

重定向按 origin 控制。origin 定义为 `scheme + host + effective port`：

- 初始 origin 自动包含在许可范围内。
- 跨 origin 只能跳转到 grant 中逐项列出的 origin。
- 不接受通配 host、通配子域或任意端口。
- 禁止 HTTPS 降级到 HTTP，即使目标 origin 被列出；需要清晰 HTTP 时必须重新签发 HTTP grant。
- 每次跳转重新执行直链、scheme 和 Header 传播策略；认证和 Cookie 不跨 origin 泄漏。

显式创建的 `http` grant 允许明文连接，这是已确认的产品范围；实现和 UI/调用方必须能够识别其明文属性，但不能在引擎内部悄悄把 HTTPS 降级成 HTTP。

### 5.3 SMB2/3

SMB grant 仅支持：

- `smb://` 直链。
- 用户名、密码和可选 Domain。
- SMB2/3 dialect。

不编译或启用 SMB1，不执行 NetBIOS、Bonjour、工作组、服务器或共享发现。凭据必须通过受控的 SMB 配置路径传递，业务层不能构造 `:smb-*` 字符串。

### 5.4 FTP/FTPS/FTPES

FTP grant 使用类型化 transport：plain FTP、implicit TLS、explicit TLS，并支持：

- anonymous。
- username/password。
- 可选 account。

显式创建的 plain FTP grant 允许明文连接。数据连接仅保留 PASV/EPSV；证书校验策略不可由业务层关闭。FTPS/FTPES 的 scheme/option 映射必须通过集成测试确认，不能凭名称猜测 libVLC 行为。

### 5.5 NFS

NFS grant 只包含目标直链和会话期限，不包含用户名、密码或通用 Header。NFS 版本及 libnfs 所需的最小 RPC 行为在兼容性测试后锁定；不保留导出列表和目录浏览入口。

## 6. 裁剪策略

### 6.1 必须保留的能力组

以下是能力级 allowlist。具体 VLC module symbol 名称必须由固定 commit 的真实构建产物生成，不能把旧版本模块名直接当作最终清单。

| 能力组 | 保留内容 |
| --- | --- |
| libVLC/VLCKit 核心 | media/player/event、时钟、输入、静态模块注册、Objective-C 封装 |
| 本地输入 | file 及播放器正常读取本地文件所需的最小 stream/cache 层 |
| 网络输入 | HTTP/HTTPS、SMB2/3、FTP/FTPS/FTPES、NFS 及各自必要的 TLS/DNS/IO 依赖 |
| Demux/Parser | MP3、MP4/M4A、AAC、FLAC、Ogg、WAV、AIFF、APE、WavPack、Musepack 所需 demux、packetizer 和 parser |
| 音频解码 | 上述格式的 decoder；FFmpeg 如被使用，采用 decoder/demuxer allowlist |
| 音频处理 | 当前音量、静音、声道转换、重采样、播放速率和运行时 EQ 所需模块 |
| 音频输出 | iOS AudioUnit/上游实际使用的音频输出链 |
| 元数据 | 内嵌标签、章节/时长、内嵌封面 attachment 的读取；不含联网抓图 |
| 字符集 | 现有标签兼容和文件名处理实际需要的最小字符集转换能力 |

FFmpeg 不能只“保留 avcodec 模块”后继续携带所有视频 decoder。构建时应从 `--disable-everything` 或等价最小基线出发，逐项启用所需 audio decoder、parser、demuxer 和必要 protocol；禁用 encoders、muxers、filters、devices、video decoders 和 GPL/nonfree 组件。若某格式使用独立 decoder 比 FFmpeg 更小、更易审计，可在保持格式回归通过的前提下选择独立库。

### 6.2 必须移除的能力组

- 所有 video output、video filter、video splitter、deinterlace、GPU/OpenGL/Metal 视频渲染和画面抓取。
- 所有视频 decoder、video packetizer 及 VideoToolbox 视频路径；仅为音频容器解析所需的通用代码除外。
- 字幕 decoder、渲染、字体和字幕下载。
- 可视化、频谱、goom、projectM 等音频可视化输出。
- capture、camera、screen、DVD、VCD、Blu-ray、DVB 和光盘导航。
- sout、转码、录制、编码、mux、HTTP server、RTSP server。
- HLS、DASH、Smooth Streaming、网络播放列表及自适应流模块。
- RTP、RTSP、UDP、SRT、RIST、SFTP/SSH 及其他非白名单 access。
- UPnP、SAP、Bonjour/mDNS、renderer discovery、Chromecast、局域网服务发现。
- Lua Web/metadata/artwork fetcher、网页解析和在线封面下载。
- Qt、skins、ncurses、telnet、Web interface 等桌面 UI/远程控制接口。
- SMB1、NetBIOS 浏览和目录/服务发现。
- 非播放必需的 encoders、muxers、archive、云服务和 social 插件。

如果某个待移除模块是保留能力的硬依赖，必须在 Review 记录中说明依赖链、体积和安全影响，不能静默放回完整模块组。

### 6.3 模块清单的生成与审计

构建仓库需要维护三份机器可读清单：

- `required-capabilities.yml`：产品能力和格式 allowlist。
- `module-policy.yml`：允许、禁止和待确认的 VLC 模块/FFmpeg 组件。
- `build-manifest.json`：本次构建实际 commit、toolchain、configure flags、contrib、模块、架构和 SHA-256。

每次构建先生成完整 module inventory，再用固定 commit 对应的 `VLC_MODULE_REMOVAL_LIST` 生成静态模块表。CI 必须检查：

- 禁止模块不存在于生成的静态模块表。
- 必需模块全部存在。
- `nm`、`strings`、link map 和静态插件入口没有发现策略外模块。
- `otool -L`、`file`、`lipo -info` 与 XCFramework `Info.plist` 的平台和架构一致。
- 不依赖仅靠 `-dead_strip` 得到的偶然结果。

## 7. 构建仓库与可复现产物

### 7.1 建议目录

```text
MusicFreeVLCKit/
  Package.swift
  README.md
  Config/
    audio-ios.env
    required-capabilities.yml
    module-policy.yml
    sources.lock.json
  Scripts/
    bootstrap.sh
    build-device.sh
    build-simulator.sh
    create-xcframework.sh
    inventory-modules.sh
    verify-artifact.sh
    generate-sbom.sh
    package-release.sh
  Patches/
  Tests/
    Fixtures/
    ProtocolServers/
  Licenses/
  Compliance/
  .github/workflows/
```

### 7.2 构建流程

1. 校验 VLCKit、libVLC 和 contrib 源码 commit/checksum。
2. 记录 Xcode、SDK、clang、CMake/meson/autotools、构建脚本版本和环境变量。
3. 用相同 profile 分别构建 iPhoneOS `arm64`、iPhoneSimulator `arm64` 和 `x86_64`。
4. 将 Simulator 两个架构合并为同一 simulator framework slice，并校验 headers/module map 一致。
5. 使用 `xcodebuild -create-xcframework` 生成 XCFramework，同时关联每个 slice 的 dSYM；若 toolchain 产生 BCSymbolMap，也一并收集。
6. 对 release 产物 strip 非必要符号，但保留独立 dSYM 和 UUID 对应关系。
7. 运行模块、架构、格式、协议、许可证和敏感信息检查。
8. 生成 ZIP，执行 `swift package compute-checksum`，把 checksum 写入同 tag 的 `Package.swift`。
9. 从空 SwiftPM consumer 工程下载 release ZIP，完成 resolve、编译、链接和最小播放 smoke test。

构建脚本必须支持从干净 checkout 一条命令重建，不依赖开发者机器上未声明的 Homebrew 状态或已存在的 contrib cache。允许缓存下载，但 cache 命中前必须校验内容。

### 7.3 SwiftPM 发布契约

公开仓库对使用方暴露稳定的产品和模块名 `VLCKit`，尽量保持当前 `import VLCKit` 和 Objective-C headers 兼容。建议 release tag 使用独立的 custom prerelease 序列，例如 `4.0.0-musicfree.1`；最终命名在 Review 后锁定。

每个 GitHub Release 至少发布：

- `VLCKit.xcframework.zip`
- `VLCKit.dSYMs.zip`
- `MusicFreeVLCKit-sources.tar.gz`
- `build-manifest.json`
- `module-inventory.json`
- `sbom.spdx.json`
- `checksums.txt`
- LGPL 文本、第三方 notices、构建和重新链接说明

SwiftPM 必须使用固定版本和固定 checksum，不使用 branch dependency。tag 发布后不可替换同名 ZIP；任何二进制变化都发布新 tag 和新 checksum。

### 7.4 许可证与供应链

- 生成完整 SBOM，列出 VLCKit、libVLC、每个 contrib、版本/commit、来源、许可证和是否链接进最终二进制。
- 禁止未批准的 GPL/nonfree 组件进入音频 profile；发现后停止发布，而不是只补 notice。
- 保留 VLCKit/libVLC LGPL-2.1-or-later 文本、copyright、修改说明、补丁、完整对应源码和构建脚本。
- 验证 XCFramework 是静态还是动态链接。若为静态链接，MusicFree 发布流程必须提供 LGPL 要求的可重新链接材料或采用经法律 Review 接受的等价机制；只有源码 ZIP 不自动满足全部义务。
- 为每个 App 版本保留其实际使用的二进制、源码、构建 manifest、dSYM、checksum 和合规材料。
- 许可证结论需要项目法律/发布 Review；本文不是法律意见。

## 8. MusicFree 接入计划

### 8.1 依赖替换

- 将 `Packages/MusicFreeVLCKit/Package.swift` 的官方 `VLCKit-SPM` 精确依赖替换为 `enefry/MusicFreeVLCKit` 的精确 release。
- 更新 `Package.resolved`、设置页依赖信息、许可证文件、revision/checksum 和现有能力文档。
- 保持只有 `VLCKitPlaybackAdapter` 可以 import `VLCKit`；Core、Infrastructure、UI 和 App 不得直接依赖自定义二进制。
- CI 禁止通过条件依赖或 fallback 再链接官方完整 VLCKit。开发期 fallback 如确有需要，必须是显式 build flag 且不能进入 release configuration。

### 8.2 API 收口

现有 `RemotePlaybackRequest(url:headers:expiresAt:)` 需要迁移为类型化 grant 构造：

- `PlaybackResource.localFile` 保持本地路径。
- 网络路径改为 `PlaybackResource.network(NetworkPlaybackGrant)` 或等价强类型接口。
- 删除协议中立的任意 Header initializer；HTTP Header、SMB/FTP 凭据只能从各自类型进入。
- `VLCKitMediaOption` 继续是封闭 enum，不增加 `raw(String)`。
- `VLCMediaFactory` 对每种 grant 做 scheme、userinfo、直链、有效期和敏感字段校验，再映射到固定 VLCKit/libVLC API。
- 任何上游缺失能力，例如 Bearer 或安全的自定义 Header，优先在自建 VLCKit access 边界补充明确 API；不能为了兼容暴露任意 VLC option string。

### 8.3 本地流程离线保证

- `VLCMediaProbe`、`VLCMetadataReader`、Documents scanner 和本地 artwork provider 只接收 `file://` resource。
- parser 保持 local-only 选项，禁止 network/fetch metadata flag。
- 移除网络 artwork fetcher 后，只读取音频文件内嵌封面或已存在的本地缓存。
- App 启动、队列恢复、数据库迁移、搜索、列表滚动、Now Playing 恢复都不能签发 grant。
- 远端播放会话内如需读取同一媒体的 metadata/attachment，必须复用同一 grant 且受其有效期约束；不能扩展为独立封面 URL 请求。

### 8.4 iOS 配置

- 只有在远端播放入口实际接入时才增加本地网络权限说明；不声明 Bonjour service。
- 为显式 HTTP/FTP 明文播放采用范围最小且经实机验证的 iOS 配置，不能用无关的全局网络放行掩盖配置问题。
- 保持 Background Audio 语义；grant 只允许当前播放连接和必要重连，不允许后台扫描。
- 重新检查隐私清单、App Store 说明和设置页第三方许可证展示。

## 9. 验证计划

### 9.1 构建与二进制

- 三个目标架构均存在且没有额外平台/slice。
- framework headers、module map、install name 和 SwiftPM consumer 链接正常。
- 每个 Mach-O UUID 都能在发布的 dSYM 中找到。
- 静态模块表中不存在所有禁止能力组。
- 对比当前约 43 MiB 的同口径 iOS Device 基线，记录 framework、Mach-O、XCFramework 和 ZIP 的大小变化。
- 至少执行两次干净构建并对比 SHA-256；若 toolchain 导致非确定字段，必须定位并记录归一化差异，不能只宣称“可重复”。

### 9.2 本地格式回归

每种已锁定格式至少准备一个合法 fixture，并增加：

- 变码率/长时长样本。
- Unicode、中文和遗留编码标签。
- 内嵌封面和无封面样本。
- 损坏、截断和伪扩展名样本。
- 含音频轨的复合容器负/正向边界样本。

记录 import、probe、metadata、artwork、首播、Seek、rate、EQ、暂停恢复、结束回调和 teardown。Simulator 结果与真机听感/路由结果分别报告。

### 9.3 协议集成

在受控测试服务器上逐项验证：

- HTTP 200/206、Range Seek、chunked、连接中断重连、Basic、Bearer、Cookie、User-Agent、Referer 和允许的自定义 Header。
- 同 origin、允许的跨 origin、未授权 origin、重定向循环以及 HTTPS 降级拒绝。
- HTTPS 有效证书、过期证书、主机名不匹配和自签证书拒绝。
- SMB2/3 匿名/凭据/Domain、随机读取、错误密码、SMB1 拒绝。
- FTP anonymous、用户名密码、account、REST Seek；FTPS/FTPES TLS 和证书失败；确认只用 PASV/EPSV。
- NFS 直链、随机读取、无权限、文件不存在和服务器中断。
- SFTP、RTSP、UDP、HLS、DASH、播放列表和目录 URL 在创建 `VLCMedia` 前或模块选择阶段稳定失败。

### 9.4 “未显式使用则不联网”验证

- 冷启动、迁移、恢复队列、扫描 Documents、导入本地音乐、读取本地元数据/封面和本地连续播放全流程抓取网络连接证据，预期为零。
- 在无网络/拒绝出站环境重复本地测试，行为和结果不得变化。
- 检查没有 service discovery、renderer discovery、metadata fetcher、update checker 或自动 artwork 网络模块被注册/调用。
- 未携带 grant 的 `http://`、`https://`、`smb://`、`ftp://`、`nfs://` 输入必须在适配层失败。
- grant 过期、stop、换曲和 deinit 后不能建立新连接。

### 9.5 敏感信息与异常路径

- 对 URL、query、Basic/Bearer、Cookie、SMB/FTP 凭据注入唯一 canary，扫描 stdout/stderr、OSLog、诊断导出、错误、Mirror、崩溃日志和持久化目录，预期无泄漏。
- 验证 Header CRLF、NUL、超长值、userinfo、非法 scheme、通配 redirect origin 全部被拒绝。
- 认证信息不跨 redirect origin；停止和换曲后旧授权不能复用。
- 低内存、后台/前台、网络切换、音频中断、路由变化、服务器断线和快速换曲不产生 use-after-free 或串流串台。

### 9.6 MusicFree 回归与真机门槛

- 运行 Architecture checks 和 MusicFree Core、Infrastructure、VLCKit、UI、App、UI Test 现有测试。
- Generic iOS build、Simulator build、Archive 均通过。
- 至少一台真实 iPhone 验证所有本地格式和四类网络协议组。
- 验证锁屏、后台、耳机/蓝牙路由、中断恢复、Seek、EQ 和至少两小时连续播放。
- 测量启动时间、首次播放时间、内存、CPU、功耗和二进制体积，与当前官方二进制同条件对比。

## 10. 分阶段实施

### Phase 0：基线固化

- 保存当前官方 XCFramework 的尺寸、module inventory、依赖、格式和网络协议结果。
- 固定 fixture checksum、设备/iOS 版本和测试服务器配置。
- 输出第一版 capability-to-module 映射。

完成条件：所有裁剪结论都有可重复的官方基线可对比。

### Phase 1：公开构建仓库和源码锁定

- 创建 `enefry/MusicFreeVLCKit`。
- 固定 VLCKit/libVLC commit、contrib lock、toolchain 和构建 profile。
- 建立一键构建、manifest、SBOM 和许可证目录。

完成条件：未裁剪的固定源码基线可以从干净环境完成三架构构建。

### Phase 2：依赖和模块裁剪

- 先收缩 contrib/FFmpeg，再收缩 libVLC configure，最后维护 `VLC_MODULE_REMOVAL_LIST`。
- 每删除一组模块就运行格式和本地播放 smoke test。
- 产出实际 allow/deny module policy 和差异报告。

完成条件：禁止模块从静态模块表消失，格式矩阵仍通过，且没有依赖完整视频栈的隐性回退。

### Phase 3：网络白名单和授权边界

- 保留并验证 HTTP/HTTPS、SMB2/3、FTP/FTPS/FTPES、NFS。
- 补齐受控 Header、认证和 redirect 接口。
- 完成 no-network、secret redaction 和非白名单协议负向测试。

完成条件：只有合法 grant 可以联网，直链协议矩阵通过，其他网络入口稳定失败。

### Phase 4：XCFramework、SwiftPM 和合规发布

- 生成 Device/Simulator XCFramework、dSYM、checksum、SBOM、源码和构建材料。
- 发布不可变 GitHub prerelease。
- 用空 consumer 和 MusicFree package graph 验证远程解析与链接。

完成条件：从公开 release 可复现下载、校验、编译和符号化。

### Phase 5：MusicFree 接入

- 替换依赖和许可证记录。
- 将 remote request 迁移为 grant API。
- 保持本地流程离线并更新 capability/format/manual test 文档。
- 完成全量自动化和真机验证。

完成条件：达到第 11 节全部发布门槛后，才移除官方二进制回退并进入 release。

## 11. 发布验收门槛

以下条件全部满足才算完成，不以“能编译”代替：

1. VLCKit、libVLC、contrib、toolchain 和构建参数全部可追溯、无浮动依赖。
2. XCFramework 只包含 iOS Device arm64 和 Simulator arm64/x86_64。
3. 11 类音频格式通过固定 fixture 的自动化和真机回归。
4. HTTP/HTTPS、SMB2/3、FTP/FTPS/FTPES、NFS 直链通过协议矩阵。
5. 视频、发现、浏览、SFTP、HLS/DASH、非白名单协议和流输出模块不在静态模块表。
6. 无 grant 的本地完整流程有“零网络连接”证据。
7. grant、URL 和凭据没有日志、持久化、错误或 redirect 泄漏。
8. SwiftPM release checksum 固定，干净 consumer 可下载、编译和链接。
9. dSYM、SBOM、对应源码、构建/重新链接材料和第三方 notices 完整。
10. MusicFree 架构检查、测试、Archive 和真机长时播放通过。
11. 实际二进制尺寸相对约 43 MiB 基线有明确、可解释的下降，并通过 Review 约定的体积目标。

## 12. 风险与处理原则

| 风险 | 处理原则 |
| --- | --- |
| VLC module 名称或依赖随 commit 变化 | 从固定产物生成 inventory；能力清单稳定，module 名清单按 commit 锁定 |
| FFmpeg 模块仍带入视频 decoder | FFmpeg 使用 allowlist，并从 binary symbol/module 双向审计 |
| SMB/NFS/TLS contrib 拉高体积 | 先保证白名单功能和许可证，再以实际 size report 决定进一步替换，不能静默删协议 |
| Bearer/自定义 Header 缺少安全上游 API | 在自建 access 边界增加窄接口；不开放任意 VLC option |
| 裁剪后某格式只在 Simulator 可用 | 保持未验证状态，阻止发布，直到真机 fixture 通过 |
| LGPL 静态链接材料不完整 | 发布前完成法律和重新链接材料 Review；不以 App Store 可上传作为合规证明 |
| 自建版本落后上游安全修复 | 建立上游 commit 监控；每次升级重新跑完整模块、协议、格式和合规矩阵 |
| 自定义构建失败时回退官方完整版本 | 禁止 release 静默回退；只能通过显式评审的新版本切换依赖 |

## 13. 待 Review 决策

以下内容尚未由当前需求锁定，实施前需要确认：

1. 自定义 SwiftPM tag 规则，建议从 `4.0.0-musicfree.1` 开始。
2. XCFramework 的最低 iOS deployment target；建议以 MusicFree 实际支持范围和固定 Xcode 能构建的最低值共同决定，而不是沿用未核实的上游默认值。
3. 体积门槛。建议第一阶段以同口径 iOS Device Mach-O 至少缩小 50% 作为目标，以禁止模块不存在作为硬门槛；最终数字由 Phase 0 基线确认。
4. HTTP 代理是否进入第一阶段；当前计划不包含代理自动发现、PAC/WPAD 或代理凭据。
5. NFS 需要覆盖的版本和服务器实现矩阵。
6. MusicFree 中由哪个明确用户入口签发网络 grant；当前计划不新增服务器管理或浏览 UI。
7. LGPL 静态链接的最终发布材料和保存周期，由法律/发布 Review 确认。

Review 通过前，不开始源码 fork、依赖替换或 MusicFree 接口改造。
