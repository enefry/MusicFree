import MusicTestSupport
import Testing
import VLCKitPlaybackAdapter

@Test("VLCKit adapter shell compiles without linking the binary")
func vlcKitAdapterShellCompiles() {
    _ = VLCKitPlaybackAdapterModule.self
    _ = MusicTestSupportModule.self
}

