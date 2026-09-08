import UIKit

/// UIKit counterparts for the semantic SwiftUI colors in `MusicFreeColorTokens`.
///
/// The values intentionally use UIKit's dynamic system colors instead of
/// resolved RGB values so light/dark mode and accessibility contrast continue
/// to follow the system without requiring view-level branching.
public enum MusicFreeUIColorTokens {
    public static let backgroundPrimary = UIColor.systemBackground
    public static let backgroundSecondary = UIColor.secondarySystemBackground
    public static let backgroundGrouped = UIColor.systemGroupedBackground
    public static let surfaceElevated = UIColor.tertiarySystemBackground
    public static let playerSurface = UIColor.secondarySystemBackground
    /// An explicitly resolved, fully opaque player surface. Semantic system
    /// colors can be re-composited by iOS 26 accessory chrome; the Mini
    /// Player must not allow the scroll content to show through that layer.
    public static let playerSurfaceOpaque = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1)
            : UIColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    }
    public static let playerControl = UIColor.systemGray5

    public static let foregroundPrimary = UIColor.label
    public static let foregroundSecondary = UIColor.secondaryLabel
    public static let foregroundTertiary = UIColor.tertiaryLabel
    public static let separator = UIColor.separator

    public static var accent: UIColor { MusicFreeAccentColorStore.uiColor }
    public static var accentSoft: UIColor {
        UIColor { _ in
            MusicFreeAccentColorStore.uiColor(forHex: MusicFreeAccentColorStore.hexValue)
                .withAlphaComponent(0.14)
        }
    }
    public static var onAccent: UIColor { MusicFreeAccentColorStore.onAccentUIColor }
    public static let positive = UIColor.systemGreen
    public static let warning = UIColor.systemOrange
    public static let destructive = UIColor.systemRed
    public static let disabled = UIColor.tertiaryLabel
}

/// Dynamic UIKit fonts corresponding to the SwiftUI typography tokens.
public enum MusicFreeUIFontTokens {
    public static var screenTitle: UIFont { preferred(.title1, weight: .semibold) }
    public static var sectionTitle: UIFont { UIFont.preferredFont(forTextStyle: .headline) }
    public static var rowTitle: UIFont { UIFont.preferredFont(forTextStyle: .body) }
    public static var rowSubtitle: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    public static var body: UIFont { UIFont.preferredFont(forTextStyle: .body) }
    public static var secondary: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    public static var caption: UIFont { UIFont.preferredFont(forTextStyle: .caption1) }
    public static var controlLabel: UIFont { preferred(.headline, weight: .semibold) }

    public static func preferred(
        _ textStyle: UIFont.TextStyle,
        weight: UIFont.Weight
    ) -> UIFont {
        let preferredSize = UIFont.preferredFont(forTextStyle: textStyle).pointSize
        return UIFont.systemFont(ofSize: preferredSize, weight: weight)
    }
}

public extension MusicFreeSpacingTokens {
    static var contentInsets: NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(
            top: contentInset,
            leading: contentInset,
            bottom: contentInset,
            trailing: contentInset
        )
    }

    static var rowInsets: NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(
            top: small,
            leading: contentInset,
            bottom: small,
            trailing: contentInset
        )
    }
}

public extension MusicFreeLayoutMetrics {
    static var minimumHitTargetSize: CGSize {
        CGSize(width: minimumHitTarget, height: minimumHitTarget)
    }

    static func artworkDimension(for traitCollection: UITraitCollection) -> CGFloat {
        traitCollection.horizontalSizeClass == .regular
            ? regularArtworkDimension
            : compactArtworkDimension
    }

    static func artworkSize(for traitCollection: UITraitCollection) -> CGSize {
        let dimension = artworkDimension(for: traitCollection)
        return CGSize(width: dimension, height: dimension)
    }
}
