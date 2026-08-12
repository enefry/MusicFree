import Foundation

/// Shared ordering and sectioning rules for library collections.
///
/// Repositories use the normalized value before paging, while SwiftUI uses
/// the same value to derive section titles. Keeping both operations here
/// prevents a page boundary from changing the visible alphabet order.
public enum LibrarySortSupport {
    public static let fallbackSectionTitle = "#"

    public static func normalizedSortValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let latin = trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
        return latin.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).uppercased()
    }

    public static func sectionTitle(for value: String) -> String {
        guard let firstScalar = normalizedSortValue(value).unicodeScalars.first,
              firstScalar.value >= 65,
              firstScalar.value <= 90
        else {
            return fallbackSectionTitle
        }
        return String(firstScalar)
    }

    public static func areSectionTitlesInAscendingOrder(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == fallbackSectionTitle { return false }
        if rhs == fallbackSectionTitle { return true }
        return lhs < rhs
    }

    public static func leafName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public static func parentPath(of path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }
}
