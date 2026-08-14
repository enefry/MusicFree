import SwiftUI

public enum MusicFreeAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: Self { self }

    public var title: String {
        switch self {
        case .system: return MusicFreeLocalization.localized("appearance.system")
        case .light: return MusicFreeLocalization.localized("appearance.light")
        case .dark: return MusicFreeLocalization.localized("appearance.dark")
        }
    }

    public var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum MusicFreeColorTokens {
    public static let backgroundPrimary = Color(.systemBackground)
    public static let backgroundSecondary = Color(.secondarySystemBackground)
    public static let backgroundGrouped = Color(.systemGroupedBackground)
    public static let surfaceElevated = Color(.tertiarySystemBackground)
    public static let playerSurface = Color(.secondarySystemBackground)
    public static let playerControl = Color(.systemGray5)

    public static let foregroundPrimary = Color(.label)
    public static let foregroundSecondary = Color(.secondaryLabel)
    public static let foregroundTertiary = Color(.tertiaryLabel)
    public static let separator = Color(.separator)

    public static let accent = Color(.systemPink)
    public static let accentSoft = Color(.systemPink).opacity(0.14)
    public static let onAccent = Color.white
    public static let positive = Color(.systemGreen)
    public static let warning = Color(.systemOrange)
    public static let destructive = Color(.systemRed)
    public static let disabled = Color(.tertiaryLabel)
}
