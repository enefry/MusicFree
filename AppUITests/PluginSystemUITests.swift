import XCTest

final class PluginSystemUITests: XCTestCase {
    @MainActor func testDataPluginSettingsAppearUnderMetadataEnrichment() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch()
        let pluginID = "builtin.metadata.musicBrainz"
        openPlugins(app, pluginID: pluginID)
        let enabled = app.switches["plugins.\(pluginID).enabled"].firstMatch
        let visible = app.switches["plugins.\(pluginID).visible"].firstMatch
        let originalEnabled = enabled.value as? String
        let originalVisible = visible.value as? String
        if originalVisible != "1" { visible.tap() }
        if originalEnabled != "1" { enabled.tap() }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let root = app.tables["settings.form"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        let metadata = app.cells["settings.import.metadataEnrichment.entry"].firstMatch
        for _ in 0..<12 where !metadata.isHittable { root.swipeDown() }
        XCTAssertTrue(metadata.isHittable)
        metadata.tap()
        let table = app.tables["settings.import.metadataEnrichment"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let consent = app.buttons["settings.privacyDisclosure.accept"].firstMatch
        if consent.waitForExistence(timeout: 3) { consent.tap() }
        let entry = app.cells["settings.plugins.\(pluginID).entry"].firstMatch
        for _ in 0..<12 where !entry.isHittable { table.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        XCTAssertTrue(app.tables["settings.plugins.detail.\(pluginID)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["plugins.pages.\(pluginID).service"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openPlugins(app, pluginID: pluginID)
        if originalEnabled != "1" { enabled.tap() }
        if originalVisible != "1" { visible.tap() }
    }

    @MainActor func testEnabledDSPSettingsAppearInMainList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch()
        // Exercise generic and companion pages using plugins shown by default.
        for pluginID in ["reference.gain", "builtin.dsp.stereoBalance"] {
            openPlugins(app, pluginID: pluginID)
            let enabled = app.switches["plugins.\(pluginID).enabled"].firstMatch
            let visible = app.switches["plugins.\(pluginID).visible"].firstMatch
            XCTAssertTrue(enabled.waitForExistence(timeout: 10))
            let originalEnabled = enabled.value as? String
            let originalVisible = visible.value as? String
            if originalVisible != "1" { visible.tap() }
            if originalEnabled != "1" { enabled.tap() }
            func returnToSettings() {
                app.navigationBars.buttons.element(boundBy: 0).tap()
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.tables["settings.form"].waitForExistence(timeout: 10))
            }
            returnToSettings()
            let row = app.cells["settings.plugins.\(pluginID).entry"].firstMatch
            let table = app.tables["settings.form"].firstMatch
            for _ in 0..<12 where !row.isHittable { table.swipeDown() }
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(row.isHittable)
            row.tap()
            let formID = pluginID == "reference.gain" ? "plugins.configuration.form" : "plugins.\(pluginID).form"
            XCTAssertTrue(app.tables[formID].waitForExistence(timeout: 10))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = pluginID + ".main-settings"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            openPlugins(app, pluginID: pluginID)
            enabled.tap()
            returnToSettings()
            XCTAssertTrue(row.waitForNonExistence(timeout: 10))
            openPlugins(app, pluginID: pluginID)
            if originalEnabled == "1" { enabled.tap() }
            if originalVisible != "1" { visible.tap() }
            returnToSettings()
        }
    }

    @MainActor func testPluginConfigurationPersistsAndCanBeRestored() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch(); openPlugins(app)
        func openConfiguration() {
            let entry = app.cells["plugins.reference.gain.configuration"].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
            XCTAssertTrue(app.tables["plugins.configuration.form"].waitForExistence(timeout: 10))
        }
        openConfiguration()
        let input = app.textFields["plugins.configuration.gain"].firstMatch
        let original = input.value as? String ?? ""
        let originalValue = Double(original) == nil ? "" : original
        func replaceValue(_ value: String) {
            input.tap()
            let current = input.value as? String ?? ""
            if Double(current) != nil { input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)) }
            if !value.isEmpty { input.typeText(value) }
        }
        func saveConfiguration() {
            app.navigationBars.buttons["plugins.configuration.save"].tap()
            XCTAssertTrue(app.tables["plugins.configuration.form"].waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.tables["settings.plugins.detail.reference.gain"].exists)
        }
        replaceValue("2"); saveConfiguration()
        app.terminate(); app.launch(); openPlugins(app); openConfiguration()
        XCTAssertEqual(Double(input.value as? String ?? ""), 2)
        replaceValue(originalValue); saveConfiguration()
    }

    @MainActor func testDSPPlacementPickerPersistsAcrossLaunches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch(); openPlugins(app)
        var picker: XCUIElement { app.buttons["plugins.reference.gain.placement"].firstMatch }
        func revealPicker() {
            for _ in 0..<16 where !picker.exists || !picker.isHittable { app.swipeUp() }
            if !picker.exists {
                let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.lifetime = .keepAlways; add(hierarchy)
                let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
            }
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
        }
        revealPicker()
        func shows(_ position: String) -> Bool {
            picker.label.contains(position) || (picker.value as? String)?.contains(position) == true
        }
        let initial = shows("Before mixing each track") ? "Before mixing each track" : "After mixing the output"
        XCTAssertTrue(shows(initial))
        let changed = initial == "Before mixing each track" ? "After mixing the output" : "Before mixing each track"
        func choose(_ position: String) {
            picker.tap()
            let option = app.buttons[position].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                shows(position)
            }, object: nil)], timeout: 5), .completed)
        }
        choose(changed)
        app.terminate(); app.launch(); openPlugins(app)
        revealPicker(); XCTAssertTrue(shows(changed))
        choose(initial)
    }
    @MainActor func testSourceDescriptorOpensNativeForm() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch()
        openPlugins(app, pluginID: "reference.source")
        let sources = app.cells["plugins.reference.source.sources"]
        for _ in 0..<8 where !sources.isHittable { app.swipeUp() }
        XCTAssertTrue(sources.waitForExistence(timeout: 10)); sources.tap()
        let add = app.cells["plugins.source.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        XCTAssertTrue(app.textFields["plugins.source.name"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["plugins.source.field.collection"].exists)
        XCTAssertTrue(app.cells["plugins.source.save"].exists)
        XCTAssertFalse(app.alerts["onlineSources.applicationPrivacy.sheet"].exists)
    }
    @MainActor func testPluginSwitchesPersistAndRemainIndependent() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch()
        openPlugins(app)
        let enabled = app.switches["plugins.reference.gain.enabled"]
        let load = app.switches["plugins.reference.gain.loadAllowed"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        let initialEnabled = enabled.value as? String
        let initialLoad = load.value as? String
        enabled.tap()
        let changed = NSPredicate { _, _ in (enabled.value as? String) != initialEnabled }
        let saved = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5)
        if saved != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.lifetime = .keepAlways; add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertEqual(saved, .completed)
        XCTAssertEqual(load.value as? String, initialLoad)
        let changedEnabled = enabled.value as? String
        XCTAssertNotEqual(changedEnabled, initialEnabled)
        app.terminate(); app.launch()
        openPlugins(app)
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertEqual(enabled.value as? String, changedEnabled)
        XCTAssertEqual(load.value as? String, initialLoad)
        // Restore only the preference this test changed.
        enabled.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (enabled.value as? String) == initialEnabled
        }, object: nil)], timeout: 5), .completed)
        XCTAssertEqual(enabled.value as? String, initialEnabled)
    }
    @MainActor func testEqualizerPluginProvidesCompletePage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch(); openPlugins(app, pluginID: "builtin.dsp.equalizer")
        let page = app.cells["plugins.pages.builtin.dsp.equalizer.settings"].firstMatch
        for _ in 0..<8 where !page.isHittable { app.swipeUp() }
        XCTAssertTrue(page.waitForExistence(timeout: 10)); page.tap()
        XCTAssertTrue(app.tables["settings.playback.equalizer.form"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings.playback.equalizer.preset"].exists)
        let band = app.sliders["settings.playback.equalizer.band.1000"].firstMatch
        for _ in 0..<15 where !band.isHittable { app.swipeUp() }
        XCTAssertTrue(band.exists)
        XCTAssertFalse(app.tables["plugins.configuration.form"].exists)
    }

    @MainActor func testNativeSourcePluginUsesAccountPageAndLoginForm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences", "--bvt-seed-online-sources", "--bvt-reset-online-sources"]
        defer { app.terminate() }
        app.launch(); openPlugins(app, pluginID: "builtin.source.dsAudio")
        XCTAssertFalse(app.cells["plugins.builtin.source.dsAudio.policy"].exists)
        XCTAssertFalse(app.cells["plugins.builtin.source.dsAudio.revoke"].exists)
        let page = app.cells["plugins.pages.builtin.source.dsAudio.sources"].firstMatch
        for _ in 0..<8 where !page.isHittable { app.swipeUp() }
        XCTAssertTrue(page.waitForExistence(timeout: 10)); page.tap()
        XCTAssertTrue(app.tables["plugins.builtin.source.dsAudio.sources.form"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.cells["onlineSources.downloadQueue"].exists)
        let privacy = app.buttons["onlineSources.applicationPrivacy.confirm"].firstMatch
        if privacy.waitForExistence(timeout: 5) { privacy.tap() }
        let add = app.navigationBars.buttons["onlineSources.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        app.buttons["DS Audio"].firstMatch.tap()
        XCTAssertTrue(app.textFields["onlineSources.dsaudio.add.endpoint"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["plugins.source.field.nativeSource"].exists)
    }

    @MainActor func testMusicKitPluginProvidesAuthorizationEntryWhileDisabled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch(); openPlugins(app, pluginID: "builtin.metadata.musicKit")
        let page = app.cells["plugins.pages.builtin.metadata.musicKit.service"].firstMatch
        for _ in 0..<8 where !page.isHittable { app.swipeUp() }
        XCTAssertTrue(page.waitForExistence(timeout: 10)); page.tap()
        XCTAssertTrue(app.tables["plugins.builtin.metadata.musicKit.service"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["plugins.builtin.metadata.musicKit.authorization"].exists)
    }

    @MainActor private func openPlugins(_ app: XCUIApplication, pluginID: String = "reference.gain") {
        let tab = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20)); tab.tap()
        let entry = app.descendants(matching: .any)["settings.plugins.entry"].firstMatch
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let table = app.tables["settings.plugins"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let plugin = app.cells["plugins.\(pluginID).entry"].firstMatch
        for _ in 0..<12 where !plugin.isHittable { table.swipeUp() }
        XCTAssertTrue(plugin.waitForExistence(timeout: 10)); plugin.tap()
        XCTAssertTrue(app.tables["settings.plugins.detail.\(pluginID)"].waitForExistence(timeout: 10))
    }
}
