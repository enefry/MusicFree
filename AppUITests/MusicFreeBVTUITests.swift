import XCTest

final class MusicFreeBVTUITests: XCTestCase {
    private let trackTitle = "BVT Tone"
    private let playlistName = "BVT 自动巡检"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAgentBVTCompletesCoreIPhoneFlowAndPersistsState() {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--bvt-seed-audio"]
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
    private func assertMainTabs(in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.waitForExistence(timeout: 15),
            "The app must expose its main navigation as a native tab bar."
        )
        for title in ["Library", "Playlists", "Settings"] {
            let button = tabBar.buttons[title].firstMatch
            XCTAssertTrue(button.exists, "Missing native tab: \(title)")
            XCTAssertTrue(button.isHittable, "Native tab is not hittable: \(title)")
        }
        XCTAssertFalse(app.staticTexts["Library unavailable"].exists)
        XCTAssertFalse(app.staticTexts["App service unavailable"].exists)
    }

    @MainActor
    private func createPlaylist(in app: XCUIApplication) {
        tapTab("Playlists", in: app)

        let playlistRow = app.buttons.containing(
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

        let refreshButton = app.buttons.matching(
            NSPredicate(format: "identifier == 'settings.storage.refresh' AND enabled == true")
        ).firstMatch
        XCTAssertTrue(scrollToElement(refreshButton, in: app))
        refreshButton.tap()
        XCTAssertTrue(app.staticTexts["Media files"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Could not load settings"].exists)

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

        let playlistRow = app.buttons.containing(
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
        let trackRow = tracks.buttons.containing(.staticText, identifier: trackTitle).firstMatch
        XCTAssertTrue(trackRow.waitForExistence(timeout: 5))
        trackRow.tap()

        let miniPlayer = app.descendants(matching: .any)["player.mini"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        XCTAssertTrue(
            miniPlayer.staticTexts[trackTitle].waitForExistence(timeout: 15),
            "Directly selecting a song must refresh the Mini Player metadata."
        )
        miniPlayer.tap()

        let continuePlaying = app.scrollViews["player.nowPlaying.upperScroll"].firstMatch
        XCTAssertTrue(continuePlaying.waitForExistence(timeout: 10))
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
        let playlistRow = app.buttons.containing(
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

        XCTFail(
            "Tab \(title) did not become hittable "
                + "(nativeExists: \(nativeButton.exists), "
                + "fallbackExists: \(fallbackButton.exists))."
        )
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
}
