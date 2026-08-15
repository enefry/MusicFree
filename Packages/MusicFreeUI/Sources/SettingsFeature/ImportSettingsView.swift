import DesignSystem
import SettingsAPI
import SwiftUI

struct ImportSettingsView: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Section(L("导入与资料库")) {
            HStack {
                Text(L("重复内容"))
                Spacer()
                Text(L("跳过已有内容"))
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }
            .accessibilityIdentifier("settings.import.duplicatePolicy")

            Text(L("当前版本对相同内容统一跳过导入；替换和保留重复副本尚未接入。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        }
    }
}
