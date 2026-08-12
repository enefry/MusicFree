import AppServices
import DesignSystem
import Observation
import SettingsAPI
import SwiftUI

public struct SettingsScene: View {
    private let releaseInfoProvider: any SettingsReleaseInfoProviding
    private let diagnosticsProvider: any SettingsDiagnosticsProviding
    @Binding private var appearance: MusicFreeAppearance
    @State private var viewModel: SettingsViewModel

    @MainActor
    init(
        store: any SettingsFeatureStore,
        appearance: Binding<MusicFreeAppearance> = .constant(.system),
        releaseInfoProvider: any SettingsReleaseInfoProviding,
        diagnosticsProvider: any SettingsDiagnosticsProviding

    ) {
        self.releaseInfoProvider = releaseInfoProvider
        self.diagnosticsProvider = diagnosticsProvider
        _appearance = appearance
        _viewModel = State(initialValue: SettingsViewModel(store: store))
    }

    /// The configured entry point used by the App composition root.
    @MainActor
    public init(
        settingsServing: any SettingsServing,
        storageMaintenance: (any StorageMaintenanceServing)? = nil,
        appearance: Binding<MusicFreeAppearance> = .constant(.system),
        releaseInfoProvider: any SettingsReleaseInfoProviding = EmptySettingsReleaseInfoProvider(),
        diagnosticsProvider: any SettingsDiagnosticsProviding = EmptySettingsDiagnosticsProvider()
    ) {
        self.releaseInfoProvider = releaseInfoProvider
        self.diagnosticsProvider = diagnosticsProvider
        _appearance = appearance
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
            releaseInfoProvider: EmptySettingsReleaseInfoProvider(),
            diagnosticsProvider: EmptySettingsDiagnosticsProvider()
        )
    }

    @MainActor
    public var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView("加载设置")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(failure):
                VStack(spacing: MusicFreeSpacingTokens.small) {
                    ErrorStateView(
                        title: "设置加载失败",
                        message: failure.message,
                        retryTitle: "重试",
                        retry: { Task { await viewModel.retry() } }
                    )

                    Button(role: .destructive) {
                        viewModel.requestReset()
                    } label: {
                        Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.recovery.reset")
                }
                .padding(.bottom, MusicFreeSpacingTokens.xLarge)
            case .loaded:
                settingsForm(viewModel: viewModel)
            }
        }
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                .accessibilityLabel(Text("重新加载设置"))
                .help("重新加载设置")
            }
        }
        .confirmationDialog(
            "恢复默认设置？",
            isPresented: $viewModel.isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("恢复默认设置", role: .destructive) {
                Task { await viewModel.confirmReset() }
            }
            Button("取消", role: .cancel) {
                viewModel.cancelReset()
            }
        } message: {
            Text("播放、导入和存储偏好将恢复为默认值。")
        }
        .confirmationDialog(
            maintenanceConfirmationTitle,
            isPresented: $viewModel.isMaintenanceConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("继续", role: .destructive) {
                Task { await viewModel.confirmStorageMaintenance() }
            }
            Button("取消", role: .cancel) {
                viewModel.cancelStorageMaintenance()
            }
        } message: {
            Text("操作只处理应用生成的缓存或已记录的维护事务，不会删除资料库媒体文件。")
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
                Section("状态") {
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(MusicFreeColorTokens.warning)
                    Text(failure.diagnosticCode)
                        .font(MusicFreeTypographyTokens.caption.monospaced())
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    if viewModel.canRetryFailedSave {
                        Button("重试保存") {
                            viewModel.retryFailedSave()
                        }
                    }
                }
            }

            Section("外观") {
                Picker("配色", selection: $appearance) {
                    ForEach(MusicFreeAppearance.allCases) { option in
                        Label(option.title, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance")
            }

            PlaybackSettingsView(viewModel: viewModel)
            ImportSettingsView(viewModel: viewModel)
            StorageSettingsView(viewModel: viewModel)

            Section("关于") {
                NavigationLink {
                    AboutDependenciesView(provider: releaseInfoProvider, settingsViewModel: self.viewModel)
                } label: {
                    Label("版本与第三方许可", systemImage: "info.circle")
                }
                .accessibilityIdentifier("settings.about")

                NavigationLink {
                    SettingsDiagnosticsView(
                        provider: diagnosticsProvider,
                        lastFailure: viewModel.lastFailure
                    )
                } label: {
                    Label("诊断信息", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("settings.diagnostics")
            }

            Section {
                Button(role: .destructive) {
                    viewModel.requestReset()
                } label: {
                    Label("恢复默认设置", systemImage: "arrow.counterclockwise")
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
        case .clearImportStaging: return "清理导入暂存？"
        case .repairPendingRemovals: return "修复待删除项目？"
        case .clearFinalizedQuarantine: return "清理已完成隔离？"
        case nil: return "执行存储维护？"
        }
    }
}
