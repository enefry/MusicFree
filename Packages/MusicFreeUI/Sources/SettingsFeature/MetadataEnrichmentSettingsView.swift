import DesignSystem
import LibraryAPI
import MusicDomain
import SettingsAPI
import SwiftUI

struct MetadataEnrichmentSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    let metadataServerEnabled: Bool
    let lyricsEnabled: Bool
    @State private var displayedSnapshot = MetadataEnrichmentSnapshot()
    @State private var displayedLyricsPreloadSnapshot = LyricsPreloadSnapshot()
    @State private var scanPresentation: ScanPresentation = .idle
    @State private var lyricsPreloadPresentation: LyricsPreloadPresentation = .idle
    @State private var privacyDisclosure: PrivacyDisclosure?
    @State private var pendingProviderActivation: ProviderActivation?

    private enum ProviderActivation: Identifiable {
        case metadata(MetadataProviderID)
        case lyrics(LyricsProviderID)

        var id: String {
            "provider-activation.\(providerID)"
        }

        var providerID: String {
            switch self {
            case let .metadata(provider):
                return provider.rawValue
            case let .lyrics(provider):
                return provider.rawValue
            }
        }
    }

    private enum ScanPresentation {
        case idle
        case starting
        case cancelling
    }

    private enum LyricsPreloadPresentation {
        case idle
        case starting
        case cancelling
    }

    init(
        viewModel: SettingsViewModel,
        metadataServerEnabled: Bool = true,
        lyricsEnabled: Bool = true
    ) {
        _viewModel = Bindable(viewModel)
        self.metadataServerEnabled = metadataServerEnabled
        self.lyricsEnabled = lyricsEnabled
    }

    var body: some View {
        List {
            metadataSection
            if lyricsEnabled {
                lyricsSection
            }
        }
        .navigationTitle(L("元数据填充"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
        .sheet(item: $privacyDisclosure) { disclosure in
            PrivacyDisclosureView(
                disclosure: disclosure,
                onAccept: acceptPrivacyDisclosure,
                onDecline: declinePrivacyDisclosure
            )
        }
        .task {
            viewModel.resumeMetadataObservation()
            displayedSnapshot = viewModel.metadataEnrichmentSnapshot
            let stream = await viewModel.makeMetadataSnapshotStream()
            for await value in stream {
                guard !Task.isCancelled else { return }
                applySnapshot(value)
            }
        }
        .task {
            viewModel.resumeLyricsPreloadObservation()
            displayedLyricsPreloadSnapshot = viewModel.lyricsPreloadSnapshot
            let stream = await viewModel.makeLyricsPreloadSnapshotStream()
            for await value in stream {
                guard !Task.isCancelled else { return }
                applyLyricsPreloadSnapshot(value)
            }
        }
    }

    private func setMetadataProviderEnabled(
        _ provider: MetadataProviderID,
        _ isEnabled: Bool
    ) {
        guard isEnabled else {
            viewModel.setMetadataProviderEnabled(provider, false)
            return
        }
        requestProviderActivation(.metadata(provider))
    }

    private func setLyricsProviderEnabled(
        _ provider: LyricsProviderID,
        _ isEnabled: Bool
    ) {
        guard isEnabled else {
            viewModel.setLyricsProviderEnabled(provider, false)
            return
        }
        requestProviderActivation(.lyrics(provider))
    }

    private func requestProviderActivation(_ activation: ProviderActivation) {
        pendingProviderActivation = activation

        if !viewModel.isPrivacyPolicyAccepted {
            privacyDisclosure = .application
        } else if !viewModel.settings.importPreferences.privacyPreferences
            .isProviderPolicyAccepted(activation.providerID) {
            privacyDisclosure = .provider(
                PrivacyProviderCatalog.descriptor(for: activation.providerID)
            )
        } else {
            completeProviderActivation()
        }
    }

    private func acceptPrivacyDisclosure() {
        switch privacyDisclosure {
        case .application:
            viewModel.acceptPrivacyPolicy()
            guard let activation = pendingProviderActivation else {
                privacyDisclosure = nil
                return
            }
            privacyDisclosure = .provider(
                PrivacyProviderCatalog.descriptor(for: activation.providerID)
            )
        case let .provider(descriptor):
            viewModel.acceptProviderPrivacy(for: descriptor.id)
            completeProviderActivation()
        case nil:
            break
        }
    }

    private func declinePrivacyDisclosure() {
        switch privacyDisclosure {
        case .application:
            viewModel.revokeOnlinePrivacy()
        case let .provider(descriptor):
            viewModel.revokeProviderPrivacy(for: descriptor.id)
        case nil:
            break
        }
        pendingProviderActivation = nil
        privacyDisclosure = nil
    }

    private func completeProviderActivation() {
        guard let activation = pendingProviderActivation else {
            privacyDisclosure = nil
            return
        }

        pendingProviderActivation = nil
        privacyDisclosure = nil
        Task { @MainActor in
            await viewModel.waitForPendingWork()
            switch activation {
            case let .metadata(provider):
                viewModel.setMetadataProviderEnabled(provider, true)
            case let .lyrics(provider):
                viewModel.setLyricsProviderEnabled(provider, true)
            }
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        Section {
            ForEach(visibleMetadataProviderPreferences) { preference in
                metadataProviderRow(preference)
            }
            .onMove { source, destination in
                viewModel.moveMetadataProviders(
                    from: source,
                    to: destination,
                    within: visibleMetadataProviderPreferences.map(\.provider)
                )
            }

            metadataScanContent
        } header: {
            Text(L("元数据"))
                .accessibilityIdentifier("settings.import.metadata.section")
        } footer: {
            metadataFooter
        }
    }

    @ViewBuilder
    private var lyricsSection: some View {
        Section {
            ForEach(visibleLyricsProviderPreferences) { preference in
                Toggle(
                    isOn: Binding(
                        get: {
                            isLyricsProviderEffectivelyEnabled(preference.provider)
                        },
                        set: {
                            setLyricsProviderEnabled(preference.provider, $0)
                        }
                    )
                ) {
                    Label(
                        lyricsProviderTitle(preference.provider),
                        systemImage: lyricsProviderIcon(preference.provider)
                    )
                }
                .accessibilityIdentifier(
                    lyricsProviderToggleIdentifier(preference.provider)
                )
            }

            lyricsPreloadContent
        } header: {
            Text(L("歌词"))
                .accessibilityIdentifier("settings.import.lyrics.section")
        } footer: {
            Label(
                L("按启用顺序匹配歌词；播放页按需获取并保存，预下载只处理没有本地歌词的歌曲。"),
                systemImage: "info.circle"
            )
        }
    }

    @ViewBuilder
    private var lyricsPreloadContent: some View {
        let preload = displayedLyricsPreloadSnapshot
        if !viewModel.hasEnabledLyricsProviders {
            Text(L("请先开启至少一个歌词来源，本地歌词仍可显示。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        } else if !viewModel.canPreloadLyrics {
            Text(L("歌词服务不可用。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        } else if preload.status == .downloading {
            if preload.total > 0 {
                ProgressView(
                    value: Double(preload.processed),
                    total: Double(preload.total)
                )
            } else {
                ProgressView()
            }

            Button(role: .cancel) {
                cancelLyricsPreload()
            } label: {
                Label(L("取消预下载"), systemImage: "xmark")
            }
            .accessibilityIdentifier("settings.import.lyricsPreloadCancel")

            Text(L("正在预下载 %d/%d", preload.processed, preload.total))
                .font(MusicFreeTypographyTokens.secondary)
                .accessibilityIdentifier("settings.import.lyricsPreloadProgress")
            if let currentTitle = preload.currentTitle {
                Text(currentTitle)
                    .lineLimit(1)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            } else {
                Text("-")
                    .lineLimit(1)
                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
            }
        } else {
            Button {
                startLyricsPreload()
            } label: {
                Label(L("预下载歌词"), systemImage: "arrow.down.circle")
            }
            .disabled(preload.status == .downloading)
            .accessibilityIdentifier("settings.import.lyricsPreload")

            if preload.status == .completed || preload.status == .cancelled {
                Text(lyricsPreloadSummary(preload))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            } else if preload.status == .failed {
                Text(L("歌词预下载未完成，请稍后重试。"))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(MusicFreeColorTokens.warning)
            }
        }
    }

    @ViewBuilder
    private var metadataScanContent: some View {
        let scan = displayedSnapshot.scan
        if displayedSnapshot.isEnabled,
           displayedSnapshot.authorization == .authorized {
            if scan.status == .scanning {
                if scan.total > 0 {
                    ProgressView(
                        value: Double(scan.processed),
                        total: Double(scan.total)
                    )
                } else {
                    ProgressView()
                }
                Button(role: .cancel) {
                    cancelScan()
                } label: {
                    Label(L("取消扫描"), systemImage: "xmark")
                }
                .accessibilityIdentifier("settings.import.musicKitCancel")

                Text(L("正在扫描 %d/%d", scan.processed, scan.total))
                    .font(MusicFreeTypographyTokens.secondary)
                    .accessibilityIdentifier("settings.import.musicKitProgress")
                if let currentTitle = scan.currentTitle {
                    Text(currentTitle)
                        .lineLimit(1)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                } else {
                    // 防止画面抖动
                    Text("-")
                        .lineLimit(1)
                        .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                }
            } else {
                Button {
                    startScan()
                } label: {
                    Label(L("扫描并补充"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(scan.status == .scanning)
                .accessibilityIdentifier("settings.import.musicKitScan")

                if scan.status == .completed || scan.status == .cancelled {
                    Text(scanSummary(scan))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                } else if scan.status == .failed {
                    Text(L("扫描未完成，请稍后重试。"))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.warning)
                }
            }
        } else {
            Text(L("请先开启至少一个可用的元数据来源。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        }
    }

    @ViewBuilder
    private func metadataProviderRow(
        _ preference: MetadataProviderPreference
    ) -> some View {
        let status = displayedSnapshot.status(for: preference.provider)
        let isRegistered = status?.isRegistered == true

        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
            HStack(alignment: .top, spacing: MusicFreeSpacingTokens.small) {
                Toggle(
                    isOn: Binding(
                        get: {
                            isMetadataProviderEffectivelyEnabled(preference.provider)
                        },
                        set: {
                            setMetadataProviderEnabled(preference.provider, $0)
                        }
                    )
                ) {
                    Label(
                        providerTitle(preference.provider),
                        systemImage: providerIcon(preference.provider)
                    )
                }
                .disabled(!isRegistered)
                .accessibilityIdentifier(providerToggleIdentifier(preference.provider))

                Spacer(minLength: MusicFreeSpacingTokens.small)

                Text(providerStatusText(status))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(
                        isRegistered
                            ? MusicFreeColorTokens.foregroundSecondary
                            : MusicFreeColorTokens.warning
                    )
                    .multilineTextAlignment(.trailing)
            }

            if let status,
               status.isRegistered,
               status.authorization == .denied || status.authorization == .restricted {
                Button {
                    viewModel.requestMetadataAuthorization(for: preference.provider)
                } label: {
                    Label(L("重新请求权限"), systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(providerAuthorizationIdentifier(preference.provider))
            }
        }
    }

    private var metadataFooter: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
            Label(
                L("按启用顺序依次匹配；成功后停止。已有本地信息不会覆盖。"),
                systemImage: "info.circle"
            )
        }
    }

    private var visibleMetadataProviderPreferences: [MetadataProviderPreference] {
        viewModel.settings.importPreferences.metadataProviders.filter {
            isMetadataProviderVisible($0.provider)
        }
    }

    private var visibleLyricsProviderPreferences: [LyricsProviderPreference] {
        viewModel.settings.importPreferences.lyricsProviders.filter {
            isLyricsProviderVisible($0.provider)
        }
    }

    private func isMetadataProviderVisible(_ provider: MetadataEnrichmentProvider) -> Bool {
        metadataServerEnabled || provider != .metadataServer
    }

    private func isMetadataProviderEffectivelyEnabled(
        _ provider: MetadataEnrichmentProvider
    ) -> Bool {
        viewModel.settings.importPreferences.runtimeMetadataProviders.contains {
            $0.provider == provider && $0.isEnabled
        }
    }

    private func isLyricsProviderVisible(_ provider: LyricsProviderID) -> Bool {
        metadataServerEnabled || provider != .metadataServer
    }

    private func isLyricsProviderEffectivelyEnabled(_ provider: LyricsProviderID) -> Bool {
        viewModel.settings.importPreferences.runtimeLyricsProviders.contains {
            $0.provider == provider && $0.isEnabled
        }
    }

    private func lyricsProviderTitle(_ provider: LyricsProviderID) -> String {
        switch provider {
        case .metadataServer:
            return L("Metadata Server")
        case .lrclib:
            return "LRCLIB"
        default:
            return provider.rawValue
        }
    }

    private func lyricsProviderIcon(_ provider: LyricsProviderID) -> String {
        switch provider {
        case .metadataServer:
            return "server.rack"
        case .lrclib:
            return "quote.bubble"
        default:
            return "puzzlepiece.extension"
        }
    }

    private func lyricsProviderToggleIdentifier(_ provider: LyricsProviderID) -> String {
        "settings.import.lyricsProvider.\(provider.rawValue).enabled"
    }

    private func providerTitle(_ provider: MetadataEnrichmentProvider) -> String {
        switch provider {
        case .musicKit:
            return L("MusicKit")
        case .musicBrainz:
            return L("MusicBrainz")
        case .metadataServer:
            return L("Metadata Server")
        case .discogs:
            return L("Discogs")
        default:
            return provider.rawValue
        }
    }

    private func providerIcon(_ provider: MetadataEnrichmentProvider) -> String {
        switch provider {
        case .musicKit:
            return "wand.and.stars"
        case .musicBrainz:
            return "globe"
        case .metadataServer:
            return "server.rack"
        case .discogs:
            return "music.note.list"
        default:
            return "puzzlepiece.extension"
        }
    }

    private func providerStatusText(
        _ status: MetadataEnrichmentProviderSnapshot?
    ) -> String {
        guard let status else { return L("状态未知") }
        guard status.isRegistered else { return L("尚未接入") }
        switch status.authorization {
        case .notDetermined:
            return L("未授权")
        case .authorized:
            return L("可用")
        case .denied:
            return L("权限已拒绝")
        case .restricted:
            return L("设备受限")
        case .unavailable:
            return L("不可用")
        }
    }

    private func providerToggleIdentifier(_ provider: MetadataEnrichmentProvider) -> String {
        if provider == .musicKit {
            return "settings.import.musicKitEnrichment"
        }
        return "settings.import.metadataProvider.\(provider.rawValue).enabled"
    }

    private func providerAuthorizationIdentifier(_ provider: MetadataEnrichmentProvider) -> String {
        if provider == .musicKit {
            return "settings.import.musicKitAuthorization"
        }
        return "settings.import.metadataProvider.\(provider.rawValue).authorization"
    }

    private func scanSummary(_ scan: MetadataEnrichmentScanSnapshot) -> String {
        L(
            "已处理 %d 首，匹配 %d 首，无匹配 %d 首，不确定 %d 首，失败 %d 首。",
            scan.processed,
            scan.matched,
            scan.noMatch,
            scan.ambiguous,
            scan.failed
        )
    }

    private func startScan() {
        scanPresentation = .starting
        viewModel.startMetadataScan()
        displayedSnapshot = viewModel.metadataEnrichmentSnapshot
    }

    private func cancelScan() {
        scanPresentation = .cancelling
        viewModel.cancelMetadataScan()
        displayedSnapshot = viewModel.metadataEnrichmentSnapshot
    }

    private func startLyricsPreload() {
        lyricsPreloadPresentation = .starting
        viewModel.startLyricsPreload()
        displayedLyricsPreloadSnapshot = viewModel.lyricsPreloadSnapshot
    }

    private func cancelLyricsPreload() {
        lyricsPreloadPresentation = .cancelling
        viewModel.cancelLyricsPreload()
        displayedLyricsPreloadSnapshot = viewModel.lyricsPreloadSnapshot
    }

    private func applySnapshot(_ value: MetadataEnrichmentSnapshot) {
        switch scanPresentation {
        case .idle:
            break
        case .starting:
            // Ignore a queued stream value from before the start action. The
            // service's first meaningful value is scanning or a terminal state.
            guard value.scan.status != .idle else { return }
        case .cancelling:
            // Cancellation is reflected locally before a slow provider returns.
            // A late progress value must not make the page look active again.
            guard value.scan.status != .scanning else { return }
        }

        displayedSnapshot = value
        if value.scan.status != .scanning {
            scanPresentation = .idle
        }
    }

    private func applyLyricsPreloadSnapshot(_ value: LyricsPreloadSnapshot) {
        switch lyricsPreloadPresentation {
        case .idle:
            break
        case .starting:
            guard value.status != .idle else { return }
        case .cancelling:
            guard value.status != .downloading else { return }
        }

        displayedLyricsPreloadSnapshot = value
        if value.status != .downloading {
            lyricsPreloadPresentation = .idle
        }
    }

    private func lyricsPreloadSummary(_ preload: LyricsPreloadSnapshot) -> String {
        L(
            "已处理 %d 首，下载 %d 首，已有 %d 首，无歌词 %d 首，失败 %d 首。",
            preload.processed,
            preload.downloaded,
            preload.cached,
            preload.noLyrics,
            preload.failed
        )
    }
}
