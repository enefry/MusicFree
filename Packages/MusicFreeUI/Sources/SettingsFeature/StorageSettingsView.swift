import DesignSystem
import Foundation
import SettingsAPI
import SwiftUI

struct StorageSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section(L("存储状态")) {
            if let usage = viewModel.storageUsage {
                LabeledContent(L("媒体文件"), value: byteText(usage.managedMediaBytes))
                LabeledContent(L("导入暂存"), value: byteText(usage.cacheBytes))
                LabeledContent(L("隔离文件"), value: byteText(usage.quarantineBytes))
                if let available = usage.availableBytes {
                    LabeledContent(L("可用空间"), value: byteText(available))
                }
                if usage.pendingRemovalCount > 0 {
                    Label(
                        L("有 %d 个待完成的删除事务", usage.pendingRemovalCount),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(MusicFreeColorTokens.warning)
                }
            } else {
                Text(L("存储状态暂不可用"))
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            if viewModel.isRefreshingStorage {
                ProgressView(L("正在刷新存储状态"))
            }

            Button {
                Task { await viewModel.refreshStorageUsage() }
            } label: {
                Label(L("刷新存储状态"), systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("settings.storage.refresh")
            .disabled(storageActionsDisabled)

            Button {
                viewModel.requestStorageMaintenance(.clearImportStaging)
            } label: {
                Label(L("清理导入暂存"), systemImage: "trash")
            }
            .disabled(storageActionsDisabled)
            .accessibilityIdentifier("settings.storage.clearStaging")

            Button {
                viewModel.requestStorageMaintenance(.repairPendingRemovals)
            } label: {
                Label(L("修复待删除项目"), systemImage: "checkmark.circle")
            }
            .disabled(storageActionsDisabled)
            .accessibilityIdentifier("settings.storage.repairRemovals")

            Button {
                viewModel.requestStorageMaintenance(.clearFinalizedQuarantine)
            } label: {
                Label(L("清理已完成隔离"), systemImage: "archivebox")
            }
            .disabled(storageActionsDisabled)
            .accessibilityIdentifier("settings.storage.clearQuarantine")

            maintenanceStatus
        }

        Section(L("存储策略")) {
            Toggle(L("自动整理缓存"), isOn: automaticPruningBinding)
                .toggleStyle(MusicFreeSwitchToggleStyle())
                .accessibilityIdentifier("settings.storage.autoPrune")
                .disabled(viewModel.isSaving)

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
                HStack {
                    Text(L("缓存上限"))
                    Spacer(minLength: MusicFreeSpacingTokens.medium)
                    Text(cacheLimitText)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }

                Slider(
                    value: cacheLimitBinding,
                    in: Double(StorageByteLimit.minimumBytes)...Double(StorageByteLimit.maximumBytes),
                    step: Double(256 * 1_024 * 1_024)
                )
                .disabled(viewModel.isSaving)
                .accessibilityLabel(Text(L("缓存上限")))
                .accessibilityValue(Text(cacheLimitText))
                .accessibilityIdentifier("settings.storage.cacheLimit")
            }

            Stepper(value: stagingRetentionDaysBinding, in: 0...30) {
                HStack {
                    Text(L("暂存保留时间"))
                    Spacer(minLength: MusicFreeSpacingTokens.medium)
                    Text(L("%d days", stagingRetentionDays))
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }
            .disabled(viewModel.isSaving)
            .accessibilityIdentifier("settings.storage.stagingRetention")
        }
    }

    private var storageActionsDisabled: Bool {
        viewModel.isRefreshingStorage || viewModel.isMaintainingStorage
    }

    private var automaticPruningBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.storagePreferences.automaticallyPruneCache },
            set: { viewModel.setAutomaticallyPruneCache($0) }
        )
    }

    private var cacheLimitBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.settings.storagePreferences.cacheLimit.bytes) },
            set: { viewModel.setCacheLimit(bytes: Int64($0.rounded())) }
        )
    }

    private var stagingRetentionDaysBinding: Binding<Int> {
        Binding(
            get: { stagingRetentionDays },
            set: { viewModel.setStagingRetention(Duration.seconds($0 * 24 * 60 * 60)) }
        )
    }

    private var stagingRetentionDays: Int {
        Int(viewModel.settings.storagePreferences.stagingRetention.components.seconds / (24 * 60 * 60))
    }

    private var cacheLimitText: String {
        ByteCountFormatter.string(
            fromByteCount: viewModel.settings.storagePreferences.cacheLimit.bytes,
            countStyle: .file
        )
    }

    @ViewBuilder
    private var maintenanceStatus: some View {
        switch viewModel.maintenanceState {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView(L("正在维护存储"))
        case .completed(let result):
            Text(L("已释放 %@", byteText(result.freedBytes)))
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        case .failed(let message):
            Text(message)
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.destructive)
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
