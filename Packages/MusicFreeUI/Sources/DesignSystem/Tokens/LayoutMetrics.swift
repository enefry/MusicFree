import Foundation

public enum MusicFreeLayoutMetrics {
    public static let minimumHitTarget: CGFloat = 44
    public static let compactArtworkDimension: CGFloat = 52
    public static let regularArtworkDimension: CGFloat = 64
    public static let compactRowMinimumHeight: CGFloat = 68
    public static let regularRowMinimumHeight: CGFloat = 80
    public static let artworkAspectRatio: CGFloat = 1
    public static let artworkCornerRadius: CGFloat = 8
    public static let controlCornerRadius: CGFloat = 22

    /// Shared Mini Player geometry used by both the formal player and the
    /// transient online audition bar. The legacy host includes its vertical
    /// safe-area reservation; the content heights match the iOS 26 accessory
    /// environments.
    public static let miniPlayerLegacyHeight: CGFloat = 64
    public static let miniPlayerContentHeight: CGFloat = 48
    public static let miniPlayerInlineHeight: CGFloat = 44
    public static let miniPlayerHorizontalInset: CGFloat = 16
    public static let miniPlayerCornerRadius: CGFloat = 24
    public static let miniPlayerGap: CGFloat = 12
}
