import AppleSystemAdapter
import LibraryPersistenceAdapter
import LocalMediaAdapter
import MusicTestSupport
import PreferencesPersistenceAdapter
import Testing

@Test("Infrastructure module graph compiles")
func infrastructureModuleGraphCompiles() {
    _ = LocalMediaAdapterModule.self
    _ = LibraryPersistenceAdapterModule.self
    _ = AppleSystemAdapterModule.self
    _ = PreferencesPersistenceAdapterModule.self
    _ = MusicTestSupportModule.self
}

