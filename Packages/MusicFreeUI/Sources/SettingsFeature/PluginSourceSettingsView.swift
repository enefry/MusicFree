import AppServices
import MusicDomain
import MediaSourceAPI
import SettingsAPI
import MusicFreePluginAPI
import SwiftUI

@MainActor struct PluginSourceSettingsView: View {
    let descriptor: PluginDescriptor
    let settings: any SettingsServing
    let plugins: any PluginServing
    @State private var configurations: [OnlineSourceConfiguration] = []
    var body: some View {
        List {
            ForEach(configurations, id: \.sourceID) { configuration in
                NavigationLink(configuration.displayName) {
                    PluginSourceEditor(descriptor: descriptor, configuration: configuration, settings: settings, plugins: plugins)
                }
            }
            NavigationLink("添加来源") {
                PluginSourceEditor(descriptor: descriptor, configuration: nil, settings: settings, plugins: plugins)
            }
            .accessibilityIdentifier("plugins.source.add")
        }.navigationTitle("账户与来源").task { await reload() }
    }
    private func reload() async {
        if let current = try? await settings.load() {
            configurations = current.importPreferences.onlineSourcePreferences.sources.filter { $0.providerKind.rawValue == descriptor.onlineProviderID }
        }
    }
}

@MainActor struct PluginSourceEditor: View {
    let descriptor: PluginDescriptor
    let configuration: OnlineSourceConfiguration?
    let settings: any SettingsServing
    let plugins: any PluginServing
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NativePluginSourceForm(descriptor: descriptor, configuration: configuration, settings: settings,
            plugins: plugins, onSaved: { dismiss() })
            .navigationTitle(configuration == nil ? "添加来源" : "编辑来源")
    }
}
@MainActor private struct NativePluginSourceForm: UIViewControllerRepresentable {
    let descriptor: PluginDescriptor
    let configuration: OnlineSourceConfiguration?
    let settings: any SettingsServing
    let plugins: any PluginServing
    let onSaved: () -> Void
    func makeUIViewController(context: Context) -> PluginSourceEditorViewController {
        PluginSourceEditorViewController(descriptor: descriptor, configuration: configuration,
            settings: settings, plugins: plugins, onSaved: onSaved)
    }
    func updateUIViewController(_ controller: PluginSourceEditorViewController, context: Context) {}
}
