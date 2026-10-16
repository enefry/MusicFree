import BuiltinPluginSettings
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct MusicCatalogCookieSettingsTests {
    @Test(arguments: [false, true])
    func clearingCookieCommitsPreferenceBeforeDeletingCredential(saveFails: Bool) async throws {
        let id = PluginID(rawValue: "builtin.lyrics.qqMusic")
        var preference = PluginPreference(pluginID: id, configuration: ["retained": .text("value")], credentialRecordID: "old-record")
        var events: [String] = []
        let context = PluginSettingsContext(descriptor: .init(id: id, name: "QQ Music", kinds: [.lyrics]),
            readPreference: { preference }, saveConfiguration: { values, record in
                events.append("save")
                if saveFails { throw PluginError.unavailable }
                preference.configuration = values
                preference.credentialRecordID = record
            }, saveCredential: { _ in Issue.record("Clearing must not create a credential"); return "unexpected" },
            deleteCredential: { record in events.append("delete:" + record) }, setConsent: { _ in })
        let controller = MusicCatalogCookieSettingsViewController(context: context)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        for _ in 0..<200 where !controller.canEdit { await Task.yield() }
        let clear = try #require(controller.rows["plugins.\(id.rawValue).cookie.remove"])
        #expect(clear.enabled)
        clear.action?()
        for _ in 0..<200 where !controller.canEdit { await Task.yield() }
        #expect(preference.configuration == ["retained": .text("value")])
        #expect(preference.credentialRecordID == (saveFails ? "old-record" : nil))
        #expect(events == (saveFails ? ["save"] : ["save", "delete:old-record"]))
        #expect(controller.rows["plugins.\(id.rawValue).cookie.remove"]?.enabled == saveFails)
    }
}
