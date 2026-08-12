import SwiftUI

public struct PlaybackControlButton: View {
    private let systemImage: String
    private let accessibilityLabel: String
    private let accessibilityHint: String?
    private let accessibilityValue: String?
    private let isSelected: Bool
    private let isLoading: Bool
    private let isEnabled: Bool
    private let foregroundColor: Color
    private let backgroundColor: Color
    private let showsBackground: Bool
    private let controlSize: CGFloat
    private let symbolFont: Font
    private let action: () -> Void

    public init(
        systemImage: String,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        accessibilityValue: String? = nil,
        isSelected: Bool = false,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        foregroundColor: Color = MusicFreeColorTokens.onAccent,
        backgroundColor: Color = MusicFreeColorTokens.accent,
        showsBackground: Bool = true,
        controlSize: CGFloat = MusicFreeLayoutMetrics.minimumHitTarget,
        symbolFont: Font = MusicFreeTypographyTokens.controlLabel,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityValue = accessibilityValue
        self.isSelected = isSelected
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.showsBackground = showsBackground
        self.controlSize = controlSize
        self.symbolFont = symbolFont
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foregroundColor)
                } else {
                    Image(systemName: systemImage)
                        .font(symbolFont)
                }
            }
            .frame(
                width: controlSize,
                height: controlSize
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background {
            if showsBackground {
                Circle().fill(backgroundColor)
            }
        }
        .clipShape(Circle())
        .opacity(isEnabled && !isLoading ? 1 : 0.45)
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(accessibilityHint ?? ""))
        .accessibilityValue(Text(accessibilityValue ?? (isLoading ? "Loading" : "")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
