import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI
import UIKit

struct GenresView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let addCollectionToPlaylist: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionPlaylistActionPending: (LibraryCollectionQueueTarget) -> Bool
    let compactRoute: ((LibraryDestination) -> LibraryCompactRoute)?

    @State private var isEditing = false
    @State private var selectedGenreIDs: Set<GenreID> = []
    @State private var pendingGenreDeletionIDs: Set<GenreID> = []
    @State private var isDeleting = false
    @State private var deletionErrorMessage: String?

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
            emptyTitle: L("暂无流派"),
            emptyMessage: L("导入带有流派信息的本地音频后会显示在这里。"),
            emptySystemImage: "guitars",
            retry: { viewModel.retry(section: .genres) }
        ) {
            NativeLibraryCollectionView(
                sections: groupedGenreKeys.map { key in
                    NativeLibraryCollectionSection(
                        id: "library.genres.\(key)",
                        headerTitle: key,
                        items: genres(for: key).map { genre in
                            NativeLibraryCollectionItem(
                                id: genre.id.rawValue,
                                accessibilityLabel: genre.name,
                                accessibilityHint: L("打开流派，按住显示更多操作")
                            )
                        }
                    )
                },
                layout: .list,
                header: nil,
                footer: viewModel.shouldShowPageFooter(for: .genres)
                    ? AnyView(LibraryPageFooter(section: .genres, viewModel: viewModel))
                    : nil,
                optionsAccessibilityPrefix: "library.genre",
                isEditing: isEditing,
                selectedIDs: Set(selectedGenreIDs.map(\.rawValue)),
                isDisabled: isDeleting,
                rowContent: { item, editing, selected in
                    guard let genre = genre(for: item.id) else {
                        return AnyView(EmptyView())
                    }
                    return AnyView(
                        GenreCollectionRow(
                            genre: genre,
                            isSelected: selected,
                            isEditing: editing
                        )
                    )
                },
                activateAction: { item in
                    navigate(.genre(GenreID(item.id)))
                },
                contextMenu: { item in
                    guard let genre = genre(for: item.id) else { return nil }
                    return contextMenu(for: genre)
                },
                shareText: { item in genre(for: item.id)?.name },
                onSelectionChanged: { ids in
                    selectedGenreIDs = Set(ids.map { GenreID($0) })
                },
                onEditingChanged: { editing in
                    if editing {
                        isEditing = true
                    } else {
                        finishEditing()
                    }
                },
                onLastItemDisplayed: { itemID in
                    guard itemID == orderedGenres.last?.id.rawValue else { return }
                    viewModel.loadNextPage(for: .genres)
                }
            )
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.genres")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing, !selectedGenreIDs.isEmpty {
                LibraryBatchDeletionBar(
                    count: selectedGenreIDs.count,
                    scope: .genres,
                    accessibilityIdentifier: "library.genres.deleteSelected",
                    isDisabled: isDeleting,
                    action: requestDeleteSelected
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button {
                        finishEditing()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Text(L("完成选择流派")))
                    .accessibilityIdentifier("library.genres.finishSelection")
                    .disabled(isDeleting)
                }
            }
        }
        .batchDeletionPresentation(
            isPresented: pendingGenreDeletionPresentation,
            count: pendingGenreDeletionIDs.count,
            scope: .genres,
            isDeleting: isDeleting,
            action: {
                let genreIDs = pendingGenreDeletionIDs
                pendingGenreDeletionIDs.removeAll()
                deleteSelectedGenres(genreIDs)
            }
        )
        .libraryDeletionErrorPresentation(errorMessage: $deletionErrorMessage)
    }

    private var pendingGenreDeletionPresentation: Binding<Bool> {
        Binding(
            get: { !pendingGenreDeletionIDs.isEmpty },
            set: { isPresented in
                if !isPresented { pendingGenreDeletionIDs.removeAll() }
            }
        )
    }

    private func finishEditing() {
        guard !isDeleting else { return }
        isEditing = false
        selectedGenreIDs.removeAll()
    }

    private func genre(for rawID: String) -> Genre? {
        viewModel.genres.first { $0.id.rawValue == rawID }
    }

    private func requestDeleteSelected() {
        guard !isDeleting, !selectedGenreIDs.isEmpty else { return }
        pendingGenreDeletionIDs = selectedGenreIDs
    }

    private func deleteSelectedGenres(_ genreIDs: Set<GenreID>) {
        guard !genreIDs.isEmpty, !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                let targets = Set(genreIDs.map { LibraryCollectionQueueTarget.genre($0) })
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: targets,
                    from: viewModel.library
                )
                if !itemIDs.isEmpty {
                    _ = try await viewModel.library.delete(itemIDs)
                    viewModel.removeDeletedTracks(itemIDs)
                }
                finishEditing()
                viewModel.load(section: .genres, reset: true)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func contextMenu(for genre: Genre) -> NativeLibraryContextMenuContents {
        let target = LibraryCollectionQueueTarget.genre(genre.id)
        let delete = UIAction(
            title: L("删除"),
            image: UIImage(systemName: "trash"),
            attributes: isDeleting ? [.disabled, .destructive] : [.destructive]
        ) { _ in
            guard !isDeleting else { return }
            pendingGenreDeletionIDs = [genre.id]
        }

        var secondaryActions: [UIMenuElement] = [
            UIAction(
                title: L("下一首播放"),
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                attributes: enqueueNextCollection == nil
                    || isCollectionQueueActionPending(target)
                    ? [.disabled]
                    : []
            ) { _ in enqueueNextCollection?(target) },
            UIAction(
                title: L("加入队列"),
                image: UIImage(systemName: "text.append"),
                attributes: enqueueCollection == nil
                    || isCollectionQueueActionPending(target)
                    ? [.disabled]
                    : []
            ) { _ in enqueueCollection?(target) }
        ]
        if addCollectionToPlaylist != nil {
            secondaryActions.append(
                UIAction(
                    title: L("添加到播放列表"),
                    image: UIImage(systemName: "text.badge.plus"),
                    attributes: isCollectionPlaylistActionPending(target) ? [.disabled] : []
                ) { _ in addCollectionToPlaylist?(target) }
            )
        }

        return NativeLibraryContextMenuContents(
            primaryActions: [delete],
            secondaryActions: secondaryActions
        )
    }
}

private struct GenreCollectionRow: View {
    let genre: Genre
    let isSelected: Bool
    let isEditing: Bool

    var body: some View {
        HStack(spacing: MusicFreeSpacingTokens.medium) {
            Image(systemName: isEditing ? (isSelected ? "checkmark.circle.fill" : "circle") : "guitars")
                .foregroundStyle(
                    isEditing && isSelected
                        ? MusicFreeColorTokens.accent
                        : MusicFreeColorTokens.foregroundTertiary
                )
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
    }
}
