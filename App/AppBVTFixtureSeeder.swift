#if DEBUG
import Foundation
import DesignSystem
import MediaSourceAPI
import MusicDomain
import PreferencesPersistenceAdapter
import SettingsAPI

/// Creates one deterministic local-audio input only for the explicit BVT launch.
/// The normal Debug and Release startup paths never write this fixture.
enum AppBVTFixtureSeeder {
    static let launchArgument = "--bvt-seed-audio"
    /// Adds the two imported remote-source-shaped tracks used by the UIKit
    /// Songs visual baseline without changing the default BVT fixture set.
    static let uikitSongsLaunchArgument = "--bvt-seed-uikit-songs"
    static let layoutLaunchArgument = "--bvt-seed-layout-library"
    static let artistAlbumsLaunchArgument = "--bvt-seed-artist-albums"
    static let noAlbumLaunchArgument = "--bvt-seed-no-album"
    static let onlineSourcesLaunchArgument = "--bvt-seed-online-sources"
    static let resetOnlineSourcesLaunchArgument = "--bvt-reset-online-sources"
    static let resetPlaybackHistoryLaunchArgument = "--bvt-reset-playback-history"
    static let resetUserInterfacePreferencesLaunchArgument =
        "--bvt-reset-user-interface-preferences"
    static let trackTitle = "BVT Tone"
    static let longTrackTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
    static let dsAudioSourceID = MediaSourceID("bvt.dsaudio")
    static let googleDriveSourceID = MediaSourceID("bvt.google-drive")

    private static let onlineSourceSeedMarkerKey = "com.musicfree.bvt.online-sources-seeded"
    private static let onlineSourceFixtureFolderID = "bvt-folder"
    private static let onlineSourceFixtureSubfolderID = "bvt-subfolder"
    private static let onlineSourceFixtureAlbumID = "bvt-album"
    private static let onlineSourceFixtureArtistID = "bvt-artist"
    private static let onlineSourceFixtureAudioID = "bvt-audio"
    private static let onlineSourceFixtureNextPageToken = "bvt-next-page"
    // Keep the first page larger than two screens so the catalog's automatic
    // prefetch path is exercised only after the user has meaningfully scrolled.
    private static let onlineSourceFixtureFirstPageCount = 80

    private struct Fixture {
        let title: String
        let artist: String
        let album: String
        let genre: String
        let year: String
        let folder: String
    }

    private static let layoutFixtures = (1...8).map { index in
        Fixture(
            title: String(format: "Layout Song %02d", index),
            artist: String(format: "Layout Artist %02d", index),
            album: String(format: "Layout Album %02d", index),
            genre: String(format: "Layout Genre %02d", index),
            year: "2026",
            folder: String(format: "Layout Folder %02d", index)
        )
    }

    static func seedIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) {
        if arguments.contains(resetUserInterfacePreferencesLaunchArgument) {
            UserDefaults.standard.set(
                MusicFreeLanguage.english.rawValue,
                forKey: MusicFreeLocalization.languageStorageKey
            )
            UserDefaults.standard.set(
                MusicFreeAppearance.dark.rawValue,
                forKey: AppUserInterfacePreferences.appearanceStorageKey
            )
            UserDefaults.standard.set(
                MusicFreeAccentColorStore.defaultHex,
                forKey: MusicFreeAccentColorStore.storageKey
            )
        }

        let shouldSeedAudio = arguments.contains(launchArgument)
        let shouldSeedUIKitSongs = arguments.contains(uikitSongsLaunchArgument)
        let shouldSeedLayout = arguments.contains(layoutLaunchArgument)
        let shouldSeedArtistAlbums = arguments.contains(artistAlbumsLaunchArgument)
        let shouldSeedNoAlbum = arguments.contains(noAlbumLaunchArgument)
        let shouldSeedOnlineSources = arguments.contains(onlineSourcesLaunchArgument)
        guard shouldSeedAudio || shouldSeedUIKitSongs || shouldSeedLayout || shouldSeedArtistAlbums
            || shouldSeedNoAlbum || shouldSeedOnlineSources
        else {
            return
        }

        if shouldSeedOnlineSources {
            seedOnlineSources(
                reset: arguments.contains(resetOnlineSourcesLaunchArgument)
            )
        }

        guard (shouldSeedAudio || shouldSeedUIKitSongs || shouldSeedLayout || shouldSeedArtistAlbums
            || shouldSeedNoAlbum),
              let documentsURL = try? fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
              )
        else {
            return
        }

        let fixtureDirectory = documentsURL.appendingPathComponent("Imported", isDirectory: true)
        try? fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let audioFixtureDirectory = shouldSeedUIKitSongs
            ? fixtureDirectory.appendingPathComponent("UIKitSongs/WithArtwork", isDirectory: true)
            : fixtureDirectory
        if shouldSeedAudio {
            try? fileManager.createDirectory(
                at: audioFixtureDirectory,
                withIntermediateDirectories: true
            )
            for title in [trackTitle, longTrackTitle] {
                let fixtureURL = audioFixtureDirectory.appendingPathComponent("\(title).wav")
                try? makeWaveData(title: title).write(to: fixtureURL, options: .atomic)

                let lyricsURL = audioFixtureDirectory.appendingPathComponent("\(title).lrc")
                try? makeLyricsData(title: title).write(to: lyricsURL, options: .atomic)
            }
        }

        if shouldSeedUIKitSongs {
            let visualFixtures = [
                (title: "BVT DS Audio Tone", artist: "BVT Online Artist", album: "BVT Online Album"),
                (title: "BVT Google Drive Tone", artist: "BVT Online Artist", album: "BVT Online Album"),
            ]
            let visualFixtureDirectory = fixtureDirectory.appendingPathComponent(
                "UIKitSongs/NoArtwork",
                isDirectory: true
            )
            try? fileManager.createDirectory(
                at: visualFixtureDirectory,
                withIntermediateDirectories: true
            )
            for fixture in visualFixtures {
                let fixtureURL = visualFixtureDirectory.appendingPathComponent(
                    "\(fixture.title).wav"
                )
                try? makeWaveData(
                    title: fixture.title,
                    artist: fixture.artist,
                    album: fixture.album
                ).write(to: fixtureURL, options: .atomic)
            }
        }

        if shouldSeedAudio {
            let coverURL = audioFixtureDirectory.appendingPathComponent("cover.png")
            let coverData = makeCoverData()
            if (try? Data(contentsOf: coverURL)) != coverData {
                try? coverData.write(to: coverURL, options: .atomic)
            }
        }

        let layoutDirectory = fixtureDirectory.appendingPathComponent("LayoutFixtures", isDirectory: true)
        if shouldSeedLayout {
            for fixture in layoutFixtures {
                let folderURL = layoutDirectory.appendingPathComponent(fixture.folder, isDirectory: true)
                try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                let fixtureURL = folderURL.appendingPathComponent("\(fixture.title).wav")
                if !fileManager.fileExists(atPath: fixtureURL.path) {
                    try? makeWaveData(
                        title: fixture.title,
                        artist: fixture.artist,
                        album: fixture.album,
                        genre: fixture.genre,
                        year: fixture.year
                    ).write(to: fixtureURL, options: .atomic)
                }
            }
        } else {
            try? fileManager.removeItem(at: layoutDirectory)
        }

        let artistAlbumsDirectory = fixtureDirectory.appendingPathComponent(
            "ArtistAlbumFixtures",
            isDirectory: true
        )
        if shouldSeedArtistAlbums {
            try? fileManager.createDirectory(
                at: artistAlbumsDirectory,
                withIntermediateDirectories: true
            )
            let fixtures = [
                (title: "BVT First Album Tone", album: "BVT First Album", year: "2024"),
                (title: "BVT Second Album Tone", album: "BVT Second Album", year: "2025"),
            ]
            for fixture in fixtures {
                let fixtureURL = artistAlbumsDirectory.appendingPathComponent(
                    "\(fixture.title).wav"
                )
                try? makeWaveData(
                    title: fixture.title,
                    artist: "BVT Multi Album Artist",
                    album: fixture.album,
                    genre: "BVT Artist Genre",
                    year: fixture.year
                ).write(to: fixtureURL, options: .atomic)
            }
        } else {
            try? fileManager.removeItem(at: artistAlbumsDirectory)
        }

        let noAlbumDirectory = fixtureDirectory.appendingPathComponent(
            "NoAlbumFixtures",
            isDirectory: true
        )
        if shouldSeedNoAlbum {
            try? fileManager.createDirectory(
                at: noAlbumDirectory,
                withIntermediateDirectories: true
            )
            let fixtureURL = noAlbumDirectory.appendingPathComponent("BVT No Album Tone.wav")
            // Keep this fixture free of an IPRD chunk. An empty IPRD is not
            // equivalent across all WAV metadata readers and can be surfaced
            // as a synthetic album during a later import.
            try? makeWaveData(
                title: "BVT No Album Tone",
                artist: "BVT No Album Artist",
                album: nil
            ).write(to: fixtureURL, options: .atomic)
        } else {
            try? fileManager.removeItem(at: noAlbumDirectory)
        }
    }

    static func shouldUseOnlineSourceFixtures(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains(onlineSourcesLaunchArgument)
    }

    static func makeOnlineSourceFactory() -> any OnlineSourceFactory {
        BVTOnlineSourceFactory()
    }

    private static func seedOnlineSources(reset: Bool) {
        guard let defaults = UserDefaults(suiteName: PreferencesConfiguration.defaultSuiteName) else {
            return
        }

        if reset {
            defaults.removeObject(forKey: onlineSourceSeedMarkerKey)
            defaults.removeObject(forKey: PreferencesConfiguration.defaultKey)
            try? UserDefaultsOnlineDownloadQueueStore(
                suiteName: PreferencesConfiguration.defaultSuiteName
            ).clear()
        }
        guard defaults.object(forKey: onlineSourceSeedMarkerKey) == nil else {
            return
        }

        do {
            let settings = AppSettings(
                importPreferences: ImportPreferences(
                    privacyPreferences: .defaults,
                    onlineSourcePreferences: OnlineSourcePreferences(
                        isEnabled: false,
                        sources: [
                            try makeOnlineSourceConfiguration(
                                sourceID: dsAudioSourceID,
                                providerKind: .dsAudio,
                                displayName: "BVT DS Audio"
                            ),
                            try makeOnlineSourceConfiguration(
                                sourceID: googleDriveSourceID,
                                providerKind: .googleDrive,
                                displayName: "BVT Google Drive"
                            ),
                        ]
                    )
                )
            )
            defaults.set(try JSONEncoder().encode(settings), forKey: PreferencesConfiguration.defaultKey)
            defaults.set(true, forKey: onlineSourceSeedMarkerKey)
        } catch {
            // The fixture is best-effort. A normal app launch must remain usable
            // even if the simulator's test preferences store is unavailable.
        }
    }

    private static func makeOnlineSourceConfiguration(
        sourceID: MediaSourceID,
        providerKind: OnlineProviderKind,
        displayName: String
    ) throws -> OnlineSourceConfiguration {
        try OnlineSourceConfiguration(
            sourceID: sourceID,
            providerKind: providerKind,
            displayName: displayName,
            endpoint: providerKind == .dsAudio
                ? URL(string: "https://bvt.example.test/dsaudio")
                : nil,
            isEnabled: false
        )
    }

    private struct BVTOnlineSourceFactory: OnlineSourceFactory {
        func makeSource(
            for configuration: OnlineSourceConfiguration
        ) throws -> (any OnlineSource)? {
            switch configuration.providerKind {
            case .dsAudio, .googleDrive:
                return BVTOnlineSource(
                    sourceID: configuration.sourceID,
                    providerKind: configuration.providerKind,
                    displayName: configuration.displayName
                )
            case .baiduPan, .gateway:
                return nil
            }
        }
    }

    private struct BVTOnlineSource: PlaybackSource, SearchableDownloadSource {
        let descriptor: MediaSourceDescriptor
        let capabilities: MediaSourceCapabilities = []
        let providerKind: OnlineProviderKind
        let onlineCapabilities: OnlineSourceCapabilities
        let privacyPolicyVersion = "1.2.0"

        init(
            sourceID: MediaSourceID,
            providerKind: OnlineProviderKind,
            displayName: String
        ) {
            descriptor = MediaSourceDescriptor(
                sourceID: sourceID,
                kind: .remote,
                displayName: displayName,
                isReadOnly: true
            )
            self.providerKind = providerKind
            onlineCapabilities = providerKind == .dsAudio
                ? [.browsing, .downloading, .searching, .onlinePlayback, .httpTranscoding]
                : [.browsing, .downloading, .searching]
        }

        func resolve(_: MediaItemID) async throws -> PlaybackResource {
            .local(URL(fileURLWithPath: "/dev/null"))
        }

        func artwork(for _: ArtworkID) async throws -> ArtworkResource? {
            nil
        }

        func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage {
            if let parentID = request.parentID {
                guard parentID.sourceID == descriptor.sourceID else {
                    return SourceCatalogPage(items: [])
                }
                if let folderIndex = folderItems.firstIndex(where: {
                    $0.id.externalID == parentID.externalID
                }) {
                    return SourceCatalogPage(items: [subfolderItem(
                        parentID: parentID,
                        index: folderIndex + 1
                    )])
                }
                if subfolderItems.contains(where: {
                    $0.id.externalID == parentID.externalID
                }) {
                    return SourceCatalogPage(items: [audioItem(parentID: parentID)])
                }
                if let album = albumItems.first(where: {
                    $0.id.externalID == parentID.externalID
                }) {
                    guard providerKind == .dsAudio else {
                        return SourceCatalogPage(items: [])
                    }
                    return SourceCatalogPage(items: [audioItem(
                        parentID: parentID,
                        index: 1,
                        title: "\(album.displayName) Tone",
                        artist: album.artist ?? "BVT Album Artist",
                        album: album.displayName
                    )])
                }
                if let artist = artistItems.first(where: {
                    $0.id.externalID == parentID.externalID
                }) {
                    guard providerKind == .dsAudio else {
                        return SourceCatalogPage(items: [])
                    }
                    return SourceCatalogPage(items: [audioItem(
                        parentID: parentID,
                        index: 1,
                        title: "\(artist.displayName) Tone",
                        artist: artist.artist ?? artist.displayName,
                        album: "BVT Online Album"
                    )])
                }
                return SourceCatalogPage(items: [])
            }
            guard providerKind == .dsAudio else {
                return SourceCatalogPage(items: [folderItem])
            }
            switch request.mode {
            case .folders:
                return page(items: folderItems, request: request)
            case .albums:
                return page(items: albumItems, request: request)
            case .artists:
                return page(items: artistItems, request: request)
            case .allMusic:
                return page(items: allMusicItems, request: request)
            }
        }

        private func page(
            items: [SourceCatalogItem],
            request: SourceBrowseRequest
        ) -> SourceCatalogPage {
            let sortedItems = sortItems(items, using: request.sort)
            let pageSize = min(
                request.pageSize,
                AppBVTFixtureSeeder.onlineSourceFixtureFirstPageCount
            )
            let startIndex: Int
            if request.pageToken == nil {
                startIndex = 0
            } else if request.pageToken?.rawValue == onlineSourceFixtureNextPageToken {
                startIndex = min(pageSize, sortedItems.count)
            } else {
                return SourceCatalogPage(items: [])
            }

            let endIndex = min(
                startIndex + (request.pageToken == nil ? pageSize : sortedItems.count),
                sortedItems.count
            )
            let pageItems = Array(sortedItems[startIndex..<endIndex])
            return SourceCatalogPage(
                items: pageItems,
                nextPageToken: endIndex < sortedItems.count
                    ? MediaSourceCursor(onlineSourceFixtureNextPageToken)
                    : nil
            )
        }

        func search(_ request: SourceSearchRequest) async throws -> SourceCatalogPage {
            let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return try await browse(
                    SourceBrowseRequest(
                        parentID: request.parentID,
                        mode: request.mode,
                        sort: request.sort,
                        pageSize: request.pageSize,
                        pageToken: request.pageToken
                    )
                )
            }
            let candidates: [SourceCatalogItem]
            switch (request.mode, request.parentID?.externalID) {
            case (.albums, nil):
                candidates = albumItems
            case (.artists, nil):
                candidates = artistItems
            case (.allMusic, nil):
                candidates = allMusicItems
            case (.folders, nil):
                candidates = folderItems
            default:
                if let parentID = request.parentID,
                   let subfolder = subfolderItems.first(where: {
                       $0.id.externalID == parentID.externalID
                   }) {
                    candidates = [audioItem(parentID: subfolder.id)]
                } else if let parentID = request.parentID,
                          let item = allCatalogItems.first(where: {
                              $0.id.externalID == parentID.externalID
                          }) {
                    switch item.kind {
                    case .folder:
                        candidates = subfolderItems.filter {
                            $0.parentID?.externalID == item.id.externalID
                        }
                    case .album:
                        candidates = [audioItem(
                            parentID: item.id,
                            index: 1,
                            title: "\(item.displayName) Tone",
                            artist: item.artist ?? "BVT Album Artist",
                            album: item.displayName
                        )]
                    case .artist:
                        candidates = [audioItem(
                            parentID: item.id,
                            index: 1,
                            title: "\(item.displayName) Tone",
                            artist: item.artist ?? item.displayName,
                            album: "BVT Online Album"
                        )]
                    case .track, .audioFile, .unknown:
                        candidates = [item]
                    }
                } else {
                    candidates = []
                }
            }
            let matches = candidates.filter { item in
                [item.displayName, item.title, item.artist, item.album]
                    .compactMap { $0?.localizedCaseInsensitiveContains(query) }
                    .contains(true)
            }
            return page(
                items: matches,
                sort: request.sort,
                pageSize: request.pageSize,
                pageToken: request.pageToken
            )
        }

        private func page(
            items: [SourceCatalogItem],
            sort: SourceCatalogSort,
            pageSize: Int,
            pageToken: MediaSourceCursor?
        ) -> SourceCatalogPage {
            let sortedItems = sortItems(items, using: sort)
            let effectivePageSize = min(
                pageSize,
                AppBVTFixtureSeeder.onlineSourceFixtureFirstPageCount
            )
            let startIndex: Int
            if pageToken == nil {
                startIndex = 0
            } else if pageToken?.rawValue == onlineSourceFixtureNextPageToken {
                startIndex = min(effectivePageSize, sortedItems.count)
            } else {
                return SourceCatalogPage(items: [])
            }
            let endIndex = min(
                startIndex + (pageToken == nil ? effectivePageSize : sortedItems.count),
                sortedItems.count
            )
            return SourceCatalogPage(
                items: Array(sortedItems[startIndex..<endIndex]),
                nextPageToken: endIndex < sortedItems.count
                    ? MediaSourceCursor(onlineSourceFixtureNextPageToken)
                    : nil
            )
        }

        func download(
            _ itemID: SourceObjectID,
            options: DownloadOptions
        ) async throws -> DownloadReceipt {
            guard let item = allMusicItems.first(where: { $0.id == itemID }) else {
                throw FixtureError.resourceNotFound
            }
            let fileManager = FileManager.default
            let stagingURL = fileManager.temporaryDirectory
                .appendingPathComponent("MusicFree-BVT-\(UUID().uuidString).wav")
            let data = makeWaveData(
                title: item.title ?? item.displayName,
                artist: item.artist ?? "BVT Online Artist",
                album: item.album ?? "BVT Online Album"
            )
            try data.write(to: stagingURL, options: .atomic)
            return DownloadReceipt(
                sourceID: descriptor.sourceID,
                itemID: itemID,
                fileURL: stagingURL,
                contentRevision: "bvt-\(providerKind.rawValue)-1",
                byteCount: Int64(data.count)
            )
        }

        func playbackAccess(
            for itemID: SourceObjectID,
            purpose _: PlaybackPurpose
        ) async throws -> PlaybackAccess {
            guard providerKind == .dsAudio,
                  allMusicItems.contains(where: { $0.id == itemID })
            else {
                return .downloadRequired
            }
            return .http(
                request: RemotePlaybackRequest(
                    url: URL(string: "http://127.0.0.1:9/bvt/\(descriptor.sourceID.rawValue)/\(itemID.externalID)")!,
                    headers: ["Accept": "audio/*"],
                    expiresAt: Date().addingTimeInterval(300)
                ),
                transcode: TranscodeDescriptor(container: "wav")
            )
        }

        private var folderItems: [SourceCatalogItem] {
            (1...AppBVTFixtureSeeder.onlineSourceFixtureFirstPageCount + 4)
                .map(folderItem(index:))
        }

        private func folderItem(index: Int) -> SourceCatalogItem {
            SourceCatalogItem(
                id: SourceObjectID(
                    sourceID: descriptor.sourceID,
                    externalID: index == 1
                        ? onlineSourceFixtureFolderID
                        : "bvt-folder-\(String(format: "%02d", index))"
                ),
                kind: .folder,
                displayName: index == 1
                    ? "\(descriptor.displayName) Folder"
                    : "\(descriptor.displayName) Folder \(String(format: "%02d", index))"
            )
        }

        private var subfolderItems: [SourceCatalogItem] {
            folderItems.map { folder in
                let index = folderItems.firstIndex(of: folder).map { $0 + 1 } ?? 1
                return subfolderItem(parentID: folder.id, index: index)
            }
        }

        private func subfolderItem(
            parentID: SourceObjectID,
            index: Int
        ) -> SourceCatalogItem {
            SourceCatalogItem(
                id: SourceObjectID(
                    sourceID: descriptor.sourceID,
                    externalID: index == 1
                        ? onlineSourceFixtureSubfolderID
                        : "bvt-subfolder-\(String(format: "%02d", index))"
                ),
                kind: .folder,
                displayName: index == 1
                    ? "\(descriptor.displayName) Subfolder"
                    : "\(descriptor.displayName) Subfolder \(String(format: "%02d", index))",
                parentID: parentID
            )
        }

        private var albumItems: [SourceCatalogItem] {
            (1...AppBVTFixtureSeeder.onlineSourceFixtureFirstPageCount + 4)
                .map(albumItem(index:))
        }

        private func albumItem(index: Int) -> SourceCatalogItem {
            SourceCatalogItem(
                id: SourceObjectID(
                    sourceID: descriptor.sourceID,
                    externalID: index == 1
                        ? onlineSourceFixtureAlbumID
                        : "bvt-album-\(String(format: "%02d", index))"
                ),
                kind: .album,
                displayName: index == 1
                    ? "\(descriptor.displayName) Album"
                    : "\(descriptor.displayName) Album \(String(format: "%02d", index))",
                artist: "BVT Album Artist \(String(format: "%02d", index))",
                album: index == 1
                    ? "\(descriptor.displayName) Album"
                    : "\(descriptor.displayName) Album \(String(format: "%02d", index))"
            )
        }

        private var artistItems: [SourceCatalogItem] {
            (1...AppBVTFixtureSeeder.onlineSourceFixtureFirstPageCount + 4)
                .map(artistItem(index:))
        }

        private func artistItem(index: Int) -> SourceCatalogItem {
            let name = index == 1
                ? "\(descriptor.displayName) Artist"
                : "\(descriptor.displayName) Artist \(String(format: "%02d", index))"
            return SourceCatalogItem(
                id: SourceObjectID(
                    sourceID: descriptor.sourceID,
                    externalID: index == 1
                        ? onlineSourceFixtureArtistID
                        : "bvt-artist-\(String(format: "%02d", index))"
                ),
                kind: .artist,
                displayName: name,
                artist: name
            )
        }

        private var allMusicItems: [SourceCatalogItem] {
            (1...AppBVTFixtureSeeder.onlineSourceFixtureFirstPageCount + 4).map {
                audioItem(parentID: nil, index: $0)
            }
        }

        private var allCatalogItems: [SourceCatalogItem] {
            folderItems + subfolderItems + albumItems + artistItems + allMusicItems
        }

        private var folderItem: SourceCatalogItem { folderItem(index: 1) }

        private var subfolderItem: SourceCatalogItem {
            subfolderItem(
                parentID: SourceObjectID(
                    sourceID: descriptor.sourceID,
                    externalID: onlineSourceFixtureFolderID
                ),
                index: 1
            )
        }

        private var albumItem: SourceCatalogItem { albumItem(index: 1) }
        private var artistItem: SourceCatalogItem { artistItem(index: 1) }

        private var audioItem: SourceCatalogItem {
            audioItem(
                parentID: SourceObjectID(
                    sourceID: descriptor.sourceID,
                    externalID: onlineSourceFixtureSubfolderID
                )
            )
        }

        private func audioItem(parentID: SourceObjectID?) -> SourceCatalogItem {
            audioItem(
                parentID: parentID,
                index: 1,
                title: "\(descriptor.displayName) Tone",
                artist: "BVT Online Artist",
                album: "BVT Online Album"
            )
        }

        private func audioItem(
            parentID: SourceObjectID?,
            index: Int,
            title: String? = nil,
            artist: String? = nil,
            album: String? = nil
        ) -> SourceCatalogItem {
            let fallbackTitle = index == 1
                ? "\(descriptor.displayName) Tone"
                : "\(descriptor.displayName) Tone \(String(format: "%02d", index))"
            let normalizedTitle = title ?? fallbackTitle
            return SourceCatalogItem(
                id: SourceObjectID(
                    sourceID: descriptor.sourceID,
                    externalID: index == 1
                        ? onlineSourceFixtureAudioID
                        : "bvt-audio-\(String(format: "%02d", index))"
                ),
                kind: .audioFile,
                displayName: "\(normalizedTitle).wav",
                parentID: parentID,
                title: normalizedTitle,
                artist: artist ?? "BVT Online Artist \(String(format: "%02d", index))",
                album: album ?? "BVT Online Album \(String(format: "%02d", index))",
                duration: .seconds(30),
                contentRevision: "bvt-\(providerKind.rawValue)-\(index)",
                mimeType: "audio/wav",
                isPlayable: providerKind == .dsAudio
            )
        }

        private func catalogYear(for item: SourceCatalogItem) -> Int? {
            let externalID = item.id.externalID
            if externalID == onlineSourceFixtureAlbumID
                || externalID == onlineSourceFixtureAudioID {
                return 2021
            }
            guard let value = externalID.split(separator: "-").last,
                  let index = Int(value)
            else {
                return nil
            }
            return 2020 + index
        }

        private func sortItems(
            _ items: [SourceCatalogItem],
            using sort: SourceCatalogSort
        ) -> [SourceCatalogItem] {
            items.sorted { left, right in
                let comparison: ComparisonResult
                switch sort.key {
                case .year:
                    let leftYear = catalogYear(for: left) ?? 0
                    let rightYear = catalogYear(for: right) ?? 0
                    if leftYear != rightYear {
                        let isAscending = sort.direction == .ascending
                        return isAscending ? leftYear < rightYear : leftYear > rightYear
                    }
                    comparison = left.displayName.localizedStandardCompare(right.displayName)
                case .artist:
                    comparison = (left.artist ?? "").localizedStandardCompare(right.artist ?? "")
                case .album:
                    comparison = (left.album ?? "").localizedStandardCompare(right.album ?? "")
                case .name:
                    comparison = left.displayName.localizedStandardCompare(right.displayName)
                }
                if comparison != .orderedSame {
                    let isAscending = sort.direction == .ascending
                    return isAscending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
                return left.id.externalID < right.id.externalID
            }
        }
    }

    private enum FixtureError: Error {
        case resourceNotFound
    }

    private static func makeLyricsData(title: String) -> Data {
        let lines = [
            "[00:00.00]Now the night is moving on",
            "[00:04.00]Every sound becomes a light",
            "[00:08.00]\(title)",
            "[00:12.00]Keep the moment close to me",
            "[00:16.00]Let the rhythm carry through",
            "[00:20.00]We will find the way back home",
            "[00:24.00]Stay with me until the end"
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func makeCoverData() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAUUlEQVRIx2P8717HQEvA8ouJhbYW/KS1BTT3wS8mVtpaMByCaDQVEfQBjVPRaCQPvA9oH0TMo6mIgAWjqYigBUO/LBqNZIIW0CGIRlPRAPsAACtZIT1eLtkxAAAAAElFTkSuQmCC") ?? Data()
    }

    private static func makeWaveData(
        title: String,
        artist: String = "BVT Artist",
        album: String? = "BVT Album",
        genre: String = "BVT Genre",
        year: String = "2026"
    ) -> Data {
        let sampleRate: UInt32 = 8_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        // The UI flow intentionally spends more than a few seconds moving
        // between the library, mini player, and now-playing surfaces. Keep
        // the fixture alive long enough that the queue remains observable.
        let sampleCount = Int(sampleRate) * 30
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = UInt32(sampleCount * bytesPerSample)
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bytesPerSample)
        let blockAlign = channelCount * UInt16(bytesPerSample)
        let infoList = makeInfoList(
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            year: year
        )

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(44 + infoList.count) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("LIST")
        data.appendLittleEndian(UInt32(infoList.count))
        data.append(infoList)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)

        for index in 0..<sampleCount {
            let phase = 2 * Double.pi * 440 * Double(index) / Double(sampleRate)
            let sample = Int16((sin(phase) * Double(Int16.max) * 0.08).rounded())
            data.appendLittleEndian(sample)
        }
        return data
    }

    private static func makeInfoList(
        title: String,
        artist: String,
        album: String?,
        genre: String,
        year: String
    ) -> Data {
        var info = Data()
        info.appendASCII("INFO")
        appendInfo("INAM", value: title, to: &info)
        appendInfo("IART", value: artist, to: &info)
        if let album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendInfo("IPRD", value: album, to: &info)
        }
        appendInfo("IGNR", value: genre, to: &info)
        appendInfo("ICRD", value: year, to: &info)
        return info
    }

    private static func appendInfo(_ key: String, value: String, to data: inout Data) {
        let valueData = Data((value + "\0").utf8)
        data.appendASCII(key)
        data.appendLittleEndian(UInt32(valueData.count))
        data.append(valueData)
        if !valueData.count.isMultiple(of: 2) {
            data.append(0)
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
#endif
