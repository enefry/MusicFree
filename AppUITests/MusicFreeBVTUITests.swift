import XCTest

final class MusicFreeBVTUITests: XCTestCase {
    private let trackTitle = "BVT Tone"
    private let playlistName = "BVT 自动巡检"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Xcode's default per-test timeout is shorter than the end-to-end BVT
        // flows. Keep timeout protection while allowing the longest fixture
        // scenario to finish instead of force-quitting the runner at 40s.
        executionTimeAllowance = 900
    }

    @MainActor
    func testAgentBVTCompletesCoreIPhoneFlowAndPersistsState() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-audio",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        createPlaylist(in: app)
        let expectedPruningValue = changeStoragePreference(in: app)
        addSeededTrackToPlaylist(in: app)
        playAndFavoriteSeededTrack(in: app)

        app.terminate()
        app.launch()

        assertMainTabs(in: app)
        assertFavoritePersisted(in: app)
        assertPlaylistPersisted(in: app)
        assertStoragePreferencePersisted(expectedPruningValue, in: app)
        assertSeedWasIdempotent(in: app)
    }

    @MainActor
    func testUIKitShellLibrarySongsSlicePlaysSeededTrack() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--uikit-shell",
            "--bvt-seed-audio",
            "--bvt-seed-uikit-songs",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["app.root"].firstMatch
                .waitForExistence(timeout: 15),
            "The UIKit root must expose a stable root identifier."
        )

        let songsSection = app.descendants(matching: .any)[
            "library.home.section.tracks"
        ].firstMatch
        XCTAssertTrue(
            songsSection.waitForExistence(timeout: 20),
            "The UIKit Library home must expose the Songs section."
        )
        songsSection.tap()

        XCTAssertTrue(
            app.navigationBars["Songs"].waitForExistence(timeout: 10),
            "Selecting Songs must push a native UIKit navigation surface."
        )
        XCTAssertTrue(
            app.collectionViews["library.tracks.collection"].waitForExistence(timeout: 10),
            "The Songs surface must be backed by the UIKit collection view."
        )
        let seededTrack = app.collectionViews["library.tracks.collection"].cells
            .matching(NSPredicate(format: "label == %@", trackTitle))
            .firstMatch
        XCTAssertTrue(
            seededTrack.waitForExistence(timeout: 30),
            "The seeded audio track must render in the UIKit list."
        )
        XCTAssertTrue(
            app.staticTexts[trackTitle].firstMatch.waitForExistence(timeout: 10),
            "The seeded track title must remain visible in the UIKit list."
        )
        XCTAssertTrue(
            app.staticTexts["BVT Artist"].firstMatch.waitForExistence(timeout: 15),
            "The UIKit list must render the asynchronously loaded artist subtitle."
        )
        for title in ["BVT DS Audio Tone", "BVT Extremely Long Track Title That Must Stay Inside The Player Width", "BVT Google Drive Tone"] {
            XCTAssertTrue(
                app.staticTexts[title].firstMatch.waitForExistence(timeout: 15),
                "The UIKit visual fixture must render (title)."
            )
        }
        attachScreenshot(named: "uikit-songs")
        XCTAssertTrue(seededTrack.isHittable)
        seededTrack.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: 20),
            "Selecting a UIKit track must feed the shared playback service and show Mini Player."
        )
        let miniTitle = app.staticTexts.matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "player.mini.title",
                trackTitle
            )
        ).firstMatch
        XCTAssertTrue(
            miniTitle.waitForExistence(timeout: 10),
            "Compact Mini Player must refresh its title after selecting a UIKit track."
        )
        attachScreenshot(named: "uikit-songs-mini-player")
    }

    @MainActor
    func testUIKitShellNowPlayingSliceRendersNativePlayerControls() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--uikit-shell",
            "--bvt-seed-audio",
            "--bvt-seed-uikit-songs",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        let songsSection = app.descendants(matching: .any)[
            "library.home.section.tracks"
        ].firstMatch
        XCTAssertTrue(songsSection.waitForExistence(timeout: 20))
        songsSection.tap()

        XCTAssertTrue(
            app.navigationBars["Songs"].waitForExistence(timeout: 10)
        )
        let seededTrack = app.collectionViews["library.tracks.collection"].cells
            .matching(NSPredicate(format: "label == %@", trackTitle))
            .firstMatch
        XCTAssertTrue(seededTrack.waitForExistence(timeout: 30))
        seededTrack.tap()

        let miniPlayerOpen = app.buttons["player.mini"].firstMatch
        XCTAssertTrue(
            miniPlayerOpen.waitForExistence(timeout: 20),
            "The UIKit Mini Player must expose a concrete presentation target."
        )
        miniPlayerOpen.coordinate(
            withNormalizedOffset: CGVector(dx: 0.30, dy: 0.50)
        ).tap()
        attachScreenshot(named: "uikit-now-playing-debug")

        let nowPlaying = app.descendants(matching: .any)[
            "player.nowPlaying"
        ].firstMatch
        XCTAssertTrue(
            nowPlaying.waitForExistence(timeout: 15),
            "The UIKit Player Sheet must expose the native Now Playing surface."
        )
        XCTAssertTrue(
            app.staticTexts[trackTitle].firstMatch.waitForExistence(timeout: 10),
            "The native Now Playing surface must render the current title."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["player.nowPlaying.artwork"]
                .firstMatch.waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.sliders["Playback progress"].firstMatch.exists
                || app.sliders["播放进度"].firstMatch.exists,
            "The native Now Playing surface must expose playback progress."
        )
        XCTAssertTrue(
            app.buttons["Pause"].firstMatch.exists
                || app.buttons["暂停"].firstMatch.exists
                || app.buttons["Play"].firstMatch.exists
                || app.buttons["播放"].firstMatch.exists,
            "The native Now Playing surface must expose transport control."
        )
        XCTAssertTrue(
            app.buttons["AirPlay"].firstMatch.exists
                || app.buttons["播放队列"].firstMatch.exists
                || app.buttons["Play queue"].firstMatch.exists,
            "The native Now Playing footer must expose system/player actions."
        )

        let more = app.buttons["player.nowPlaying.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        for labels in [
            ["Share", "分享"],
            ["Play next", "下一首播放"],
            ["Add to queue", "加入队列"],
            ["Add to playlist", "添加到播放列表"],
            ["View song details", "查看歌曲详情"],
            ["Go to Album", "跳转到专辑"],
            ["Go to Artist", "跳转到艺人"],
            ["Delete", "删除"],
        ] {
            let predicate = NSPredicate(
                format: "label == %@ OR label == %@",
                labels[0],
                labels[1]
            )
            XCTAssertTrue(
                app.buttons.matching(predicate).firstMatch.waitForExistence(timeout: 5),
                "Now Playing must expose the Apple Music-style action: \(labels[0])."
            )
        }
        for labels in [
            ["Download", "下载"],
            ["Add to Library", "收藏到资料库"],
            ["Create Station", "创建电台"],
            ["Share Lyrics", "分享歌词"],
        ] {
            let predicate = NSPredicate(
                format: "label == %@ OR label == %@",
                labels[0],
                labels[1]
            )
            XCTAssertFalse(
                app.buttons.matching(predicate).firstMatch.exists,
                "Now Playing must not expose the unavailable action: \(labels[0])."
            )
        }
        attachScreenshot(named: "uikit-now-playing-native")
    }

    @MainActor
    func testUIKitShellLibraryBrowseCollectionsRenderSeededData() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--uikit-shell",
            "--bvt-seed-audio",
            "--bvt-seed-layout-library",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        let pages: [(title: String, rawValue: String, itemPrefix: String)] = [
            ("Albums", "albums", "library.album.open."),
            ("Artists", "artists", "library.artist.open."),
            ("Genres", "genres", "library.genre.open."),
            ("Folders", "folders", "library.folder.open."),
        ]

        for page in pages {
            let section = app.descendants(matching: .any)[
                "library.home.section.\(page.rawValue)"
            ].firstMatch
            XCTAssertTrue(
                section.waitForExistence(timeout: 20),
                "The UIKit Library home must expose the \(page.title) section."
            )
            section.tap()

            XCTAssertTrue(
                app.navigationBars[page.title].waitForExistence(timeout: 10),
                "Selecting \(page.title) must push the native browse controller."
            )
            XCTAssertTrue(
                app.collectionViews["library.\(page.rawValue).collection"]
                    .waitForExistence(timeout: 15),
                "\(page.title) must be backed by the UIKit collection view."
            )

            let seededItem = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", page.itemPrefix)
            ).firstMatch
            XCTAssertTrue(
                seededItem.waitForExistence(timeout: 30),
                "The seeded \(page.title) item must render in the UIKit surface."
            )
            XCTAssertTrue(seededItem.isHittable)
            seededItem.tap()

            let detailIdentifier = page.rawValue == "artists"
                ? "library.artistDetail"
                : "library.collectionDetail"
            let detail = app.descendants(matching: .any)[detailIdentifier].firstMatch
            XCTAssertTrue(
                detail.waitForExistence(timeout: 15),
                "Selecting a \(page.title) item must push the native detail surface."
            )

            if page.rawValue == "artists" {
                XCTAssertTrue(
                    app.collectionViews["library.artist.albums"]
                        .waitForExistence(timeout: 15),
                    "Artists must use the native UIKit album grid."
                )
                XCTAssertTrue(
                    detail.descendants(matching: .any)["library.artist.header.title"]
                        .waitForExistence(timeout: 15),
                    "Artist details must render the artist header."
                )
            } else {
                XCTAssertTrue(
                    app.collectionViews["library.collectionDetail.collection"]
                        .waitForExistence(timeout: 15),
                    "The \(page.title) detail must use the native UIKit collection view."
                )
                let detailTrack = app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "library.collection.track.play.")
                ).firstMatch
                XCTAssertTrue(
                    detailTrack.waitForExistence(timeout: 30),
                    "The \(page.title) detail must render at least one filtered track."
                )
            }

            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(
                app.collectionViews["library.\(page.rawValue).collection"]
                    .waitForExistence(timeout: 10),
                "Back navigation from the \(page.title) detail must return to its collection."
            )
            app.navigationBars[page.title].buttons.firstMatch.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["library.home"].firstMatch
                    .waitForExistence(timeout: 10),
                "Back navigation from \(page.title) must return to the UIKit Library home."
            )
        }
    }

    @MainActor
    func testUIKitShellLibraryCollectionDetailExposesNativeActions() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--uikit-shell",
            "--bvt-seed-audio",
            "--bvt-seed-layout-library",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        let albumsSection = app.descendants(matching: .any)[
            "library.home.section.albums"
        ].firstMatch
        XCTAssertTrue(albumsSection.waitForExistence(timeout: 20))
        albumsSection.tap()

        let seededAlbum = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.album.open.")
        ).firstMatch
        XCTAssertTrue(seededAlbum.waitForExistence(timeout: 30))
        seededAlbum.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["library.collectionDetail"].firstMatch
                .waitForExistence(timeout: 15)
        )
        attachScreenshot(named: "uikit-collection-detail")
        let collectionMenu = app.buttons["library.collection.menu"].firstMatch
        XCTAssertTrue(collectionMenu.waitForExistence(timeout: 10))
        collectionMenu.tap()

        XCTAssertTrue(app.buttons["Play next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add to queue"].exists)
        XCTAssertTrue(app.buttons["Add to playlist"].exists)

        app.buttons["Play next"].tap()

        XCTAssertTrue(collectionMenu.waitForExistence(timeout: 5))
        collectionMenu.tap()
        let selectButton = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "选择歌曲", "Select Songs")
        ).firstMatch
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()
        XCTAssertTrue(
            app.buttons["library.collection.finishSelection"].waitForExistence(timeout: 5)
        )
        let detailTrack = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.collection.track.play.")
        ).firstMatch
        XCTAssertTrue(detailTrack.waitForExistence(timeout: 10))
        // In selection mode, a normal tap selects the row and updates the
        // batch deletion action. The context menu is intentionally not used
        // for this selection-state assertion.
        detailTrack.tap()
        XCTAssertTrue(app.buttons["library.collection.deleteSelected"].isEnabled)
        attachScreenshot(named: "uikit-collection-detail-selection")
        app.buttons["library.collection.finishSelection"].tap()
    }

    @MainActor
    func testUIKitShellLibraryAlbumEditorRendersMetadataForm() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--uikit-shell",
            "--bvt-seed-audio",
            "--bvt-seed-layout-library",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        let albumsSection = app.descendants(matching: .any)[
            "library.home.section.albums"
        ].firstMatch
        XCTAssertTrue(albumsSection.waitForExistence(timeout: 20))
        albumsSection.tap()
        let seededAlbum = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.album.open.")
        ).firstMatch
        XCTAssertTrue(seededAlbum.waitForExistence(timeout: 30))
        seededAlbum.tap()

        let collectionMenu = app.buttons["library.collection.menu"].firstMatch
        XCTAssertTrue(collectionMenu.waitForExistence(timeout: 30))
        collectionMenu.tap()
        let editButton = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "编辑专辑", "Edit Album")
        ).firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 30))
        editButton.tap()

        let editor = app.descendants(matching: .any)["library.albumEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.textFields["library.albumEditor.title"].waitForExistence(timeout: 10),
            "Album editor must expose the title field."
        )
        XCTAssertTrue(
            app.textFields["library.albumEditor.artist"].waitForExistence(timeout: 10),
            "Album editor must expose the artist relationship field."
        )
        XCTAssertTrue(
            app.textFields["library.albumEditor.year"].waitForExistence(timeout: 10),
            "Album editor must expose the release year field."
        )
        XCTAssertTrue(
            app.buttons["library.albumEditor.coverPicker"].waitForExistence(timeout: 10),
            "Album editor must expose the manual cover picker."
        )
        XCTAssertTrue(
            app.buttons["library.albumEditor.coverRemove"].waitForExistence(timeout: 10),
            "Album editor must expose the manual cover removal action."
        )
        XCTAssertTrue(
            app.buttons["library.albumEditor.refreshSource"].waitForExistence(timeout: 10),
            "Album editor must expose the remote source refresh action."
        )
        let cancelButton = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "取消", "Cancel")
        ).firstMatch
        let saveButton = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "保存", "Save")
        ).firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10))
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        attachScreenshot(named: "uikit-album-editor")

        cancelButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.collectionDetail"].firstMatch
                .waitForExistence(timeout: 10),
            "Cancelling the album editor must return to the native collection detail."
        )
    }

    @MainActor
    func testUIKitShellLibraryTrackDetailRendersNativeSurface() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--uikit-shell",
            "--bvt-seed-audio",
            "--bvt-seed-layout-library",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        app.descendants(matching: .any)["library.home.section.albums"].firstMatch.tap()
        let seededAlbum = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.album.open.")
        ).firstMatch
        XCTAssertTrue(seededAlbum.waitForExistence(timeout: 30))
        seededAlbum.tap()

        let detailCollection = app.collectionViews[
            "library.collectionDetail.collection"
        ].firstMatch
        XCTAssertTrue(
            detailCollection.waitForExistence(timeout: 15),
            "The album detail must expose its native track collection before opening song details."
        )
        let detailTrack = detailCollection.cells.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "library.collection.track.play.",
                trackTitle
            )
        ).firstMatch
        XCTAssertTrue(detailTrack.waitForExistence(timeout: 30))
        XCTAssertTrue(detailTrack.isHittable)
        // A normal tap is the established playback action. Song details are
        // intentionally exposed through the native long-press context menu.
        detailTrack.press(forDuration: 1.0)
        let viewDetails = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label ==[c] %@ OR label ==[c] %@",
                "View song details",
                "查看歌曲详情"
            )
        ).firstMatch
        XCTAssertTrue(
            viewDetails.waitForExistence(timeout: 5),
            "Long-pressing a song must expose the native View song details action."
        )
        viewDetails.tap()

        let detail = app.descendants(matching: .any)["library.trackDetail"].firstMatch
        XCTAssertTrue(
            detail.waitForExistence(timeout: 15),
            "Selecting View song details must push the native track detail surface."
        )
        let title = detail.descendants(matching: .any)[
            "library.trackDetail.title"
        ].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, trackTitle)
        XCTAssertTrue(
            detail.descendants(matching: .any)["library.trackDetail.favorite"]
                .firstMatch.waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.buttons["library.trackDetail.addToPlaylist"].firstMatch
                .waitForExistence(timeout: 10)
        )
        attachScreenshot(named: "uikit-track-detail")
    }

    @MainActor
    private func assertMainTabs(in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: 15),
            "The app must expose its main navigation as a native tab bar."
        )
        for title in ["Library", "Playlists", "Online Sources", "Settings"] {
            let button = tabBar.buttons[title].firstMatch
            XCTAssertTrue(button.exists, "Missing native tab: \(title)")
            XCTAssertTrue(button.isHittable, "Native tab is not hittable: \(title)")
        }
        XCTAssertFalse(app.staticTexts["Library unavailable"].exists)
        XCTAssertFalse(app.staticTexts["App service unavailable"].exists)
    }

    @MainActor
    func testRegularWidthUsesThreeColumnNavigationShell() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-audio",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        guard window.frame.width >= 700 else {
            throw XCTSkip("Three-column shell requires a regular-width destination.")
        }

        let sidebar = app.descendants(matching: .any)["app.sidebar"].firstMatch
        let secondary = app.descendants(matching: .any)["app.secondaryColumn"].firstMatch
        let detail = app.descendants(matching: .any)["app.detailColumn"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        XCTAssertTrue(secondary.waitForExistence(timeout: 10))
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["app.route.library"].firstMatch
                .waitForExistence(timeout: 5),
            "Wide regular layouts must expose the primary sidebar instead of starting collapsed."
        )
        XCTAssertFalse(app.tabBars.firstMatch.exists)

        let favoritesSection = app.buttons["library.section.favorites"].firstMatch
        let albumsSection = app.buttons["library.section.albums"].firstMatch
        let tracksSection = app.buttons["library.section.tracks"].firstMatch
        XCTAssertTrue(favoritesSection.waitForExistence(timeout: 5))
        XCTAssertTrue(albumsSection.waitForExistence(timeout: 5))
        XCTAssertTrue(tracksSection.waitForExistence(timeout: 5))

        favoritesSection.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].firstMatch.waitForExistence(timeout: 10))

        albumsSection.tap()
        XCTAssertTrue(app.navigationBars["Albums"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            detail.descendants(matching: .any)["library.tracks"].firstMatch
                .waitForNonExistence(timeout: 10),
            "Selecting Albums in the secondary column must remove the song list."
        )

        tracksSection.tap()
        XCTAssertTrue(app.navigationBars["Songs"].firstMatch.waitForExistence(timeout: 10))

        let track = app.staticTexts[trackTitle].firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 30))
        XCTAssertTrue(track.isHittable)
        track.tap()

        let miniPlayerProgress = app.descendants(matching: .any)[
            "player.mini.progress"
        ].firstMatch
        XCTAssertTrue(
            miniPlayerProgress.waitForExistence(timeout: 15),
            "Regular-width Mini Player should expose a seek progress control."
        )
        let seekSlider = miniPlayerProgress.sliders.firstMatch
        XCTAssertTrue(seekSlider.waitForExistence(timeout: 5))
        XCTAssertTrue(seekSlider.isEnabled)

        let settingsRoute = app.descendants(matching: .any)["app.route.settings"].firstMatch
        if !settingsRoute.waitForExistence(timeout: 2) {
            let showSidebar = app.buttons["Show Sidebar"].firstMatch
            XCTAssertTrue(showSidebar.waitForExistence(timeout: 2))
            showSidebar.tap()
        }
        XCTAssertTrue(settingsRoute.waitForExistence(timeout: 5))
        settingsRoute.tap()
        XCTAssertTrue(secondary.staticTexts["General"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            detail.buttons["settings.language"].firstMatch.waitForExistence(timeout: 10)
        )
    }

    @MainActor
    func testAuditionSharesNativeMiniPlayerSlot() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-audio", "--bvt-seed-uikit-songs",
            "--bvt-seed-online-sources", "--bvt-reset-online-sources",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()
        assertMainTabs(in: app)
        tapTab("Library", in: app)
        let songs = app.descendants(matching: .any)["library.home.section.tracks"].firstMatch
        XCTAssertTrue(songs.waitForExistence(timeout: 20))
        songs.tap()
        let track = app.collectionViews["library.tracks.collection"].cells
            .matching(NSPredicate(format: "label == %@", trackTitle)).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        track.tap()
        let formalTitle = app.staticTexts["player.mini.title"].firstMatch
        XCTAssertTrue(formalTitle.waitForExistence(timeout: 20))
        let formalPlay = app.buttons["player.mini.playPause"].firstMatch
        if formalPlay.label == "暂停" || formalPlay.label == "Pause" { formalPlay.tap() }
        let pausedTitle = formalTitle.label

        tapTab("Online Sources", in: app)
        let consent = app.buttons["onlineSources.applicationPrivacy.confirm"].firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 15))
        consent.tap()
        enableOnlineSourcesService(in: app)
        openOnlineSource(named: "BVT DS Audio", in: app)
        acceptOnlineSourcePrivacy(sourceID: "bvt.dsaudio", in: app)
        enableOnlineSource(sourceID: "bvt.dsaudio", in: app)
        let catalog = app.collectionViews["onlineSources.catalog.list"].firstMatch
        let allMusic = catalog.cells["onlineSources.detail.bvt.dsaudio.category.allMusic"].firstMatch
        XCTAssertTrue(allMusic.waitForExistence(timeout: 15))
        allMusic.tap()
        let auditions = catalog.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "onlineSources.detail.bvt.dsaudio.item.", ".audition"
        ))
        XCTAssertTrue(auditions.firstMatch.waitForExistence(timeout: 15))
        guard let audition = auditions.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("The loaded catalog must expose a visible audition action.")
            return
        }
        audition.tap()
        let auditionTitle = app.staticTexts["player.onlineAudition.title"].firstMatch
        XCTAssertTrue(auditionTitle.waitForExistence(timeout: 15))
        if app.alerts.firstMatch.waitForExistence(timeout: 3) {
            app.alerts.firstMatch.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(formalTitle.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["player.onlineAudition.close"].exists)
        attachScreenshot(named: "audition-native-expanded")

        catalog.swipeUp()
        catalog.swipeUp()
        let subtitle = app.staticTexts["player.onlineAudition.subtitle"].firstMatch
        XCTAssertTrue(subtitle.waitForNonExistence(timeout: 5), "Native inline mode must hide secondary metadata.")
        XCTAssertTrue(auditionTitle.exists)
        XCTAssertFalse(app.buttons["player.onlineAudition.next"].exists)
        attachScreenshot(named: "audition-native-inline")
        auditionTitle.tap()
        let dismiss = app.buttons["player.onlineAudition.sheet.dismiss"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertTrue(auditionTitle.waitForExistence(timeout: 5))

        let collapse = app.buttons["player.onlineAudition.collapse"].firstMatch
        for _ in 0..<4 {
            catalog.swipeDown()
            if collapse.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(collapse.exists, "Scrolling back must restore the expanded native accessory.")
        collapse.tap()
        let capsule = app.staticTexts["player.onlineAudition.capsule.title"].firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
        attachScreenshot(named: "audition-native-manual-collapse")
        capsule.tap()
        XCTAssertTrue(auditionTitle.waitForExistence(timeout: 5))
        auditionTitle.tap()
        let close = app.buttons["player.onlineAudition.sheet.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(formalTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(formalTitle.label, pausedTitle)
        XCTAssertTrue(formalPlay.label == "播放" || formalPlay.label == "Play")
        XCTAssertTrue(auditionTitle.waitForNonExistence(timeout: 5))
        attachScreenshot(named: "audition-native-formal-restored")
    }

    @MainActor
    func testOnlineSourceLongPressRenamesOnlyName() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-online-sources", "--bvt-reset-online-sources",
            "--bvt-reset-user-interface-preferences"
        ]
        app.launch()
        assertMainTabs(in: app)
        tapTab("Online Sources", in: app)
        let cancelPrivacy = app.buttons["onlineSources.applicationPrivacy.cancel"].firstMatch
        XCTAssertTrue(cancelPrivacy.waitForExistence(timeout: 15))
        cancelPrivacy.tap()
        let source = app.cells["onlineSources.source.bvt.dsaudio"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.press(forDuration: 1.0)
        let rename = app.buttons.matching(NSPredicate(format: "label IN %@", ["Rename", "重命名"])).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let name = app.textFields["onlineSources.rename.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.textFields.count, 1)
        XCTAssertEqual(app.alerts.secureTextFields.count, 0)
        name.tap()
        let original = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        let save = app.buttons["onlineSources.rename.save"].firstMatch
        XCTAssertFalse(save.isEnabled)
        name.typeText("Renamed NAS")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(source.staticTexts["Renamed NAS"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--bvt-seed-online-sources"]
        app.launch()
        tapTab("Online Sources", in: app)
        XCTAssertTrue(cancelPrivacy.waitForExistence(timeout: 15))
        cancelPrivacy.tap()
        XCTAssertTrue(source.staticTexts["Renamed NAS"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOnlineSourcesBVTCompletesPrivacyMultiSourceCatalogSearchAndImportFlow() {
        let app = XCUIApplication()
        defer { app.terminate() }
        // The first launch resets the durable fixture. Later relaunches, if
        // this test is interrupted, keep the accepted source state intact so
        // the flow can still prove persistence rather than re-seeding over it.
        app.launchArguments = [
            "--bvt-seed-online-sources",
            "--bvt-reset-online-sources",
            "--bvt-reset-user-interface-preferences"
        ]
        app.launch()

        assertMainTabs(in: app)
        tapTab("Online Sources", in: app)

        // The application disclosure is shown on the first visit to the tab,
        // before any source-level action is available.
        let applicationPrivacySheet = app.descendants(matching: .any)[
            "onlineSources.applicationPrivacy.sheet"
        ].firstMatch
        XCTAssertTrue(applicationPrivacySheet.waitForExistence(timeout: 15))
        let applicationPrivacyCancel = button(
            identifier: "onlineSources.applicationPrivacy.cancel",
            labels: ["Cancel", "取消"],
            in: app
        )
        XCTAssertTrue(applicationPrivacyCancel.waitForExistence(timeout: 5))
        applicationPrivacyCancel.tap()
        XCTAssertTrue(applicationPrivacySheet.waitForNonExistence(timeout: 10))

        // Adding a source is gated by the application agreement. Verify that
        // cancelling the disclosure does not leak the add sheet, then accept
        // it and add a second Google Drive instance.
        let addButton = app.buttons["onlineSources.add"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        let googleDriveOption = app.buttons["Google Drive"].firstMatch
        XCTAssertTrue(
            googleDriveOption.waitForExistence(timeout: 5),
            "The add button must present the provider menu before any provider consent is shown."
        )
        googleDriveOption.tap()
        XCTAssertTrue(applicationPrivacySheet.waitForExistence(timeout: 10))
        XCTAssertTrue(applicationPrivacyCancel.waitForExistence(timeout: 5))
        applicationPrivacyCancel.tap()
        XCTAssertTrue(applicationPrivacySheet.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["onlineSources.add.sheet"].exists)

        addButton.tap()
        XCTAssertTrue(googleDriveOption.waitForExistence(timeout: 5))
        googleDriveOption.tap()
        XCTAssertTrue(applicationPrivacySheet.waitForExistence(timeout: 10))
        let applicationPrivacyConfirm = button(
            identifier: "onlineSources.applicationPrivacy.confirm",
            labels: ["Agree", "同意"],
            in: app
        )
        XCTAssertTrue(applicationPrivacyConfirm.waitForExistence(timeout: 5))
        applicationPrivacyConfirm.tap()
        XCTAssertTrue(applicationPrivacySheet.waitForNonExistence(timeout: 10))

        let addSheet = app.descendants(matching: .any)["onlineSources.add.sheet"].firstMatch
        XCTAssertTrue(addSheet.waitForExistence(timeout: 10))

        let addedDisplayName = "BVT Extra Google Drive"
        let displayNameField = app.textFields["onlineSources.add.displayName"].firstMatch
        XCTAssertTrue(displayNameField.waitForExistence(timeout: 5))
        displayNameField.tap()
        displayNameField.typeText(addedDisplayName)
        let submitAddButton = button(
            identifier: "onlineSources.add.submit",
            labels: ["Add", "添加"],
            in: app
        )
        XCTAssertTrue(submitAddButton.waitForExistence(timeout: 5))
        XCTAssertTrue(submitAddButton.isEnabled)
        submitAddButton.tap()
        XCTAssertTrue(addSheet.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[addedDisplayName].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["BVT DS Audio"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["BVT Google Drive"].waitForExistence(timeout: 10))
        attachScreenshot(named: "26-online-sources-root")

        enableOnlineSourcesService(in: app)

        // DS Audio: source-level consent, source toggle, browse, search,
        // temporary audition entry, download, and local import.
        openOnlineSource(named: "BVT DS Audio", in: app)
        acceptOnlineSourcePrivacy(sourceID: "bvt.dsaudio", in: app)
        enableOnlineSource(sourceID: "bvt.dsaudio", in: app)

        let catalogCollectionView = app.collectionViews[
            "onlineSources.catalog.list"
        ].firstMatch
        XCTAssertTrue(
            catalogCollectionView.waitForExistence(timeout: 10),
            "The catalog must expose a native collection surface for pull-to-refresh."
        )
        XCTAssertFalse(
            app.navigationBars.buttons.matching(
                NSPredicate(format: "identifier CONTAINS[c] 'refresh' OR label CONTAINS[c] 'refresh' OR label CONTAINS[c] '刷新'")
            ).firstMatch.exists,
            "Catalog refresh must be performed with pull-to-refresh, not a toolbar button."
        )
        attachScreenshot(named: "27-online-source-detail-root")

        let dsAlbumCategory = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.dsaudio.category.albums"
        ].firstMatch
        XCTAssertTrue(
            dsAlbumCategory.waitForExistence(timeout: 15),
            "DS Audio must expose an album browsing dimension at the catalog root."
        )
        dsAlbumCategory.tap()
        let dsAlbum = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.dsaudio.item.bvt-album.open"
        ].firstMatch
        XCTAssertTrue(
            dsAlbum.waitForExistence(timeout: 15),
            "The album browsing page must render album containers."
        )
        dsAlbum.tap()
        XCTAssertTrue(
            app.staticTexts["BVT DS Audio Album Tone"].waitForExistence(timeout: 15),
            "Opening an album must load its audio items."
        )
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio Album")
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio")

        let dsArtistCategory = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.dsaudio.category.artists"
        ].firstMatch
        XCTAssertTrue(
            dsArtistCategory.waitForExistence(timeout: 15),
            "DS Audio must expose an artist browsing dimension at the catalog root."
        )
        dsArtistCategory.tap()
        let dsArtist = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.dsaudio.item.bvt-artist.open"
        ].firstMatch
        XCTAssertTrue(
            dsArtist.waitForExistence(timeout: 15),
            "The artist browsing page must render artist containers."
        )
        dsArtist.tap()
        XCTAssertTrue(
            app.staticTexts["BVT DS Audio Artist Tone"].waitForExistence(timeout: 15),
            "Opening an artist must load its audio items."
        )
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio Artist")
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio")

        let dsFolder = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.dsaudio.item.bvt-folder.open"
        ].firstMatch
        XCTAssertTrue(dsFolder.waitForExistence(timeout: 20))
        dsFolder.tap()

        let dsSubfolder = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.dsaudio.item.bvt-subfolder.open"
        ].firstMatch
        XCTAssertTrue(dsSubfolder.waitForExistence(timeout: 15))
        attachScreenshot(named: "28-online-source-detail-folder")

        let dsFolderImport = app.buttons[
            "onlineSources.detail.bvt.dsaudio.item.bvt-folder.downloadAndImportAll"
        ].firstMatch
        XCTAssertTrue(
            dsFolderImport.waitForExistence(timeout: 10),
            "An entered DS Audio folder must expose the top-right recursive import action."
        )

        // Starting an import must leave a task behind even when the source
        // detail is no longer visible. Double-tapping the selected Online
        // Sources tab is the native tab re-selection path back to the source
        // list.
        dsFolderImport.tap()
        tapTab("Playlists", in: app)
        let onlineSourcesTab = app.tabBars.buttons["Online Sources"].firstMatch
        XCTAssertTrue(onlineSourcesTab.waitForExistence(timeout: 10))
        onlineSourcesTab.doubleTap()
        // A native UITableView disclosure row remains an XCUIElementTypeCell
        // even when it carries the button accessibility trait. Match by the
        // stable identifier instead of coupling this BVT to an element type.
        let queueEntry = app.descendants(matching: .any)[
            "onlineSources.downloadQueue"
        ].firstMatch
        XCTAssertTrue(
            queueEntry.waitForExistence(timeout: 15),
            "The source list must keep a separate download/import queue entry."
        )
        queueEntry.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["onlineSources.downloadQueue.view"].firstMatch
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts["BVT DS Audio Folder"].waitForExistence(timeout: 10),
            "The queue must retain the task after leaving the source detail."
        )
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "Online Sources")
        XCTAssertTrue(app.buttons["onlineSources.add"].firstMatch.waitForExistence(timeout: 10))
        openOnlineSource(named: "BVT DS Audio", in: app)
        XCTAssertTrue(dsFolder.waitForExistence(timeout: 15))
        dsFolder.tap()
        dsSubfolder.tap()

        let dsAudioTitle = "BVT DS Audio Tone"
        let dsAudioFile = "BVT DS Audio Tone"
        XCTAssertTrue(app.staticTexts[dsAudioFile].waitForExistence(timeout: 15))

        XCTAssertFalse(
            app.buttons["onlineSources.detail.bvt.dsaudio.catalog.back"].exists,
            "The catalog must use the system NavigationStack back button."
        )
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio")
        XCTAssertTrue(dsSubfolder.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[dsAudioFile].waitForNonExistence(timeout: 10))
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio Folder")
        XCTAssertTrue(
            dsFolder.waitForExistence(timeout: 15),
            "Returning to the online source root must restore the root folder."
        )
        XCTAssertTrue(dsSubfolder.waitForNonExistence(timeout: 10))
        dsFolder.tap()
        XCTAssertTrue(dsSubfolder.waitForExistence(timeout: 15))
        dsSubfolder.tap()
        XCTAssertTrue(app.staticTexts[dsAudioFile].waitForExistence(timeout: 15))

        let dsAudition = app.buttons[
            "onlineSources.detail.bvt.dsaudio.item.bvt-audio.audition"
        ].firstMatch
        XCTAssertTrue(dsAudition.waitForExistence(timeout: 10))
        dsAudition.tap()
        let dsStopAudition = app.buttons[
            "onlineSources.detail.bvt.dsaudio.item.bvt-audio.stopAudition"
        ].firstMatch
        let auditionFailureAlert = app.alerts.firstMatch
        XCTAssertTrue(
            waitForEither(dsStopAudition, auditionFailureAlert, timeout: 15),
            "Audition must either enter its transient playback state or present a recoverable playback error."
        )
        var auditionRetainedSurface = false
        if auditionFailureAlert.exists {
            auditionFailureAlert.buttons.element(boundBy: 0).tap()
            auditionRetainedSurface = true
        } else if dsStopAudition.exists {
            // A successful fixture exposes a stop action. Stopping the session
            // is expected to hide the global audition surface, so no failure
            // surface assertions should run after this branch.
            dsStopAudition.tap()
            XCTAssertTrue(dsStopAudition.waitForNonExistence(timeout: 10))
            XCTAssertTrue(
                app.descendants(matching: .any)["player.onlineAudition.surface"]
                    .firstMatch.waitForNonExistence(timeout: 10),
                "Stopping a successful audition must hide the global player surface."
            )
        }

        if auditionRetainedSurface {
            // The transient player is global to the root shell. Exercise its
            // collapsed state and native Sheet when the fixture returns a
            // recoverable HTTP failure; the failure state must retain the
            // player entry for retry.
            let auditionSurface = app.descendants(matching: .any)[
                "player.onlineAudition.surface"
            ].firstMatch
            XCTAssertTrue(
                auditionSurface.waitForExistence(timeout: 10),
                "A failed audition must retain the global player surface."
            )
            XCTAssertTrue(
                app.staticTexts["player.onlineAudition.title"].firstMatch
                    .waitForExistence(timeout: 5)
            )
            let collapseAudition = app.buttons["player.onlineAudition.collapse"].firstMatch
            XCTAssertTrue(collapseAudition.waitForExistence(timeout: 5))
            XCTAssertFalse(
                app.buttons["player.onlineAudition.close"].exists,
                "The compact audition bar must not expose a close action."
            )
            collapseAudition.tap()
            let auditionCapsule = app.descendants(matching: .any)[
                "player.onlineAudition.capsule"
            ].firstMatch
            XCTAssertTrue(auditionCapsule.waitForExistence(timeout: 5))
            app.staticTexts["player.onlineAudition.capsule.title"].firstMatch.tap()
            XCTAssertTrue(auditionSurface.waitForExistence(timeout: 5))
            app.staticTexts["player.onlineAudition.title"].firstMatch.tap()
            let auditionSheet = app.navigationBars["试听"].firstMatch
            XCTAssertTrue(
                auditionSheet.waitForExistence(timeout: 5),
                "Tapping the audition title must open the native queue Sheet."
            )
            XCTAssertTrue(
                app.sliders["player.onlineAudition.sheet.progress"].firstMatch.exists,
                "The audition Sheet must expose a seek control."
            )
            XCTAssertTrue(
                app.buttons["player.onlineAudition.sheet.previous"].firstMatch.exists
                    && app.buttons["player.onlineAudition.sheet.next"].firstMatch.exists,
                "The audition Sheet must expose previous and next controls."
            )
            let sheetDismiss = app.buttons["player.onlineAudition.sheet.dismiss"].firstMatch
            sheetDismiss.tap()
            XCTAssertTrue(
                auditionSurface.waitForExistence(timeout: 5),
                "The Sheet chevron must only collapse the panel and retain audition."
            )
            app.staticTexts["player.onlineAudition.title"].firstMatch.tap()
            XCTAssertTrue(auditionSheet.waitForExistence(timeout: 5))
            auditionSheet.swipeDown()
            XCTAssertTrue(
                auditionSurface.waitForExistence(timeout: 5),
                "Interactive Sheet dismissal must only collapse the panel and retain audition."
            )
            app.staticTexts["player.onlineAudition.title"].firstMatch.tap()
            let sheetClose = app.buttons["player.onlineAudition.sheet.close"].firstMatch
            XCTAssertTrue(sheetClose.waitForExistence(timeout: 5))
            sheetClose.tap()
            XCTAssertTrue(
                auditionSurface.waitForNonExistence(timeout: 10),
                "Ending audition from the Sheet must clear the global audition surface."
            )
            XCTAssertTrue(
                auditionCapsule.waitForNonExistence(timeout: 10),
                "Ending audition from the Sheet must clear the compact capsule."
            )
        }

        let dsDownload = app.buttons[
            "onlineSources.detail.bvt.dsaudio.item.bvt-audio.downloadAndImport"
        ].firstMatch
        let dsCompleted = app.descendants(matching: .any)[
            "onlineSources.detail.bvt.dsaudio.item.bvt-audio.completed"
        ].firstMatch
        let dsAlreadyImported = app.descendants(matching: .any)[
            "onlineSources.detail.bvt.dsaudio.item.bvt-audio.alreadyImported"
        ].firstMatch
        let dsSkipped = app.descendants(matching: .any)[
            "onlineSources.detail.bvt.dsaudio.item.bvt-audio.skipped"
        ].firstMatch
        let dsRetry = app.buttons[
            "onlineSources.detail.bvt.dsaudio.item.bvt-audio.retryDownload"
        ].firstMatch
        if dsDownload.waitForExistence(timeout: 10) {
            XCTAssertGreaterThanOrEqual(dsAudition.frame.width, 40)
            XCTAssertGreaterThanOrEqual(dsDownload.frame.width, 40)
            XCTAssertFalse(
                dsAudition.frame.intersects(dsDownload.frame),
                "Audition and download accessories must keep independent hit areas."
            )
            XCTAssertLessThanOrEqual(
                dsDownload.frame.maxX,
                catalogCollectionView.frame.maxX + 1,
                "The trailing download accessory must remain inside the catalog cell."
            )
            dsDownload.tap()
        } else {
            XCTAssertTrue(
                dsAlreadyImported.waitForExistence(timeout: 5)
                    || dsCompleted.waitForExistence(timeout: 5)
                    || dsSkipped.waitForExistence(timeout: 5),
                "DS Audio fixture must expose an import action or an existing successful terminal state."
            )
        }
        let importDeadline = Date().addingTimeInterval(45)
        while Date() < importDeadline
            && !dsCompleted.exists
            && !dsAlreadyImported.exists
            && !dsSkipped.exists
            && !dsRetry.exists {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(
            dsCompleted.exists || dsAlreadyImported.exists || dsSkipped.exists,
            "DS Audio import must reach a successful terminal state; retry is only valid for a real failure."
        )

        // Search is performed inside the folder. The fixture deliberately
        // accepts the parent ID while returning the same source-owned result,
        // which keeps the test focused on the UI search submission path.
        // The UIKit catalog owns a native UISearchController. Keep this
        // assertion scoped to the catalog page so a global Library search
        // control can never mask a missing catalog search field.
        let searchField = app.searchFields[
            "onlineSources.detail.bvt.dsaudio.searchField"
        ].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 15))
        searchField.tap()
        searchField.typeText(dsAudioTitle)
        let keyboardSearch = app.keyboards.buttons["Search"].firstMatch
        if keyboardSearch.waitForExistence(timeout: 3) {
            keyboardSearch.tap()
        } else {
            let keyboardReturn = app.keyboards.buttons["return"].firstMatch
            if keyboardReturn.exists {
                keyboardReturn.tap()
            }
        }
        XCTAssertTrue(app.staticTexts[dsAudioFile].waitForExistence(timeout: 15))

        // Revoke only DS Audio from Settings. The source remains configured,
        // but entering it again must present its source-level disclosure.
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio Subfolder")
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio Folder")
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio")
        returnToOnlineSourceList(in: app)
        revokeOnlineSourcePrivacyInSettings(sourceID: "bvt.dsaudio", in: app)
        XCTAssertTrue(app.staticTexts["BVT DS Audio"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["BVT Google Drive"].waitForExistence(timeout: 10))

        openOnlineSource(named: "BVT DS Audio", in: app)
        let dsPrivacySheet = app.descendants(matching: .any)[
            "onlineSources.source.bvt.dsaudio.privacy.sheet"
        ].firstMatch
        XCTAssertTrue(dsPrivacySheet.waitForExistence(timeout: 15))
        let closePrivacy = button(
            identifier: "onlineSources.sourcePrivacy.close",
            labels: ["Close", "关闭", "Cancel", "取消"],
            in: app
        )
        XCTAssertTrue(closePrivacy.waitForExistence(timeout: 10))
        closePrivacy.tap()
        XCTAssertTrue(dsPrivacySheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons["onlineSources.add"].firstMatch.waitForExistence(timeout: 10),
            "Cancelling source consent must remain on the UIKit Online Sources root."
        )

        // Google Drive: the seeded second instance gets an independent
        // disclosure and can be authorized, browsed, and downloaded.
        openOnlineSource(named: "BVT Google Drive", in: app)
        acceptOnlineSourcePrivacy(sourceID: "bvt.google-drive", in: app)
        enableOnlineSource(sourceID: "bvt.google-drive", in: app)

        let authorizeGoogleDrive = app.buttons[
            "onlineSources.source.bvt.google-drive.googleDrive.authorize"
        ].firstMatch
        XCTAssertTrue(authorizeGoogleDrive.waitForExistence(timeout: 10))
        authorizeGoogleDrive.tap()
        XCTAssertTrue(app.staticTexts["Google Drive 已授权"].waitForExistence(timeout: 15))

        let googleFolder = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.google-drive.item.bvt-folder.open"
        ].firstMatch
        XCTAssertTrue(googleFolder.waitForExistence(timeout: 20))
        XCTAssertTrue(scrollToAnyElement(googleFolder, in: app, maximumSwipes: 8))
        googleFolder.tap()
        let googleSubfolder = app.collectionViews["onlineSources.catalog.list"].cells[
            "onlineSources.detail.bvt.google-drive.item.bvt-subfolder.open"
        ].firstMatch
        XCTAssertTrue(googleSubfolder.waitForExistence(timeout: 15))
        XCTAssertTrue(scrollToAnyElement(googleSubfolder, in: app, maximumSwipes: 8))
        XCTAssertTrue(googleSubfolder.isHittable)
        XCTAssertTrue(googleSubfolder.isEnabled)
        googleSubfolder.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertTrue(app.staticTexts["BVT Google Drive Tone"].waitForExistence(timeout: 15))

        XCTAssertFalse(
            app.buttons["onlineSources.detail.bvt.google-drive.catalog.back"].exists,
            "Google Drive catalog must use the system NavigationStack back button."
        )
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT Google Drive Folder")
        XCTAssertTrue(googleSubfolder.waitForExistence(timeout: 15))
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT Google Drive")
        XCTAssertTrue(googleFolder.waitForExistence(timeout: 15))
        googleFolder.tap()
        XCTAssertTrue(googleSubfolder.waitForExistence(timeout: 15))
        XCTAssertTrue(scrollToAnyElement(googleSubfolder, in: app, maximumSwipes: 8))
        googleSubfolder.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertTrue(app.staticTexts["BVT Google Drive Tone"].waitForExistence(timeout: 15))

        let googleDownload = app.buttons[
            "onlineSources.detail.bvt.google-drive.item.bvt-audio.downloadAndImport"
        ].firstMatch
        XCTAssertTrue(googleDownload.waitForExistence(timeout: 10))
        googleDownload.tap()
        let googleCompleted = app.descendants(matching: .any)[
            "onlineSources.detail.bvt.google-drive.item.bvt-audio.completed"
        ].firstMatch
        let googleAlreadyImported = app.descendants(matching: .any)[
            "onlineSources.detail.bvt.google-drive.item.bvt-audio.alreadyImported"
        ].firstMatch
        let googleSkipped = app.descendants(matching: .any)[
            "onlineSources.detail.bvt.google-drive.item.bvt-audio.skipped"
        ].firstMatch
        let googleRetry = app.buttons[
            "onlineSources.detail.bvt.google-drive.item.bvt-audio.retryDownload"
        ].firstMatch
        let googleImportDeadline = Date().addingTimeInterval(45)
        while Date() < googleImportDeadline
            && !googleCompleted.exists
            && !googleAlreadyImported.exists
            && !googleSkipped.exists
            && !googleRetry.exists {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(
            googleCompleted.exists || googleAlreadyImported.exists || googleSkipped.exists,
            "Google Drive import must reach a successful terminal state; a retry state indicates a real download/import failure."
        )

        returnToOnlineSourceList(in: app)

        // The imported DS Audio media must be visible through the existing
        // local library path, proving that online downloads do not create a
        // second playback/library pipeline.
        tapTab("Library", in: app)
        openLibrarySection("Songs", in: app)
        XCTAssertTrue(app.staticTexts[dsAudioTitle].waitForExistence(timeout: 30))

        // Application-level revocation disables every online source while
        // retaining the configured source rows and already imported media.
        tapTab("Settings", in: app)
        waitForSettingsForm(in: app)
        let privacyEntry = app.descendants(matching: .any)["settings.privacy"].firstMatch
        XCTAssertTrue(scrollToElement(privacyEntry, in: app, maximumSwipes: 16))
        privacyEntry.tap()

        let applicationRevoke = app.buttons[
            "settings.privacy.application.revoke"
        ].firstMatch
        XCTAssertTrue(scrollToAnyElement(applicationRevoke, in: app, maximumSwipes: 16))
        applicationRevoke.tap()
        let applicationRevokeConfirm = app.buttons[
            "settings.privacy.application.revoke.confirm"
        ].firstMatch
        XCTAssertTrue(applicationRevokeConfirm.waitForExistence(timeout: 5))
        applicationRevokeConfirm.tap()
        XCTAssertTrue(
            app.buttons["settings.privacy.application.accept"].firstMatch
                .waitForExistence(timeout: 15)
        )

        tapTab("Online Sources", in: app)
        XCTAssertTrue(
            applicationPrivacySheet.waitForExistence(timeout: 15),
            "Revoking the application privacy agreement must present the disclosure again on the next Online Sources visit."
        )
        XCTAssertTrue(
            app.buttons["onlineSources.applicationPrivacy.confirm"].firstMatch
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["BVT DS Audio"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["BVT Google Drive"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testOnlineSourceCatalogDimensionsPaginateAndSort() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-online-sources",
            "--bvt-reset-online-sources",
            "--bvt-reset-user-interface-preferences",
        ]
        app.launch()

        assertMainTabs(in: app)
        tapTab("Online Sources", in: app)

        let applicationPrivacySheet = app.descendants(matching: .any)[
            "onlineSources.applicationPrivacy.sheet"
        ].firstMatch
        XCTAssertTrue(applicationPrivacySheet.waitForExistence(timeout: 15))
        let applicationPrivacyConfirm = app.buttons[
            "onlineSources.applicationPrivacy.confirm"
        ].firstMatch
        XCTAssertTrue(applicationPrivacyConfirm.waitForExistence(timeout: 5))
        applicationPrivacyConfirm.tap()
        XCTAssertTrue(applicationPrivacySheet.waitForNonExistence(timeout: 10))

        enableOnlineSourcesService(in: app)
        openOnlineSource(named: "BVT DS Audio", in: app)
        acceptOnlineSourcePrivacy(sourceID: "bvt.dsaudio", in: app)
        enableOnlineSource(sourceID: "bvt.dsaudio", in: app)

        let catalog = app.collectionViews["onlineSources.catalog.list"].firstMatch
        XCTAssertTrue(catalog.waitForExistence(timeout: 15))

        let albumCategory = catalog.cells[
            "onlineSources.detail.bvt.dsaudio.category.albums"
        ].firstMatch
        XCTAssertTrue(albumCategory.waitForExistence(timeout: 15))
        albumCategory.tap()

        let albumSort = app.navigationBars.buttons[
            "onlineSources.detail.bvt.dsaudio.sort"
        ].firstMatch
        XCTAssertTrue(albumSort.waitForExistence(timeout: 10))
        let albumDescending = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS[c] 'Descending' OR label CONTAINS[c] '降序'"
            )
        ).firstMatch
        albumSort.tap()
        XCTAssertTrue(
            albumDescending.waitForExistence(timeout: 5),
            "The catalog sort menu must expose a descending option."
        )
        albumDescending.tap()

        XCTAssertTrue(
            catalog.cells[
                "onlineSources.detail.bvt.dsaudio.item.bvt-album-84.open"
            ].firstMatch.waitForExistence(timeout: 20),
            "Changing sort must reload the first page in the selected order."
        )
        let lastSortedAlbum = catalog.cells[
            "onlineSources.detail.bvt.dsaudio.item.bvt-album.open"
        ].firstMatch
        XCTAssertTrue(
            scrollToAnyElement(lastSortedAlbum, in: app, maximumSwipes: 20),
            "The sorted album catalog must expose its later page."
        )
        XCTAssertTrue(lastSortedAlbum.waitForExistence(timeout: 20))
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio")

        let artistCategory = catalog.cells[
            "onlineSources.detail.bvt.dsaudio.category.artists"
        ].firstMatch
        XCTAssertTrue(artistCategory.waitForExistence(timeout: 15))
        artistCategory.tap()
        XCTAssertTrue(
            catalog.cells[
                "onlineSources.detail.bvt.dsaudio.item.bvt-artist.open"
            ].firstMatch.waitForExistence(timeout: 15)
        )
        let lastArtist = catalog.cells[
            "onlineSources.detail.bvt.dsaudio.item.bvt-artist-84.open"
        ].firstMatch
        XCTAssertTrue(
            scrollToAnyElement(lastArtist, in: app, maximumSwipes: 20),
            "The artist catalog must expose its later page."
        )
        XCTAssertTrue(lastArtist.waitForExistence(timeout: 20))
        tapSystemNavigationBack(in: app, expectedPreviousTitle: "BVT DS Audio")

        let allMusicCategory = catalog.cells[
            "onlineSources.detail.bvt.dsaudio.category.allMusic"
        ].firstMatch
        XCTAssertTrue(allMusicCategory.waitForExistence(timeout: 15))
        allMusicCategory.tap()
        let firstAllMusicItem = app.staticTexts["BVT DS Audio Tone"].firstMatch
        XCTAssertTrue(
            scrollToAnyElement(firstAllMusicItem, in: app, maximumSwipes: 20),
            "The all-music catalog must render audio rows with their titles."
        )
        let lastAllMusicItem = app.staticTexts["BVT DS Audio Tone 84"].firstMatch
        XCTAssertTrue(
            scrollToAnyElement(lastAllMusicItem, in: app, maximumSwipes: 20),
            "The all-music catalog must expose its later page."
        )
        XCTAssertTrue(lastAllMusicItem.waitForExistence(timeout: 20))
    }

    @MainActor
    func testLiveDSAudioBrowseAndImportIfEnabled() throws {
#if !LIVE_DSAUDIO
        guard ProcessInfo.processInfo.environment["MUSICFREE_LIVE_DSAUDIO"] == "1" else {
            throw XCTSkip("Set MUSICFREE_LIVE_DSAUDIO=1 to run against the logged-in DSM source.")
        }
#endif

        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()

        assertMainTabs(in: app)
        tapTab("Online Sources", in: app)

        let dsAudioSource = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "onlineSources.source.dsAudio."
            )
        ).firstMatch
        guard dsAudioSource.waitForExistence(timeout: 20) else {
            throw XCTSkip(
                "No persisted real DS Audio source was found on this simulator; "
                    + "complete DSM login and source setup before running the live test."
            )
        }
        XCTAssertTrue(
            dsAudioSource.isHittable,
            "The persisted real DS Audio source must be enterable."
        )
        dsAudioSource.tap()

        let firstFolder = waitForLiveButton(
            withIdentifierSuffix: ".open",
            in: app,
            maximumSwipes: 12,
            timeout: 30
        )

        // Prove that Browse means folder navigation, not a flat one-shot list.
        if let firstFolder {
            firstFolder.tap()
            let catalogBack = app.navigationBars.buttons["BackButton"].firstMatch
            XCTAssertTrue(
                catalogBack.waitForExistence(timeout: 15),
                "Entering a DS Audio folder must expose the system navigation back action."
            )
            XCTAssertTrue(
                catalogBack.isHittable,
                "The system navigation back action must remain available from the navigation bar."
            )
            XCTAssertFalse(
                app.buttons.matching(
                    NSPredicate(format: "identifier ENDSWITH '.catalog.back'")
                ).firstMatch.exists,
                "The catalog must not add a second custom back button."
            )
            XCTAssertTrue(
                waitForLiveButton(
                    withIdentifierSuffix: ".open",
                    in: app,
                    maximumSwipes: 12,
                    timeout: 15
                ) != nil
                    || waitForLiveButton(
                        withIdentifierSuffix: ".downloadAndImport",
                        in: app,
                        maximumSwipes: 12,
                        timeout: 15
                    ) != nil,
                "The entered DS Audio folder must expose child content."
            )
            catalogBack.tap()
            XCTAssertTrue(
                waitForLiveButton(
                    withIdentifierSuffix: ".open",
                    in: app,
                    maximumSwipes: 12,
                    timeout: 15
                ) != nil
                    || waitForLiveButton(
                        withIdentifierSuffix: ".downloadAndImport",
                        in: app,
                        maximumSwipes: 12,
                        timeout: 15
                    ) != nil,
                "Returning from a DS Audio folder must restore the parent catalog."
            )
        } else {
            XCTAssertNotNil(
                waitForLiveButton(
                    withIdentifierSuffix: ".downloadAndImport",
                    in: app,
                    maximumSwipes: 12,
                    timeout: 10
                ),
                "DS Audio catalog did not expose a folder or audio file."
            )
        }

        // Exercise recursive discovery without waiting for an arbitrarily large
        // NAS folder to finish. Once at least one item is processed, cancel the
        // batch and prove that every active import control settles before the
        // test starts one bounded single-file import.
        guard let rootFolder = waitForLiveButton(
            withIdentifierSuffix: ".open",
            in: app,
            maximumSwipes: 12,
            timeout: 10
        ) else {
            XCTFail("The real DS Audio source must expose a folder for recursive import testing.")
            return
        }
        rootFolder.tap()
        guard let folderImport = waitForLiveButton(
            withIdentifierSuffix: ".downloadAndImportAll",
            in: app,
            maximumSwipes: 12,
            timeout: 10
        ) else {
            XCTFail("An entered DS Audio folder must expose a fixed recursive import action.")
            return
        }
        folderImport.tap()
        waitForLiveBatchImportProgressThenCancel(in: app, timeout: 120)

        guard let importedTitle = importFreshLiveDSAudioItem(in: app, maximumAttempts: 8) else {
            return
        }

        tapTab("Library", in: app)
        openLibrarySection("Songs", in: app)
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(
            tracks.waitForExistence(timeout: 30),
            "The local library must remain available after a real DS Audio import."
        )
        guard let importedRow = waitForLibraryTrack(
            titled: importedTitle,
            in: tracks,
            maximumSwipes: 40
        ) else {
            XCTFail("The newly imported DS Audio item is missing from the local library: \(importedTitle)")
            return
        }
        XCTAssertFalse(
            importedRow.label.range(
                of: #"^[0-9A-Fa-f-]{36}\.[A-Za-z0-9]+$"#,
                options: .regularExpression
            ) != nil,
            "The imported title must not expose an internal UUID staging filename."
        )
        importedRow.press(forDuration: 1.0)
        let details = app.buttons["View song details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()

        let detail = app.descendants(matching: .any)["library.trackDetail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15))
        let detailTitle = detail.descendants(matching: .any)[
            "library.trackDetail.title"
        ].firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(detailTitle.label, importedTitle)
        XCTAssertFalse(
            detailTitle.label.range(
                of: #"^[0-9A-Fa-f-]{36}\.[A-Za-z0-9]+$"#,
                options: .regularExpression
            ) != nil,
            "The DS Audio detail title must remain human readable after import."
        )
        XCTAssertTrue(
            detail.descendants(matching: .any)["library.trackDetail.artist"].firstMatch
                .waitForExistence(timeout: 15),
            "The real DS Audio import should retain catalog or embedded artist metadata."
        )
        XCTAssertTrue(
            detail.descendants(matching: .any)["library.trackDetail.album"].firstMatch
                .waitForExistence(timeout: 15),
            "The real DS Audio import should retain catalog or embedded album metadata."
        )
    }

    @MainActor
    private func createPlaylist(in app: XCUIApplication) {
        tapTab("Playlists", in: app)

        let playlistRow = app.cells.containing(
            .staticText,
            identifier: playlistName
        ).firstMatch
        if playlistRow.waitForExistence(timeout: 3) {
            XCTAssertFalse(app.staticTexts["Could not load playlist"].exists)
            return
        }

        let createButton = app.buttons["New playlist"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 10))
        createButton.tap()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(playlistName)
        app.buttons["Save"].tap()

        XCTAssertTrue(nameField.waitForNonExistence(timeout: 10))
        let detail = app.descendants(matching: .any)["playlists.detail"].firstMatch
        if detail.waitForExistence(timeout: 5) {
            let backButton = app.navigationBars.buttons["Playlists"].firstMatch
            XCTAssertTrue(backButton.waitForExistence(timeout: 5))
            backButton.tap()
        }
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Operation failed"].exists)
    }

    @MainActor
    private func changeStoragePreference(in app: XCUIApplication) -> String {
        tapTab("Settings", in: app)
        waitForSettingsForm(in: app)

        let storageMaintenance = app.descendants(matching: .any)[
            "settings.storage.maintenance"
        ].firstMatch
        XCTAssertTrue(scrollToElement(storageMaintenance, in: app))
        storageMaintenance.tap()
        let maintenanceForm = app.descendants(matching: .any)[
            "settings.storage.maintenance.form"
        ].firstMatch
        XCTAssertTrue(maintenanceForm.waitForExistence(timeout: 10))

        let pruningSwitch = app.switches["settings.storage.autoPrune"]
        XCTAssertTrue(scrollToElement(pruningSwitch, in: app))
        XCTAssertTrue(pruningSwitch.isEnabled, "The storage preference should remain editable after settings load.")
        let originalValue = String(describing: pruningSwitch.value ?? "")
        pruningSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()

        let changed = NSPredicate(format: "value != %@ AND enabled == true", originalValue)
        expectation(for: changed, evaluatedWith: pruningSwitch)
        waitForExpectations(timeout: 10)
        let changedValue = String(describing: pruningSwitch.value ?? "")
        return changedValue
    }

    @MainActor
    private func addSeededTrackToPlaylist(in app: XCUIApplication) {
        tapTab("Library", in: app)
        openLibrarySection("Songs", in: app)

        let track = app.staticTexts[trackTitle].firstMatch
        if !track.waitForExistence(timeout: 30) {
            app.descendants(matching: .any)["library.tracks"].firstMatch.swipeDown()
        }
        XCTAssertTrue(
            track.waitForExistence(timeout: 30),
            "The imported fixture must be available before testing playlist persistence."
        )

        let backButton = app.navigationBars.buttons["Library"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()
        tapTab("Playlists", in: app)

        let playlistRow = app.cells.containing(
            .staticText,
            identifier: playlistName
        ).firstMatch
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 10))
        playlistRow.tap()

        let detail = app.descendants(matching: .any)["playlists.detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        if detail.staticTexts[trackTitle].firstMatch.waitForExistence(timeout: 2) {
            return
        }

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'Add songs' AND enabled == true")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 15))
        addButton.tap()

        let addSheet = app.descendants(matching: .any)["playlists.addTracks"].firstMatch
        XCTAssertTrue(addSheet.waitForExistence(timeout: 10))
        let candidate = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'playlists.addTrack.' AND label CONTAINS %@ AND enabled == true",
                trackTitle
            )
        ).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        candidate.tap()

        let submitButton = app.buttons["playlists.addTracks.submit"].firstMatch
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        let submitEnabled = NSPredicate(format: "enabled == true")
        expectation(for: submitEnabled, evaluatedWith: submitButton)
        waitForExpectations(timeout: 5)
        submitButton.tap()
        XCTAssertTrue(addSheet.waitForNonExistence(timeout: 15))
        XCTAssertTrue(detail.staticTexts[trackTitle].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    private func playAndFavoriteSeededTrack(in app: XCUIApplication) {
        tapTab("Library", in: app)
        openLibrarySection("Songs", in: app)

        let track = app.staticTexts[trackTitle].firstMatch
        XCTAssertTrue(
            track.waitForExistence(timeout: 30),
            "The BVT fixture should be imported through the real Documents scan."
        )
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(tracks.waitForExistence(timeout: 5))
        let trackRow = tracks.cells.containing(.staticText, identifier: trackTitle).firstMatch
        XCTAssertTrue(trackRow.waitForExistence(timeout: 5))
        trackRow.tap()

        let miniPlayer = app.buttons["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(
            miniPlayer.staticTexts[trackTitle].waitForExistence(timeout: 15),
            "Directly selecting a song must refresh the Mini Player metadata."
        )
        miniPlayer.tap()

        let artworkSurface = app.descendants(matching: .any)[
            "player.nowPlaying.artwork"
        ].firstMatch
        XCTAssertTrue(
            artworkSurface.waitForExistence(timeout: 10),
            "Opening the Mini Player must start in the artwork surface."
        )
        XCTAssertTrue(app.staticTexts[trackTitle].firstMatch.waitForExistence(timeout: 10))
        let favoriteButton = app.buttons["Favorite"].firstMatch
        let unfavoriteButton = app.buttons["Remove from favorites"].firstMatch
        if favoriteButton.waitForExistence(timeout: 3) {
            favoriteButton.tap()
        }
        XCTAssertTrue(unfavoriteButton.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Playback failed"].exists)
    }

    @MainActor
    private func assertFavoritePersisted(in app: XCUIApplication) {
        tapTab("Library", in: app)
        openLibrarySection("Favorites", in: app)
        XCTAssertTrue(app.staticTexts[trackTitle].firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor
    private func assertPlaylistPersisted(in app: XCUIApplication) {
        tapTab("Playlists", in: app)
        let playlistRow = app.cells.containing(
            .staticText,
            identifier: playlistName
        ).firstMatch
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 10))
        playlistRow.tap()
        let detail = app.descendants(matching: .any)["playlists.detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCTAssertTrue(
            detail.staticTexts[trackTitle].firstMatch.waitForExistence(timeout: 10),
            "Playlist membership and ordering must survive application relaunch."
        )
        XCTAssertFalse(app.staticTexts["Could not load playlist"].exists)
    }

    @MainActor
    private func assertStoragePreferencePersisted(
        _ expectedValue: String,
        in app: XCUIApplication
    ) {
        tapTab("Settings", in: app)
        waitForSettingsForm(in: app)
        let storageMaintenance = app.descendants(matching: .any)[
            "settings.storage.maintenance"
        ].firstMatch
        XCTAssertTrue(scrollToElement(storageMaintenance, in: app))
        storageMaintenance.tap()
        let maintenanceForm = app.descendants(matching: .any)[
            "settings.storage.maintenance.form"
        ].firstMatch
        XCTAssertTrue(maintenanceForm.waitForExistence(timeout: 10))
        let pruningSwitch = app.switches["settings.storage.autoPrune"]
        XCTAssertTrue(scrollToElement(pruningSwitch, in: app))
        XCTAssertEqual(String(describing: pruningSwitch.value ?? ""), expectedValue)
    }

    @MainActor
    private func waitForSettingsForm(in app: XCUIApplication) {
        let settingsForm = app.descendants(matching: .any)["settings.form"]
        XCTAssertTrue(
            settingsForm.waitForExistence(timeout: 15),
            "The settings form should appear after settings finish loading."
        )
        XCTAssertFalse(app.staticTexts["Could not load settings"].exists)
    }

    @MainActor
    private func assertSeedWasIdempotent(in app: XCUIApplication) {
        tapTab("Library", in: app)
        let libraryBackButton = app.navigationBars.buttons["Library"].firstMatch
        if libraryBackButton.waitForExistence(timeout: 2) {
            libraryBackButton.tap()
        }
        openLibrarySection("Songs", in: app)
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(tracks.waitForExistence(timeout: 15))
        let trackRows = tracks.cells.containing(.staticText, identifier: trackTitle)
        XCTAssertEqual(trackRows.count, 1)
    }

    @MainActor
    private func tapTab(_ title: String, in app: XCUIApplication) {
        let nativeButton = app.tabBars.buttons[title].firstMatch
        let fallbackButton = app.descendants(matching: .any)["app.tabBar"]
            .firstMatch.buttons[title].firstMatch

        if nativeButton.exists, nativeButton.isHittable {
            nativeButton.tap()
            return
        }
        if fallbackButton.exists, fallbackButton.isHittable {
            fallbackButton.tap()
            return
        }

        for _ in 0..<4 {
            // Only use the system navigation-back control here. Selecting the
            // first toolbar button is unsafe on Online Sources because the
            // source-list root puts its Add action in that position.
            let backButton = app.navigationBars.buttons["BackButton"].firstMatch
            guard backButton.exists, backButton.isHittable else { break }
            backButton.tap()
            if nativeButton.waitForExistence(timeout: 2), nativeButton.isHittable {
                nativeButton.tap()
                return
            }
            if fallbackButton.exists, fallbackButton.isHittable {
                fallbackButton.tap()
                return
            }
        }

        let settingsForm = app.collectionViews["settings.form"].firstMatch
        if settingsForm.exists {
            for _ in 0..<8 {
                settingsForm.swipeDown()
                if nativeButton.exists, nativeButton.isHittable {
                    nativeButton.tap()
                    return
                }
                if fallbackButton.exists, fallbackButton.isHittable {
                    fallbackButton.tap()
                    return
                }
            }
        }

        let visibleCollection = app.collectionViews.firstMatch
        if visibleCollection.exists {
            for _ in 0..<4 {
                visibleCollection.swipeDown()
                if nativeButton.exists, nativeButton.isHittable {
                    nativeButton.tap()
                    return
                }
                if fallbackButton.exists, fallbackButton.isHittable {
                    fallbackButton.tap()
                    return
                }
            }
        }

        XCTFail(
            "Tab \(title) did not become hittable "
                + "(nativeExists: \(nativeButton.exists), "
                + "fallbackExists: \(fallbackButton.exists))."
        )
    }

    @MainActor
    private func openOnlineSource(named displayName: String, in app: XCUIApplication) {
        let label = app.staticTexts[displayName].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 15))
        XCTAssertTrue(label.isHittable, "Online source row is not hittable: \(displayName)")
        label.tap()
    }

    @MainActor
    private func button(
        identifier: String,
        labels: [String],
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR label IN %@",
                identifier,
                labels
            )
        ).firstMatch
    }

    @MainActor
    private func acceptOnlineSourcePrivacy(sourceID: String, in app: XCUIApplication) {
        let detail = app.descendants(matching: .any)[
            "onlineSources.detail.\(sourceID)"
        ].firstMatch
        let sheet = app.descendants(matching: .any)[
            "onlineSources.source.\(sourceID).privacy.sheet"
        ].firstMatch
        if !sheet.waitForExistence(timeout: 3) {
            XCTAssertTrue(
                detail.waitForExistence(timeout: 12),
                "The source must either request consent or open its already-consented UIKit detail."
            )
            return
        }
        let confirm = button(
            identifier: "onlineSources.source.\(sourceID).privacy.accept.confirm",
            labels: ["Agree", "同意"],
            in: app
        )
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15))
        XCTAssertTrue(
            detail.waitForExistence(timeout: 15),
            "Accepting source privacy must finish the UIKit push before the next cross-tab action."
        )
    }

    @MainActor
    private func enableOnlineSource(sourceID: String, in app: XCUIApplication) {
        openOnlineSourceAvailabilitySettings(in: app)
        let toggle = app.switches[
            "settings.import.onlineSource.\(sourceID).enabled"
        ].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertTrue(toggle.isEnabled, "Online source setting is still gated: \(sourceID)")
        if !isOnValue(toggle.value) {
            toggle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)
            ).tap()
        }
        waitForOnValue(on: toggle, timeout: 10)
        tapTab("Online Sources", in: app)
    }

    @MainActor
    private func enableOnlineSourcesService(in app: XCUIApplication) {
        openOnlineSourceAvailabilitySettings(in: app)
        let toggle = app.switches["settings.import.onlineSources.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertTrue(toggle.isEnabled, "The application privacy agreement should unlock the online-source switch.")
        if !isOnValue(toggle.value) {
            toggle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)
            ).tap()
        }
        waitForOnValue(on: toggle, timeout: 10)
        tapTab("Online Sources", in: app)
    }

    @MainActor
    private func openOnlineSourceAvailabilitySettings(in app: XCUIApplication) {
        tapTab("Settings", in: app)
        let onlineSourcesToggle = app.descendants(matching: .any)[
            "settings.import.onlineSources.toggle"
        ].firstMatch
        if onlineSourcesToggle.waitForExistence(timeout: 2) {
            return
        }

        waitForSettingsForm(in: app)
        let entry = app.descendants(matching: .any)[
            "settings.import.onlineSourceAvailability.entry"
        ].firstMatch
        XCTAssertTrue(scrollToElement(entry, in: app, maximumSwipes: 16))
        entry.tap()
        XCTAssertTrue(
            onlineSourcesToggle.waitForExistence(timeout: 15),
            "Online-source availability must be reachable from Import and Library."
        )
    }

    @MainActor
    private func openPrivacySettings(in app: XCUIApplication) {
        tapTab("Settings", in: app)
        let privacyEntry = app.descendants(matching: .any)[
            "settings.privacy"
        ].firstMatch
        if privacyEntry.waitForExistence(timeout: 2) {
            return
        }

        waitForSettingsForm(in: app)
        XCTAssertTrue(scrollToElement(privacyEntry, in: app, maximumSwipes: 16))
        privacyEntry.tap()
        let privacyAccept = app.buttons["settings.privacy.application.accept"].firstMatch
        let privacyRevoke = app.buttons["settings.privacy.application.revoke"].firstMatch
        XCTAssertTrue(
            waitForEither(privacyAccept, privacyRevoke, timeout: 15),
            "Privacy settings must remain reachable for agreement management."
        )
    }

    @MainActor
    private func revokeOnlineSourcePrivacyInSettings(
        sourceID: String,
        in app: XCUIApplication
    ) {
        openPrivacySettings(in: app)
        let privacyRow = app.descendants(matching: .any)[
            "settings.privacy.onlineSource.\(sourceID).privacy"
        ].firstMatch
        XCTAssertTrue(
            scrollToElement(privacyRow, in: app, maximumSwipes: 16),
            "The source privacy detail row must be reachable in the independent settings section."
        )
        privacyRow.tap()

        let revoke = app.buttons[
            "settings.privacy.onlineSource.\(sourceID).revoke"
        ].firstMatch
        XCTAssertTrue(
            scrollToElement(revoke, in: app, maximumSwipes: 16),
            "The source privacy revoke action must be reachable in the independent settings section."
        )
        revoke.tap()
        let confirm = app.buttons[
            "settings.privacy.onlineSource.\(sourceID).revoke.confirm"
        ].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        tapTab("Online Sources", in: app)
    }

    @MainActor
    private func tapSystemNavigationBack(
        in app: XCUIApplication,
        expectedPreviousTitle: String
    ) {
        // A native searchable navigation bar owns the leading control while
        // its search context is active. Exit that context first, then use the
        // system NavigationStack back action.
        let cancelSearch = app.buttons.matching(
            NSPredicate(format: "label == 'Cancel' OR label == '取消'")
        ).firstMatch
        if cancelSearch.waitForExistence(timeout: 2) {
            // On iOS 26 the searchable drawer can report the system Cancel
            // button as temporarily non-hittable while the keyboard is
            // dismissing. Tapping its own coordinate still exercises the
            // same native control and lets NavigationStack expose its back
            // button on the next run-loop turn.
            cancelSearch.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }

        let backButton = app.navigationBars.buttons["BackButton"].firstMatch
        if backButton.waitForExistence(timeout: 10) {
            if backButton.isHittable {
                backButton.tap()
            } else {
                backButton.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).tap()
            }
            return
        }

        let titledBackButton = app.navigationBars.buttons[expectedPreviousTitle].firstMatch
        XCTAssertTrue(
            titledBackButton.waitForExistence(timeout: 5),
            "The system navigation bar must expose a back action to \(expectedPreviousTitle)."
        )
        if titledBackButton.isHittable {
            titledBackButton.tap()
        } else {
            // iOS 26.5 can keep the native back button non-hittable while the
            // searchable navigation bar settles. Its coordinate still targets
            // the same system control and avoids falling back to app content.
            titledBackButton.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).tap()
        }
    }

    @MainActor
    private func isOnValue(_ value: Any?) -> Bool {
        switch String(describing: value ?? "") {
        case "1", "true", "True", "on", "On", "ON", "已开启":
            return true
        default:
            return false
        }
    }

    @MainActor
    private func waitForOnValue(
        on element: XCUIElement,
        timeout: TimeInterval
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return self.isOnValue(element.value)
            },
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected \(element.identifier) to be on, actual value: \(String(describing: element.value))."
        )
    }

    @MainActor
    private func returnToOnlineSourceList(in app: XCUIApplication) {
        for _ in 0..<8 {
            if app.buttons["onlineSources.add"].waitForExistence(timeout: 2) {
                return
            }
            let backButton = app.navigationBars.buttons["BackButton"].firstMatch
            if backButton.waitForExistence(timeout: 2), backButton.isHittable {
                backButton.tap()
                continue
            }
            let titledBackButton = app.navigationBars.buttons["Online Sources"].firstMatch
            if titledBackButton.waitForExistence(timeout: 2), titledBackButton.isHittable {
                titledBackButton.tap()
                continue
            }
            break
        }
        XCTAssertTrue(
            app.buttons["onlineSources.add"].firstMatch.waitForExistence(timeout: 10)
        )
    }

    @MainActor
    private func waitForValue(
        _ expectedValue: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected \(element.identifier) to have value \(expectedValue), "
                + "actual value: \(String(describing: element.value))."
        )
    }

    @MainActor
    private func waitForEither(
        _ first: XCUIElement,
        _ second: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if first.exists || second.exists {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return first.exists || second.exists
    }

    @MainActor
    private func scrollToAnyElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int
    ) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable {
            return true
        }
        let collection = app.collectionViews.firstMatch
        for _ in 0..<maximumSwipes {
            if collection.exists {
                collection.swipeUp()
            } else {
                app.swipeUp()
            }
            if element.waitForExistence(timeout: 1), element.isHittable {
                return true
            }
        }
        return false
    }

    @MainActor
    private func waitForLiveButton(
        withIdentifierSuffix suffix: String,
        in app: XCUIApplication,
        maximumSwipes: Int,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let predicate = NSPredicate(format: "identifier ENDSWITH %@", suffix)
        while Date() < deadline {
            let buttons = app.buttons.matching(predicate).allElementsBoundByIndex
            if let button = buttons.first(where: {
                $0.exists && $0.isEnabled && $0.isHittable
            }) {
                return button
            }

            let collection = app.collectionViews.firstMatch
            if collection.exists {
                collection.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        return nil
    }

    @MainActor
    private func waitForLiveBatchImportProgressThenCancel(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let progressPredicate = NSPredicate(format: "identifier ENDSWITH '.importProgress'")
        let failedIdentifierPredicate = NSPredicate(
            format: "identifier ENDSWITH '.importFailed'"
        )
        let progress = app.descendants(matching: .any).matching(progressPredicate).firstMatch
        XCTAssertTrue(
            progress.waitForExistence(timeout: 30),
            "Recursive DS Audio import must publish progress."
        )

        var didProcessItem = false
        while Date() < deadline {
            let progressDescription = [
                progress.label,
                String(describing: progress.value ?? ""),
            ].joined(separator: " ")
            if progressDescription.range(
                of: #"[1-9][0-9]*/[1-9][0-9]*"#,
                options: .regularExpression
            ) != nil {
                didProcessItem = true
                break
            }
            if app.descendants(matching: .any)
                .matching(failedIdentifierPredicate).firstMatch.exists {
                XCTFail("Recursive DS Audio import reported a failure.")
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        let currentDirectoryCancel = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '.cancelImport'")
        ).firstMatch
        let inlineCancel = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '.cancelImport'")
        ).firstMatch
        guard didProcessItem else {
            if waitForEither(currentDirectoryCancel, inlineCancel, timeout: 5) {
                let cancel = currentDirectoryCancel.exists
                    ? currentDirectoryCancel
                    : inlineCancel
                if cancel.isHittable {
                    cancel.tap()
                }
            }
            XCTFail(
                "Recursive DS Audio import did not publish non-zero progress within \(timeout) seconds."
            )
            return
        }

        XCTAssertTrue(
            waitForEither(currentDirectoryCancel, inlineCancel, timeout: 15),
            "A running recursive DS Audio import must expose cancellation."
        )
        let cancel = currentDirectoryCancel.exists ? currentDirectoryCancel : inlineCancel
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()

        let restart = app.buttons.matching(
            NSPredicate(
                format: "identifier ENDSWITH '.downloadAndImportAll'"
            )
        ).firstMatch
        XCTAssertTrue(
            restart.waitForExistence(timeout: 20),
            "Cancelling a recursive import must restore the current-directory import action."
        )
        let activeCancel = app.buttons.matching(
            NSPredicate(
                format: "identifier ENDSWITH '.cancelDownload' OR identifier ENDSWITH '.cancelImport'"
            )
        ).firstMatch
        XCTAssertTrue(
            activeCancel.waitForNonExistence(timeout: 20),
            "Cancelling a recursive import must stop every active download/import control."
        )
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.75))
            XCTAssertFalse(
                activeCancel.exists,
                "A cancelled recursive import must not restart an active child task."
            )
        }
    }

    @MainActor
    private func importFreshLiveDSAudioItem(
        in app: XCUIApplication,
        maximumAttempts: Int
    ) -> String? {
        let collection = app.collectionViews.firstMatch
        var alreadyImportedCandidate: (title: String, actionIdentifier: String)?
        for _ in 0..<24 {
            if collection.exists {
                collection.swipeUp()
            } else {
                app.swipeUp()
            }
        }

        for attempt in 1...maximumAttempts {
            guard let download = waitForLiveButton(
                withIdentifierSuffix: ".downloadAndImport",
                in: app,
                maximumSwipes: 6,
                timeout: 20
            ) else {
                if let alreadyImportedCandidate {
                    let attachment = XCTAttachment(
                        string: "outcome=alreadyImported title=\(alreadyImportedCandidate.title) "
                            + "action=\(alreadyImportedCandidate.actionIdentifier)"
                    )
                    attachment.name = "Live DS Audio existing imported item"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    return alreadyImportedCandidate.title
                }
                XCTFail("The DS Audio folder exposed no remaining single-file import action.")
                return nil
            }
            let title = liveCatalogTitle(for: download, in: app)
            let actionSuffix = ".downloadAndImport"
            let actionIdentifier = download.identifier
            guard actionIdentifier.hasSuffix(actionSuffix) else {
                XCTFail("Unexpected DS Audio import identifier: \(actionIdentifier)")
                return nil
            }
            let itemPrefix = String(actionIdentifier.dropLast(actionSuffix.count))
            let completed = app.descendants(matching: .any)[
                "\(itemPrefix).completed"
            ].firstMatch
            let alreadyImported = app.descendants(matching: .any)[
                "\(itemPrefix).alreadyImported"
            ].firstMatch
            let failedOrCancelled = app.descendants(matching: .any)[
                "\(itemPrefix).retryDownload"
            ].firstMatch

            download.tap()
            let deadline = Date().addingTimeInterval(150)
            while Date() < deadline {
                if completed.exists {
                    let attachment = XCTAttachment(
                        string: "attempt=\(attempt) title=\(title) action=\(actionIdentifier)"
                    )
                    attachment.name = "Live DS Audio imported item"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    return title
                }
                if alreadyImported.exists {
                    if alreadyImportedCandidate == nil {
                        alreadyImportedCandidate = (title, actionIdentifier)
                    }
                    break
                }
                if failedOrCancelled.exists {
                    XCTFail("The selected DS Audio file failed to download or import: \(title)")
                    return nil
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            }
            if !alreadyImported.exists {
                XCTFail("The selected DS Audio file did not reach a terminal state: \(title)")
                return nil
            }
        }

        if let alreadyImportedCandidate {
            let attachment = XCTAttachment(
                string: "outcome=alreadyImported title=\(alreadyImportedCandidate.title) "
                    + "action=\(alreadyImportedCandidate.actionIdentifier)"
            )
            attachment.name = "Live DS Audio existing imported item"
            attachment.lifetime = .keepAlways
            add(attachment)
            return alreadyImportedCandidate.title
        }

        XCTFail(
            "Could not find a not-yet-imported DS Audio file after \(maximumAttempts) attempts."
        )
        return nil
    }

    @MainActor
    private func liveCatalogTitle(
        for download: XCUIElement,
        in app: XCUIApplication
    ) -> String {
        let value = String(describing: download.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value != "nil" {
            return value
        }

        let row = app.cells.containing(
            .button,
            identifier: download.identifier
        ).firstMatch
        if row.waitForExistence(timeout: 5),
           let displayName = row.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return URL(fileURLWithPath: displayName)
                .deletingPathExtension()
                .lastPathComponent
        }
        return URL(fileURLWithPath: download.identifier)
            .deletingPathExtension()
            .lastPathComponent
    }

    @MainActor
    private func waitForLibraryTrack(
        titled title: String,
        in tracks: XCUIElement,
        maximumSwipes: Int
    ) -> XCUIElement? {
        let predicate = NSPredicate(format: "label == %@", title)
        for _ in 0...maximumSwipes {
            let row = tracks.cells.matching(predicate).firstMatch
            if row.exists, row.isHittable {
                return row
            }
            tracks.swipeUp()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        return nil
    }

    @MainActor
    private func openLibrarySection(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.tap()
            return
        }

        let label = app.staticTexts[title].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap()
    }

    @MainActor
    private func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.waitForExistence(timeout: 2) && isFullyVisibleAboveTabBar(element, in: app) {
            return true
        }

        let scrollContainer = settingsScrollContainer(in: app)
        for _ in 0..<maximumSwipes {
            scrollContainer.swipeUp()
            if element.waitForExistence(timeout: 1) && isFullyVisibleAboveTabBar(element, in: app) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func isFullyVisibleAboveTabBar(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        let tabBar = tabBarElement(in: app)
        guard element.exists, element.isHittable, tabBar.exists else {
            return false
        }
        return !element.frame.isEmpty && element.frame.maxY <= tabBar.frame.minY
    }

    @MainActor
    private func tabBarElement(in app: XCUIApplication) -> XCUIElement {
        let nativeTabBar = app.tabBars.firstMatch
        return nativeTabBar.exists
            ? nativeTabBar
            : app.descendants(matching: .any)["app.tabBar"].firstMatch
    }

    @MainActor
    private func settingsScrollContainer(in app: XCUIApplication) -> XCUIElement {
        let settingsForm = app.collectionViews["settings.form"].firstMatch
        return settingsForm.waitForExistence(timeout: 2) ? settingsForm : app
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
