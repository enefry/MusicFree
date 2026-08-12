import SwiftUI

public struct EmptyStateView: View {
    private let title: Text
    private let message: Text?
    private let systemImage: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        title: String,
        message: String? = nil,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = Text(title)
        self.message = message.map(Text.init)
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = Text(title)
        self.message = nil
        self.systemImage = systemImage
        self.actionTitle = nil
        self.action = nil
    }

    public var body: some View {
        VStack(spacing: MusicFreeSpacingTokens.medium) {
            Image(systemName: systemImage)
                .font(MusicFreeTypographyTokens.screenTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                .accessibilityHidden(true)

            title
                .font(MusicFreeTypographyTokens.sectionTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                message
                    .font(MusicFreeTypographyTokens.body)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action, !actionTitle.isEmpty {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: MusicFreeLayoutMetrics.minimumHitTarget)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .padding(.vertical, MusicFreeSpacingTokens.xLarge)
        .accessibilityElement(children: .contain)
    }
}

// Existing placeholder Features keep their public call shape until they migrate
// to EmptyStateView directly. The implementation now lives in the formal component.
public struct MusicFreeEmptyState: View {
    private let title: LocalizedStringKey
    private let systemImage: String

    public init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        EmptyStateView(title, systemImage: systemImage)
    }
}
