import SwiftUI

public struct ErrorStateView: View {
    private let title: String
    private let message: String
    private let retryTitle: String?
    private let retry: (() -> Void)?

    public init(
        title: String = "Unable to load",
        message: String,
        retryTitle: String? = "Try Again",
        retry: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: MusicFreeSpacingTokens.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(MusicFreeTypographyTokens.screenTitle)
                .foregroundStyle(MusicFreeColorTokens.destructive)
                .accessibilityHidden(true)

            Text(title)
                .font(MusicFreeTypographyTokens.sectionTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(MusicFreeTypographyTokens.body)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let retryTitle, let retry, !retryTitle.isEmpty {
                Button(retryTitle, action: retry)
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
