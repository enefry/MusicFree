import UIKit

enum MiniPlayerSwipeAction: Equatable {
    case previous
    case next
}

enum MiniPlayerSwipePolicy {
    static let minimumDragDistance: CGFloat = 12
    static let baseActivationDistance: CGFloat = 52
    static let maximumDisplayOffset: CGFloat = 72
    static let unavailableDirectionResistance: CGFloat = 0.28

    static func commitOffset(
        for action: MiniPlayerSwipeAction,
        pageWidth: CGFloat
    ) -> CGFloat {
        let width = max(pageWidth, 1)
        return action == .next ? -width : width
    }

    static func action(
        for translation: CGSize,
        predictedEndTranslation _: CGSize,
        canGoPrevious: Bool,
        canGoNext: Bool,
        activationDistance: CGFloat = baseActivationDistance
    ) -> MiniPlayerSwipeAction? {
        guard isHorizontal(translation),
              abs(translation.width) >= max(1, activationDistance)
        else { return nil }

        if translation.width > 0 {
            return canGoPrevious ? .previous : nil
        }
        return canGoNext ? .next : nil
    }

    static func activationDistance(for carouselWidth: CGFloat) -> CGFloat {
        max(baseActivationDistance, carouselWidth * 0.12)
    }

    static func displayOffset(
        for translation: CGSize,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) -> CGFloat {
        guard isHorizontal(translation) else { return 0 }

        let isAvailable = translation.width > 0 ? canGoPrevious : canGoNext
        let resistance = isAvailable ? 1 : unavailableDirectionResistance
        return min(abs(translation.width) * resistance, maximumDisplayOffset)
            * (translation.width < 0 ? -1 : 1)
    }

    private static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }
}
