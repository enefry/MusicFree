import SwiftUI

public struct LoadingStateView<Content: View>: View {
    private let isLoading: Bool
    private let label: String
    private let content: Content

    public init(
        isLoading: Bool,
        label: String = "Loading",
        @ViewBuilder content: () -> Content
    ) {
        self.isLoading = isLoading
        self.label = label
        self.content = content()
    }

    public var body: some View {
        content
            .overlay {
                if isLoading {
                    ProgressView()
                        .frame(
                            width: MusicFreeLayoutMetrics.minimumHitTarget,
                            height: MusicFreeLayoutMetrics.minimumHitTarget
                        )
                        .background(.regularMaterial, in: Circle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(label))
                        .accessibilityAddTraits(.updatesFrequently)
                        .allowsHitTesting(false)
                }
            }
    }
}
