@testable import LibraryFeature
import DesignSystem
import SwiftUI
import Testing

@Test("Album grid columns remain top-aligned")
func albumGridColumnsRemainTopAligned() {
    let expectedColumn = GridItem(
        .flexible(),
        spacing: MusicFreeSpacingTokens.large,
        alignment: .top
    )

    #expect(LibraryAlbumGridLayout.columns.count == 2)
    #expect(LibraryAlbumGridLayout.columns.allSatisfy { $0 == expectedColumn })
}
