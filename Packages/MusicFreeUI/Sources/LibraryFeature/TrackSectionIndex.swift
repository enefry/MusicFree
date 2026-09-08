import Foundation
import LibraryAPI

enum TrackSectionIndex {
    static let fallbackTitle = LibrarySortSupport.fallbackSectionTitle

    static func title(for value: String) -> String {
        LibrarySortSupport.sectionTitle(for: value)
    }

    static func normalizedSortValue(_ value: String) -> String {
        LibrarySortSupport.normalizedSortValue(value)
    }

    static func areInAscendingOrder(_ lhs: String, _ rhs: String) -> Bool {
        LibrarySortSupport.areSectionTitlesInAscendingOrder(lhs, rhs)
    }
}
