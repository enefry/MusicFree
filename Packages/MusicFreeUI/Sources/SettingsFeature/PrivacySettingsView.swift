import DesignSystem
import MusicDomain
import SafariServices
import SettingsAPI
import SwiftUI

enum PrivacyPolicyURLs {
    static let app = URL(
        string: "https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.1.0.md"
    )!
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

struct PrivacyProviderDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let service: String
    let data: String
    let purpose: String
    let policyURL: URL?
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
                policyURL: URL(string: "https://lrclib.net/privacy")
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
                .padding(MusicFreeSpacingTokens.large)
            }
            .navigationTitle(L("隐私与联网服务"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: MusicFreeSpacingTokens.small) {
                    Button(role: .cancel, action: onDecline) {
                        Label(L("不同意"), systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.privacyDisclosure.decline")

                    Button(action: onAccept) {
                        Label(L("同意并继续"), systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.privacyDisclosure.accept")
                }
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
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.medium) {
            Text(descriptor.title)
                .font(MusicFreeTypographyTokens.sectionTitle)

            privacyRow(L("服务"), descriptor.service)
            privacyRow(L("发送信息"), descriptor.data)
            privacyRow(L("用途"), descriptor.purpose)

            Text(L("关闭 Provider 后不再发送新的请求；已经由第三方服务接收的请求日志由其隐私政策管理。"))

            if let policyURL = descriptor.policyURL {
                SafariServiceLink(
                    title: L("查看服务隐私政策"),
                    url: policyURL
                )
            }
        }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.large) {
                Text(descriptor.title)
                    .font(MusicFreeTypographyTokens.sectionTitle)

                detailRow(L("服务"), descriptor.service)
                detailRow(L("发送信息"), descriptor.data)
                detailRow(L("用途"), descriptor.purpose)

                if let policyURL = descriptor.policyURL {
                    SafariServiceLink(
                        title: L("查看服务隐私政策"),
                        url: policyURL
                    )
                }
            }
            .padding(MusicFreeSpacingTokens.large)
        }
        .navigationTitle(L("服务说明"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
            Text(title)
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            Text(value)
        }
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
                    VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
                        NavigationLink {
                            PrivacyProviderDetailsView(descriptor: descriptor)
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

                        HStack {
                            Spacer(minLength: MusicFreeSpacingTokens.small)
                            providerConsentButton(for: descriptor)
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

    @ViewBuilder
    private func providerConsentButton(
        for descriptor: PrivacyProviderDescriptor
    ) -> some View {
        if isProviderPolicyAccepted(descriptor) {
            Button(role: .destructive) {
                viewModel.revokeProviderPrivacy(for: descriptor.id)
            } label: {
                Label(L("撤回"), systemImage: "hand.raised")
            }
            .accessibilityIdentifier(
                "settings.privacy.provider.\(descriptor.id).revoke"
            )
        } else {
            Button {
                viewModel.acceptProviderPrivacy(for: descriptor.id)
            } label: {
                Label(L("同意"), systemImage: "checkmark")
            }
            .disabled(!viewModel.isPrivacyPolicyAccepted)
            .accessibilityIdentifier(
                "settings.privacy.provider.\(descriptor.id).accept"
            )
        }
    }
}
