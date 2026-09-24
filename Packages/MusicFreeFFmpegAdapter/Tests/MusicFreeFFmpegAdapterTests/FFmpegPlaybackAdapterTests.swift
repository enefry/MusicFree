import Testing
@testable import FFmpegPlaybackAdapter

/// 占位测试，确保测试目标可编译。真正的解码/播放集成测试留待后续版本
/// （需要真机或带音频样本的 iOS 模拟器环境）。
@Suite struct FFmpegPlaybackAdapterTests {
    @MainActor
    @Test func packageLinks() {
        // 能实例化引擎即说明库与 ffmpeg 动态库链接成功。
        _ = FFmpegPlaybackEngine()
    }
}
