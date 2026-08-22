import AppServices
import DesignSystem
import Observation
import SettingsAPI
import SwiftUI

public struct SettingsScene<AdditionsContent: View>: View {
    private let releaseInfoProvider: any SettingsReleaseInfoProviding
    private let diagnosticsProvider: any SettingsDiagnosticsProviding
    private let appIconOptions: [SettingsAppIconOption]
    private let appIconProvider: any SettingsAppIconProviding
    private let sleepTimerServing: (any SleepTimerServing)?
    private let metadataServerEnabled: Bool
    private let lyricsEnabled: Bool
    private let additionContent: AdditionsContent?
    @Binding private var appearance: MusicFreeAppearance
    @Binding private var language: MusicFreeLanguage
    @State private var viewModel: SettingsViewModel
    @State private var storageRefreshToast: StorageRefreshToast?

    @MainActor
    init(
        store: any SettingsFeatureStore,
        appearance: Binding<MusicFreeAppearance> = .constant(.system),
        language: Binding<MusicFreeLanguage> = .constant(.english),
        releaseInfoProvider: any SettingsReleaseInfoProviding,
        diagnosticsProvider: any SettingsDiagnosticsProviding,
        appIconOptions: [SettingsAppIconOption] = [],
        appIconProvider: any SettingsAppIconProviding = EmptySettingsAppIconProvider(),
        sleepTimerServing: (any SleepTimerServing)? = nil,
        metadataEnrichment: (any MetadataEnrichmentServing)? = nil,
        lyricsServing: (any LyricsServing)? = nil,
        metadataServerEnabled: Bool = true,
        lyricsEnabled: Bool = true,
        @ViewBuilder additionContent: () -> AdditionsContent? = { nil }
    ) {
        self.releaseInfoProvider = releaseInfoProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.appIconOptions = appIconOptions
        self.appIconProvider = appIconProvider
        self.sleepTimerServing = sleepTimerServing
        self.metadataServerEnabled = metadataServerEnabled
        self.lyricsEnabled = lyricsEnabled
        _appearance = appearance
        _language = language
        _viewModel = State(initialValue: SettingsViewModel(
            store: store,
            metadataEnrichment: metadataEnrichment,
            lyricsServing: lyricsServing
        ))
        self.additionContent = additionContent()
    }

    /// The configured entry point used by the App composition root.
    @MainActor
    public init(
        settingsServing: any SettingsServing,
        storageMaintenance: (any StorageMaintenanceServing)? = nil,
        appearance: Binding<MusicFreeAppearance> = .constant(.system),
        language: Binding<MusicFreeLanguage> = .constant(.english),
        releaseInfoProvider: any SettingsReleaseInfoProviding = EmptySettingsReleaseInfoProvider(),
        diagnosticsProvider: any SettingsDiagnosticsProviding = EmptySettingsDiagnosticsProvider(),
        appIconOptions: [SettingsAppIconOption] = [],
        appIconProvider: any SettingsAppIconProviding = EmptySettingsAppIconProvider(),
        sleepTimerServing: (any SleepTimerServing)? = nil,
        metadataEnrichment: (any MetadataEnrichmentServing)? = nil,
        lyricsServing: (any LyricsServing)? = nil,
        metadataServerEnabled: Bool = true,
        lyricsEnabled: Bool = true,
        @ViewBuilder additionContent: () -> AdditionsContent? = { nil }
    ) {
        self.releaseInfoProvider = releaseInfoProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.appIconOptions = appIconOptions
        self.appIconProvider = appIconProvider
        self.sleepTimerServing = sleepTimerServing
        self.metadataServerEnabled = metadataServerEnabled
        self.lyricsEnabled = lyricsEnabled
        _appearance = appearance
        _language = language
        _viewModel = State(initialValue: SettingsViewModel(
            store: AppServicesSettingsStore(
                serving: settingsServing,
                storageMaintenance: storageMaintenance
            ),
            metadataEnrichment: metadataEnrichment,
            lyricsServing: lyricsServing
        ))
        self.additionContent = additionContent()
    }

    /// Compatibility initializer for package graph checks and previews.
    @MainActor
    public init() {
        self.init(
            store: UnconfiguredSettingsStore(),
            appearance: .constant(.system),
            language: .constant(.english),
            releaseInfoProvider: EmptySettingsReleaseInfoProvider(),
            diagnosticsProvider: EmptySettingsDiagnosticsProvider(),
            appIconOptions: [],
            appIconProvider: EmptySettingsAppIconProvider(),
            sleepTimerServing: nil,
            metadataEnrichment: nil,
            lyricsServing: nil
        )
    }

    @MainActor
    public var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView(L("加载设置"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(failure):
                VStack(spacing: MusicFreeSpacingTokens.small) {
                    ErrorStateView(
                        title: L("设置加载失败"),
                        message: failure.message,
                        retryTitle: L("重试"),
                        retry: { Task { await viewModel.retry() } }
                    )

                    Button(role: .destructive) {
                        viewModel.requestReset()
                    } label: {
                        Label(L("恢复默认设置"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.recovery.reset")
                }
                .padding(.bottom, MusicFreeSpacingTokens.xLarge)
            case .loaded:
                settingsForm(viewModel: viewModel)
            }
        }
        .navigationTitle(L("设置"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                .accessibilityLabel(Text(L("重新加载设置")))
                .help(L("重新加载设置"))
            }
        }
        .confirmationDialog(
            L("恢复默认设置？"),
            isPresented: $viewModel.isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L("恢复默认设置"), role: .destructive) {
                Task { await viewModel.confirmReset() }
            }
            Button(L("取消"), role: .cancel) {
                viewModel.cancelReset()
            }
        } message: {
            Text(L("播放、导入和存储偏好将恢复为默认值。"))
        }
        .confirmationDialog(
            maintenanceConfirmationTitle,
            isPresented: $viewModel.isMaintenanceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L("继续"), role: .destructive) {
                Task { await viewModel.confirmStorageMaintenance() }
            }
            Button(L("取消"), role: .cancel) {
                viewModel.cancelStorageMaintenance()
            }
        } message: {
            Text(maintenanceConfirmationMessage)
        }
        .task {
            await viewModel.load()
        }
        .overlay(alignment: .bottom) {
            if let storageRefreshToast {
                StorageRefreshToastView(toast: storageRefreshToast)
                    .padding(.horizontal, MusicFreeSpacingTokens.large)
                    .padding(.bottom, MusicFreeSpacingTokens.large)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: storageRefreshToast?.id)
        .task(id: storageRefreshToast?.id) {
            guard storageRefreshToast != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                storageRefreshToast = nil
            }
        }
    }

    private func settingsForm(viewModel: SettingsViewModel) -> some View {
        Form {
            if let failure = viewModel.lastFailure {
                Section(L("状态")) {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(MusicFreeColorTokens.warning)
                    Text(failure.diagnosticCode)
                        .font(MusicFreeTypographyTokens.caption.monospaced())
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    if viewModel.canRetryFailedSave {
                        Button(L("重试保存")) {
                            viewModel.retryFailedSave()
                        }
                    }
                }
            }

            Section(L("外观")) {
                Picker(L("应用语言"), selection: $language) {
                    ForEach(MusicFreeLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.language")

                Picker(L("配色"), selection: $appearance) {
                    ForEach(MusicFreeAppearance.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.appearance")

                if !appIconOptions.isEmpty {
                    AppIconSettingsView(
                        options: appIconOptions,
                        provider: appIconProvider
                    )
                }
            }

            PlaybackSettingsView(
                viewModel: viewModel,
                sleepTimerServing: sleepTimerServing
            )
            ImportSettingsView(
                viewModel: viewModel,
                metadataServerEnabled: metadataServerEnabled,
                lyricsEnabled: lyricsEnabled
            )
            StorageSettingsView(
                viewModel: viewModel,
                onRefreshCompleted: { succeeded in
                    presentStorageRefreshToast(succeeded: succeeded)
                }
            )

            Section(L("隐私")) {
                NavigationLink {
                    PrivacySettingsView(
                        viewModel: viewModel,
                        metadataServerEnabled: metadataServerEnabled,
                        lyricsEnabled: lyricsEnabled
                    )
                } label: {
                    Label(L("隐私与联网服务"), systemImage: "hand.raised.shield")
                }
                .accessibilityIdentifier("settings.privacy")
            }

#if DEBUG
            Section(L("调试")) {
                Button(role: .destructive) {
                    viewModel.resetAllPrivacy()
                } label: {
                    Label(L("重置全部隐私"), systemImage: "arrow.counterclockwise")
                }
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier("settings.debug.resetAllPrivacy")
            }
#endif

            Section(L("关于")) {
                NavigationLink {
                    AboutDependenciesView(provider: releaseInfoProvider, settingsViewModel: self.viewModel)
                } label: {
                    Label(L("版本与第三方许可"), systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.about")

                NavigationLink {
                    SettingsDiagnosticsView(
                        provider: diagnosticsProvider,
                        lastFailure: viewModel.lastFailure
                    )
                } label: {
                    Label(L("诊断信息"), systemImage: "stethoscope")
                }
                .accessibilityIdentifier("settings.diagnostics")
            }

            Section {
                Button(role: .destructive) {
                    viewModel.requestReset()
                } label: {
                    Label(L("恢复默认设置"), systemImage: "arrow.counterclockwise")
                }
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier("settings.reset")
            }
            if let additionContent {
                Section {
                    additionContent
                }
            }
        }
        .accessibilityIdentifier("settings.form")
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
    }

    private var maintenanceConfirmationTitle: String {
        switch viewModel.requestedMaintenanceAction {
        case .clearImportStaging: return L("清理导入暂存？")
        case .repairPendingRemovals: return L("修复待删除项目？")
        case .clearFinalizedQuarantine: return L("清理已完成隔离？")
        case nil: return L("执行存储维护？")
        }
    }

    private var maintenanceConfirmationMessage: String {
        switch viewModel.requestedMaintenanceAction {
        case .clearImportStaging:
            return L("将删除导入暂存目录中的文件；已经进入资料库的媒体文件不受影响。")
        case .repairPendingRemovals:
            return L("将核对未完成的删除事务，并恢复或完成能够确定状态的事务；无法判断的事务会保留。")
        case .clearFinalizedQuarantine:
            return L("将删除已完成处理的隔离副本，并保留 pending 隔离文件；清理后的副本不能恢复。")
        case nil:
            return L("操作只处理应用生成的缓存或已记录的维护事务，不会删除资料库媒体文件。")
        }
    }

    @MainActor
    private func presentStorageRefreshToast(succeeded: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            storageRefreshToast = StorageRefreshToast(
                result: succeeded ? .succeeded : .failed
            )
        }
    }
}
