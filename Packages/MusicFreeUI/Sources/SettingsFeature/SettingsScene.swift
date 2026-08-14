import AppServices
import DesignSystem
import Observation
import SettingsAPI
import SwiftUI

public struct SettingsScene: View {
    private let releaseInfoProvider: any SettingsReleaseInfoProviding
    private let diagnosticsProvider: any SettingsDiagnosticsProviding
    private let appIconOptions: [SettingsAppIconOption]
    private let appIconProvider: any SettingsAppIconProviding
    @Binding private var appearance: MusicFreeAppearance
    @Binding private var language: MusicFreeLanguage
    @State private var viewModel: SettingsViewModel

    @MainActor
    init(
        store: any SettingsFeatureStore,
        appearance: Binding<MusicFreeAppearance> = .constant(.system),
        language: Binding<MusicFreeLanguage> = .constant(.english),
        releaseInfoProvider: any SettingsReleaseInfoProviding,
        diagnosticsProvider: any SettingsDiagnosticsProviding,
        appIconOptions: [SettingsAppIconOption] = [],
        appIconProvider: any SettingsAppIconProviding = EmptySettingsAppIconProvider()

    ) {
        self.releaseInfoProvider = releaseInfoProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.appIconOptions = appIconOptions
        self.appIconProvider = appIconProvider
        _appearance = appearance
        _language = language
        _viewModel = State(initialValue: SettingsViewModel(store: store))
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
        appIconProvider: any SettingsAppIconProviding = EmptySettingsAppIconProvider()
    ) {
        self.releaseInfoProvider = releaseInfoProvider
        self.diagnosticsProvider = diagnosticsProvider
        self.appIconOptions = appIconOptions
        self.appIconProvider = appIconProvider
        _appearance = appearance
        _language = language
        _viewModel = State(initialValue: SettingsViewModel(
            store: AppServicesSettingsStore(
                serving: settingsServing,
                storageMaintenance: storageMaintenance
            )
        ))
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
            appIconProvider: EmptySettingsAppIconProvider()
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
            Text(L("操作只处理应用生成的缓存或已记录的维护事务，不会删除资料库媒体文件。"))
        }
        .task {
            await viewModel.load()
        }
        .onDisappear {
            viewModel.stopObservingChanges()
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

            PlaybackSettingsView(viewModel: viewModel)
            ImportSettingsView(viewModel: viewModel)
            StorageSettingsView(viewModel: viewModel)

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
}
