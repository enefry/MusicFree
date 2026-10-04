import XCTest

final class PluginSystemUITests: XCTestCase {
    @MainActor func testDSPPlacementPickerPersistsAcrossLaunches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch(); openPlugins(app, seekGain: false)
        var picker: XCUIElement { app.descendants(matching: .any)["plugins.reference.gain.placement"].firstMatch }
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
        let initial = shows("每轨混音前") ? "每轨混音前" : "总线混音后"
        XCTAssertTrue(shows(initial))
        let changed = initial == "每轨混音前" ? "总线混音后" : "每轨混音前"
        func choose(_ position: String) {
            picker.tap()
            let option = app.buttons[position].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                shows(position)
            }, object: nil)], timeout: 5), .completed)
        }
        choose(changed)
        app.terminate(); app.launch(); openPlugins(app, seekGain: false)
        revealPicker(); XCTAssertTrue(shows(changed))
        choose(initial)
    }
    @MainActor func testSourceDescriptorOpensNativeForm() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bvt-reset-user-interface-preferences"]
        defer { app.terminate() }
        app.launch()
        openPlugins(app)
        let sources = app.buttons["plugins.reference.source.sources"]
        for _ in 0..<8 where !sources.isHittable { app.swipeUp() }
        XCTAssertTrue(sources.waitForExistence(timeout: 10)); sources.tap()
        let add = app.buttons["plugins.source.add"]
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
        enabled.switches.firstMatch.tap()
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
        enabled.switches.firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (enabled.value as? String) == initialEnabled
        }, object: nil)], timeout: 5), .completed)
        XCTAssertEqual(enabled.value as? String, initialEnabled)
    }
    @MainActor private func openPlugins(_ app: XCUIApplication, seekGain: Bool = true) {
        let tab = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20)); tab.tap()
        let entry = app.descendants(matching: .any)["settings.plugins.entry"].firstMatch
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        if seekGain {
            let gain = app.switches["plugins.reference.gain.enabled"]
            for _ in 0..<5 where !gain.isHittable { app.swipeUp() }
        }
    }
}
