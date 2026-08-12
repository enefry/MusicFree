import DesignSystem
import SettingsAPI
import SwiftUI

struct ImportSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section("导入与资料库") {
            Picker("重复内容", selection: duplicatePolicyBinding) {
                ForEach(DuplicateImportPolicy.allCases, id: \.self) { policy in
                    Text(policyTitle(policy)).tag(policy)
                }
            }
            .disabled(viewModel.isSaving)
            .accessibilityIdentifier("settings.import.duplicatePolicy")

            Text(policyDescription(viewModel.settings.importPreferences.duplicatePolicy))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        }
    }

    private var duplicatePolicyBinding: Binding<DuplicateImportPolicy> {
        Binding(
            get: { viewModel.settings.importPreferences.duplicatePolicy },
            set: { viewModel.setDuplicateImportPolicy($0) }
        )
    }

    private func policyTitle(_ policy: DuplicateImportPolicy) -> String {
        switch policy {
        case .skipExisting:
            return "跳过已有内容"
        case .replaceExisting:
            return "替换已有内容"
        case .keepBoth:
            return "保留重复副本"
        }
    }

    private func policyDescription(_ policy: DuplicateImportPolicy) -> String {
        switch policy {
        case .skipExisting:
            return "检测到相同内容时跳过导入，避免资料库出现重复歌曲。"
        case .replaceExisting:
            return "保存替换意图；当前内容寻址资料库仍使用安全的跳过行为，"
                + "替换事务接入后生效。"
        case .keepBoth:
            return "保存保留副本意图；当前内容寻址资料库仍使用安全的跳过行为，"
                + "重复副本事务接入后生效。"
        }
    }
}
