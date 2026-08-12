import SwiftUI

public struct CapabilitySection<Content: View>: View {
    private let isAvailable: Bool
    private let content: Content

    public init(
        isAvailable: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.isAvailable = isAvailable
        self.content = content()
    }

    public var body: some View {
        if isAvailable {
            content
        }
    }
}
