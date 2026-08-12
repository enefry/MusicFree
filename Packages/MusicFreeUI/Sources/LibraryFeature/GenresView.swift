import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

struct GenresView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionPlaylistActionPending: (LibraryCollectionQueueTarget) -> Bool
    let compactRoute: ((LibraryDestination) -> LibraryCompactRoute)?

    init(
        viewModel: LibraryViewModel,
        navigate: @escaping (LibraryDestination) -> Void,
        enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionQueueActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false },
        addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionPlaylistActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false },
        compactRoute: ((LibraryDestination) -> LibraryCompactRoute)? = nil
    ) {
        self.viewModel = viewModel
        self.navigate = navigate
        self.enqueueNextCollection = enqueueNextCollection
        self.enqueueCollection = enqueueCollection
        self.isCollectionQueueActionPending = isCollectionQueueActionPending
        self.addCollectionToPlaylist = addCollectionToPlaylist
        self.isCollectionPlaylistActionPending = isCollectionPlaylistActionPending
        self.compactRoute = compactRoute
    }

    private var orderedGenres: [Genre] {
        viewModel.genres.sorted { lhs, rhs in
            let left = LibrarySortSupport.normalizedSortValue(lhs.sortName ?? lhs.name)
            let right = LibrarySortSupport.normalizedSortValue(rhs.sortName ?? rhs.name)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    private var groupedGenreKeys: [String] {
        Array(Set(orderedGenres.map { LibrarySortSupport.sectionTitle(for: $0.sortName ?? $0.name) }))
            .sorted(by: LibrarySortSupport.areSectionTitlesInAscendingOrder)
    }

    private func genres(for key: String) -> [Genre] {
        orderedGenres.filter {
            LibrarySortSupport.sectionTitle(for: $0.sortName ?? $0.name) == key
        }
    }

    var body: some View {
        LibraryContentState(
            state: viewModel.state(for: .genres),
            hasContent: !viewModel.genres.isEmpty,
            emptyTitle: "暂无流派",
            emptyMessage: "导入带有流派信息的本地音频后会显示在这里。",
            emptySystemImage: "guitars",
            retry: { viewModel.retry(section: .genres) }
        ) {
            List {
                ForEach(groupedGenreKeys, id: \.self) { key in
                    Section {
                        ForEach(genres(for: key)) { genre in
                            row(for: genre)
                                .listRowInsets(EdgeInsets())
                                .onAppear {
                                    if genre.id == orderedGenres.last?.id {
                                        viewModel.loadNextPage(for: .genres)
                                    }
                                }
                        }
                    } header: {
                        Text(key)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                            .textCase(nil)
                    }
                    .sectionIndexLabel(key)
                }
                LibraryPageFooter(section: .genres, viewModel: viewModel)
            }
            .listStyle(.plain)
            .listSectionIndexVisibility(groupedGenreKeys.isEmpty ? .hidden : .visible)
            .scrollContentBackground(.hidden)
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.genres")
        }
    }

    @ViewBuilder
    private func row(for genre: Genre) -> some View {
        let label = HStack(spacing: MusicFreeSpacingTokens.medium) {
            Image(systemName: "guitars")
                .foregroundStyle(MusicFreeColorTokens.accent)
                .frame(width: MusicFreeLayoutMetrics.minimumHitTarget)

            Text(genre.name)
                .font(MusicFreeTypographyTokens.rowTitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                .lineLimit(1)

            Spacer(minLength: MusicFreeSpacingTokens.small)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .contentShape(Rectangle())

        Group {
            if let compactRoute {
                NavigationLink(value: compactRoute(.genre(genre.id))) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: LibraryDestination.genre(genre.id)) {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            let target = LibraryCollectionQueueTarget.genre(genre.id)
            LibraryCollectionQueueMenuActions(
                target: target,
                accessibilityPrefix: "library.genre.menu",
                enqueueNext: enqueueNextCollection,
                enqueue: enqueueCollection,
                addToPlaylist: addCollectionToPlaylist,
                isPending: isCollectionQueueActionPending(target)
                    || isCollectionPlaylistActionPending(target)
            )
        }
        .accessibilityIdentifier("library.genre.open.\(genre.id.rawValue)")
        .accessibilityHint("打开流派，按住显示播放队列操作")
    }
}
