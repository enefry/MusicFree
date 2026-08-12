import AppServices
import MusicTestSupport
import Testing

@Test("Core module graph compiles")
func coreModuleGraphCompiles() {
    _ = AppServicesModule.self
    _ = MusicTestSupportModule.self
}

