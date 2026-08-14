import SwiftUI

/// A compact action used for the primary playback actions on list pages.
public struct MusicFreePillActionButton: View {
    private let title: String
    private let systemImage: String
    private let action: () -> Void
    private let isEnabled: Bool

    public init(
        title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(MusicFreeColorTokens.accent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    MusicFreeColorTokens.playerControl.opacity(isEnabled ? 1 : 0.55),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(MusicFreeColorTokens.separator.opacity(0.24), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The two primary actions used by Apple Music collection pages. Keeping this
/// in the design system makes album, artist, genre, folder, and playlist
/// details share the same touch target and horizontal rhythm.
public struct MusicFreeDetailActionBar: View {
    public enum Presentation: Sendable {
        case splitPills
        case albumHero
    }

    private let playAction: () -> Void
    private let shuffleAction: () -> Void
    private let isEnabled: Bool
    private let presentation: Presentation
    private let playAccessibilityIdentifier: String?
    private let shuffleAccessibilityIdentifier: String?

    public init(
        isEnabled: Bool = true,
        presentation: Presentation = .splitPills,
        playAccessibilityIdentifier: String? = nil,
        shuffleAccessibilityIdentifier: String? = nil,
        playAction: @escaping () -> Void,
        shuffleAction: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.presentation = presentation
        self.playAccessibilityIdentifier = playAccessibilityIdentifier
        self.shuffleAccessibilityIdentifier = shuffleAccessibilityIdentifier
        self.playAction = playAction
        self.shuffleAction = shuffleAction
    }

    public var body: some View {
        switch presentation {
        case .splitPills:
            splitPillActions
        case .albumHero:
            albumHeroActions
        }
    }

    private var splitPillActions: some View {
        HStack(spacing: MusicFreeSpacingTokens.small) {
            MusicFreePillActionButton(
                title: L("播放"),
                systemImage: "play.fill",
                isEnabled: isEnabled,
                action: playAction
            )
            .accessibilityIdentifier(playAccessibilityIdentifier ?? "")

            MusicFreePillActionButton(
                title: L("随机播放"),
                systemImage: "shuffle",
                isEnabled: isEnabled,
                action: shuffleAction
            )
            .accessibilityIdentifier(shuffleAccessibilityIdentifier ?? "")
        }
    }

    private var albumHeroActions: some View {
        HStack(spacing: MusicFreeSpacingTokens.large) {
            Button(action: shuffleAction) {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(MusicFreeColorTokens.foregroundPrimary)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(L("随机播放"))
            .accessibilityIdentifier(shuffleAccessibilityIdentifier ?? "")

            Button(action: playAction) {
                Label(L("播放"), systemImage: "play.fill")
                    .font(.headline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(MusicFreeColorTokens.backgroundPrimary)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .tint(MusicFreeColorTokens.foregroundPrimary)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityIdentifier(playAccessibilityIdentifier ?? "")

            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 272)
        .frame(maxWidth: .infinity)
    }
}

/// A single accessibility element that behaves like Apple's switch while
/// avoiding the nested switch representation produced by the default SwiftUI
/// form toggle on iOS 26.
public struct MusicFreeSwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
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
                    .fill(.white)
                    .frame(width: 27, height: 27)
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                    .padding(2)
                    .offset(x: isOn ? 20 : 0)
                    .animation(.snappy(duration: 0.18), value: isOn)
            }
            .accessibilityHidden(true)
    }
}

public struct MusicFreeSectionHeader: View {
    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        _ title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)

            Spacer(minLength: MusicFreeSpacingTokens.small)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MusicFreeColorTokens.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
