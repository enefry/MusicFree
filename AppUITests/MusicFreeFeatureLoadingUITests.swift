import XCTest

final class MusicFreeFeatureLoadingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
            app.staticTexts["Playlists"].waitForExistence(timeout: 5),
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
    func testMetadataEnrichmentScanStartsAndCancels() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15))
        let settingsTab = tabBar.buttons.element(boundBy: 2)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["settings.form"].waitForExistence(timeout: 15)
        )
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

        let metadataServerToggle = app.switches[
            "settings.import.metadataProvider.metadataServer.enabled"
        ].firstMatch
        XCTAssertTrue(metadataServerToggle.waitForExistence(timeout: 10))
        if (metadataServerToggle.value as? String) != "1" {
            metadataServerToggle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            ).tap()
            let enabledExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == '1'"),
                object: metadataServerToggle
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [enabledExpectation], timeout: 15),
                .completed,
                "Enabling Metadata Server should update the persisted settings state."
            )
        }

        let scanButton = app.buttons["settings.import.musicKitScan"].firstMatch
        XCTAssertTrue(
            scanButton.waitForExistence(timeout: 10),
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
    func testAppleMusicLayoutReviewScreenshots() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--bvt-seed-audio", "-AppleInterfaceStyle", "Dark"]
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
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
        openTrackDetailFromMenu(in: app)
        assertTrackDetailMetadata(in: app)
        attachScreenshot(named: "10-track-detail")
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
        XCTAssertEqual(
            favorite.frame.midY,
            delete.frame.midY,
            accuracy: 5,
            "Delete must be in the compact first action row."
        )
        attachScreenshot(named: "library-native-context-actions")
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
        let pages: [(title: String, identifier: String, itemPrefix: String, isGrid: Bool)] = [
            ("Albums", "library.albums", "library.album.open.", true),
            ("Artists", "library.artists", "library.artist.open.", false),
            ("Genres", "library.genres", "library.genre.open.", false),
            ("Folders", "library.folders", "library.folder.open.", false),
            ("Songs", "library.tracks", "library.track.play.", false)
        ]

        for page in pages {
            openLibrarySection(page.title, in: app)
            let content = app.descendants(matching: .any)[page.identifier].firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 20))
            assertCollectionPage(
                content,
                itemPrefix: page.itemPrefix,
                isGrid: page.isGrid,
                screenshotName: page.title.lowercased(),
                in: app
            )
            backTo("Library", in: app)
        }
    }

    @MainActor
    func testAppleMusicPlaylistScreenshots() {
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(tabButton("Playlists", in: app).waitForExistence(timeout: 15))
        waitForSeededLibraryTrack(in: app)
        tabButton("Playlists", in: app).tap()
        XCTAssertTrue(app.staticTexts["Playlists"].waitForExistence(timeout: 10))
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
        tabButton("Settings", in: app).tap()
        let form = app.descendants(matching: .any)["settings.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        attachScreenshot(named: "16-settings-playback")

        let storageRefresh = app.buttons["settings.storage.refresh"].firstMatch
        XCTAssertTrue(scrollToElement(storageRefresh, in: app))
        attachScreenshot(named: "17-settings-storage")

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
        let app = reviewApp()
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
        attachScreenshot(named: "21-mini-player")
        miniPlayer.tap()

        let artworkSurface = app.descendants(matching: .any)[
            "player.nowPlaying.artwork"
        ].firstMatch
        XCTAssertTrue(
            artworkSurface.waitForExistence(timeout: 10),
            "Opening the Mini Player must start in the artwork surface."
        )
        XCTAssertTrue(app.buttons["Favorite"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["More actions"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Playback progress"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Lyrics"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["AirPlay"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play queue"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.scrollViews["player.nowPlaying.upperScroll"].firstMatch.exists,
            "The artwork surface must not create a second queue scroll container."
        )
        attachScreenshot(named: "22-now-playing-default")

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

        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        guard let pauseButton = app.buttons.matching(identifier: "Pause")
            .allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("The visible Now Playing pause control must be hittable.")
            return
        }
        pauseButton.tap()

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
        let lyricsScrollView = app.scrollViews["player.nowPlaying.lyricsScroll"].firstMatch
        XCTAssertTrue(
            lyricsScrollView.waitForExistence(timeout: 15),
            "The seeded local LRC should render one embedded lyrics scroll container."
        )
        XCTAssertFalse(
            app.scrollViews["player.nowPlaying.upperScroll"].firstMatch.exists,
            "Switching to lyrics must replace the queue scroll container."
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
    func testMiniPlayerHorizontalSwipeChangesTrackWithoutOpeningPlayer() {
        let firstTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"
        let secondTitle = "BVT Tone"
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
        firstTrack.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(miniPlayer.staticTexts[firstTitle].waitForExistence(timeout: 15))

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

        miniPlayer.swipeLeft()
        XCTAssertTrue(
            miniPlayer.staticTexts[secondTitle].waitForExistence(timeout: 15),
            "Swiping left on the MiniPlayer must advance to the next track."
        )
        assertNowPlayingIsNotPresented(in: app)

        miniPlayer.swipeRight()
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
            app.scrollViews["player.nowPlaying.upperScroll"].firstMatch.waitForExistence(timeout: 10),
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
        let app = reviewApp()
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(tabButton("Library", in: app).waitForExistence(timeout: 15))
        openLibrarySection("Songs", in: app)
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let trackRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", trackTitle)
        ).firstMatch
        XCTAssertTrue(trackRow.waitForExistence(timeout: 30))

        let playAllButton = tracks.buttons["Play"].firstMatch
        XCTAssertTrue(playAllButton.waitForExistence(timeout: 5))
        playAllButton.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
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
        let queueScrollView = app.scrollViews["player.nowPlaying.upperScroll"].firstMatch
        XCTAssertTrue(queueScrollView.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            if !moreButton.isHittable {
                queueScrollView.swipeDown()
            }
            XCTAssertTrue(moreButton.isHittable)
            moreButton.tap()
            let enqueueButton = app.buttons[
                "player.nowPlaying.actions.enqueue"
            ].firstMatch
            XCTAssertTrue(enqueueButton.waitForExistence(timeout: 5))
            enqueueButton.tap()
            XCTAssertTrue(enqueueButton.waitForNonExistence(timeout: 5))
        }

        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        let originalMoreButtonY = moreButton.frame.minY
        let originalQueueButtonY = queueButton.frame.minY

        for _ in 0..<3 {
            queueScrollView.swipeUp()
            if moreButton.frame.minY < originalMoreButtonY - 40 {
                break
            }
        }

        XCTAssertLessThan(
            moreButton.frame.minY,
            originalMoreButtonY - 40,
            "Scrolling Continue Playing must move the upper player content."
        )
        XCTAssertEqual(
            queueButton.frame.minY,
            originalQueueButtonY,
            accuracy: 1,
            "Scrolling the queue must keep the playback controls pinned."
        )
    }

    @MainActor
    private func reviewApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--bvt-seed-audio",
            "-AppleInterfaceStyle",
            "Dark",
            "-musicfree.language",
            "en"
        ]
        return app
    }

    @MainActor
    private func assertCollectionPage(
        _ content: XCUIElement,
        itemPrefix: String,
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

        let last = items.element(boundBy: max(items.count - 1, 0))
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(
            last.frame.maxY,
            content.frame.maxY + 2,
            "The last (itemPrefix) item must not extend beyond its collection view."
        )
        XCTAssertGreaterThan(
            last.frame.maxY,
            content.frame.maxY - 180,
            "The collection view must not leave a large blank tail after its last item."
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
        let existingRow = app.buttons.containing(.staticText, identifier: playlistName).firstMatch
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
            app.buttons.containing(.staticText, identifier: playlistName).firstMatch
                .waitForExistence(timeout: 10)
        )
    }

    @MainActor
    private func openReviewPlaylist(in app: XCUIApplication) {
        let playlistRow = app.buttons.containing(
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
    private func waitForSeededLibraryTrack(in app: XCUIApplication) {
        openLibrarySection("Songs", in: app)
        let track = app.staticTexts["BVT Tone"].firstMatch
        if !track.waitForExistence(timeout: 60) {
            // A first launch may still be importing Documents. Pull to refresh
            // so the scanner runs again before failing the visual review.
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeDown()
            }
        }
        XCTAssertTrue(
            track.waitForExistence(timeout: 30),
            "The seeded BVT track should be visible before capturing detail pages."
        )
        backTo("Library", in: app)
    }

    @MainActor
    private func openTrackDetailFromMenu(in app: XCUIApplication) {
        let tracks = app.descendants(matching: .any)["library.tracks"].firstMatch
        let trackRow = tracks.cells.matching(
            NSPredicate(format: "label == %@", "BVT Tone")
        ).firstMatch
        XCTAssertTrue(trackRow.waitForExistence(timeout: 5))
        trackRow.press(forDuration: 1.0)
        assertTrackQueueMenuActions(in: app)
        let detail = app.buttons["View song details"].firstMatch
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

        let editorForm = app.collectionViews.firstMatch
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
            nativeMenuActionExists("Play next", in: app),
            "Every song options menu should expose insertion after the current item."
        )
        XCTAssertTrue(
            nativeMenuActionExists("Add to queue", in: app),
            "Every song options menu should expose append-to-queue."
        )
    }

    @MainActor
    private func nativeMenuActionExists(_ label: String, in app: XCUIApplication) -> Bool {
        let labeledElement = app.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] %@", label)
        ).firstMatch
        if labeledElement.waitForExistence(timeout: 5) {
            return true
        }
        return app.buttons.matching(
            NSPredicate(format: "label ==[c] %@", label)
        ).firstMatch.waitForExistence(timeout: 5)
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
        XCTAssertTrue(albumTile.staticTexts["2026"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            albumTile.staticTexts[artistName].exists,
            "Artist album cards should use the release year, not the artist name, as metadata."
        )
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(shuffleButton.waitForExistence(timeout: 10))
        XCTAssertTrue(playButton.isEnabled)
        XCTAssertTrue(shuffleButton.isEnabled)
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
        let identified = app.scrollViews["player.nowPlaying.upperScroll"].firstMatch
        if identified.waitForExistence(timeout: 3) {
            return identified
        }
        // SwiftUI can expose an empty scroll container without its identifier
        // on iOS 26. Prefer the stable identifier once queue rows are present.
        return app.scrollViews.firstMatch
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
