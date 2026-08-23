import DesignSystem
import MusicDomain
import SafariServices
import SettingsAPI
import SwiftUI
import WebKit

enum PrivacyPolicyURLs {
    static let app = URL(
        string: "https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.1.0.md"
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
            Text(L("应用隐私政策 v1.1.0"))
                .font(MusicFreeTypographyTokens.sectionTitle)

            Text(L("本地播放器的基本播放功能不需要联网。元数据和歌词服务属于可选的第三方服务，所有 Provider 默认关闭。"))

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

struct PrivacySettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    let metadataServerEnabled: Bool
    let lyricsEnabled: Bool

    var body: some View {
        List {
            Section {
                if viewModel.isPrivacyPolicyAccepted {
                    Label(L("应用隐私政策已同意"), systemImage: "checkmark.shield")
                        .foregroundStyle(MusicFreeColorTokens.accent)

                    Button(role: .destructive) {
                        viewModel.revokeOnlinePrivacy()
                    } label: {
                        Label(L("撤回同意并关闭联网服务"), systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings.privacy.application.revoke")
                } else {
                    Text(L("未同意应用隐私政策时，元数据和歌词 Provider 不会发起网络请求。"))
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
            }

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
        .navigationTitle(L("隐私与联网"))
        .navigationBarTitleDisplayMode(.inline)
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
