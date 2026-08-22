import DesignSystem
import Foundation
import SettingsAPI
import SwiftUI

enum CacheLimitSliderScale {
    private static let megabyte: Int64 = 1_000_000
    private static let gigabyte: Int64 = 1_000_000_000

    static func position(for bytes: Int64, maximumBytes: Int64) -> Double {
        let minimumBytes = StorageByteLimit.minimumBytes
        guard maximumBytes > minimumBytes else { return 0 }
        let clampedBytes = min(max(bytes, minimumBytes), maximumBytes)
        let normalized = Double(clampedBytes - minimumBytes)
            / Double(maximumBytes - minimumBytes)
        return normalized.squareRoot()
    }

    static func bytes(for position: Double, maximumBytes: Int64) -> Int64 {
        let minimumBytes = StorageByteLimit.minimumBytes
        guard maximumBytes > minimumBytes else { return minimumBytes }

        let clampedPosition = min(max(position, 0), 1)
        if clampedPosition == 0 { return minimumBytes }
        if clampedPosition == 1 { return maximumBytes }

        let normalized = clampedPosition * clampedPosition
        let rawBytes = Double(minimumBytes)
            + normalized * Double(maximumBytes - minimumBytes)
        let step = rawBytes < Double(gigabyte) ? 100 * megabyte : gigabyte
        let roundedBytes = (rawBytes / Double(step)).rounded() * Double(step)
        return min(max(Int64(roundedBytes), minimumBytes), maximumBytes)
    }

    static func text(for bytes: Int64) -> String {
        let usesGigabytes = bytes >= gigabyte
        let unit = usesGigabytes ? gigabyte : megabyte
        let value = Int64((Double(bytes) / Double(unit)).rounded())
        return "\(value.formatted()) \(usesGigabytes ? "GB" : "MB")"
    }
}

struct StorageSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    private let onRefreshCompleted: @MainActor (Bool) -> Void

    init(
        viewModel: SettingsViewModel,
        onRefreshCompleted: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        _viewModel = Bindable(viewModel)
        self.onRefreshCompleted = onRefreshCompleted
    }

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

            Button {
                Task { @MainActor in
                    let succeeded = await viewModel.refreshStorageUsage()
                    guard !Task.isCancelled else { return }
                    onRefreshCompleted(succeeded)
                }
            } label: {
                HStack {
                    Label(L("刷新存储状态"), systemImage: "arrow.clockwise")
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                        .opacity(viewModel.isRefreshingStorage ? 1 : 0)
                        .accessibilityHidden(!viewModel.isRefreshingStorage)
                }
            }
            .accessibilityIdentifier("settings.storage.refresh")
            // A refresh already in flight is coalesced by the view model, so
            // keep this action reachable while the initial usage query runs.
            .disabled(viewModel.isMaintainingStorage)

            NavigationLink {
                StorageMaintenanceView(viewModel: viewModel)
            } label: {
                VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                    Label(L("存储维护"), systemImage: "wrench.and.screwdriver")
                    Text(L("清理暂存、修复删除事务或清理已完成的隔离文件。"))
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }
            .accessibilityIdentifier("settings.storage.maintenance")
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
                    in: 0...1,
                    onEditingChanged: handleCacheLimitEditingChanged
                )
                .disabled(viewModel.isSaving || viewModel.maximumCacheLimitBytes == nil)
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

    private var automaticPruningBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.storagePreferences.automaticallyPruneCache },
            set: { viewModel.setAutomaticallyPruneCache($0) }
        )
    }

    private var cacheLimitBinding: Binding<Double> {
        Binding(
            get: {
                CacheLimitSliderScale.position(
                    for: viewModel.displayedCacheLimitBytes,
                    maximumBytes: cacheLimitSliderMaximumBytes
                )
            },
            set: {
                viewModel.updateCacheLimitDraft(
                    bytes: CacheLimitSliderScale.bytes(
                        for: $0,
                        maximumBytes: cacheLimitSliderMaximumBytes
                    )
                )
            }
        )
    }

    private var cacheLimitSliderMaximumBytes: Int64 {
        viewModel.maximumCacheLimitBytes ?? viewModel.displayedCacheLimitBytes
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
        CacheLimitSliderScale.text(for: viewModel.displayedCacheLimitBytes)
    }

    private func handleCacheLimitEditingChanged(_ isEditing: Bool) {
        if isEditing {
            viewModel.beginCacheLimitEditing()
        } else {
            viewModel.endCacheLimitEditing()
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum StorageRefreshResult: Equatable {
    case succeeded
    case failed
}

struct StorageRefreshToast: Identifiable, Equatable {
    let id: UUID
    let result: StorageRefreshResult

    init(result: StorageRefreshResult) {
        id = UUID()
        self.result = result
    }
}

struct StorageRefreshToastView: View {
    let toast: StorageRefreshToast

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MusicFreeSpacingTokens.large)
            .padding(.vertical, MusicFreeSpacingTokens.small)
            .background(tint, in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .accessibilityIdentifier("settings.storage.refresh.toast")
    }

    private var message: String {
        switch toast.result {
        case .succeeded:
            return L("存储状态已更新")
        case .failed:
            return L("存储状态刷新失败，请稍后重试。")
        }
    }

    private var systemImage: String {
        switch toast.result {
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private var tint: Color {
        switch toast.result {
        case .succeeded:
            return MusicFreeColorTokens.positive
        case .failed:
            return MusicFreeColorTokens.destructive
        }
    }
}

struct StorageMaintenanceView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(L("操作前请确认")) {
                Label(
                    L("这些操作只处理应用生成的暂存、隔离文件和已记录的维护事务。"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(MusicFreeColorTokens.warning)

                Text(L("不会删除已经进入资料库的媒体文件。清理已完成的文件后，不能从隔离目录恢复这些副本。"))
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            maintenanceStatus

            ForEach(StorageMaintenanceAction.allCases, id: \.self) { action in
                maintenanceSection(for: action)
            }
        }
        .accessibilityIdentifier("settings.storage.maintenance.form")
        .navigationTitle(L("存储维护"))
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
    }

    @ViewBuilder
    private func maintenanceSection(for action: StorageMaintenanceAction) -> some View {
        Section {
            if let currentValue = currentValue(for: action) {
                Text(currentValue)
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(L("详细说明"))
                    .font(.subheadline.weight(.semibold))
                Text(action.detail)
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(L("操作预期"))
                    .font(.subheadline.weight(.semibold))
                Text(action.expectation)
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }

            actionButton(for: action)
        } header: {
            Label(action.title, systemImage: action.systemImage)
        }
    }

    @ViewBuilder
    private func actionButton(for action: StorageMaintenanceAction) -> some View {
        switch action {
        case .repairPendingRemovals:
            Button {
                viewModel.requestStorageMaintenance(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(maintenanceActionsDisabled)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        case .clearImportStaging, .clearFinalizedQuarantine:
            Button(role: .destructive) {
                viewModel.requestStorageMaintenance(action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(maintenanceActionsDisabled)
            .accessibilityIdentifier(action.accessibilityIdentifier)
        }
    }

    private var maintenanceActionsDisabled: Bool {
        viewModel.isRefreshingStorage || viewModel.isMaintainingStorage
    }

    private var maintenanceStatus: some View {
        Group {
            switch viewModel.maintenanceState {
            case .idle:
                EmptyView()
            case .loading:
                Section(L("最近一次操作")) {
                    ProgressView(L("正在维护存储"))
                }
            case .completed(let result):
                Section(L("最近一次操作")) {
                    Label(L("维护完成"), systemImage: "checkmark.circle")
                        .foregroundStyle(MusicFreeColorTokens.positive)
                    if result.freedBytes > 0 {
                        Text(L("已释放 %@", byteText(result.freedBytes)))
                    }
                    if result.repairedPendingRemovalCount > 0 {
                        Text(L("已修复 %d 个待删除事务", result.repairedPendingRemovalCount))
                    }
                    if result.freedBytes == 0 && result.repairedPendingRemovalCount == 0 {
                        Text(L("操作完成，未发现需要处理的项目。"))
                    }
                }
            case .failed(let message):
                Section(L("最近一次操作")) {
                    Label(message, systemImage: "xmark.octagon")
                        .foregroundStyle(MusicFreeColorTokens.destructive)
                }
            }
        }
    }

    private func currentValue(for action: StorageMaintenanceAction) -> String? {
        guard let usage = viewModel.storageUsage else { return nil }
        switch action {
        case .clearImportStaging:
            return L("当前暂存：%@", byteText(usage.cacheBytes))
        case .repairPendingRemovals:
            return L("当前待修复：%d 项", usage.pendingRemovalCount)
        case .clearFinalizedQuarantine:
            return L("当前隔离：%@", byteText(usage.quarantineBytes))
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension StorageMaintenanceAction {
    var title: String {
        switch self {
        case .clearImportStaging: return L("清理导入暂存")
        case .repairPendingRemovals: return L("修复待删除项目")
        case .clearFinalizedQuarantine: return L("清理已完成隔离")
        }
    }

    var systemImage: String {
        switch self {
        case .clearImportStaging: return "trash"
        case .repairPendingRemovals: return "checkmark.circle"
        case .clearFinalizedQuarantine: return "archivebox"
        }
    }

    var detail: String {
        switch self {
        case .clearImportStaging:
            return L("删除导入流程留下的暂存副本。只处理暂存目录，不影响已经进入资料库的媒体文件。")
        case .repairPendingRemovals:
            return L("检查未完成的删除事务，并根据资料库记录恢复或完成事务。不会重新删除资料库中的媒体文件。")
        case .clearFinalizedQuarantine:
            return L("删除已经完成处理的隔离副本，保留仍处于 pending 状态的文件。清理后不能从隔离目录恢复这些副本。")
        }
    }

    var expectation: String {
        switch self {
        case .clearImportStaging:
            return L("清理完成后，导入暂存占用会减少，存储状态会更新；正在进行的导入会等待维护完成。")
        case .repairPendingRemovals:
            return L("待删除项目会逐项核对；可恢复或可完成的事务会被处理，仍无法判断的事务会保留。")
        case .clearFinalizedQuarantine:
            return L("清理完成后，隔离文件占用会减少；pending 隔离文件会保留，不会被清理。")
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .clearImportStaging: return "settings.storage.clearStaging"
        case .repairPendingRemovals: return "settings.storage.repairRemovals"
        case .clearFinalizedQuarantine: return "settings.storage.clearQuarantine"
        }
    }
}
