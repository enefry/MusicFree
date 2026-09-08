import DesignSystem
import MediaSourceAPI
import MusicDomain
import SafariServices
import SettingsAPI
import SwiftUI
import WebKit

enum PrivacyPolicyURLs {
    static let app = URL(
        string: "https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.2.0.md"
    )!
}

enum PrivacyPolicyHTMLResources {
    static let lrclib = "PRIVACY_POLICY_LRCLIB"
}

private struct SafariDestination: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

private struct SafariServiceView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ viewController: SFSafariViewController, context: Context) {}
}

private struct SafariServiceLink: View {
    let title: String
    let url: URL
    @State private var destination: SafariDestination?

    var body: some View {
        Button {
            destination = SafariDestination(url: url)
        } label: {
            Label(title, systemImage: "safari")
        }
        .sheet(item: $destination) { destination in
            SafariServiceView(url: destination.url)
                .ignoresSafeArea()
                .presentationDetents([.large])
        }
    }
}

private struct LocalHTMLServiceLink: View {
    let title: String
    let resourceName: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(title, systemImage: "doc.text")
        }
        .sheet(isPresented: $isPresented) {
            LocalHTMLPolicySheet(
                title: title,
                resourceName: resourceName
            )
            .presentationDetents([.large])
        }
    }
}

private struct LocalHTMLPolicySheet: View {
    let title: String
    let resourceName: String
    @State private var externalDestination: SafariDestination?

    var body: some View {
        NavigationStack {
            LocalHTMLPolicyView(resourceName: resourceName) { url in
                externalDestination = SafariDestination(url: url)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $externalDestination) { destination in
            SafariServiceView(url: destination.url)
                .ignoresSafeArea()
                .presentationDetents([.large])
        }
    }
}

private struct LocalHTMLPolicyView: View {
    let resourceName: String
    let onOpenExternalURL: (URL) -> Void

    var body: some View {
        if let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: "html"
        ) {
            LocalHTMLWebView(
                url: url,
                onOpenExternalURL: onOpenExternalURL
            )
        } else {
            ContentUnavailableView(
                L("无法加载本地隐私说明"),
                systemImage: "doc.questionmark"
            )
        }
    }
}

private struct LocalHTMLWebView: UIViewRepresentable {
    let url: URL
    let onOpenExternalURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenExternalURL: onOpenExternalURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.loadFileURL(
            url,
            allowingReadAccessTo: url.deletingLastPathComponent()
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onOpenExternalURL: (URL) -> Void

        init(onOpenExternalURL: @escaping (URL) -> Void) {
            self.onOpenExternalURL = onOpenExternalURL
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            guard !url.isFileURL else {
                decisionHandler(.allow)
                return
            }

            if ["http", "https"].contains(url.scheme?.lowercased()) {
                onOpenExternalURL(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

struct PrivacyProviderDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let service: String
    let data: String
    let purpose: String
    let policyURL: URL?
    let localHTMLResourceName: String?

    init(
        id: String,
        title: String,
        service: String,
        data: String,
        purpose: String,
        policyURL: URL?,
        localHTMLResourceName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.service = service
        self.data = data
        self.purpose = purpose
        self.policyURL = policyURL
        self.localHTMLResourceName = localHTMLResourceName
    }
}

enum PrivacyProviderCatalog {
    static func descriptor(for providerID: String) -> PrivacyProviderDescriptor {
        switch providerID {
        case MetadataProviderID.musicKit.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("MusicKit"),
                service: "Apple Music / MusicKit",
                data: L("歌曲名称、艺人和用于目录匹配的音乐信息。"),
                purpose: L("查询歌曲元数据和封面。"),
                policyURL: URL(string: "https://www.apple.com/legal/privacy/")
            )
        case MetadataProviderID.musicBrainz.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("MusicBrainz"),
                service: "MusicBrainz and Cover Art Archive",
                data: L("歌曲名称和艺人；匹配成功后使用 MusicBrainz 发布信息请求封面。"),
                purpose: L("查询开放音乐元数据和专辑封面。"),
                policyURL: URL(string: "https://metabrainz.org/privacy")
            )
        case MetadataProviderID.metadataServer.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("Metadata Server"),
                service: L("应用配置的 Metadata Server"),
                data: L("元数据查询发送歌曲名称和艺人；歌词查询可能附带专辑和时长。"),
                purpose: L("查询元数据、封面和歌词。"),
                policyURL: URL(string: "https://music.tools4me.win/privacy")
            )
        case MetadataProviderID.discogs.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("Discogs"),
                service: "Discogs API",
                data: L("歌曲名称和艺人。应用配置的 Discogs 访问令牌不会发送给其他服务。"),
                purpose: L("查询发行版本、曲目元数据和封面。"),
                policyURL: URL(string: "https://support.discogs.com/hc/en-us/articles/360007522313-Privacy-Policy")
            )
        case LyricsProviderID.lrclib.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: "LRCLIB",
                service: "LRCLIB API",
                data: L("歌曲名称、艺人，以及可选的专辑和时长。"),
                purpose: L("查询歌词。"),
                policyURL: nil,
                localHTMLResourceName: PrivacyPolicyHTMLResources.lrclib
            )
        default:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: providerID,
                service: providerID,
                data: L("用于匹配的歌曲元数据；具体字段取决于 Provider 实现。"),
                purpose: L("提供元数据或歌词服务。"),
                policyURL: nil
            )
        }
    }
}

enum PrivacyDisclosure: Identifiable {
    case application
    case provider(PrivacyProviderDescriptor)

    var id: String {
        switch self {
        case .application:
            return "application"
        case let .provider(descriptor):
            return "provider.\(descriptor.id)"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .application:
            return "settings.privacyDisclosure.application"
        case let .provider(descriptor):
            return "settings.privacyDisclosure.provider.\(descriptor.id)"
        }
    }
}

struct PrivacyDisclosureView: View {
    let disclosure: PrivacyDisclosure
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.large) {
                    switch disclosure {
                    case .application:
                        applicationContent
                    case let .provider(descriptor):
                        providerContent(descriptor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(MusicFreeSpacingTokens.large)
            }
            .navigationTitle(L("隐私与联网服务"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: MusicFreeSpacingTokens.small) {
                    Button(role: .cancel, action: onDecline) {
                        Label(L("不同意"), systemImage: "xmark")
                            .frame(width: nil, height: 40, alignment: .center)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityIdentifier("settings.privacyDisclosure.decline")

                    Button(action: onAccept) {
                        Label(L("同意并继续"), systemImage: "checkmark")
                            .frame(width: nil, height: 40, alignment: .center)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityIdentifier("settings.privacyDisclosure.accept")
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, MusicFreeSpacingTokens.large)
                .padding(.vertical, MusicFreeSpacingTokens.small)
                .background(.bar)
            }
        }
        .accessibilityIdentifier(disclosure.accessibilityIdentifier)
        .interactiveDismissDisabled()
    }

    private var applicationContent: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.medium) {
            Text(L("应用隐私政策 v1.2.0"))
                .font(MusicFreeTypographyTokens.sectionTitle)

            Text(L("本地播放器的基本播放功能不需要联网。DS Audio、Google Drive、元数据和歌词都属于可选的第三方服务，所有 Provider 默认关闭。"))

            Text(L("同意后，应用才会在你开启 Provider 时向对应服务发送歌曲匹配信息。应用不会主动上传音频文件、完整文件路径或整个音乐库。"))

            Text(L("网络服务通常可以获得请求 IP 地址和 User-Agent，并按照各自的隐私政策处理请求日志。匹配结果、封面和歌词会保存到本地资料库。"))

            SafariServiceLink(
                title: L("查看完整隐私政策"),
                url: PrivacyPolicyURLs.app
            )
        }
    }

    private func providerContent(
        _ descriptor: PrivacyProviderDescriptor
    ) -> some View {
        PrivacyProviderContentView(descriptor: descriptor)
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
    }
}

private struct PrivacyProviderContentView: View {
    let descriptor: PrivacyProviderDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.medium) {
            Text(descriptor.title)
                .font(MusicFreeTypographyTokens.sectionTitle)

            privacyRow(L("服务"), descriptor.service)
            privacyRow(L("发送信息"), descriptor.data)
            privacyRow(L("用途"), descriptor.purpose)

            Text(L("关闭 Provider 后不再发送新的请求；已经由第三方服务接收的请求日志由其隐私政策管理。"))

            if let localHTMLResourceName = descriptor.localHTMLResourceName {
                if descriptor.id == LyricsProviderID.lrclib.rawValue {
                    Text(L("LRCLIB 未提供官方隐私协议；以下是应用提供的 Provider 隐私说明。"))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }

                LocalHTMLServiceLink(
                    title: descriptor.id == LyricsProviderID.lrclib.rawValue
                        ? L("查看应用提供的 LRCLIB 隐私说明")
                        : L("查看服务隐私政策"),
                    resourceName: localHTMLResourceName
                )
            } else if let policyURL = descriptor.policyURL {
                SafariServiceLink(
                    title: L("查看服务隐私政策"),
                    url: policyURL
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func privacyRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
            Text(title)
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            Text(value)
        }
    }
}

struct PrivacyProviderDetailsView: View {
    let descriptor: PrivacyProviderDescriptor
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.large) {
                PrivacyProviderContentView(descriptor: descriptor)
                providerConsentContent
            }
            .padding(MusicFreeSpacingTokens.large)
        }
        .navigationTitle(L("服务说明"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.privacy.provider.details.\(descriptor.id)")
    }

    private var providerConsentContent: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
            Divider()

            Text(L("Provider 隐私协议"))
                .font(MusicFreeTypographyTokens.sectionTitle)

            if !viewModel.isPrivacyPolicyAccepted {
                Text(L("请先同意应用隐私政策，才能启用此 Provider。"))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            if isProviderPolicyAccepted {
                Label(L("Provider 隐私协议已同意"), systemImage: "checkmark.shield")
                    .foregroundStyle(MusicFreeColorTokens.accent)

                Button(role: .destructive) {
                    viewModel.revokeProviderPrivacy(for: descriptor.id)
                } label: {
                    Label(L("撤回"), systemImage: "hand.raised")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier(
                    "settings.privacy.provider.\(descriptor.id).revoke"
                )
            } else {
                Button {
                    viewModel.acceptProviderPrivacy(for: descriptor.id)
                } label: {
                    Label(L("同意"), systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.isPrivacyPolicyAccepted)
                .accessibilityIdentifier(
                    "settings.privacy.provider.\(descriptor.id).accept"
                )
            }
        }
    }

    private var isProviderPolicyAccepted: Bool {
        viewModel.settings.importPreferences.privacyPreferences
            .isProviderPolicyAccepted(descriptor.id)
    }
}

private struct OnlineSourcePrivacyDetailsView: View {
    let configuration: OnlineSourceConfiguration
    @Bindable var viewModel: SettingsViewModel
    @State private var isRevokeConfirmationPresented = false

    private var currentConfiguration: OnlineSourceConfiguration {
        viewModel.onlineSourceConfigurations.first {
            $0.sourceID == configuration.sourceID
        } ?? configuration
    }

    private var isPolicyAccepted: Bool {
        currentConfiguration.privacyPolicyVersion
            == currentConfiguration.providerKind.defaultPrivacyPolicyVersion
    }

    var body: some View {
        List {
            Section {
                Label(
                    currentConfiguration.displayName,
                    systemImage: onlineSourceProviderSymbol(
                        currentConfiguration.providerKind
                    )
                )
            } header: {
                Text(L("来源"))
            }

            Section {
                privacyRow(L("来源类型"), onlineSourceProviderTitle(currentConfiguration.providerKind))
                privacyRow(L("协议版本"), currentConfiguration.providerKind.defaultPrivacyPolicyVersion)
                privacyRow(L("会发送的数据"), privacyDataDescription)
                privacyRow(L("使用目的"), privacyPurposeDescription)
            } header: {
                Text(L("来源级隐私协议"))
            }

            Section {
                if isPolicyAccepted {
                    Label(L("来源隐私协议已同意"), systemImage: "checkmark.shield")
                        .foregroundStyle(MusicFreeColorTokens.accent)

                    Button(role: .destructive) {
                        isRevokeConfirmationPresented = true
                    } label: {
                        Label(L("撤销并停用此来源"), systemImage: "hand.raised")
                    }
                    .disabled(viewModel.isSaving)
                    .accessibilityIdentifier(
                        "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).revoke"
                    )
                } else {
                    Text(L("首次进入此来源时会弹出协议；同意后才能浏览、试听或导入。"))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

                    Button {
                        viewModel.acceptOnlineSourcePrivacy(
                            configuration.sourceID,
                            policyVersion: currentConfiguration.providerKind.defaultPrivacyPolicyVersion
                        )
                    } label: {
                        Label(L("同意此来源隐私协议"), systemImage: "checkmark")
                    }
                    .disabled(viewModel.isSaving || !viewModel.isPrivacyPolicyAccepted)
                    .accessibilityIdentifier(
                        "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).accept"
                    )
                }
            } header: {
                Text(L("同意状态"))
            } footer: {
                Text(L("撤销后立即停止此来源的新请求并清除来源级同意；已经导入本地的媒体不会删除。"))
            }
        }
        .navigationTitle(currentConfiguration.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(
            "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).details"
        )
        .confirmationDialog(
            L("撤销来源隐私协议？"),
            isPresented: $isRevokeConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L("撤销并停用"), role: .destructive) {
                viewModel.revokeOnlineSourcePrivacy(configuration.sourceID)
            }
            .accessibilityIdentifier(
                "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).revoke.confirm"
            )
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(
                L("撤销“\(currentConfiguration.displayName)”后会停止此来源的新请求并清除来源级同意；已经导入本地的媒体不会删除。")
            )
        }
    }

    private var privacyDataDescription: String {
        switch currentConfiguration.providerKind {
        case .dsAudio:
            L("你填写的 DS Audio 地址、账号和本次登录所需的认证信息，以及浏览、搜索、下载和临时试听所需的音频目录数据。验证码只在本次验证期间使用。")
        case .googleDrive:
            L("Google OAuth 会话和 Google Drive 文件目录、文件大小及下载所需的临时访问信息。令牌只存放在系统 Keychain；1.2.0 不进行 Google Drive 在线试听。")
        case .baiduPan:
            L("百度网盘来源配置和 Provider 实现实际需要的数据。当前版本未提供可用的百度网盘适配器。")
        case .gateway:
            L("网关 Provider 实现声明的目录和访问数据。当前版本未提供可用的网关适配器。")
        }
    }

    private var privacyPurposeDescription: String {
        switch currentConfiguration.providerKind {
        case .dsAudio:
            L("仅用于浏览来源目录、搜索音频、下载并导入本地媒体库，以及临时试听。")
        case .googleDrive:
            L("仅用于浏览 Google Drive 音频文件、下载并导入本地媒体库。")
        case .baiduPan, .gateway:
            L("仅用于未来 Provider 支持的在线源功能。")
        }
    }

    private func privacyRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
            Text(title)
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PrivacySettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    let metadataServerEnabled: Bool
    let lyricsEnabled: Bool
    @State private var isApplicationPrivacyRevokeConfirmationPresented = false

    var body: some View {
        List {
            applicationPrivacySection
            onlineSourceAvailabilitySection
            onlineSourcePrivacySection

            Section {
                ForEach(providerDescriptors) { descriptor in
                    NavigationLink {
                        PrivacyProviderDetailsView(
                            descriptor: descriptor,
                            viewModel: viewModel
                        )
                    } label: {
                        HStack(spacing: MusicFreeSpacingTokens.small) {
                            Label(descriptor.title, systemImage: "network")
                            Spacer(minLength: MusicFreeSpacingTokens.small)
                            Text(providerConsentStatus(for: descriptor))
                                .font(MusicFreeTypographyTokens.caption)
                                .foregroundStyle(
                                    isProviderPolicyAccepted(descriptor)
                                        ? MusicFreeColorTokens.accent
                                        : MusicFreeColorTokens.foregroundSecondary
                                )
                        }
                    }
                    .accessibilityIdentifier("settings.privacy.provider.\(descriptor.id)")
                }
            } header: {
                Text(L("Provider 服务说明"))
            } footer: {
                Text(L("Provider 同意独立保存；撤回后会同时关闭对应 Provider，未启用的 Provider 不会发起请求。"))
            }
        }
        .navigationTitle(L("隐私与联网服务"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            L("撤回应用隐私政策？"),
            isPresented: $isApplicationPrivacyRevokeConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L("撤回并关闭所有在线源"), role: .destructive) {
                viewModel.revokeOnlinePrivacy()
            }
            .accessibilityIdentifier("settings.privacy.application.revoke.confirm")
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("这会撤销应用级同意，同时撤销并停用所有在线源；来源配置和已经导入本地的媒体会保留。"))
        }
    }

    @ViewBuilder
    private var applicationPrivacySection: some View {
        Section {
            if viewModel.isPrivacyPolicyAccepted {
                Label(L("应用隐私政策已同意"), systemImage: "checkmark.shield")
                    .foregroundStyle(MusicFreeColorTokens.accent)

                Button(role: .destructive) {
                    isApplicationPrivacyRevokeConfirmationPresented = true
                } label: {
                    Label(L("撤回同意并关闭联网服务"), systemImage: "hand.raised")
                }
                .accessibilityIdentifier("settings.privacy.application.revoke")
            } else {
                Text(L("未同意应用隐私政策时，元数据、歌词和在线源都不会发起网络请求。"))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

                Button {
                    viewModel.acceptPrivacyPolicy()
                } label: {
                    Label(L("同意应用隐私政策"), systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("settings.privacy.application.accept")
            }

            SafariServiceLink(
                title: L("查看完整隐私政策"),
                url: PrivacyPolicyURLs.app
            )
        } header: {
            Text(L("应用隐私政策"))
        } footer: {
            Text(L("首次进入在线源时会单独弹出应用级协议；这里用于查看和撤回同意。撤回后会同时停用所有在线源。"))
        }
    }

    @ViewBuilder
    private var onlineSourceAvailabilitySection: some View {
        Section {
            Toggle(
                L("启用在线源服务"),
                isOn: Binding(
                    get: { viewModel.isPrivacyPolicyAccepted && viewModel.isOnlineSourcesEnabled },
                    set: { viewModel.setOnlineSourcesEnabled($0) }
                )
            )
            .disabled(viewModel.isSaving || !viewModel.isPrivacyPolicyAccepted)
            .accessibilityValue(onlineSourcesAvailabilityStatus)
            .accessibilityIdentifier("settings.privacy.onlineSources.toggle")

            if !viewModel.isPrivacyPolicyAccepted {
                Text(L("请先同意应用隐私政策，在线源服务会保持关闭。"))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            if viewModel.onlineSourceConfigurations.isEmpty {
                Text(L("还没有配置在线源。请从在线源 Tab 添加来源。"))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            } else {
                ForEach(viewModel.onlineSourceConfigurations, id: \.sourceID) { configuration in
                    Toggle(
                        isOn: Binding(
                            get: {
                                viewModel.onlineSourceConfigurations
                                    .first(where: { $0.sourceID == configuration.sourceID })?
                                    .isEnabled == true
                            },
                            set: { viewModel.setOnlineSourceEnabled(configuration.sourceID, $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                            Text(configuration.displayName)
                            Text(onlineSourceProviderTitle(configuration.providerKind))
                                .font(MusicFreeTypographyTokens.caption)
                                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                            Text(sourceAvailabilityStatus(configuration))
                                .font(MusicFreeTypographyTokens.caption)
                                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        }
                    }
                    .disabled(
                        viewModel.isSaving
                            || !viewModel.isPrivacyPolicyAccepted
                            || !isOnlineSourcePrivacyAccepted(configuration)
                    )
                    .accessibilityIdentifier(
                        "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).enabled"
                    )
                }
            }
        } header: {
            Text(L("在线源可用性"))
        } footer: {
            Text(L("总开关控制在线源服务；每个来源还可以独立启用或关闭。已经导入本地的媒体不受影响。"))
        }
    }

    @ViewBuilder
    private var onlineSourcePrivacySection: some View {
        Section {
            if viewModel.onlineSourceConfigurations.isEmpty {
                Text(L("添加来源后，这里会显示每个来源独立的隐私协议状态。"))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            } else {
                ForEach(viewModel.onlineSourceConfigurations, id: \.sourceID) { configuration in
                    NavigationLink {
                        OnlineSourcePrivacyDetailsView(
                            configuration: configuration,
                            viewModel: viewModel
                        )
                    } label: {
                        HStack(spacing: MusicFreeSpacingTokens.small) {
                            Label(
                                configuration.displayName,
                                systemImage: onlineSourceProviderSymbol(
                                    configuration.providerKind
                                )
                            )
                            Spacer(minLength: MusicFreeSpacingTokens.small)
                            Text(
                                isOnlineSourcePrivacyAccepted(configuration)
                                    ? L("已同意")
                                    : L("待同意")
                            )
                                .font(MusicFreeTypographyTokens.caption)
                                .foregroundStyle(
                                    isOnlineSourcePrivacyAccepted(configuration)
                                        ? MusicFreeColorTokens.accent
                                        : MusicFreeColorTokens.foregroundSecondary
                                )
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.privacy.onlineSource.\(configuration.sourceID.rawValue).privacy"
                    )
                }
            }
        } header: {
            Text(L("在线源隐私协议"))
        } footer: {
            Text(L("每个来源单独保存同意状态。点击来源查看协议详情并撤销；撤销某个来源会立即停用它，撤销应用隐私协议会同时清除所有来源同意。"))
        }
    }

    private var onlineSourcesAvailabilityStatus: String {
        guard viewModel.isPrivacyPolicyAccepted else {
            return L("需要先同意应用隐私政策")
        }
        return viewModel.isOnlineSourcesEnabled ? L("已开启") : L("已关闭")
    }

    private func sourceAvailabilityStatus(
        _ configuration: OnlineSourceConfiguration
    ) -> String {
        guard viewModel.isPrivacyPolicyAccepted else {
            return L("需要先同意应用隐私政策")
        }
        guard isOnlineSourcePrivacyAccepted(configuration) else {
            return L("需要先同意来源隐私协议")
        }
        if configuration.isEnabled {
            return viewModel.isOnlineSourcesEnabled ? L("已启用") : L("已启用，但总开关已关闭")
        }
        return L("已关闭")
    }

    private func isOnlineSourcePrivacyAccepted(
        _ configuration: OnlineSourceConfiguration
    ) -> Bool {
        configuration.privacyPolicyVersion
            == configuration.providerKind.defaultPrivacyPolicyVersion
    }

    private var providerDescriptors: [PrivacyProviderDescriptor] {
        var providerIDs: [String] = []
        var seen = Set<String>()

        for status in viewModel.metadataEnrichmentSnapshot.providerStatuses where status.isRegistered {
            let provider = status.provider
            guard metadataServerEnabled || provider != .metadataServer else {
                continue
            }
            if seen.insert(provider.rawValue).inserted {
                providerIDs.append(provider.rawValue)
            }
        }

        if lyricsEnabled {
            for preference in viewModel.settings.importPreferences.lyricsProviders {
                let provider = preference.provider
                guard viewModel.availableLyricsProviderIDs.contains(provider) else {
                    continue
                }
                guard metadataServerEnabled || provider != .metadataServer else {
                    continue
                }
                if seen.insert(provider.rawValue).inserted {
                    providerIDs.append(provider.rawValue)
                }
            }
        }

        return providerIDs.map(PrivacyProviderCatalog.descriptor)
    }

    private func isProviderPolicyAccepted(
        _ descriptor: PrivacyProviderDescriptor
    ) -> Bool {
        viewModel.settings.importPreferences.privacyPreferences
            .isProviderPolicyAccepted(descriptor.id)
    }

    private func providerConsentStatus(
        for descriptor: PrivacyProviderDescriptor
    ) -> String {
        isProviderPolicyAccepted(descriptor) ? L("已确认") : L("未确认")
    }
}

private func onlineSourceProviderTitle(_ providerKind: OnlineProviderKind) -> String {
    switch providerKind {
    case .dsAudio: return "DS Audio"
    case .googleDrive: return "Google Drive"
    case .baiduPan: return L("百度网盘")
    case .gateway: return L("网关")
    }
}

private func onlineSourceProviderSymbol(_ providerKind: OnlineProviderKind) -> String {
    switch providerKind {
    case .dsAudio: return "waveform"
    case .googleDrive: return "externaldrive"
    case .baiduPan: return "cloud"
    case .gateway: return "network"
    }
}
