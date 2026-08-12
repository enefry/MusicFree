import SwiftUI

@main
struct MusicFreeApp: App {
    private let container: AppContainer

    init() {
#if DEBUG
        AppBVTFixtureSeeder.seedIfRequested()
#endif
        print("Temp: \(NSTemporaryDirectory())")
        container = AppContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootScene(container: container)
        }
    }
}
