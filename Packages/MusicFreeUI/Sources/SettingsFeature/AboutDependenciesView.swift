import DesignSystem
import SwiftUI

struct AboutDependenciesView: View {
    let provider: any SettingsReleaseInfoProviding

    @State private var releaseInfo: SettingsReleaseInfo?
    @State private var isLoading = true
    @Bindable var settingsViewModel: SettingsViewModel

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载发布信息")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let releaseInfo {
                releaseContent(releaseInfo)
            } else {
                EmptyStateView(
                    title: "暂无发布信息",
                    message: "当前构建未提供只读发布清单。",
                    systemImage: "info.circle"
                )
            }
        }
        .navigationTitle("关于与许可")
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
                Section("应用") {
                    if let appVersion = nonEmpty(releaseInfo.appVersion) {
                        LabeledContent("版本", value: appVersion)
                    }
                    if let buildNumber = nonEmpty(releaseInfo.buildNumber) {
                        LabeledContent("构建", value: buildNumber)
                    }
                }
            }

            Section("依赖许可") {
                if releaseInfo.dependencies.isEmpty {
                    Text("暂无依赖清单")
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
            Section("播放能力") {
                capabilityRow("变速播放", isSupported: settingsViewModel.supportsVariableRate)
                capabilityRow("均衡器", isSupported: settingsViewModel.supportsEqualizer)
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
                Text(isSupported ? "已启用" : "待支持")
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
        .accessibilityLabel(Text("\(title)，\(isSupported ? "已启用" : "待播放引擎支持")"))
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
            kind = "源码"
        case .binary:
            kind = "二进制"
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

    @State private var snapshot = SettingsDiagnosticsSnapshot()
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载诊断信息")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                diagnosticsContent
            }
        }
        .navigationTitle("诊断信息")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            snapshot = await provider.diagnostics()
            isLoading = false
        }
    }

    @ViewBuilder
    private var diagnosticsContent: some View {
        Form {
            if let lastFailure {
                Section("最近一次设置错误") {
                    Text(lastFailure.message)
                    Text(lastFailure.diagnosticCode)
                        .font(MusicFreeTypographyTokens.caption.monospaced())
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }

            Section("记录") {
                if snapshot.entries.isEmpty {
                    Text("暂无诊断记录")
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
}
