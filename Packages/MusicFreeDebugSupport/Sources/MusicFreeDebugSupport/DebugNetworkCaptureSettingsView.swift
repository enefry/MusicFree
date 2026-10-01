import SwiftUI
import DesignSystem

#if DEBUG && canImport(PulseUI)
import PulseUI
#endif

@MainActor
public struct DebugNetworkCaptureSettingsView: View {
    @AppStorage(DebugNetworkCapture.enabledDefaultsKey)
    private var isEnabled = false

    public init() {}

    public var body: some View {
#if DEBUG && canImport(PulseUI)
        Group {
            Toggle(isOn: $isEnabled) {
                Label(L("网络抓包 (DEBUG)"), systemImage: "network")
            }
            .accessibilityIdentifier("settings.debug.networkCapture.toggle")
            .onChange(of: isEnabled) { _, enabled in
                if enabled {
                    DebugNetworkCapture.enable()
                }
            }

            NavigationLink {
                ConsoleView(mode: .network)
                    .navigationTitle(L("网络请求"))
            } label: {
                Label(L("查看网络请求"), systemImage: "list.bullet.rectangle")
            }
            .disabled(!isEnabled)
            .accessibilityIdentifier("settings.debug.networkCapture.console")

            Text(isEnabled
                ? L("抓包已开启。关闭后需重启 App 才会停止本次运行中的抓包。请求数据仅保存在本机。")
                : L("开启后记录 URLSession 网络请求；默认关闭，仅 Debug 构建可用。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
#else
        EmptyView()
#endif
    }
}
