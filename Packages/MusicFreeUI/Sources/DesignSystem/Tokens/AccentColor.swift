import Foundation
import SwiftUI
import UIKit

/// Persists the app-wide accent color in a format that can be shared by
/// SwiftUI, UIKit, and the application shell without coupling the feature
/// packages to an app-owned settings model.
public enum MusicFreeAccentColorStore {
    public static let storageKey = "musicfree.accentColor"
    public static let defaultHex = "FF2D55"

    public static var hexValue: String {
        normalizedHex(UserDefaults.standard.string(forKey: storageKey) ?? defaultHex)
    }

    public static var color: Color {
        color(forHex: hexValue)
    }

    /// A dynamic UIColor whose provider reads the current persisted value.
    /// Existing UIKit views therefore resolve the latest accent after a redraw.
    public static var uiColor: UIColor {
        UIColor { _ in
            uiColor(forHex: hexValue)
        }
    }

    /// A dynamic foreground color for controls rendered on top of the accent.
    /// The color is selected for the strongest contrast against the current
    /// accent instead of assuming every custom color is dark enough for white.
    public static var onAccentUIColor: UIColor {
        UIColor { _ in
            onAccentUIColor(forHex: hexValue)
        }
    }

    public static func color(forHex hex: String) -> Color {
        Color(uiColor: uiColor(forHex: hex))
    }

    public static func onAccentColor(forHex hex: String) -> Color {
        Color(uiColor: onAccentUIColor(forHex: hex))
    }

    public static func uiColor(forHex hex: String) -> UIColor {
        resolvedUIColor(forHex: hex)
    }

    public static func onAccentUIColor(forHex hex: String) -> UIColor {
        let accent = resolvedUIColor(forHex: hex)
        return relativeLuminance(for: accent) > 0.179 ? .black : .white
    }

    public static func setHexValue(_ hex: String) {
        UserDefaults.standard.set(normalizedHex(hex), forKey: storageKey)
    }

    public static func reset() {
        setHexValue(defaultHex)
    }

    public static func normalizedHex(_ hex: String) -> String {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else {
            return defaultHex
        }
        return value.uppercased()
    }

    public static func hexString(for color: UIColor) -> String {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return String(
                format: "%02lX%02lX%02lX",
                lround(red * 255),
                lround(green * 255),
                lround(blue * 255)
            )
        }

        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &alpha) {
            let component = lround(white * 255)
            return String(format: "%02lX%02lX%02lX", component, component, component)
        }

        return defaultHex
    }

    private static func resolvedUIColor(forHex hex: String) -> UIColor {
        let value = normalizedHex(hex)
        guard
            let red = Int(value.prefix(2), radix: 16),
            let green = Int(value.dropFirst(2).prefix(2), radix: 16),
            let blue = Int(value.dropFirst(4).prefix(2), radix: 16)
        else {
            return UIColor(red: 1, green: 45 / 255, blue: 85 / 255, alpha: 1)
        }
        return UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    private static func relativeLuminance(for color: UIColor) -> CGFloat {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            var white: CGFloat = 0
            guard resolved.getWhite(&white, alpha: &alpha) else { return 1 }
            return linearized(white)
        }
        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }

    private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
