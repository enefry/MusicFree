import XCTest
import UIKit

final class MusicFreeFeatureLoadingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Several visual and large-history scenarios intentionally exercise
        // more than the default 40-second XCTest allowance.
        executionTimeAllowance = 900
    }

    @MainActor
    func testPlaylistAndSettingsTabsLoadConfiguredContent() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()

        let playlistTab = tabButton("Playlists", in: app)
        XCTAssertTrue(playlistTab.waitForExistence(timeout: 5))
        playlistTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["playlists.list"].firstMatch
                .waitForExistence(timeout: 5),
            "The configured playlist service should render its list screen."
        )
        XCTAssertFalse(app.staticTexts["Could not load playlist"].exists)

        let settingsTab = tabButton("Settings", in: app)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.form"].waitForExistence(timeout: 15),
            "The configured settings service should render the settings form."
        )
        XCTAssertFalse(app.staticTexts["Could not load settings"].exists)
    }

    @MainActor
    func testUIKitShellAppliesLanguageAndAppearanceChangesImmediately() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        app.launch()

        let root = app.descendants(matching: .any)["app.root"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 15))
        XCTAssertEqual(
            root.value as? String,
            "language=en;appearance=dark"
        )

        tabButton("Settings", in: app).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.form"].firstMatch
                .waitForExistence(timeout: 15)
        )

        let appearancePicker = app.buttons["settings.appearance"].firstMatch
        XCTAssertTrue(appearancePicker.waitForExistence(timeout: 5))
        appearancePicker.tap()
        XCTAssertTrue(app.buttons["Light"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Light"].firstMatch.tap()

        let lightAppearance = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "language=en;appearance=light"
            ),
            object: root
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [lightAppearance], timeout: 10),
            .completed,
            "Changing the Settings appearance must update the UIKit root immediately."
        )

        let languagePicker = app.buttons["settings.language"].firstMatch
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 10))
        languagePicker.tap()
        XCTAssertTrue(app.buttons["中文"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["中文"].firstMatch.tap()

        let chineseLanguage = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "language=zh-Hans;appearance=light"
            ),
            object: root
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [chineseLanguage], timeout: 10),
            .completed,
            "Changing the Settings language must rebuild the UIKit navigation labels immediately."
        )
        XCTAssertTrue(tabButton("资料库", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(tabButton("播放列表", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(tabButton("在线源", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(tabButton("设置", in: app).waitForExistence(timeout: 10))
        attachScreenshot(named: "settings-language-appearance-live-update")
    }

    @MainActor
    func testMetadataEnrichmentScanStartsAndCancels() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--bvt-seed-audio", "--bvt-seed-layout-library"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15))
        let settingsTab = tabBar.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["settings.form"].waitForExistence(timeout: 15)
        )

        let debugReset = app.descendants(matching: .any)[
            "settings.debug.resetAllPrivacy"
        ].firstMatch
        XCTAssertTrue(
            scrollToElement(debugReset, in: app, maximumSwipes: 12),
            "Debug builds must expose the privacy reset action."
        )
        debugReset.tap()
        scrollSettingsToTop(in: app)

        let metadataEntry = app.descendants(matching: .any)[
            "settings.import.metadataEnrichment.entry"
        ].firstMatch
        XCTAssertTrue(
            scrollToElement(metadataEntry, in: app, maximumSwipes: 12),
            "The metadata enrichment entry should be reachable in Settings."
        )
        metadataEntry.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["settings.import.metadata.section"]
                .firstMatch
                .waitForExistence(timeout: 5),
            "The metadata enrichment page should expose a Metadata section."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.import.lyrics.section"]
                .firstMatch
                .waitForExistence(timeout: 5),
            "The metadata enrichment page should expose a Lyrics section."
        )

        let privacyDisclosure = app.descendants(matching: .any)[
            "settings.privacyDisclosure"
        ].firstMatch
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings.privacyDisclosure.application"
            ].firstMatch.waitForExistence(timeout: 10),
            "Opening the Provider settings page must request the application policy first."
        )
        app.buttons["settings.privacyDisclosure.accept"].firstMatch.tap()
        XCTAssertFalse(
            privacyDisclosure.waitForExistence(timeout: 2),
            "Accepting the application policy should keep the Provider settings page open."
        )

        let musicBrainzToggle = app.switches[
            "settings.import.metadataProvider.musicBrainz.enabled"
        ].firstMatch
        XCTAssertTrue(musicBrainzToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(musicBrainzToggle.value as? String, "0")
        musicBrainzToggle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings.privacyDisclosure.provider.musicBrainz"
            ].firstMatch.waitForExistence(timeout: 10),
            "The first Provider activation must request only that Provider's disclosure."
        )
        app.buttons["settings.privacyDisclosure.accept"].firstMatch.tap()

        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '1'"),
            object: musicBrainzToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabledExpectation], timeout: 15),
            .completed,
            "Accepting both disclosures should enable only the selected Provider."
        )

        let scanButton = app.buttons["settings.import.musicKitScan"].firstMatch
        XCTAssertTrue(
            scrollToElement(scanButton, in: app, maximumSwipes: 8),
            "The metadata scan action should be available when a provider is enabled."
        )
        scanButton.tap()

        let progress = app.staticTexts["settings.import.musicKitProgress"].firstMatch
        XCTAssertTrue(
            progress.waitForExistence(timeout: 10),
            "Starting a metadata scan should immediately update the nested page."
        )

        let cancelButton = app.buttons["settings.import.musicKitCancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
            "Cancelling a metadata scan should restore the scan action."
        )
        XCTAssertFalse(cancelButton.exists)
    }

    @MainActor
    func testProviderPrivacyDeclineKeepsProviderDisabled() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()

        let settingsTab = tabButton("Settings", in: app)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()
        let form = app.descendants(matching: .any)["settings.form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 15))

        let debugReset = app.descendants(matching: .any)[
            "settings.debug.resetAllPrivacy"
        ].firstMatch
        XCTAssertTrue(scrollToElement(debugReset, in: app, maximumSwipes: 12))
        debugReset.tap()
        scrollSettingsToTop(in: app)

        let metadataEntry = app.descendants(matching: .any)[
            "settings.import.metadataEnrichment.entry"
        ].firstMatch
        XCTAssertTrue(scrollToElement(metadataEntry, in: app, maximumSwipes: 12))
        metadataEntry.tap()

        let musicBrainzToggle = app.switches[
            "settings.import.metadataProvider.musicBrainz.enabled"
        ].firstMatch
        XCTAssertTrue(musicBrainzToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings.privacyDisclosure.application"
            ].firstMatch.waitForExistence(timeout: 10)
        )
        app.buttons["settings.privacyDisclosure.accept"].firstMatch.tap()
        musicBrainzToggle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings.privacyDisclosure.provider.musicBrainz"
            ].firstMatch.waitForExistence(timeout: 10)
        )
        app.buttons["settings.privacyDisclosure.decline"].firstMatch.tap()

        let disabledExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '0'"),
            object: musicBrainzToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [disabledExpectation], timeout: 10),
            .completed,
            "Declining a Provider disclosure must leave that Provider disabled."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.import.metadata.section"]
                .firstMatch.exists,
            "Declining a Provider disclosure must keep the settings page open."
        )
    }

    @MainActor
    func testApplicationPrivacyDeclineDismissesProviderPage() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()

        let settingsTab = tabButton("Settings", in: app)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()
        let form = app.descendants(matching: .any)["settings.form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 15))

        let debugReset = app.descendants(matching: .any)[
            "settings.debug.resetAllPrivacy"
        ].firstMatch
        XCTAssertTrue(scrollToElement(debugReset, in: app, maximumSwipes: 12))
        debugReset.tap()
        scrollSettingsToTop(in: app)

        let metadataEntry = app.descendants(matching: .any)[
            "settings.import.metadataEnrichment.entry"
        ].firstMatch
        XCTAssertTrue(scrollToElement(metadataEntry, in: app, maximumSwipes: 12))
        metadataEntry.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings.privacyDisclosure.application"
            ].firstMatch.waitForExistence(timeout: 10)
        )
        app.buttons["settings.privacyDisclosure.decline"].firstMatch.tap()

        XCTAssertTrue(
            scrollToElement(metadataEntry, in: app, maximumSwipes: 12),
            "Declining the application policy should return to Settings."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["settings.import.metadata.section"]
                .firstMatch.exists,
            "Declining the application policy should dismiss the Provider page."
        )
    }

    @MainActor
    func testAppleMusicLayoutReviewScreenshots() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--bvt-seed-audio", "-AppleInterfaceStyle", "Dark"]
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app, selectForPlayback: true)
        XCTAssertTrue(
            app.staticTexts["BVT Artist"].firstMatch.waitForExistence(timeout: 15),
            "Recently added albums should show the album artist."
        )
        attachScreenshot(named: "01-library-home")

        captureLibraryPage(
            title: "Albums",
            identifier: "library.albums",
            detailTitle: "BVT Album",
            detailIdentifier: "library.collectionDetail",
            expectedListSubtitle: "BVT Artist",
            expectedDetailSubtitle: "BVT Artist",
            expectedHeaderArtist: "BVT Artist",
            expectedHeaderYear: "2026",
            expectsAlbumHeroLayout: true,
            screenshotName: "02-albums",
            detailScreenshotName: "03-album-detail",
            in: app
        )
        captureLibraryPage(
            title: "Artists",
            identifier: "library.artists",
            detailTitle: "BVT Artist",
            detailIdentifier: "library.artistDetail",
            expectsArtistAlbumGrid: true,
            screenshotName: "04-artists",
            detailScreenshotName: "05-artist-detail",
            in: app
        )
        captureLibraryPage(
            title: "Genres",
            identifier: "library.genres",
            detailTitle: "BVT Genre",
            detailIdentifier: "library.collectionDetail",
            expectedDetailSubtitle: "BVT Artist",
            screenshotName: "06-genres",
            detailScreenshotName: "07-genre-detail",
            in: app
        )
        captureLibraryPage(
            title: "Folders",
            identifier: "library.folders",
            detailTitle: nil,
            detailIdentifier: nil,
            screenshotName: "08-folders",
            detailScreenshotName: nil,
            in: app
        )

        openLibrarySection("Songs", in: app)
        let track = app.staticTexts["BVT Tone"].firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 30))
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let trackWithArtistSubtitle = tracks.cells.matching(
            NSPredicate(format: "value == %@", "BVT Artist")
        ).firstMatch
        XCTAssertTrue(
            trackWithArtistSubtitle.waitForExistence(timeout: 15),
            "The songs page should show the song artist as its subtitle."
        )
        attachScreenshot(named: "09-songs")
        openTrackDetailFromMenu(in: app, assertQueueActions: false)
        assertTrackDetailMetadata(in: app)
        attachScreenshot(named: "10-track-detail")
    }

    @MainActor
    func testLibraryHomeSearchShowsAlbumsAndSongsAndSongListHasNoSearch() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-layout-library",
            "-AppleInterfaceStyle",
            "Dark",
            "-musicfree.language",
            "en"
        ]
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        openLibrarySection("Songs", in: app)
        let seededSong = app.collectionViews["library.tracks.collection"].cells.matching(
            NSPredicate(format: "label == %@", "Layout Song 01")
        ).firstMatch
        XCTAssertTrue(
            seededSong.waitForExistence(timeout: 120),
            "The seeded layout library must finish importing before search is exercised."
        )
        backTo("Library", in: app)

        let nativeSearchTab = app.descendants(matching: .any)[
            "app.tab.librarySearch"
        ].firstMatch
        XCTAssertTrue(
            nativeSearchTab.waitForExistence(timeout: 15),
            "Compact layout should expose the system UISearchTab."
        )
        nativeSearchTab.tap()
        let searchField = app.searchFields["library.home.search"].firstMatch
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 15),
            "Library home should own the single local-library search field."
        )
        enterSearchTextReliably("Layout", in: searchField, app: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["library.search.scope"].firstMatch
                .waitForExistence(timeout: 10),
            "Search should expose the Top Results, Albums, and Songs filter."
        )
        let firstAlbum = app.staticTexts["Layout Album 01"].firstMatch
        let firstSong = app.staticTexts["Layout Song 01"].firstMatch
        XCTAssertTrue(
            firstAlbum.waitForExistence(timeout: 30),
            "Top Results should include matching albums."
        )
        XCTAssertTrue(
            firstSong.waitForExistence(timeout: 30),
            "Top Results should include matching songs."
        )
        XCTAssertLessThan(
            firstAlbum.frame.minY,
            firstSong.frame.minY,
            "Top Results should place albums before songs."
        )
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'library.search.track.options.'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Search results should keep the native song actions menu."
        )
        attachScreenshot(named: "library-home-search-results")

        let songsScope = app.buttons["library.search.scope.2"].firstMatch
        XCTAssertTrue(songsScope.waitForExistence(timeout: 5))
        songsScope.tap()
        XCTAssertTrue(firstSong.waitForExistence(timeout: 5))
        XCTAssertFalse(firstAlbum.exists, "Songs filtering should hide album matches.")

        let albumsScope = app.buttons["library.search.scope.1"].firstMatch
        XCTAssertTrue(albumsScope.waitForExistence(timeout: 5))
        albumsScope.tap()
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 5))
        XCTAssertFalse(firstSong.exists, "Albums filtering should hide song matches.")

        let cancel = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Cancel", "Close"])
        ).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        openLibrarySection("Songs", in: app)
        XCTAssertFalse(
            app.searchFields.matching(
                NSPredicate(format: "identifier BEGINSWITH 'library.tracks.search'")
            ).firstMatch.exists,
            "Songs should no longer expose a separate search field."
        )
    }

    @MainActor
    func testLibraryTrackLongPressShowsNativeContextActions() {
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(tracks.waitForExistence(timeout: 15))
        XCTAssertFalse(
            app.descendants(matching: .any)["library.tracks.edit"].exists,
            "Songs must not expose an Edit entry to start deletion selection."
        )

        let trackRow = tracks.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'library.track.play.'")
        ).firstMatch
        XCTAssertTrue(
            trackRow.waitForExistence(timeout: 15),
            "The songs page must expose at least one row for long-press actions."
        )
        trackRow.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 1.0)

        let favorite = app.buttons.matching(
            NSPredicate(format: "label == 'Favorite' OR label == 'Remove from favorites'")
        ).firstMatch
        XCTAssertTrue(
            favorite.waitForExistence(timeout: 5),
            "Long press must expose the native favorite action."
        )
        let share = app.buttons["Share"].firstMatch
        XCTAssertTrue(
            share.waitForExistence(timeout: 5),
            "Long press must expose the native share action."
        )
        let delete = app.buttons.matching(
            NSPredicate(format: "label == 'Delete' OR label == 'Delete song'")
        ).firstMatch
        XCTAssertTrue(
            delete.waitForExistence(timeout: 5),
            "Long press must expose the native destructive delete action."
        )
        XCTAssertEqual(
            favorite.frame.midY,
            share.frame.midY,
            accuracy: 5,
            "Favorite and Share must be in the compact first action row."
        )
        XCTAssertGreaterThan(
            delete.frame.midY,
            favorite.frame.midY + 40,
            "Apple Music keeps Delete in a separate destructive section below the normal actions."
        )
        assertTrackQueueMenuActions(in: app)
        attachScreenshot(named: "library-native-context-actions")

        // The visible ellipsis and row long press must expose the same action
        // model. A migration regression previously restored one entry point
        // while leaving the other without a menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.12)).tap()
        let moreButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'library.track.options.'")
        ).firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label == 'Favorite' OR label == 'Remove from favorites'")
            ).firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Share"].firstMatch.waitForExistence(timeout: 5))
        assertTrackQueueMenuActions(in: app)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label == 'Delete' OR label == 'Delete song'")
            ).firstMatch.waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testLibraryCollectionViewsKeepStableColumnsAndTail() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-audio",
            "--bvt-seed-layout-library",
            "-AppleInterfaceStyle",
            "Dark",
            "-musicfree.language",
            "en"
        ]
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        let pages: [(
            title: String,
            identifier: String,
            itemPrefix: String,
            tailLabel: String,
            isGrid: Bool
        )] = [
            ("Albums", "library.albums", "library.album.open.", "Layout Album 08", true),
            ("Artists", "library.artists", "library.artist.open.", "Layout Artist 08", false),
            ("Genres", "library.genres", "library.genre.open.", "Layout Genre 08", false),
            ("Folders", "library.folders", "library.folder.open.", "Layout Folder 08", false),
            ("Songs", "library.tracks", "library.track.play.", "Layout Song 08", false)
        ]

        for page in pages {
            openLibrarySection(page.title, in: app)
            let content = app.descendants(matching: .any)[page.identifier].firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 20))
            assertCollectionPage(
                content,
                itemPrefix: page.itemPrefix,
                tailLabel: page.tailLabel,
                isGrid: page.isGrid,
                screenshotName: page.title.lowercased(),
                in: app
            )
            backTo("Library", in: app)
        }
    }

    @MainActor
    func testLibraryAlbumsExposeNoAlbumCollection() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-audio",
            "--bvt-seed-no-album",
            "-AppleInterfaceStyle",
            "Dark",
            "-musicfree.language",
            "en"
        ]
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Albums", in: app)

        let albums = app.descendants(matching: .any)["library.albums"].firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 20))
        let noAlbum = albums.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.album.noAlbum.open")
        ).firstMatch
        XCTAssertTrue(
            noAlbum.waitForExistence(timeout: 20),
            "Albums must expose a dedicated collection for tracks without an album."
        )
        noAlbum.tap()

        let detail = app.descendants(matching: .any)["library.collectionDetail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15))
        let noAlbumHeader = detail.descendants(matching: .any)[
            "library.collection.header.title"
        ].firstMatch
        XCTAssertTrue(
            noAlbumHeader.waitForExistence(timeout: 10),
            "The no-album detail must expose a stable collection header title."
        )
        XCTAssertEqual(
            noAlbumHeader.label,
            "No Album",
            "The no-album collection title must be localized in English."
        )
        XCTAssertTrue(
            detail.cells.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "library.collection.track.play.")
            ).firstMatch.waitForExistence(timeout: 10),
            "The no-album collection must keep its tracks visible in detail."
        )
    }

    @MainActor
    func testArtistDetailUsesStableTwoColumnAlbumGrid() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "--bvt-seed-artist-albums",
            "-AppleInterfaceStyle",
            "Dark",
            "-musicfree.language",
            "en"
        ]
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        openLibrarySection("Artists", in: app)
        let artists = app.descendants(matching: .any)["library.artists"].firstMatch
        XCTAssertTrue(artists.waitForExistence(timeout: 20))

        let artist = artists.cells.matching(
            NSPredicate(format: "label == %@", "BVT Multi Album Artist")
        ).firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 20))
        artist.tap()

        let detail = app.descendants(matching: .any)["library.artistDetail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15))
        let albumGrid = detail.descendants(matching: .any)["library.artist.albums"].firstMatch
        XCTAssertTrue(albumGrid.waitForExistence(timeout: 15))

        let albumCards = detail.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.artist.album.")
        )
        let first = albumCards.element(boundBy: 0)
        let second = albumCards.element(boundBy: 1)
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(second.waitForExistence(timeout: 15))
        XCTAssertLessThan(
            first.frame.width,
            albumGrid.frame.width * 0.7,
            "Artist albums must render as two columns instead of full-width cards."
        )
        XCTAssertEqual(
            first.frame.midY,
            second.frame.midY,
            accuracy: 12,
            "Two artist album cards should align in the same row."
        )
        XCTAssertLessThan(
            first.frame.maxX,
            second.frame.minX,
            "Artist album cards should have a stable horizontal gap."
        )
        XCTAssertTrue(detail.buttons["BVT First Album"].firstMatch.exists)
        XCTAssertTrue(detail.buttons["BVT Second Album"].firstMatch.exists)
    }

    @MainActor
    func testAppleMusicPlaylistScreenshots() {
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(tabButton("Playlists", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app, selectForPlayback: true)
        tabButton("Playlists", in: app).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["playlists.list"].firstMatch
                .waitForExistence(timeout: 10)
        )
        resetReviewPlaylist(in: app)
        attachScreenshot(named: "11-playlists")

        openReviewPlaylist(in: app)
        let emptyDetail = app.descendants(matching: .any)["playlists.detail"].firstMatch
        XCTAssertTrue(emptyDetail.waitForExistence(timeout: 10))
        XCTAssertTrue(
            emptyDetail.descendants(matching: .any)["playlists.detail.header"]
                .firstMatch.waitForExistence(timeout: 30)
        )
        XCTAssertTrue(
            emptyDetail.staticTexts["0 tracks"].firstMatch.waitForExistence(timeout: 30),
            "The empty playlist detail should settle after candidate tracks reload."
        )
        attachScreenshot(named: "12-playlist-detail")

        let addButton = app.buttons.matching(
            NSPredicate(format: "label == 'Add songs' AND enabled == true")
        ).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()

        let addSheet = app.descendants(matching: .any)["playlists.addTracks"].firstMatch
        XCTAssertTrue(addSheet.waitForExistence(timeout: 10))
        XCTAssertTrue(
            addSheet.staticTexts["BVT Artist"].firstMatch.waitForExistence(timeout: 15),
            "The add-to-playlist sheet should show the song artist as its subtitle."
        )
        XCTAssertFalse(
            addSheet.staticTexts["0:30"].exists,
            "The add-to-playlist sheet should not use duration as the song subtitle."
        )
        attachScreenshot(named: "13-playlist-add-tracks")

        let candidate = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'playlists.addTrack.' AND label CONTAINS 'BVT Tone' AND enabled == true"
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

        let filledDetail = app.descendants(matching: .any)["playlists.detail"].firstMatch
        let filledHeader = filledDetail.descendants(matching: .any)["playlists.detail.header"].firstMatch
        XCTAssertTrue(filledHeader.waitForExistence(timeout: 10))
        XCTAssertTrue(filledDetail.staticTexts["BVT Tone"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            filledDetail.staticTexts["BVT Artist"].firstMatch.waitForExistence(timeout: 10),
            "Playlist detail should show the song artist as its subtitle."
        )
        XCTAssertFalse(
            filledDetail.staticTexts["0:30"].exists,
            "Playlist detail should not use duration as the song subtitle."
        )
        attachScreenshot(named: "14-playlist-detail-filled")

        let editButton = app.buttons["Edit playlist"].firstMatch
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        editButton.tap()
        let doneButton = app.buttons["Finish editing"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        attachScreenshot(named: "15-playlist-edit")
        doneButton.tap()
    }

    @MainActor
    func testAppleMusicSettingsScreenshots() {
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(tabButton("Settings", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app, selectForPlayback: true)
        tabButton("Settings", in: app).tap()
        let form = app.descendants(matching: .any)["settings.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        attachScreenshot(named: "16-settings-playback")

        let storageMaintenance = app.descendants(matching: .any)[
            "settings.storage.maintenance"
        ].firstMatch
        XCTAssertTrue(scrollToElement(storageMaintenance, in: app))
        let privacyReset = app.buttons["settings.debug.resetAllPrivacy"].firstMatch
        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(
            privacyReset.waitForExistence(timeout: 2) && privacyReset.isHittable,
            "Collapsing the iOS 26 Mini Player inline must not leave the Settings Form clipped above an empty black band."
        )
        XCTAssertLessThanOrEqual(
            privacyReset.frame.maxY,
            miniPlayer.frame.minY,
            "The final visible Settings row must remain above the inline Mini Player."
        )
        attachScreenshot(named: "17-settings-storage")
        storageMaintenance.tap()
        let maintenanceForm = app.descendants(matching: .any)[
            "settings.storage.maintenance.form"
        ].firstMatch
        XCTAssertTrue(maintenanceForm.waitForExistence(timeout: 10))

        let storagePolicyControls = [
            app.switches["settings.storage.autoPrune"].firstMatch,
            app.sliders["settings.storage.cacheLimit"].firstMatch,
            app.steppers["settings.storage.stagingRetention"].firstMatch
        ]
        for control in storagePolicyControls {
            XCTAssertTrue(scrollToElement(control, in: app))
        }

        let maintenanceButtons = [
            app.buttons["settings.storage.clearStaging"].firstMatch,
            app.buttons["settings.storage.repairRemovals"].firstMatch,
            app.buttons["settings.storage.clearQuarantine"].firstMatch
        ]
        for button in maintenanceButtons {
            XCTAssertTrue(scrollToElement(button, in: app))
            XCTAssertTrue(app.staticTexts["Details"].firstMatch.exists)
            XCTAssertTrue(app.staticTexts["What to expect"].firstMatch.exists)
        }
        backTo("Settings", in: app)
        XCTAssertTrue(form.waitForExistence(timeout: 10))

        let about = app.descendants(matching: .any)["settings.about"].firstMatch
        XCTAssertTrue(scrollToElement(about, in: app))
        about.tap()
        XCTAssertTrue(app.staticTexts["About and licenses"].waitForExistence(timeout: 10))
        attachScreenshot(named: "18-settings-about")
        backTo("Settings", in: app)
        XCTAssertTrue(form.waitForExistence(timeout: 10))

        let diagnostics = app.descendants(matching: .any)["settings.diagnostics"].firstMatch
        XCTAssertTrue(scrollToElement(diagnostics, in: app))
        diagnostics.tap()
        XCTAssertTrue(app.staticTexts["Diagnostics"].waitForExistence(timeout: 10))
        attachScreenshot(named: "19-settings-diagnostics")
    }

    @MainActor
    func testAppleMusicPlayerScreenshots() {
        let longTrackTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        // Keep this visual acceptance test deterministic. Playback history is
        // persistent across simulator launches; old runs can leave hundreds
        // of rows above the current anchor and make a short history reveal
        // look like a broken scroll position.
        let app = reviewApp(resetPlaybackHistory: true)
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer {
            device.orientation = .portrait
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 5),
            "Compact iOS 26 navigation must be the system TabView tab bar."
        )
        openLibrarySection("Songs", in: app)
        let track = app.staticTexts[longTrackTitle].firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 30))
        ensureTimedLyrics(for: longTrackTitle, in: app)
        attachScreenshot(named: "20-songs")

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let playAllButton = tracks.buttons["Play"].firstMatch
        XCTAssertTrue(playAllButton.waitForExistence(timeout: 5))
        playAllButton.tap()
        let miniPlayer = app.descendants(matching: .any)["player.mini"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))

        let longTrackRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", longTrackTitle)
        ).firstMatch
        XCTAssertTrue(longTrackRow.waitForExistence(timeout: 5))
        longTrackRow.tap()
        XCTAssertTrue(
            miniPlayer.staticTexts[longTrackTitle].waitForExistence(timeout: 15),
            "Selecting the long-title queue entry must update the Mini Player before presentation."
        )
        let otherTrackRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", "BVT Tone")
        ).firstMatch
        XCTAssertTrue(otherTrackRow.waitForExistence(timeout: 5))
        otherTrackRow.tap()
        XCTAssertTrue(
            miniPlayer.staticTexts["BVT Tone"].waitForExistence(timeout: 15),
            "The fixture must switch away from the first song so Now Playing has a real history item."
        )
        longTrackRow.tap()
        XCTAssertTrue(
            miniPlayer.staticTexts[longTrackTitle].waitForExistence(timeout: 15),
            "Returning to the first song must refresh the current row and history."
        )
        attachScreenshot(named: "21-mini-player")
        // The compact iOS 26 TabView bottom-accessory wrapper can expose a
        // stale/invalid activation point for the aggregate `player.mini`
        // accessibility element even though its child content is hittable.
        // Tap the visible title child so the test exercises the same
        // presentation gesture without depending on that wrapper point.
        // Use the aggregate element's frame only to derive a coordinate. Its
        // accessibility activation point is invalid on this compact layout,
        // but XCTest can still synthesize a hit at the visible center.
        let miniPlayerButton = app.buttons["player.mini"].firstMatch
        XCTAssertTrue(
            miniPlayerButton.waitForExistence(timeout: 5),
            "The Mini Player presenting control must remain a concrete Button."
        )
        let miniPlayerTapPoint = miniPlayerButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.30, dy: 0.50)
        )
        miniPlayerTapPoint.tap()

        let artworkSurface = app.descendants(matching: .any)[
            "player.nowPlaying.artwork"
        ].firstMatch
        XCTAssertTrue(
            artworkSurface.waitForExistence(timeout: 10),
            "Opening the Mini Player must start in the artwork surface."
        )
        let artworkLoadedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Artwork loaded"),
            object: artworkSurface
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [artworkLoadedExpectation], timeout: 15),
            .completed,
            "The Apple Music visual comparison must use a loaded cover, not the placeholder."
        )
        XCTAssertTrue(app.buttons["Favorite"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["More actions"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Playback progress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Lyrics"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["AirPlay"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play queue"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.tables["player.nowPlaying.upperScroll"].firstMatch.exists,
            "The artwork surface must not create the queue table."
        )
        attachScreenshot(named: "22-now-playing-default")

        // REGRESSION GUARD: keep the fixture paused after the default-player
        // screenshot. The remaining queue/history checks intentionally take
        // longer than the seeded track; allowing playback to finish can remove
        // all upcoming entries and falsely disable queue sorting.
        if let pauseButton = app.buttons.matching(identifier: "Pause")
            .allElementsBoundByIndex
            .first(where: { $0.isHittable }) {
            pauseButton.tap()
        }

        let queueButton = app.buttons["player.queue.footer"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        queueButton.tap()

        XCTAssertTrue(
            app.staticTexts["Continue Playing"].waitForExistence(timeout: 10),
            "The regression fixture must include a visible Continue Playing row."
        )

        let queueScrollView = playerQueueScrollView(in: app)
        XCTAssertTrue(queueScrollView.waitForExistence(timeout: 10))
        XCTAssertFalse(queueScrollView.frame.isEmpty)
        XCTAssertGreaterThanOrEqual(queueScrollView.frame.minX, -1)
        XCTAssertLessThanOrEqual(queueScrollView.frame.maxX, app.frame.maxX + 1)
        let continuePlayingList = app.descendants(matching: .any)[
            "player.continuePlaying.list"
        ].firstMatch
        XCTAssertTrue(continuePlayingList.waitForExistence(timeout: 10))
        let currentQueueRow = app.descendants(matching: .any)[
            "player.nowPlaying.current"
        ].firstMatch
        XCTAssertTrue(
            currentQueueRow.waitForExistence(timeout: 10),
            "The queue surface must expose a distinct current-playing row."
        )
        XCTAssertLessThanOrEqual(
            currentQueueRow.frame.minY,
            queueScrollView.frame.minY + 120,
            "The queue must open with the current-playing row anchored near the top."
        )
        let historyHeading = app.descendants(matching: .any)[
            "player.nowPlaying.history.heading"
        ].firstMatch
        let historyRows = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@ AND identifier != %@",
                "player.nowPlaying.history.",
                "player.nowPlaying.history.clear",
                "player.nowPlaying.history.heading"
            )
        )
        // History is above the current anchor and is intentionally virtualized. The
        // heading and rows may not exist in the accessibility tree until the
        // user pulls the table down; checking existence
        // before that would turn the intended Apple Music behavior into a
        // false failure.
        XCTAssertFalse(
            isElementVisible(historyHeading, in: queueScrollView),
            "History should start above the current row and appear only after pulling down."
        )
        XCTAssertTrue(
            continuePlayingList.staticTexts["BVT Artist"].firstMatch
                .waitForExistence(timeout: 10),
            "Continue Playing rows should resolve artists from track relationships."
        )
        XCTAssertFalse(continuePlayingList.staticTexts["BVT Album"].exists)
        XCTAssertFalse(continuePlayingList.staticTexts["Local music"].exists)

        let modeControls = app.descendants(matching: .any)[
            "player.nowPlaying.modeControls"
        ].firstMatch
        XCTAssertTrue(modeControls.waitForExistence(timeout: 5))
        XCTAssertEqual(
            modeControls.buttons.count,
            4,
            "Queue mode controls should stay as one four-button group."
        )

        let nowPlayingTitle = app.staticTexts[longTrackTitle].firstMatch
        XCTAssertTrue(nowPlayingTitle.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(
            nowPlayingTitle.frame.minX,
            -1,
            "A long Now Playing title must not escape the leading screen edge."
        )
        XCTAssertLessThanOrEqual(
            nowPlayingTitle.frame.maxX,
            app.frame.maxX + 1,
            "A long Now Playing title must not expand the player beyond the screen width."
        )

        for label in ["Shuffle", "Repeat song", "Repeat queue"] {
            let control = app.buttons[label].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(
                control.frame.minX,
                -1,
                "\(label) must not be pushed beyond the leading screen edge."
            )
            XCTAssertLessThanOrEqual(
                control.frame.maxX,
                app.frame.maxX + 1,
                "\(label) must not be pushed beyond the trailing screen edge."
            )
        }
        attachScreenshot(named: "23-now-playing-queue")

        revealQueueHistory(historyHeading, in: queueScrollView)
        XCTAssertTrue(
            historyHeading.waitForExistence(timeout: 10),
            "Pulling down must materialize the History heading above the current row."
        )
        XCTAssertTrue(
            isElementVisible(historyHeading, in: queueScrollView),
            "Pulling down from the current row must reveal the History section."
        )
        XCTAssertGreaterThan(
            historyRows.count,
            0,
            "Switching tracks in the fixture must create at least one History row."
        )
        let visibleHistoryRow = historyRows.allElementsBoundByIndex.first {
            isElementHittable($0, in: queueScrollView)
        }
        XCTAssertNotNil(
            visibleHistoryRow,
            "History rows must be visible after the Apple Music-style pull-down."
        )
        attachScreenshot(named: "23-now-playing-history")

        if let pauseButton = app.buttons.matching(identifier: "Pause")
            .allElementsBoundByIndex.first(where: { $0.isHittable }) {
            pauseButton.tap()
        }

        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        let originalQueueButtonY = queueButton.frame.minY
        if queueScrollView.isHittable, !queueScrollView.frame.isEmpty {
            queueScrollView.swipeUp()
        }

        let pinnedQueueButton = app.buttons["player.queue.footer"].firstMatch
        XCTAssertTrue(pinnedQueueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(
            pinnedQueueButton.isHittable,
            "Playback controls must stay pinned while the Continue Playing list scrolls independently."
        )
        XCTAssertEqual(
            pinnedQueueButton.frame.minY,
            originalQueueButtonY,
            accuracy: 1,
            "Scrolling Continue Playing must not move the pinned playback controls."
        )

        let lyricsButton = app.buttons["Lyrics"].firstMatch
        XCTAssertTrue(lyricsButton.waitForExistence(timeout: 5))
        lyricsButton.tap()
        let embeddedLyricsScrollView = app.scrollViews[
            "player.nowPlaying.lyricsScroll"
        ].firstMatch
        let navigationLyricsScrollView = app.scrollViews["lyrics.scroll"].firstMatch
        let lyricsScrollView = embeddedLyricsScrollView.waitForExistence(timeout: 3)
            ? embeddedLyricsScrollView
            : navigationLyricsScrollView
        XCTAssertTrue(
            lyricsScrollView.waitForExistence(timeout: 15),
            "The seeded local LRC should render a lyrics scroll container."
        )
        XCTAssertFalse(
            app.tables["player.nowPlaying.upperScroll"].firstMatch.exists,
            "Switching to lyrics must replace the queue table."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["player.nowPlaying.lyrics.line.0"]
                .waitForExistence(timeout: 10)
        )
        attachScreenshot(named: "24-now-playing-lyrics")

        let lyricsReturnButton = app.buttons["player.lyrics.footer"].firstMatch
        XCTAssertTrue(lyricsReturnButton.waitForExistence(timeout: 5))
        lyricsReturnButton.tap()
        XCTAssertTrue(artworkSurface.waitForExistence(timeout: 5))

        device.orientation = .landscapeLeft
        let scrollingPlayer = app.scrollViews["player.nowPlaying.scroll"].firstMatch
        XCTAssertTrue(
            scrollingPlayer.waitForExistence(timeout: 5),
            "A short-height player must fall back to an outer scroll view."
        )

        let landscapeQueueButton = app.buttons["player.queue.footer"].firstMatch
        for _ in 0..<8 where !landscapeQueueButton.isHittable {
            swipeUpPastMediaSliders(in: scrollingPlayer)
        }
        XCTAssertTrue(
            landscapeQueueButton.isHittable,
            "The scrolling fallback must keep lower playback controls reachable."
        )
        XCTAssertLessThanOrEqual(
            landscapeQueueButton.frame.maxY,
            app.frame.maxY + 1,
            "The reachable footer control must remain inside the landscape viewport."
        )

        device.orientation = .portrait
        let restoredQueueButton = app.buttons["player.queue.footer"].firstMatch
        XCTAssertTrue(restoredQueueButton.waitForExistence(timeout: 5))
        restoredQueueButton.tap()
        XCTAssertTrue(
            app.staticTexts["Continue Playing"].waitForExistence(timeout: 10)
        )

        let moreButton = app.buttons["More actions"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()
        let manageQueueAction = app.buttons[
            "player.nowPlaying.actions.manageQueue"
        ].firstMatch
        XCTAssertTrue(
            manageQueueAction.waitForExistence(timeout: 10),
            "Full queue editing should remain behind the header menu."
        )
        manageQueueAction.tap()
        XCTAssertTrue(app.staticTexts["Play queue"].waitForExistence(timeout: 10))
        let queueList = app.descendants(matching: .any)["player.queue.list"].firstMatch
        XCTAssertTrue(queueList.waitForExistence(timeout: 10))
        XCTAssertTrue(
            queueList.staticTexts["BVT Artist"].firstMatch.waitForExistence(timeout: 10),
            "Queue rows should resolve artist names instead of exposing internal IDs."
        )
        XCTAssertFalse(queueList.staticTexts["BVT Album"].exists)
        XCTAssertFalse(queueList.staticTexts["Local music"].exists)
        let currentRow = app.descendants(matching: .any)["player.queue.current"].firstMatch
        XCTAssertTrue(currentRow.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            currentRow.frame.minY,
            queueList.frame.minY + 140,
            "The queue must initially anchor the current item near the top of its viewport."
        )

        let historySection = queueList.staticTexts["History"].firstMatch
        attachScreenshot(named: "23-queue")

        // XCTest can fail instead of returning false when a List header has no
        // activation point because it is above the current viewport.
        queueList.swipeDown()
        XCTAssertTrue(
            historySection.isHittable,
            "Pulling down from the current item should reveal playback history."
        )
        XCTAssertTrue(app.buttons["player.history.clear"].firstMatch.isHittable)
        attachScreenshot(named: "25-queue-history")

        let editQueueButton = app.buttons["player.queue.edit"].firstMatch
        XCTAssertTrue(editQueueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(editQueueButton.isEnabled)
        editQueueButton.tap()

        let doneEditingButton = app.buttons["player.queue.doneEditing"].firstMatch
        let cancelEditingButton = app.buttons["player.queue.cancelEditing"].firstMatch
        XCTAssertTrue(doneEditingButton.waitForExistence(timeout: 5))
        XCTAssertTrue(cancelEditingButton.waitForExistence(timeout: 5))
        XCTAssertTrue(queueList.exists)
        attachScreenshot(named: "26-queue-sorting")

        cancelEditingButton.tap()
        XCTAssertTrue(editQueueButton.waitForExistence(timeout: 5))
    }

    @MainActor
    func testNowPlayingPresentationStaysStableAcrossRepeatedTransitions() {
        let expectedTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(tracks.waitForExistence(timeout: 10))
        XCTAssertTrue(tracks.buttons["Play"].firstMatch.waitForExistence(timeout: 10))
        tracks.buttons["Play"].firstMatch.tap()

        let track = tracks.cells.matching(
            NSPredicate(format: "label == %@", expectedTitle)
        ).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()

        let miniPlayer = app.buttons["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(miniPlayer.staticTexts[expectedTitle].waitForExistence(timeout: 15))

        // REGRESSION GUARD: this test spends longer than the seeded 30-second
        // track while cycling through Artwork, Queue, Lyrics, and dismissal.
        // Pause the fixture before the first presentation so an automatic
        // track change cannot masquerade as a missing or clipped title.
        let pauseButton = app.buttons["Pause"].firstMatch
        XCTAssertTrue(
            pauseButton.waitForExistence(timeout: 5),
            "The transition fixture must expose a pause control before cycling."
        )
        pauseButton.tap()

        for cycle in 0..<3 {
            miniPlayer.tap()
            let artworkSurface = app.descendants(matching: .any)[
                "player.nowPlaying.artwork"
            ].firstMatch
            XCTAssertTrue(artworkSurface.waitForExistence(timeout: 10))

            let loadedArtwork = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Artwork loaded"),
                object: artworkSurface
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [loadedArtwork], timeout: 15),
                .completed,
                "Every repeated presentation must use the real cover before visual assertions."
            )
            assertNowPlayingPresentationFrameIsStable(
                expectedTitle: expectedTitle,
                artworkSurface: artworkSurface,
                surfaceIdentifier: "player.nowPlaying.artwork",
                in: app
            )
            attachScreenshot(named: "now-playing-regression-\(cycle)-artwork")

            let queueButton = app.buttons["player.queue.footer"].firstMatch
            XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
            queueButton.tap()
            let queueScroll = playerQueueScrollView(in: app)
            XCTAssertTrue(queueScroll.waitForExistence(timeout: 10))
            XCTAssertTrue(
                app.staticTexts["Continue Playing"].waitForExistence(timeout: 10)
            )
            assertNowPlayingPresentationFrameIsStable(
                expectedTitle: expectedTitle,
                surfaceIdentifier: "player.nowPlaying.current",
                in: app
            )
            attachScreenshot(named: "now-playing-regression-\(cycle)-queue")

            let lyricsButton = app.buttons["Lyrics"].firstMatch
            XCTAssertTrue(lyricsButton.waitForExistence(timeout: 5))
            lyricsButton.tap()
            let embeddedLyricsScrollView = app.scrollViews[
                "player.nowPlaying.lyricsScroll"
            ].firstMatch
            let navigationLyricsScrollView = app.scrollViews["lyrics.scroll"].firstMatch
            XCTAssertTrue(
                embeddedLyricsScrollView.waitForExistence(timeout: 3)
                    || navigationLyricsScrollView.waitForExistence(timeout: 15)
            )
            assertNowPlayingPresentationFrameIsStable(
                expectedTitle: expectedTitle,
                surfaceIdentifier: "player.nowPlaying.lyrics",
                in: app
            )
            attachScreenshot(named: "now-playing-regression-\(cycle)-lyrics")

            let artworkReturnButton = app.buttons["player.lyrics.footer"].firstMatch
            XCTAssertTrue(artworkReturnButton.waitForExistence(timeout: 5))
            artworkReturnButton.tap()
            XCTAssertTrue(artworkSurface.waitForExistence(timeout: 10))
            assertNowPlayingPresentationFrameIsStable(
                expectedTitle: expectedTitle,
                artworkSurface: artworkSurface,
                surfaceIdentifier: "player.nowPlaying.artwork",
                in: app
            )

            let nowPlaying = app.descendants(matching: .any)["player.nowPlaying"].firstMatch
            XCTAssertTrue(nowPlaying.waitForExistence(timeout: 5))
            let start = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.075)
            )
            let end = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)
            )
            start.press(forDuration: 0.08, thenDragTo: end)
            XCTAssertTrue(nowPlaying.waitForNonExistence(timeout: 5))
            XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testNowPlayingLargeHistoryScrollRemainsResponsive() {
        let currentTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let alternateTitle = "BVT Tone"
        let app = reviewApp(resetPlaybackHistory: true)
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(tracks.waitForExistence(timeout: 10))
        XCTAssertTrue(tracks.buttons["Play"].firstMatch.waitForExistence(timeout: 10))
        tracks.buttons["Play"].firstMatch.tap()

        let currentRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", currentTitle)
        ).firstMatch
        let alternateRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", alternateTitle)
        ).firstMatch
        XCTAssertTrue(currentRow.waitForExistence(timeout: 10))
        XCTAssertTrue(alternateRow.waitForExistence(timeout: 10))
        currentRow.tap()

        let miniPlayer = app.buttons["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(miniPlayer.staticTexts[currentTitle].waitForExistence(timeout: 15))

        // Each explicit play creates a separate session record. Generate more
        // rows than a phone viewport can hold so UITableView reuse and scrolling
        // are exercised with a real playback-history snapshot.
        for index in 0..<100 {
            let row = index.isMultiple(of: 2) ? alternateRow : currentRow
            let expectedTitle = index.isMultiple(of: 2) ? alternateTitle : currentTitle
            row.tap()
            // A rapid sequence of taps can cancel an in-flight playback
            // command before it records its session. Confirm each transition
            // before starting the next one, otherwise the test claims to
            // create 100 rows while the store contains only a fraction.
            XCTAssertTrue(
                miniPlayer.staticTexts[expectedTitle].waitForExistence(timeout: 5),
                "The app must remain responsive while building a large history."
            )
        }

        miniPlayer.tap()
        let artworkSurface = app.descendants(matching: .any)[
            "player.nowPlaying.artwork"
        ].firstMatch
        XCTAssertTrue(artworkSurface.waitForExistence(timeout: 10))
        let loadedArtwork = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Artwork loaded"),
            object: artworkSurface
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loadedArtwork], timeout: 15), .completed)

        let queueButton = app.buttons["player.queue.footer"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        queueButton.tap()
        let queueScroll = playerQueueScrollView(in: app)
        XCTAssertTrue(queueScroll.waitForExistence(timeout: 10))

        let currentQueueRow = app.descendants(matching: .any)[
            "player.nowPlaying.current"
        ].firstMatch
        XCTAssertTrue(currentQueueRow.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            currentQueueRow.frame.minY,
            queueScroll.frame.minY + 120,
            "Large-history queues must still open with the current row at the top."
        )

        // Use the stable product identifier instead of a label subscript. In
        // XCTest, staticTexts["History"] queries the accessibility identifier
        // and can miss the localized heading entirely. The heading is above
        // the current-playing anchor and lives in a UITableView, so a large
        // history is intentionally not materialized until the user scrolls it
        // into the viewport.
        let historyHeading = app.descendants(matching: .any)[
            "player.nowPlaying.history.heading"
        ].firstMatch

        // The oldest row is adjacent to the current anchor because the
        // repository returns history newest-first. Verify that near boundary
        // before moving all the way to the history header; otherwise the
        // upward pass can legitimately leave that row just above the viewport
        // while the current row is pinned at the bottom edge.
        let oldestHistoryRow = app.descendants(matching: .any)[
            "player.nowPlaying.history.oldest"
        ].firstMatch
        for _ in 0..<3 where !isElementVisible(oldestHistoryRow, in: queueScroll) {
            pullQueueDown(in: queueScroll)
        }
        XCTAssertTrue(
            isElementVisible(oldestHistoryRow, in: queueScroll),
            "Pulling down from the current row must reveal the oldest adjacent history row."
        )

        // A hundred history rows are intentionally above the current anchor.
        // Use page-sized system swipes here; short pulls can stop halfway
        // through a large table, where the heading is not materialized
        // yet and XCTest reports a false missing-element failure.
        let maximumHistoryRevealSwipes = 40
        for _ in 0..<maximumHistoryRevealSwipes {
            if isElementVisible(historyHeading, in: queueScroll) {
                break
            }
            queueScroll.swipeDown()
        }
        XCTAssertTrue(
            historyHeading.waitForExistence(timeout: 10),
            "Pulling down must materialize the History heading above the current row."
        )
        let historyCount = Int(historyHeading.value as? String ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(
            historyCount,
            80,
            "The large-history fixture must expose at least 80 historical sessions."
        )

        XCTAssertTrue(
            isElementVisible(historyHeading, in: queueScroll),
            "A large history must be reachable above the current-playing anchor."
        )

        // The newest row is adjacent to the History header. It proves that a
        // large lazy list can reach its opposite boundary after the initial
        // current-row anchor has been moved out of the viewport.
        let newestHistoryRow = app.descendants(matching: .any)[
            "player.nowPlaying.history.newest"
        ].firstMatch
        for _ in 0..<4 where !isElementVisible(newestHistoryRow, in: queueScroll) {
            queueScroll.swipeDown()
        }
        XCTAssertTrue(
            isElementVisible(newestHistoryRow, in: queueScroll),
            "Scrolling to the History header must materialize its newest row."
        )

        let endScrollStart = Date()
        // REGRESSION GUARD: traverse back to the current anchor with the
        // system scroll view. Native page swipes cover more of a large lazy
        // list per XCTest interaction than a short coordinate drag, so the
        // elapsed value reflects layout work instead of gesture overhead.
        // Stop as soon as the current row is visible. Continuing a fixed
        // number of swipes can move past the anchor into the queue tail and
        // remove the current row from UITableView's accessibility tree again.
        let maximumHistorySwipes = min(40, max(12, historyCount / 4 + 8))
        var returnedToCurrentAnchor = isElementVisible(currentQueueRow, in: queueScroll)
        for _ in 0..<maximumHistorySwipes where !returnedToCurrentAnchor {
            queueScroll.swipeUp()
            returnedToCurrentAnchor = isElementVisible(currentQueueRow, in: queueScroll)
        }
        XCTAssertTrue(
            returnedToCurrentAnchor,
            "Scrolling through a large history must return to the current-playing anchor."
        )

        // Keep the reach-to-oldest metric separate from the round-trip metric
        // below. Combining them makes a healthy list fail because of the
        // additional three pairs of verification gestures. Keep the sample
        // large enough to exercise repeated lazy-list traversal without
        // making the wall-clock assertion depend on eight XCTest gesture
        // round trips and their simulator idle waits.
        let endScrollElapsed = Date().timeIntervalSince(endScrollStart)
        let roundTripStart = Date()
        for _ in 0..<3 {
            pullQueueUp(in: queueScroll)
            pullQueueDown(in: queueScroll)
        }
        let roundTripElapsed = Date().timeIntervalSince(roundTripStart)
        XCTAssertLessThan(
            endScrollElapsed,
            35,
            "Large-history scrolling must reach the oldest row without a long layout stall."
        )
        XCTAssertLessThan(
            roundTripElapsed,
            20,
            "Large-history round-trip scrolling must remain responsive."
        )
        XCTAssertTrue(
            app.buttons["player.queue.footer"].firstMatch.isHittable,
            "Fixed playback controls must remain responsive after large-history scrolling."
        )
    }

    @MainActor
    func testMiniPlayerHorizontalSwipeChangesTrackWithoutOpeningPlayer() {
        let firstTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let playAllButton = tracks.buttons["Play"].firstMatch
        XCTAssertTrue(playAllButton.waitForExistence(timeout: 10))
        playAllButton.tap()

        let firstTrack = tracks.cells.matching(
            NSPredicate(format: "label == %@", firstTitle)
        ).firstMatch
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 10))
        let libraryRows = tracks.cells.allElementsBoundByIndex
        guard let firstTrackIndex = libraryRows.firstIndex(where: { $0.label == firstTitle }),
              firstTrackIndex + 1 < libraryRows.count else {
            XCTFail("The seeded library must expose a following track for MiniPlayer swipe validation.")
            return
        }
        let secondTitle = libraryRows[firstTrackIndex + 1].label
        XCTAssertFalse(secondTitle.isEmpty)
        firstTrack.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(miniPlayer.staticTexts[firstTitle].waitForExistence(timeout: 15))
        let nextControl = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Next track", "下一首")
        ).firstMatch
        XCTAssertTrue(
            nextControl.waitForExistence(timeout: 5),
            "The MiniPlayer must expose a Next track control."
        )
        XCTAssertTrue(
            nextControl.isEnabled,
            "The MiniPlayer next control must be enabled before swipe; frame=\(nextControl.frame)."
        )

        let partialDragStart = miniPlayer.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)
        )
        let partialDragEnd = miniPlayer.coordinate(
            withNormalizedOffset: CGVector(dx: 0.40, dy: 0.50)
        )
        partialDragStart.press(forDuration: 0.08, thenDragTo: partialDragEnd)
        XCTAssertTrue(
            miniPlayer.staticTexts[firstTitle].waitForExistence(timeout: 5),
            "Releasing before the activation distance must retract to the current track."
        )

        dragMiniPlayer(miniPlayer, from: 0.78, to: 0.22)
        XCTAssertTrue(
            miniPlayer.staticTexts[secondTitle].waitForExistence(timeout: 15),
            "Swiping left on the MiniPlayer must advance to the next track; swipeState=\(String(describing: miniPlayer.value))."
        )
        assertNowPlayingIsNotPresented(in: app)

        dragMiniPlayer(miniPlayer, from: 0.22, to: 0.78)
        XCTAssertTrue(
            miniPlayer.staticTexts[firstTitle].waitForExistence(timeout: 15),
            "Swiping right on the MiniPlayer must return to the previous track."
        )
        assertNowPlayingIsNotPresented(in: app)
    }

    @MainActor
    func testNowPlayingDismissGestureFollowsDragAndCloses() {
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let playAllButton = tracks.buttons["Play"].firstMatch
        XCTAssertTrue(playAllButton.waitForExistence(timeout: 10))
        playAllButton.tap()

        let track = tracks.cells.matching(
            NSPredicate(
                format: "label == %@",
                "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
            )
        ).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let nowPlaying = app.descendants(matching: .any)["player.nowPlaying"].firstMatch
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 10))

        // The system drag indicator is owned by the Sheet, so it is outside
        // the Now Playing accessibility element. Start from its screen edge
        // instead of routing the gesture through the inner player content.
        let shortDragStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.075)
        )
        let shortDragEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09)
        )
        shortDragStart.press(forDuration: 0.08, thenDragTo: shortDragEnd)
        XCTAssertTrue(
            nowPlaying.waitForExistence(timeout: 2),
            "A short downward drag should return the player to its resting position."
        )

        let longDragStart = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.075)
        )
        let longDragEnd = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)
        )
        longDragStart.press(forDuration: 0.08, thenDragTo: longDragEnd)

        XCTAssertTrue(
            nowPlaying.waitForNonExistence(timeout: 3),
            "A long downward drag should animate the player out before dismissing it."
        )
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: 5),
            "Dismissing Now Playing should return to the MiniPlayer."
        )
    }

    @MainActor
    func testNowPlayingBackdropIsTransparentDuringSystemDrag() {
        let currentTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(tracks.buttons["Play"].firstMatch.waitForExistence(timeout: 10))
        tracks.buttons["Play"].firstMatch.tap()

        let currentRow = tracks.cells.matching(
            NSPredicate(
                format: "label == %@",
                currentTitle
            )
        ).firstMatch
        XCTAssertTrue(currentRow.waitForExistence(timeout: 10))
        currentRow.tap()

        let miniPlayer = app.buttons["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let nowPlaying = app.descendants(matching: .any)["player.nowPlaying"].firstMatch
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 10))
        XCTAssertEqual(
            nowPlaying.value as? String,
            currentTitle,
            "Now Playing must expose the current item while the sheet is resting."
        )

        let start = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.075)
        )
        let end = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34)
        )
        // REGRESSION GATE: keep the native Sheet gesture on the test's main
        // actor. Calling XCUIScreen from a worker while this synchronous event
        // is in flight violates XCTest's UI isolation and can kill the test
        // runner, which hides the actual presentation result.
        start.press(
            forDuration: 0.08,
            thenDragTo: end,
            withVelocity: 500,
            thenHoldForDuration: 1.5
        )

        XCTAssertTrue(
            nowPlaying.waitForExistence(timeout: 5),
            "A partial system drag should settle back to Now Playing."
        )
        XCTAssertEqual(
            nowPlaying.value as? String,
            currentTitle,
            "After a cancelled drag, Now Playing must retain the current item."
        )
        // Keep a safe post-gesture attachment for failure diagnosis. The
        // actual mid-transition pixels are captured by the host-side
        // simulator check, because XCTest's synchronous gesture API does not
        // provide a safe main-actor callback while the touch is held.
        attachScreenshot(named: "now-playing-dismiss-after-partial-drag")
    }

    @MainActor
    func testPlaybackQueueSurvivesAppTerminationAndRelaunch() {
        let currentTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let upcomingTitle = "BVT Tone"
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let playAllButton = tracks.buttons["Play"].firstMatch
        XCTAssertTrue(playAllButton.waitForExistence(timeout: 10))
        playAllButton.tap()

        let currentTrack = tracks.cells.matching(
            NSPredicate(format: "label == %@", currentTitle)
        ).firstMatch
        XCTAssertTrue(currentTrack.waitForExistence(timeout: 10))
        currentTrack.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(miniPlayer.staticTexts[currentTitle].waitForExistence(timeout: 15))

        app.terminate()
        app.launch()

        let restoredMiniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(restoredMiniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(
            restoredMiniPlayer.staticTexts[currentTitle].waitForExistence(timeout: 15),
            "A cold launch must restore the paused current song."
        )
        restoredMiniPlayer.tap()

        let queueButton = app.buttons["player.queue.footer"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 10))
        queueButton.tap()

        let continuePlaying = app.descendants(matching: .any)[
            "player.continuePlaying.list"
        ].firstMatch
        XCTAssertTrue(
            continuePlaying.waitForExistence(timeout: 15),
            "A cold launch must keep the unplayed portion of the queue."
        )
        XCTAssertTrue(continuePlaying.staticTexts[upcomingTitle].waitForExistence(timeout: 10))

        XCTAssertTrue(
            playerQueueScrollView(in: app).waitForExistence(timeout: 10),
            "The restored queue surface should remain scrollable inside Now Playing."
        )
    }

    @MainActor
    func testLibraryTrackQueueActionsPreserveCurrentPlaybackAndUpdateQueue() {
        let currentTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let queuedTitle = "BVT Tone"
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        openLibrarySection("Songs", in: app)

        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(tracks.waitForExistence(timeout: 15))
        let playAllButton = tracks.buttons["Play"].firstMatch
        XCTAssertTrue(playAllButton.waitForExistence(timeout: 5))
        playAllButton.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        let currentRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", currentTitle)
        ).firstMatch
        XCTAssertTrue(currentRow.waitForExistence(timeout: 5))
        currentRow.tap()
        XCTAssertTrue(miniPlayer.staticTexts[currentTitle].waitForExistence(timeout: 15))

        invokeQueueMenuAction("Play next", for: queuedTitle, in: tracks, app: app)
        XCTAssertTrue(
            miniPlayer.staticTexts[currentTitle].waitForExistence(timeout: 5),
            "Inserting a next item must not replace the current song."
        )

        invokeQueueMenuAction("Add to queue", for: queuedTitle, in: tracks, app: app)
        XCTAssertTrue(
            miniPlayer.staticTexts[currentTitle].waitForExistence(timeout: 5),
            "Appending an item must not replace the current song."
        )

        miniPlayer.tap()
        let queueButton = app.buttons["player.queue.footer"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 10))
        queueButton.tap()
        let continuePlaying = app.descendants(matching: .any)[
            "player.continuePlaying.list"
        ].firstMatch
        XCTAssertTrue(continuePlaying.waitForExistence(timeout: 10))
        let queuedRows = continuePlaying.staticTexts.matching(identifier: queuedTitle)
        XCTAssertTrue(
            queuedRows.element(boundBy: 1).waitForExistence(timeout: 10),
            "Queue menu commands should add another occurrence without replacing the current song."
        )
    }

    @MainActor
    func testCollectionDetailQueueMenusEnqueueCompleteCollections() {
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)

        assertCollectionQueueMenu(
            sectionTitle: "Albums",
            contentIdentifier: "library.albums",
            collectionTitle: "BVT Album",
            detailIdentifier: "library.collectionDetail",
            menuIdentifier: "library.collection.menu",
            in: app
        )
        assertCollectionQueueMenu(
            sectionTitle: "Artists",
            contentIdentifier: "library.artists",
            collectionTitle: "BVT Artist",
            detailIdentifier: "library.artistDetail",
            menuIdentifier: "library.artistDetail.menu",
            in: app
        )
        assertCollectionQueueMenu(
            sectionTitle: "Genres",
            contentIdentifier: "library.genres",
            collectionTitle: "BVT Genre",
            detailIdentifier: "library.collectionDetail",
            menuIdentifier: "library.collection.menu",
            in: app
        )
    }

    @MainActor
    func testNowPlayingQueueScrollsWhenContentExceedsViewport() {
        let trackTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let alternateTitle = "BVT Tone"
        let app = reviewApp(resetPlaybackHistory: true)
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        openLibrarySection("Songs", in: app)
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let trackRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", trackTitle)
        ).firstMatch
        let alternateRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", alternateTitle)
        ).firstMatch
        XCTAssertTrue(trackRow.waitForExistence(timeout: 30))
        XCTAssertTrue(alternateRow.waitForExistence(timeout: 10))

        let playAllButton = tracks.buttons["Play"].firstMatch
        XCTAssertTrue(playAllButton.waitForExistence(timeout: 5))
        playAllButton.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        trackRow.tap()
        XCTAssertTrue(miniPlayer.staticTexts[trackTitle].waitForExistence(timeout: 15))
        alternateRow.tap()
        XCTAssertTrue(miniPlayer.staticTexts[alternateTitle].waitForExistence(timeout: 15))
        trackRow.tap()
        XCTAssertTrue(miniPlayer.staticTexts[trackTitle].waitForExistence(timeout: 15))
        miniPlayer.tap()

        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        guard let pauseButton = app.buttons.matching(identifier: "Pause")
            .allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("The visible Now Playing pause control must be hittable.")
            return
        }
        pauseButton.tap()

        let queueButton = app.buttons["player.queue.footer"].firstMatch
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        queueButton.tap()

        let moreButton = app.buttons["More actions"].firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        let queueScrollView = playerQueueScrollView(in: app)
        XCTAssertTrue(queueScrollView.waitForExistence(timeout: 10))

        let historyHeading = app.descendants(matching: .any)[
            "player.nowPlaying.history.heading"
        ].firstMatch
        revealQueueHistory(historyHeading, in: queueScrollView)
        XCTAssertTrue(
            historyHeading.waitForExistence(timeout: 10),
            "Pulling down from the current item must materialize the History heading."
        )
        XCTAssertTrue(
            isElementVisible(historyHeading, in: queueScrollView),
            "Pulling down from the current item must reveal playback history."
        )

        for _ in 0..<5 {
            if !moreButton.isHittable {
                bringQueueActionIntoView(moreButton, in: queueScrollView)
            }
            XCTAssertTrue(moreButton.isHittable)
            moreButton.tap()
            let enqueueButton = app.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Add to queue", "加入队列")
            ).firstMatch
            XCTAssertTrue(enqueueButton.waitForExistence(timeout: 5))
            enqueueButton.tap()
            XCTAssertTrue(enqueueButton.waitForNonExistence(timeout: 5))
        }

        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        let currentMoreButtonIdentifier = "player.nowPlaying.current.more"
        let currentMoreButton = app.buttons[currentMoreButtonIdentifier].firstMatch
        XCTAssertTrue(currentMoreButton.waitForExistence(timeout: 5))
        let originalCurrentMoreButtonY = currentMoreButton.frame.minY
        let originalQueueButtonY = queueButton.frame.minY
        var didScrollQueueContent = false

        for _ in 0..<3 {
            queueScrollView.swipeUp()
            let refreshedMoreButton = app.buttons[
                currentMoreButtonIdentifier
            ].firstMatch
            if !refreshedMoreButton.exists {
                didScrollQueueContent = true
                break
            }
            let refreshedFrame = refreshedMoreButton.frame
            if !refreshedFrame.isEmpty,
               refreshedFrame.minY < originalCurrentMoreButtonY - 40 {
                didScrollQueueContent = true
                break
            }
        }

        XCTAssertTrue(
            didScrollQueueContent,
            "Scrolling Continue Playing must move the upper player content."
        )
        XCTAssertEqual(
            queueButton.frame.minY,
            originalQueueButtonY,
            accuracy: 1,
            "Scrolling the queue must keep the playback controls pinned."
        )

        let progressSlider = app.sliders["Playback progress"].firstMatch
        XCTAssertTrue(
            progressSlider.waitForExistence(timeout: 5),
            "The fixed progress control must remain available while the queue scrolls."
        )
        let visibleQueueTexts = queueScrollView.staticTexts.allElementsBoundByIndex.filter {
            let textFrame = $0.frame
            return !textFrame.isEmpty && textFrame.intersects(queueScrollView.frame)
        }
        XCTAssertFalse(
            visibleQueueTexts.isEmpty,
            "Continue Playing must retain visible text after scrolling."
        )
        if let lowestVisibleQueueText = visibleQueueTexts.max(by: {
            $0.frame.maxY < $1.frame.maxY
        }) {
            XCTAssertLessThanOrEqual(
                lowestVisibleQueueText.frame.maxY,
                progressSlider.frame.minY - 8,
                "Queue text must remain above the fixed progress control instead of being blocked by it."
            )
        }
        attachScreenshot(named: "queue-after-scroll")
    }

    @MainActor
    private func reviewApp(resetPlaybackHistory: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--bvt-seed-audio",
            "-AppleInterfaceStyle",
            "Dark",
            "-musicfree.language",
            "en"
        ]
        if resetPlaybackHistory {
            app.launchArguments.append("--bvt-reset-playback-history")
        }
        return app
    }

    @MainActor
    private func dragMiniPlayer(_ miniPlayer: XCUIElement, from startX: CGFloat, to endX: CGFloat) {
        let start = miniPlayer.coordinate(
            withNormalizedOffset: CGVector(dx: startX, dy: 0.5)
        )
        let end = miniPlayer.coordinate(
            withNormalizedOffset: CGVector(dx: endX, dy: 0.5)
        )
        start.press(
            forDuration: 0.08,
            thenDragTo: end,
            withVelocity: 500,
            thenHoldForDuration: 0
        )
    }

    @MainActor
    private func assertNowPlayingPresentationFrameIsStable(
        expectedTitle: String,
        artworkSurface: XCUIElement? = nil,
        surfaceIdentifier: String,
        in app: XCUIApplication
    ) {
        // REGRESSION GATE: Every Now Playing layout/background change must run
        // this boundary check together with the screenshot transition test.
        // It catches the third-occurrence failure where a zero-width frame
        // leaves only the tail of the title visible during presentation.
        let nowPlaying = app.descendants(matching: .any)["player.nowPlaying"].firstMatch
        XCTAssertTrue(nowPlaying.exists)

        // REGRESSION GATE: do not query the title globally. During a system
        // Sheet transition the presenting Mini Player can retain an off-screen
        // accessibility copy (for example x = -161) while it is being removed.
        // Scope the title to the visible Now Playing surface instead.
        let visibleSurface = app.descendants(matching: .any)[surfaceIdentifier].firstMatch
        XCTAssertTrue(
            visibleSurface.waitForExistence(timeout: 5),
            "The \(surfaceIdentifier) surface must stay mounted."
        )
        let surfaceFrame = visibleSurface.frame
        XCTAssertFalse(
            surfaceFrame.isEmpty,
            "The visible \(surfaceIdentifier) surface must retain a measurable frame."
        )
        XCTAssertGreaterThanOrEqual(
            surfaceFrame.minX,
            -1,
            "The visible \(surfaceIdentifier) surface must not escape the leading screen edge."
        )
        XCTAssertLessThanOrEqual(
            surfaceFrame.maxX,
            app.frame.maxX + 1,
            "The visible \(surfaceIdentifier) surface must stay inside the screen width."
        )
        XCTAssertGreaterThanOrEqual(
            surfaceFrame.minY,
            -1,
            "The visible \(surfaceIdentifier) surface must not escape above the screen."
        )
        XCTAssertLessThanOrEqual(
            surfaceFrame.maxY,
            app.frame.maxY + 1,
            "The visible \(surfaceIdentifier) surface must stay inside the screen height."
        )
        // SwiftUI may either propagate the surface identifier to contained
        // elements or preserve the title's own identifier, depending on the
        // container. Query by label plus both supported identifiers; using
        // staticTexts[expectedTitle] would query identifiers and can select
        // the artwork element instead of the title.
        let titleCandidates = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@ AND (identifier == %@ OR identifier == %@)",
                expectedTitle,
                surfaceIdentifier,
                "player.nowPlaying.current.title"
            )
        ).allElementsBoundByIndex
        let title = titleCandidates.first { candidate in
            let frame = candidate.frame
            return !frame.isEmpty
                && frame.minX >= -1
                && frame.maxX <= app.frame.maxX + 1
                && frame.minY >= 0
                && frame.maxY <= app.frame.maxY + 1
        }
        XCTAssertTrue(
            title != nil,
            "The visible Now Playing title must stay mounted."
        )
        guard let title else { return }
        XCTAssertGreaterThanOrEqual(
            title.frame.minX,
            -1,
            "The current title must not be horizontally clipped during a transition."
        )
        XCTAssertLessThanOrEqual(
            title.frame.maxX,
            app.frame.maxX + 1,
            "The current title must remain inside the screen width during a transition."
        )

        if let artworkSurface {
            XCTAssertFalse(artworkSurface.frame.isEmpty)
            XCTAssertGreaterThanOrEqual(artworkSurface.frame.minX, -1)
            XCTAssertLessThanOrEqual(artworkSurface.frame.maxX, app.frame.maxX + 1)
        }
    }

    @MainActor
    private func assertCollectionPage(
        _ content: XCUIElement,
        itemPrefix: String,
        tailLabel: String,
        isGrid: Bool,
        screenshotName: String,
        in app: XCUIApplication
    ) {
        let items = content.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", itemPrefix)
        )
        let first = items.element(boundBy: 0)
        let second = items.element(boundBy: 1)
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(second.waitForExistence(timeout: 20))

        if isGrid {
            XCTAssertLessThan(
                first.frame.width,
                content.frame.width * 0.72,
                "Album cells must keep two columns instead of expanding to the full width."
            )
            XCTAssertEqual(
                first.frame.midY,
                second.frame.midY,
                accuracy: 12,
                "The first album row must contain two aligned cells."
            )
        }

        attachScreenshot(named: "layout-\(screenshotName)-top")

        for _ in 0..<12 {
            content.swipeUp()
        }

        let last = content.cells.matching(
            NSPredicate(format: "label CONTAINS %@", tailLabel)
        ).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            last.frame.maxY,
            content.frame.maxY + 2,
            "The last (itemPrefix) item must not extend beyond its collection view."
        )
        // A short collection is allowed to leave unused viewport space. The
        // invariant is that the final item is visible and fully contained;
        // long collections are exercised by the repeated swipe-up above.
        XCTAssertGreaterThanOrEqual(
            last.frame.minY,
            content.frame.minY - 2,
            "The final item must remain visible after reaching the collection tail."
        )
        attachScreenshot(named: "layout-\(screenshotName)-bottom")
    }

    @MainActor
    private func assertNowPlayingIsNotPresented(in app: XCUIApplication) {
        XCTAssertFalse(
            app.descendants(matching: .any)["player.nowPlaying.scroll"].firstMatch.exists
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["player.nowPlaying.upperScroll"].firstMatch.exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["player.mini"].firstMatch.isHittable,
            "A MiniPlayer swipe must not present the full-screen player."
        )
    }

    @MainActor
    private func swipeUpPastMediaSliders(in scrollView: XCUIElement) {
        let start = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.96, dy: 0.76)
        )
        let end = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.96, dy: 0.56)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func bringQueueActionIntoView(
        _ element: XCUIElement,
        in scrollView: XCUIElement
    ) {
        // A full XCTest swipe can move the compact current row past the top
        // edge. Use short, deterministic drags so the system sheet keeps its
        // own dismissal gesture and the queue settles on the visible row.
        for _ in 0..<5 where !element.isHittable {
            let start = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34)
            )
            let end = scrollView.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    private func revealQueueHistory(
        _ heading: XCUIElement,
        in scrollView: XCUIElement
    ) {
        // Use the table gesture so the Sheet and its inner list
        // keep the same gesture owner. Short coordinate drags can be consumed
        // by the Sheet's dismissal recognizer without changing the list
        // offset, which makes a lazy History header look incorrectly absent.
        for _ in 0..<8 where !isElementVisible(heading, in: scrollView) {
            scrollView.swipeDown()
        }
    }

    @MainActor
    private func pullQueueDown(in scrollView: XCUIElement) {
        let start = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)
        )
        let end = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func pullQueueUp(in scrollView: XCUIElement) {
        let start = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)
        )
        let end = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func isElementHittable(
        _ element: XCUIElement,
        in container: XCUIElement
    ) -> Bool {
        guard element.exists else { return false }
        let elementFrame = element.frame
        let containerFrame = container.frame
        guard !elementFrame.isEmpty,
              !containerFrame.isEmpty,
              elementFrame.intersects(containerFrame)
        else {
            return false
        }
        return element.isHittable
    }

    @MainActor
    private func isElementVisible(
        _ element: XCUIElement,
        in container: XCUIElement
    ) -> Bool {
        guard element.exists else { return false }
        let elementFrame = element.frame
        let containerFrame = container.frame
        return !elementFrame.isEmpty && elementFrame.intersects(containerFrame)
    }

    @MainActor
    private func captureLibraryPage(
        title: String,
        identifier: String,
        detailTitle: String?,
        detailIdentifier: String?,
        expectedListSubtitle: String? = nil,
        expectedDetailSubtitle: String? = nil,
        expectedHeaderArtist: String? = nil,
        expectedHeaderYear: String? = nil,
        expectsAlbumHeroLayout: Bool = false,
        expectsArtistAlbumGrid: Bool = false,
        screenshotName: String,
        detailScreenshotName: String?,
        in app: XCUIApplication
    ) {
        openLibrarySection(title, in: app)
        let content = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(
            content.waitForExistence(timeout: 15)
                || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No '")).firstMatch.waitForExistence(timeout: 5),
            "The \(title) page should resolve to content or an explicit empty state."
        )
        if let expectedListSubtitle {
            let item = content.cells.matching(
                NSPredicate(format: "value == %@", expectedListSubtitle)
            ).firstMatch
            XCTAssertTrue(
                item.waitForExistence(timeout: 15),
                "The \(title) page should show \(expectedListSubtitle) as secondary metadata."
            )
        }
        attachScreenshot(named: screenshotName)

        if let detailTitle, let detailIdentifier, let detailScreenshotName {
            let item = content.cells.matching(
                NSPredicate(format: "label == %@", detailTitle)
            ).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 15), "Expected seeded \(title) item: \(detailTitle)")
            item.tap()
            let detail = app.descendants(matching: .any)[detailIdentifier].firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 15))
            if let expectedDetailSubtitle {
                XCTAssertTrue(
                    detail.staticTexts[expectedDetailSubtitle].firstMatch.waitForExistence(timeout: 15),
                    "The \(detailTitle) song rows should show \(expectedDetailSubtitle)."
                )
            }
            if let expectedHeaderArtist {
                let headerArtist = detail.descendants(matching: .any)[
                    "library.collection.header.artist"
                ].firstMatch
                XCTAssertTrue(
                    headerArtist.waitForExistence(timeout: 15),
                    "The \(detailTitle) header should show its album artist."
                )
                XCTAssertEqual(headerArtist.label, expectedHeaderArtist)
            }
            if let expectedHeaderYear {
                let headerYear = detail.descendants(matching: .any)[
                    "library.collection.header.year"
                ].firstMatch
                XCTAssertTrue(
                    headerYear.waitForExistence(timeout: 15),
                    "The \(detailTitle) header should show its release year when available."
                )
                XCTAssertEqual(headerYear.label, expectedHeaderYear)
            }
            if expectsAlbumHeroLayout {
                assertAlbumHeroLayout(
                    detailTitle: detailTitle,
                    detail: detail,
                    in: app
                )
            }
            if expectsArtistAlbumGrid {
                assertArtistAlbumLayout(
                    artistName: detailTitle,
                    detail: detail
                )
            }
            attachScreenshot(named: detailScreenshotName)

            if expectsArtistAlbumGrid {
                let albumTile = detail.buttons["BVT Album"].firstMatch
                XCTAssertTrue(albumTile.waitForExistence(timeout: 10))
                albumTile.tap()

                let albumDetail = app.descendants(matching: .any)[
                    "library.collectionDetail"
                ].firstMatch
                XCTAssertTrue(
                    albumDetail.waitForExistence(timeout: 15),
                    "An artist album tile should open the existing album detail page."
                )
                XCTAssertEqual(
                    albumDetail.descendants(matching: .any)[
                        "library.collection.header.title"
                    ].firstMatch.label,
                    "BVT Album"
                )
                back(in: app)
                back(in: app)
            } else {
                let trackRows = detail.cells.matching(
                    NSPredicate(format: "identifier BEGINSWITH 'library.collection.track.play.'")
                )
                // Album hero content can fill the first viewport in
                // landscape. Scroll the real collection view before asserting
                // that its native song cell is available for context actions.
                for _ in 0..<4 where !trackRows.firstMatch.exists {
                    detail.swipeUp()
                }
                let trackRow = trackRows.firstMatch
                XCTAssertTrue(
                    trackRow.waitForExistence(timeout: 10),
                    "The (title) detail should expose a native collection-view song row."
                )
                trackRow.press(forDuration: 1.0)
                assertTrackQueueMenuActions(in: app)
                let detailAction = app.buttons["View song details"].firstMatch
                XCTAssertTrue(detailAction.waitForExistence(timeout: 5))
                detailAction.tap()
                XCTAssertTrue(
                    app.descendants(matching: .any)["library.trackDetail"].waitForExistence(timeout: 15),
                    "The song options menu should route to song detail."
                )
                if expectsAlbumHeroLayout {
                    back(in: app)
                    back(in: app)
                } else {
                    backTo(detailTitle, in: app)
                    backTo(title, in: app)
                }
            }
        }
        backTo("Library", in: app)
    }

    @MainActor
    private func resetReviewPlaylist(in app: XCUIApplication) {
        let playlistName = "Apple Music UI"
        let existingRow = app.cells.containing(.staticText, identifier: playlistName).firstMatch
        if existingRow.waitForExistence(timeout: 3) {
            existingRow.press(forDuration: 1.0)
            let deleteMenuItem = app.buttons.matching(
                NSPredicate(format: "label == 'Delete' AND enabled == true")
            ).firstMatch
            XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 5))
            deleteMenuItem.tap()

            XCTAssertTrue(app.staticTexts["Delete playlist?"].waitForExistence(timeout: 5))
            let confirmDelete = app.buttons.matching(
                NSPredicate(format: "label == 'Delete' AND enabled == true")
            ).firstMatch
            XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
            confirmDelete.tap()
            XCTAssertTrue(existingRow.waitForNonExistence(timeout: 10))
        }

        let createButton = app.buttons["New playlist"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 10))
        createButton.tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(playlistName)
        app.buttons["Save"].tap()

        let detail = app.descendants(matching: .any)["playlists.detail"]
        if detail.waitForExistence(timeout: 5) {
            backTo("Playlists", in: app)
        }
        XCTAssertTrue(
            app.cells.containing(.staticText, identifier: playlistName).firstMatch
                .waitForExistence(timeout: 10)
        )
    }

    @MainActor
    private func openReviewPlaylist(in app: XCUIApplication) {
        let playlistRow = app.cells.containing(
            .staticText,
            identifier: "Apple Music UI"
        ).firstMatch
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 10))
        playlistRow.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["playlists.detail"]
                .waitForExistence(timeout: 15)
        )
    }

    @MainActor
    private func waitForSeededLibraryTrack(
        in app: XCUIApplication,
        selectForPlayback: Bool = false
    ) {
        openLibrarySection("Songs", in: app)
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        XCTAssertTrue(
            tracks.waitForExistence(timeout: 60),
            "The songs collection should be visible before locating the seeded track."
        )
        let track = tracks.cells.matching(
            NSPredicate(format: "label == %@", "BVT Tone")
        ).firstMatch
        if !track.waitForExistence(timeout: 60) {
            // A first launch may still be importing Documents. Pull to refresh
            // so the scanner runs again before failing the visual review.
            if tracks.isHittable {
                tracks.swipeDown()
            }
        }
        XCTAssertTrue(
            track.waitForExistence(timeout: 30),
            "The seeded BVT track should be visible before capturing detail pages."
        )
        if selectForPlayback {
            track.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["player.mini"]
                    .staticTexts["BVT Tone"]
                    .waitForExistence(timeout: 15),
                "Visual baselines must start from the same BVT Tone Mini Player state."
            )
        }
        backTo("Library", in: app)
    }

    @MainActor
    private func openTrackDetailFromMenu(
        in app: XCUIApplication,
        assertQueueActions: Bool = true
    ) {
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let trackRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", "BVT Tone")
        ).firstMatch
        XCTAssertTrue(trackRow.waitForExistence(timeout: 5))
        trackRow.press(forDuration: 1.0)
        if assertQueueActions {
            assertTrackQueueMenuActions(in: app)
        }
        let detail = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label ==[c] %@ OR label ==[c] %@",
                "View song details",
                "查看歌曲详情"
            )
        ).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        detail.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.trackDetail"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func ensureTimedLyrics(for trackTitle: String, in app: XCUIApplication) {
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let trackCell = tracks.cells.matching(
            NSPredicate(format: "label == %@", trackTitle)
        ).firstMatch
        XCTAssertTrue(trackCell.waitForExistence(timeout: 10))

        trackCell.press(forDuration: 1.0)

        let details = app.buttons["View song details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()

        let detail = app.descendants(matching: .any)["library.trackDetail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        let edit = app.buttons["library.trackDetail.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let editorForm = app.scrollViews["library.trackEditor.scroll"].firstMatch
        XCTAssertTrue(editorForm.waitForExistence(timeout: 5))
        for _ in 0..<6 {
            editorForm.swipeUp()
        }

        let lyricsEditor = app.descendants(matching: .any)[
            "library.trackEditor.lyrics"
        ].firstMatch
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 10))
        lyricsEditor.tap()
        lyricsEditor.typeText(
            "[00:00.00]Now the night is moving on\n"
                + "[00:04.00]Every sound becomes a light\n"
                + "[00:08.00]\(trackTitle)\n"
                + "[00:12.00]Keep the moment close to me\n"
                + "[00:16.00]Let the rhythm carry through\n"
                + "[00:20.00]We will find the way back home\n"
                + "[00:24.00]Stay with me until the end"
        )

        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(lyricsEditor.waitForNonExistence(timeout: 10))
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        backTo("Songs", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["library.tracks"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertTrackQueueMenuActions(in app: XCUIApplication) {
        XCTAssertTrue(
            nativeMenuActionExists(["Play next", "下一首播放"], in: app),
            "Every song options menu should expose insertion after the current item."
        )
        XCTAssertTrue(
            nativeMenuActionExists(["Add to queue", "加入队列"], in: app),
            "Every song options menu should expose append-to-queue."
        )
    }

    @MainActor
    private func nativeMenuActionExists(_ labels: [String], in app: XCUIApplication) -> Bool {
        for label in labels {
            let labeledElement = app.descendants(matching: .any).matching(
                NSPredicate(format: "label ==[c] %@", label)
            ).firstMatch
            if labeledElement.waitForExistence(timeout: 2) {
                return true
            }
            if app.buttons.matching(
                NSPredicate(format: "label ==[c] %@", label)
            ).firstMatch.waitForExistence(timeout: 2) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func assertCollectionQueueMenu(
        sectionTitle: String,
        contentIdentifier: String,
        collectionTitle: String,
        detailIdentifier: String,
        menuIdentifier: String,
        in app: XCUIApplication
    ) {
        openLibrarySection(sectionTitle, in: app)
        let content = app.descendants(matching: .any)[contentIdentifier].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 15))
        let collection = content.cells.matching(
            NSPredicate(format: "label == %@", collectionTitle)
        ).firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 15))
        collection.tap()

        let detail = app.descendants(matching: .any)[detailIdentifier].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15))
        let menu = app.buttons[menuIdentifier].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        assertTrackQueueMenuActions(in: app)

        let enqueue = app.buttons["Add to queue"].firstMatch
        XCTAssertTrue(enqueue.isEnabled)
        enqueue.tap()
        XCTAssertTrue(enqueue.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Could not update the play queue"].waitForExistence(timeout: 2))

        backTo(sectionTitle, in: app)
        backTo("Library", in: app)
    }

    @MainActor
    private func invokeQueueMenuAction(
        _ actionTitle: String,
        for trackTitle: String,
        in tracks: XCUIElement,
        app: XCUIApplication
    ) {
        let trackCell = tracks.cells.matching(
            NSPredicate(format: "label == %@", trackTitle)
        ).firstMatch
        XCTAssertTrue(trackCell.waitForExistence(timeout: 5))
        trackCell.press(forDuration: 1.0)

        let action = app.buttons[actionTitle].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isEnabled)
        action.tap()
        XCTAssertTrue(action.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertTrackDetailMetadata(in app: XCUIApplication) {
        let detail = app.descendants(matching: .any)["library.trackDetail"].firstMatch
        let title = detail.descendants(matching: .any)[
            "library.trackDetail.title"
        ].firstMatch
        let artist = detail.descendants(matching: .any)[
            "library.trackDetail.artist"
        ].firstMatch
        let album = detail.descendants(matching: .any)[
            "library.trackDetail.album"
        ].firstMatch
        let duration = detail.descendants(matching: .any)[
            "library.trackDetail.duration"
        ].firstMatch

        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "BVT Tone")
        XCTAssertTrue(artist.waitForExistence(timeout: 15))
        XCTAssertEqual(artist.label, "BVT Artist")
        XCTAssertTrue(album.waitForExistence(timeout: 15))
        XCTAssertEqual(album.label, "BVT Album")
        XCTAssertTrue(duration.waitForExistence(timeout: 10))
        XCTAssertTrue(
            duration.label.hasPrefix("Duration "),
            "Duration should remain visible as explicitly labeled technical metadata."
        )
        XCTAssertGreaterThan(artist.frame.minY, title.frame.minY)
        XCTAssertGreaterThan(album.frame.minY, artist.frame.minY)
        XCTAssertGreaterThan(duration.frame.minY, album.frame.minY)
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
    private func backTo(_ title: String, in app: XCUIApplication) {
        let back = app.navigationBars.buttons[title].firstMatch
        if back.waitForExistence(timeout: 3) {
            back.tap()
        }
    }

    @MainActor
    private func enterSearchTextReliably(
        _ text: String,
        in field: XCUIElement,
        app: XCUIApplication
    ) {
        for _ in 0..<4 {
            field.tap()
            clearSearchField(field, in: app)
            field.tap()
            for character in text {
                field.typeText(String(character))
            }

            if (field.value as? String) == text {
                return
            }
        }

        let actualValue = field.value as? String ?? "nil"
        XCTFail(
            "The search field did not accept the complete query. "
                + "Expected \(text), got \(actualValue)."
        )
    }

    @MainActor
    private func clearSearchField(_ field: XCUIElement, in app: XCUIApplication) {
        guard let currentValue = field.value as? String, !currentValue.isEmpty else {
            return
        }

        let deleteKey = app.keys["delete"].firstMatch
        XCTAssertTrue(
            deleteKey.waitForExistence(timeout: 2),
            "The simulator keyboard must expose a delete key while editing search."
        )
        for _ in currentValue {
            deleteKey.tap()
        }
    }

    @MainActor
    private func back(in app: XCUIApplication) {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
    }

    @MainActor
    private func assertAlbumHeroLayout(
        detailTitle: String,
        detail: XCUIElement,
        in app: XCUIApplication
    ) {
        let headerTitle = detail.descendants(matching: .any)[
            "library.collection.header.title"
        ].firstMatch
        let headerArtist = detail.descendants(matching: .any)[
            "library.collection.header.artist"
        ].firstMatch
        let headerYear = detail.descendants(matching: .any)[
            "library.collection.header.year"
        ].firstMatch
        let playButton = detail.buttons["library.collection.play"].firstMatch
        let shuffleButton = detail.buttons["library.collection.shuffle"].firstMatch

        XCTAssertTrue(headerTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(headerTitle.label, detailTitle)
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(shuffleButton.waitForExistence(timeout: 10))
        XCTAssertTrue(playButton.isEnabled)
        XCTAssertTrue(shuffleButton.isEnabled)
        XCTAssertGreaterThan(headerArtist.frame.minY, headerTitle.frame.minY)
        XCTAssertGreaterThan(headerYear.frame.minY, headerArtist.frame.minY)
        XCTAssertGreaterThan(playButton.frame.minY, headerYear.frame.minY)
        XCTAssertGreaterThan(
            playButton.frame.width,
            shuffleButton.frame.width,
            "Album playback must remain the visually primary action."
        )
        XCTAssertLessThan(
            playButton.frame.minX,
            shuffleButton.frame.minX,
            "Album hero controls should place the primary play action before shuffle."
        )
        let firstAlbumTrackNumber = detail.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.collection.track.number.")
        ).firstMatch
        XCTAssertTrue(
            firstAlbumTrackNumber.waitForExistence(timeout: 10),
            "Album tracks should use numbered rows instead of repeating artwork."
        )
        XCTAssertEqual(firstAlbumTrackNumber.label, "1")
        XCTAssertFalse(
            app.navigationBars.firstMatch.staticTexts[detailTitle].exists,
            "The navigation bar must not repeat the album title above the hero title."
        )
        XCTAssertFalse(
            detail.staticTexts["Songs"].exists,
            "Album tracks should begin without an extra Songs section heading."
        )
    }

    @MainActor
    private func assertArtistAlbumLayout(
        artistName: String,
        detail: XCUIElement
    ) {
        let headerTitle = detail.descendants(matching: .any)[
            "library.artist.header.title"
        ].firstMatch
        let albumGrid = detail.descendants(matching: .any)[
            "library.artist.albums"
        ].firstMatch
        let albumTile = detail.buttons["BVT Album"].firstMatch
        let playButton = detail.buttons["library.artist.play"].firstMatch
        let shuffleButton = detail.buttons["library.artist.shuffle"].firstMatch

        XCTAssertTrue(headerTitle.waitForExistence(timeout: 10))
        XCTAssertEqual(headerTitle.label, artistName)
        XCTAssertTrue(albumGrid.waitForExistence(timeout: 10))
        XCTAssertTrue(albumTile.waitForExistence(timeout: 10))
        // Native UIKit collection cells expose the card as a button and keep
        // the release year as its accessibility value rather than as a
        // nested StaticText under the transparent activation layer.
        XCTAssertEqual(albumTile.value as? String, "2026")
        XCTAssertFalse(
            albumTile.staticTexts[artistName].exists,
            "Artist album cards should use the release year, not the artist name, as metadata."
        )
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(shuffleButton.waitForExistence(timeout: 10))
        XCTAssertTrue(playButton.isEnabled)
        XCTAssertTrue(shuffleButton.isEnabled)
        let albumTitle = detail.staticTexts["BVT Album"].firstMatch
        XCTAssertTrue(
            albumTitle.waitForExistence(timeout: 10),
            "The artist album card must keep its title mounted below the artwork."
        )
        XCTAssertLessThanOrEqual(
            albumTitle.frame.maxY,
            albumGrid.frame.maxY + 1,
            "The artist album title must remain inside the collection surface."
        )
        XCTAssertFalse(
            detail.staticTexts["BVT Tone"].exists,
            "Artist details should be album-first instead of reusing the generic song collection."
        )
    }

    @MainActor
    private func tabButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let nativeButton = app.tabBars.buttons[title].firstMatch
        if nativeButton.exists {
            return nativeButton
        }
        return app.descendants(matching: .any)["app.tabBar"]
            .firstMatch.buttons[title].firstMatch
    }

    @MainActor
    private func playerQueueScrollView(in app: XCUIApplication) -> XCUIElement {
        app.tables["player.nowPlaying.upperScroll"].firstMatch
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
    private func scrollSettingsToTop(in app: XCUIApplication) {
        let scrollContainer = settingsScrollContainer(in: app)
        for _ in 0..<12 {
            scrollContainer.swipeDown()
        }
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
