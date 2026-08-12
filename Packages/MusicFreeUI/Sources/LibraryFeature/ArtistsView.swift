import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

struct ArtistsView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let artworkServing: (any ArtworkServing)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool

    init(
        viewModel: LibraryViewModel,
        navigate: @escaping (LibraryDestination) -> Void,
        artworkServing: (any ArtworkServing)? = nil,
        enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionQueueActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false }
    ) {
        self.viewModel = viewModel
        self.navigate = navigate
        self.artworkServing = artworkServing
        self.enqueueNextCollection = enqueueNextCollection
        self.enqueueCollection = enqueueCollection
        self.isCollectionQueueActionPending = isCollectionQueueActionPending
    }

    private var orderedArtists: [Artist] {
        viewModel.artists.sorted { lhs, rhs in
            let left = LibrarySortSupport.normalizedSortValue(lhs.sortName ?? lhs.name)
            let right = LibrarySortSupport.normalizedSortValue(rhs.sortName ?? rhs.name)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    private var groupedArtistKeys: [String] {
        Array(Set(orderedArtists.map { LibrarySortSupport.sectionTitle(for: $0.sortName ?? $0.name) }))
            .sorted(by: LibrarySortSupport.areSectionTitlesInAscendingOrder)
    }

    private func artists(for key: String) -> [Artist] {
        orderedArtists.filter {
            LibrarySortSupport.sectionTitle(for: $0.sortName ?? $0.name) == key
        }
    }

    var body: some View {
        LibraryContentState(
            state: viewModel.state(for: .artists),
            hasContent: !viewModel.artists.isEmpty,
            emptyTitle: "暂无艺人",
            emptyMessage: "导入带有艺人信息的本地音频后会显示在这里。",
            emptySystemImage: "person.2",
            retry: { viewModel.retry(section: .artists) }
        ) {
            List {
                ForEach(groupedArtistKeys, id: \.self) { key in
                    Section {
                        ForEach(artists(for: key)) { artist in
                            ArtistRow(
                                artist: artist,
                                artworkServing: artworkServing,
                                action: { navigate(.artist(artist.id)) }
                            )
                            .listRowInsets(EdgeInsets())
                            .onAppear {
                                if artist.id == orderedArtists.last?.id {
                                    viewModel.loadNextPage(for: .artists)
                                }
                            }
                            .contextMenu {
                                let target = LibraryCollectionQueueTarget.artist(artist.id)
                                LibraryCollectionQueueMenuActions(
                                    target: target,
                                    accessibilityPrefix: "library.artist.menu",
                                    enqueueNext: enqueueNextCollection,
                                    enqueue: enqueueCollection,
                                    isPending: isCollectionQueueActionPending(target)
                                )
                            }
                            .accessibilityHint("打开艺人，按住显示播放队列操作")
                        }
                    } header: {
                        Text(key)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                            .textCase(nil)
                    }
                    .sectionIndexLabel(key)
                }
                LibraryPageFooter(section: .artists, viewModel: viewModel)
            }
            .listStyle(.plain)
            .listSectionIndexVisibility(groupedArtistKeys.isEmpty ? .hidden : .visible)
            .scrollContentBackground(.hidden)
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.artists")
        }
    }
}

private struct ArtistRow: View {
    let artist: Artist
    let artworkServing: (any ArtworkServing)?
    let action: () -> Void

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        Button(action: action) {
            MediaRow(
                title: artist.name,
                artwork: artworkLoader.image,
                artworkAccessibilityLabel: "\(artist.name)的艺人封面",
                placeholderSystemImage: "person.fill"
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("library.artist.open.\(artist.id.rawValue)")
        .task(id: artworkKey) {
            await artworkLoader.load(
                artworkID: artist.artworkID,
                sourceID: .local,
                serving: artworkServing
            )
        }
    }

    private var artworkKey: String {
        "\(MediaSourceID.local.rawValue):\(artist.artworkID?.rawValue ?? "")"
    }
}
