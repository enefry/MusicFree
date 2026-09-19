import DesignSystem
import SwiftUI

/// A single accessibility element that behaves like Apple's switch while
/// avoiding the nested switch representation produced by the default SwiftUI
/// form toggle on iOS 26.
struct MusicFreeSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: MusicFreeSpacingTokens.medium) {
                configuration.label
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)

                Spacer(minLength: MusicFreeSpacingTokens.medium)

                switchControl(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(configuration.isOn ? L("已开启") : L("已关闭")))
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction {
            configuration.isOn.toggle()
        }
    }

    private func switchControl(isOn: Bool) -> some View {
        Capsule(style: .continuous)
            .fill(isOn ? MusicFreeColorTokens.accent : MusicFreeColorTokens.separator)
            .frame(width: 51, height: 31)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(isOn ? MusicFreeColorTokens.onAccent : Color.white)
                    .frame(width: 27, height: 27)
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                    .padding(2)
                    .offset(x: isOn ? 20 : 0)
                    .animation(.snappy(duration: 0.18), value: isOn)
            }
            .accessibilityHidden(true)
    }
}
