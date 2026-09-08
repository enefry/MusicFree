import LibraryAPI
import MusicDomain
import Testing

@Test("album artwork selection prefers folder or sidecar artwork")
func albumArtworkSelectionPrefersFolderArtwork() {
    let embedded = ArtworkReference(id: ArtworkID("embedded"))
    let folder = ArtworkReference(id: ArtworkID("folder"))

    let selected = AlbumArtworkSelector.select(from: [
        AlbumArtworkCandidate(
            artwork: embedded,
            origin: .embedded,
            stableKey: "track-1"
        ),
        AlbumArtworkCandidate(
            artwork: folder,
            origin: .folderOrSidecar,
            stableKey: "track-2"
        ),
        AlbumArtworkCandidate(
            artwork: embedded,
            origin: .embedded,
            stableKey: "track-3"
        )
    ])

    #expect(selected == folder)
}

@Test("album artwork selection uses frequency and stable tie breaking")
func albumArtworkSelectionIsDeterministic() {
    let first = ArtworkReference(id: ArtworkID("first"))
    let second = ArtworkReference(id: ArtworkID("second"))

    let candidates = [
        AlbumArtworkCandidate(artwork: second, origin: .embedded, stableKey: "b"),
        AlbumArtworkCandidate(artwork: first, origin: .embedded, stableKey: "a"),
        AlbumArtworkCandidate(artwork: second, origin: .embedded, stableKey: "c")
    ]

    #expect(AlbumArtworkSelector.select(from: candidates) == second)
    #expect(AlbumArtworkSelector.select(from: candidates.reversed()) == second)
    #expect(AlbumArtworkSelector.select(from: [
        AlbumArtworkCandidate(artwork: second, origin: .embedded, stableKey: "z"),
        AlbumArtworkCandidate(artwork: first, origin: .embedded, stableKey: "a")
    ]) == first)
}
