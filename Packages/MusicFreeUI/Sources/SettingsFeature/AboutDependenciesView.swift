import DesignSystem
import MusicDomain
import SwiftUI
import UIKit

struct AboutDependenciesView: View {
    let provider: any SettingsReleaseInfoProviding

    @State private var releaseInfo: SettingsReleaseInfo?
    @State private var isLoading = true
    @Bindable var settingsViewModel: SettingsViewModel

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("加载发布信息"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let releaseInfo {
                releaseContent(releaseInfo)
            } else {
                EmptyStateView(
                    title: L("暂无发布信息"),
                    message: L("当前构建未提供只读发布清单。"),
                    systemImage: "info.circle"
                )
            }
        }
        .navigationTitle(L("关于与许可"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            releaseInfo = await provider.releaseInfo()
            isLoading = false
        }
    }

    @ViewBuilder
    private func releaseContent(_ releaseInfo: SettingsReleaseInfo) -> some View {
        Form {
            if hasApplicationMetadata(releaseInfo) {
                Section(L("应用")) {
                    if let appVersion = nonEmpty(releaseInfo.appVersion) {
                        LabeledContent(L("版本"), value: appVersion)
                    }
                    if let buildNumber = nonEmpty(releaseInfo.buildNumber) {
                        LabeledContent(L("构建"), value: buildNumber)
                    }
                }
            }

            Section(L("依赖许可")) {
                if releaseInfo.dependencies.isEmpty {
                    Text(L("暂无依赖清单"))
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                } else {
                    ForEach(releaseInfo.dependencies) { dependency in
                        NavigationLink {
                            LicenseDetailView(dependency: dependency)
                        } label: {
                            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                                Text(dependency.name)
                                    .font(MusicFreeTypographyTokens.rowTitle)
                                if let detail = dependencyDetail(dependency) {
                                    Text(detail)
                                        .font(MusicFreeTypographyTokens.secondary)
                                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                                }
                            }
                        }
                    }
                }
            }
            Section(L("播放能力")) {
                capabilityRow(L("变速播放"), isSupported: settingsViewModel.supportsVariableRate)
                capabilityRow(L("均衡器"), isSupported: settingsViewModel.supportsEqualizer)
            }
        }
    }

    private func capabilityRow(_ title: String, isSupported: Bool) -> some View {
        HStack(spacing: MusicFreeSpacingTokens.small) {
            Text(title)
            Spacer(minLength: MusicFreeSpacingTokens.small)
            HStack(spacing: MusicFreeSpacingTokens.xSmall) {
                Image(systemName: isSupported ? "checkmark.circle.fill" : "clock")
                    .imageScale(.small)
                Text(isSupported ? L("已启用") : L("待支持"))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isSupported
                    ? MusicFreeColorTokens.positive
                    : MusicFreeColorTokens.foregroundSecondary
            )
            .font(MusicFreeTypographyTokens.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L("format.commaPair", title, isSupported ? L("已启用") : L("待播放引擎支持"))))
    }

    private func hasApplicationMetadata(_ releaseInfo: SettingsReleaseInfo) -> Bool {
        nonEmpty(releaseInfo.appVersion) != nil || nonEmpty(releaseInfo.buildNumber) != nil
    }

    private func dependencyDetail(_ dependency: SettingsDependencyLicense) -> String? {
        let version = nonEmpty(dependency.version)
        let license = nonEmpty(dependency.license)
        let kind: String?
        switch dependency.kind {
        case .source:
            kind = L("源码")
        case .binary:
            kind = L("二进制")
        case .other:
            kind = nil
        }

        return [version, license, kind].compactMap { $0 }.joined(separator: " · ")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct SettingsDiagnosticsView: View {
    let provider: any SettingsDiagnosticsProviding
    let lastFailure: SettingsFeatureFailure?
    @Bindable var settingsViewModel: SettingsViewModel

    @State private var snapshot = SettingsDiagnosticsSnapshot()
    @State private var isLoading = true
    @State private var logStatus = MusicLogger.fileLogStatus()
    @State private var isPreparingLogShare = false
    @State private var shareURL: URL?
    @State private var shareErrorMessage: String?
    @State private var isShowingShareError = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView(L("加载诊断信息"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                diagnosticsContent
            }
        }
        .navigationTitle(L("诊断信息"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            snapshot = await provider.diagnostics()
            refreshLogStatus()
            isLoading = false
        }
        .onChange(of: settingsViewModel.isFileLoggingEnabled) { _, _ in
            refreshLogStatus()
        }
        .sheet(
            isPresented: Binding(
                get: { shareURL != nil },
                set: { isPresented in
                    if !isPresented {
                        shareURL = nil
                    }
                }
            )
        ) {
            if let shareURL {
                SettingsLogShareSheet(fileURL: shareURL)
            }
        }
        .alert(
            L("无法分享日志文件"),
            isPresented: $isShowingShareError
        ) {
            Button(L("确定"), role: .cancel) {}
        } message: {
            Text(shareErrorMessage ?? L("暂无可分享的日志文件"))
        }
    }

    @ViewBuilder
    private var diagnosticsContent: some View {
        Form {
            if let lastFailure {
                Section(L("最近一次设置错误")) {
                    Text(lastFailure.message)
                    Text(lastFailure.diagnosticCode)
                        .font(MusicFreeTypographyTokens.caption.monospaced())
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }

            Section(L("文件日志")) {
                Toggle(
                    L("启用文件日志"),
                    isOn: Binding(
                        get: { settingsViewModel.isFileLoggingEnabled },
                        set: { settingsViewModel.setFileLoggingEnabled($0) }
                    )
                )
                .disabled(settingsViewModel.isLoading || settingsViewModel.isSaving)
                .accessibilityIdentifier("settings.diagnostics.fileLogging")

                LabeledContent(
                    L("文件大小"),
                    value: ByteCountFormatter.string(
                        fromByteCount: logStatus.byteCount,
                        countStyle: .file
                    )
                )
                LabeledContent(
                    L("滚动上限"),
                    value: ByteCountFormatter.string(
                        fromByteCount: logStatus.maximumByteCount,
                        countStyle: .file
                    )
                )
                LabeledContent(L("文件位置"), value: MusicLogger.fileName)

                Button {
                    Task { await prepareLogShare() }
                } label: {
                    if isPreparingLogShare {
                        Label(L("正在准备日志文件"), systemImage: "hourglass")
                    } else {
                        Label(L("分享日志文件"), systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(!logStatus.isAvailable || isPreparingLogShare)
                .accessibilityIdentifier("settings.diagnostics.shareFileLog")

                Text(L("按大小滚动，最多保留当前文件和 1 个归档文件。"))
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            Section(L("记录")) {
                if snapshot.entries.isEmpty {
                    Text(L("暂无诊断记录"))
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                } else {
                    ForEach(snapshot.entries) { entry in
                        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                            Text(entry.message)
                            Text(entry.code)
                                .font(MusicFreeTypographyTokens.caption.monospaced())
                                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                            if let timestamp = entry.timestamp {
                                Text(timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(MusicFreeTypographyTokens.caption)
                                    .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func refreshLogStatus() {
        logStatus = MusicLogger.fileLogStatus()
    }

    private func prepareLogShare() async {
        guard !isPreparingLogShare else { return }

        isPreparingLogShare = true
        defer { isPreparingLogShare = false }

        await MusicLogger.flushFileLog()
        refreshLogStatus()

        guard let fileURL = logStatus.fileURL, logStatus.byteCount > 0 else {
            shareErrorMessage = L("暂无可分享的日志文件")
            isShowingShareError = true
            return
        }
        shareURL = fileURL
    }
}

private struct SettingsLogShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        return controller
    }

    func updateUIViewController(
        _: UIActivityViewController,
        context _: Context
    ) {}
}
