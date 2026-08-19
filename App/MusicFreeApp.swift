import SwiftUI

@main
struct MusicFreeApp: App {
    private let container: AppContainer

    init() {
        #if DEBUG
            AppBVTFixtureSeeder.seedIfRequested()
        #endif
        print("Temp: \(NSTemporaryDirectory())")
        if let document = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            let keepFile = "\(document)/put_music_file_here_to_auto_import.txt"
            if !FileManager.default.fileExists(atPath: keepFile) {
                FileManager.default.createFile(atPath: keepFile, contents: nil)
            }
        }
        container = AppContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootScene(container: container)
        }
    }
}
