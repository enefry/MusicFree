# MusicFree 测试与验证文档

| 文档 | 用途 |
| --- | --- |
| [`MANUAL_TEST_CASES.md`](MANUAL_TEST_CASES.md) | 真实 App 的人工功能、可访问性、稳定性和发布验收 |
| [`VLCKIT_CAPABILITY_MATRIX.md`](VLCKIT_CAPABILITY_MATRIX.md) | 固定 VLCKit 版本的能力声明边界 |
| [`VLCKIT_FORMAT_MATRIX.md`](VLCKIT_FORMAT_MATRIX.md) | 音频格式验证 backlog 和发布声明边界 |

测试文档必须同时记录构建来源、commit、设备/系统、VLCKit 版本和结果证据。不能用旧 `.xcresult`、只编译成功或 Simulator 结果替代真实设备门槛。

推荐的当前 checkout 验证顺序：

1. `xcodegen generate --spec project.yml`，确认工程由 `project.yml` 生成。
2. 运行 `Scripts/check_architecture.sh`，并检查输出是否命中 `App/`、`Packages/`；仓库含 `thirdpart/` 时，vendor 内的导入可能造成扫描误报。
3. 使用真实可用的 Simulator UDID 分开运行 Core、Infrastructure、VLCKit Adapter、UI 和 App target 测试，保存对应 `.xcresult`。
4. 运行 App UI/BVT 后，再安排真机媒体、路由、后台/锁屏、长时间播放和 MusicKit 门禁。

当前静态测试声明约 518 个；这只是源码盘点数字，不代表最近一次运行结果。自动化结果必须以具体 `.xcresult`、设备和 commit 为准。
