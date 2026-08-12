import Foundation

/// An opaque cursor returned by a repository for the next page.
public struct LibraryCursor: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var isEmpty: Bool { rawValue.isEmpty }
}

/// A bounded page and its continuation state.
public struct LibraryPage<Element: Sendable>: Sendable {
    public let elements: [Element]
    public let nextCursor: LibraryCursor?

    public init(elements: [Element], nextCursor: LibraryCursor? = nil) {
        self.elements = elements
        self.nextCursor = nextCursor?.isEmpty == true ? nil : nextCursor
    }

    public init(items: [Element], nextCursor: LibraryCursor? = nil) {
        self.init(elements: items, nextCursor: nextCursor)
    }

    public var items: [Element] { elements }

    public var hasNextPage: Bool { nextCursor != nil }

    /// Builds the next request while retaining the caller-selected page size.
    public func nextPage(limit: Int = LibraryPageRequest.defaultLimit) throws -> LibraryPageRequest? {
        guard let nextCursor else { return nil }
        return try LibraryPageRequest(limit: limit, cursor: nextCursor)
    }
}

extension LibraryPage: Codable where Element: Codable {}
extension LibraryPage: Equatable where Element: Equatable {}
