import DesignSystem
import LibraryAPI
import SettingsAPI
import SwiftUI

struct MetadataEnrichmentSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var displayedSnapshot = MetadataEnrichmentSnapshot()
    @State private var displayedLyricsPreloadSnapshot = LyricsPreloadSnapshot()
    @State private var scanPresentation: ScanPresentation = .idle
    @State private var lyricsPreloadPresentation: LyricsPreloadPresentation = .idle

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

    var body: some View {
        Form {
            metadataSection
            lyricsSection
        }
        .navigationTitle(L("元数据填充"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
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

    @ViewBuilder
    private var metadataSection: some View {
        Section {
            Text(L("按顺序尝试已启用的来源；匹配成功后停止。本地已有信息不会被覆盖。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            ForEach(
                Array(viewModel.settings.importPreferences.metadataProviders.enumerated()),
                id: \.element.provider
            ) { item in
                metadataProviderRow(
                    item.element,
                    index: item.offset,
                    total: viewModel.settings.importPreferences.metadataProviders.count
                )
            }

            Text(metadataAvailabilityText)
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            metadataScanContent
        } header: {
            Text(L("元数据"))
                .accessibilityIdentifier("settings.import.metadata.section")
        }
    }

    @ViewBuilder
    private var lyricsSection: some View {
        Section {
            Label(L("Metadata Server"), systemImage: "server.rack")
            Label("LRCLIB", systemImage: "quote.bubble")

            Text(L("优先使用 Metadata Server，未匹配时回退到 LRCLIB。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

        Text(L("打开播放页歌词时按需在线获取，成功后保存到本地资料库。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            Text(L("只处理没有本地歌词的歌曲，成功后保存到 App 资料库。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            lyricsPreloadContent
        } header: {
            Text(L("歌词"))
                .accessibilityIdentifier("settings.import.lyrics.section")
        }
    }

    @ViewBuilder
    private var lyricsPreloadContent: some View {
        let preload = displayedLyricsPreloadSnapshot
        Text(L("预下载歌词"))
            .font(MusicFreeTypographyTokens.secondary)
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

        if !viewModel.canPreloadLyrics {
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
        Text(L("扫描本地资料库"))
            .font(MusicFreeTypographyTokens.secondary)
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

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
        _ preference: MetadataProviderPreference,
        index: Int,
        total: Int
    ) -> some View {
        let status = displayedSnapshot.status(for: preference.provider)
        let isRegistered = status?.isRegistered == true

        HStack(alignment: .top, spacing: MusicFreeSpacingTokens.small) {
            Toggle(
                isOn: Binding(
                    get: {
                        viewModel.settings.importPreferences
                            .isMetadataProviderEnabled(preference.provider)
                    },
                    set: {
                        viewModel.setMetadataProviderEnabled(preference.provider, $0)
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

            VStack(alignment: .trailing, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(providerStatusText(status))
                    .font(MusicFreeTypographyTokens.secondary)
                    .foregroundStyle(
                        isRegistered
                            ? MusicFreeColorTokens.foregroundSecondary
                            : MusicFreeColorTokens.warning
                    )
                    .multilineTextAlignment(.trailing)

                HStack(spacing: MusicFreeSpacingTokens.xSmall) {
                    Button {
                        viewModel.moveMetadataProvider(at: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel(L("上移"))
                    .accessibilityIdentifier(
                        "settings.import.metadataProvider.\(preference.provider.rawValue).moveUp"
                    )

                    Button {
                        viewModel.moveMetadataProvider(at: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == total - 1)
                    .accessibilityLabel(L("下移"))
                    .accessibilityIdentifier(
                        "settings.import.metadataProvider.\(preference.provider.rawValue).moveDown"
                    )
                }
                .buttonStyle(.borderless)
            }
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

    private var metadataAvailabilityText: String {
        let availableCount = displayedSnapshot.providerStatuses.filter {
            $0.isRegistered && $0.authorization == .authorized
        }.count
        if availableCount > 0 {
            return L("已有 %d 个元数据来源可用；本地已有信息不会被覆盖。", availableCount)
        }
        return L("暂无可用的元数据来源。")
    }

    private func providerTitle(_ provider: MetadataEnrichmentProvider) -> String {
        switch provider {
        case .musicKit:
            return L("MusicKit")
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
