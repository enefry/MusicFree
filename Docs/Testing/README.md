# MusicFree 测试与验证文档

| 文档 | 用途 |
| --- | --- |
| [`MANUAL_TEST_CASES.md`](MANUAL_TEST_CASES.md) | 真实 App 的人工功能、可访问性、稳定性和发布验收 |
| [`VLCKIT_CAPABILITY_MATRIX.md`](VLCKIT_CAPABILITY_MATRIX.md) | 固定 VLCKit 版本的能力声明边界 |
| [`VLCKIT_FORMAT_MATRIX.md`](VLCKIT_FORMAT_MATRIX.md) | 音频格式验证 backlog 和发布声明边界 |

测试文档必须同时记录构建来源、commit、设备/系统、VLCKit 版本和结果证据。不能用旧 `.xcresult`、只编译成功或 Simulator 结果替代真实设备门槛。
