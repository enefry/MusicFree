# iOS 项目编译缓存规范要求

## 1. 核心编译规则
- **固定缓存目录**：在执行任何 `xcodebuild`、打包、测试或依赖安装命令时，**必须**使用 `-derivedDataPath` 参数将缓存强制指定到项目根目录下的 `./.noindex/DerivedData`。
- **原因**：避免 Xcode 默认将缓存写入全局 `~/Library/Developer/Xcode/DerivedData`,避免使用 Temp 目录, 导致多项目混杂及磁盘空间暴涨。使用 `.noindex` 命名可防止 macOS Spotlight 建立索引，降低 CPU 消耗。

## 2. 行为限制与命令生成示例
当用户要求编译项目或生成自动化脚本时，你**必须且只能**采用如下结构：
```bash
# 严禁直接运行不带路径的 xcodebuild
xcodebuild -workspace YourApp.xcworkspace -scheme YourScheme -derivedDataPath ./.noindex/DerivedData build
```

## 3. 自动化清理机制
- 在长时间高 I/O 构建或任务结束时，自动清理中间产物。

## 4. UI 风格

- 采用iOS原生，所有功能如果原生有支持，都是用原生样式，除了设置节目都采用UIKit完成
- 优先采用系统 CollectionView, ContextMenu, UIMenu, UIBarButtonItem 等

