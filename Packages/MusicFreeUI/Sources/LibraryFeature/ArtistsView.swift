import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI
import UIKit

struct ArtistsView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let artworkServing: (any ArtworkServing)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let compactRoute: ((LibraryDestination) -> LibraryCompactRoute)?

    @State private var isEditing = false
    @State private var selectedArtistIDs: Set<ArtistID> = []
    @State private var pendingArtistDeletionIDs: Set<ArtistID> = []
    @State private var isDeleting = false
    @State private var deletionErrorMessage: String?

    init(
        viewModel: LibraryViewModel,
        navigate: @escaping (LibraryDestination) -> Void,
        artworkServing: (any ArtworkServing)? = nil,
        enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionQueueActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false },
        compactRoute: ((LibraryDestination) -> LibraryCompactRoute)? = nil
    ) {
        self.viewModel = viewModel
        self.navigate = navigate
        self.artworkServing = artworkServing
        self.enqueueNextCollection = enqueueNextCollection
        self.enqueueCollection = enqueueCollection
        self.isCollectionQueueActionPending = isCollectionQueueActionPending
        self.compactRoute = compactRoute
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
            emptyTitle: L("暂无艺人"),
            emptyMessage: L("导入带有艺人信息的本地音频后会显示在这里。"),
            emptySystemImage: "person.2",
            retry: { viewModel.retry(section: .artists) }
        ) {
            NativeLibraryCollectionView(
                sections: groupedArtistKeys.map { key in
                    NativeLibraryCollectionSection(
                        id: "library.artists.\(key)",
                        headerTitle: key,
                        items: artists(for: key).map { artist in
                            NativeLibraryCollectionItem(
                                id: artist.id.rawValue,
                                accessibilityLabel: artist.name,
                                accessibilityHint: L("打开艺人，按住显示更多操作")
                            )
                        }
                    )
                },
                layout: .list,
                header: nil,
            footer: viewModel.shouldShowPageFooter(for: .artists)
                ? AnyView(LibraryPageFooter(section: .artists, viewModel: viewModel))
                : nil,
                optionsAccessibilityPrefix: "library.artist",
                isEditing: isEditing,
                selectedIDs: Set(selectedArtistIDs.map(\.rawValue)),
                isDisabled: isDeleting,
                rowContent: { item, editing, selected in
                    guard let artist = artist(for: item.id) else {
                        return AnyView(EmptyView())
                    }
                    return AnyView(
                        ArtistCollectionRow(
                            artist: artist,
                            artworkServing: artworkServing,
                            isSelected: selected,
                            isEditing: editing
                        )
                    )
                },
                activateAction: { item in
                    navigate(.artist(ArtistID(item.id)))
                },
                contextMenu: { item in
                    guard let artist = artist(for: item.id) else { return nil }
                    return contextMenu(for: artist)
                },
                shareText: { item in artist(for: item.id)?.name },
                onSelectionChanged: { ids in
                    selectedArtistIDs = Set(ids.map { ArtistID($0) })
                },
                onEditingChanged: { editing in
                    if editing {
                        isEditing = true
                    } else {
                        finishEditing()
                    }
                },
                onLastItemDisplayed: { itemID in
                    guard itemID == orderedArtists.last?.id.rawValue else { return }
                    viewModel.loadNextPage(for: .artists)
                }
            )
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.artists")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing, !selectedArtistIDs.isEmpty {
                LibraryBatchDeletionBar(
                    count: selectedArtistIDs.count,
                    scope: .artists,
                    accessibilityIdentifier: "library.artists.deleteSelected",
                    isDisabled: isDeleting,
                    action: requestDeleteSelected
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button {
                        finishEditing()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Text(L("完成选择艺人")))
                    .accessibilityIdentifier("library.artists.finishSelection")
                    .disabled(isDeleting)
                }
            }
        }
        .batchDeletionPresentation(
            isPresented: pendingArtistDeletionPresentation,
            count: pendingArtistDeletionIDs.count,
            scope: .artists,
            isDeleting: isDeleting,
            action: {
                let artistIDs = pendingArtistDeletionIDs
                pendingArtistDeletionIDs.removeAll()
                deleteSelectedArtists(artistIDs)
            }
        )
        .libraryDeletionErrorPresentation(errorMessage: $deletionErrorMessage)
    }

    private var pendingArtistDeletionPresentation: Binding<Bool> {
        Binding(
            get: { !pendingArtistDeletionIDs.isEmpty },
            set: { isPresented in
                if !isPresented { pendingArtistDeletionIDs.removeAll() }
            }
        )
    }

    private func finishEditing() {
        guard !isDeleting else { return }
        isEditing = false
        selectedArtistIDs.removeAll()
    }

    private func artist(for rawID: String) -> Artist? {
        viewModel.artists.first { $0.id.rawValue == rawID }
    }

    private func requestDeleteSelected() {
        guard !isDeleting, !selectedArtistIDs.isEmpty else { return }
        pendingArtistDeletionIDs = selectedArtistIDs
    }

    private func deleteSelectedArtists(_ artistIDs: Set<ArtistID>) {
        guard !artistIDs.isEmpty, !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                let targets = Set(artistIDs.map { LibraryCollectionQueueTarget.artist($0) })
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: targets,
                    from: viewModel.library
                )
                if !itemIDs.isEmpty {
                    _ = try await viewModel.library.delete(itemIDs)
                    viewModel.removeDeletedTracks(itemIDs)
                }
                finishEditing()
                viewModel.load(section: .artists, reset: true)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func contextMenu(for artist: Artist) -> NativeLibraryContextMenuContents {
        let target = LibraryCollectionQueueTarget.artist(artist.id)
        let delete = UIAction(
            title: L("删除"),
            image: UIImage(systemName: "trash"),
            attributes: isDeleting ? [.disabled, .destructive] : [.destructive]
        ) { _ in
            guard !isDeleting else { return }
            pendingArtistDeletionIDs = [artist.id]
        }

        let secondaryActions: [UIMenuElement] = [
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

        return NativeLibraryContextMenuContents(
            primaryActions: [delete],
            secondaryActions: secondaryActions
        )
    }
}

private struct ArtistCollectionRow: View {
    let artist: Artist
    let artworkServing: (any ArtworkServing)?
    let isSelected: Bool
    let isEditing: Bool

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        rowContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        .task(id: artworkKey) {
            await artworkLoader.load(
                artworkID: artist.artworkID,
                sourceID: .local,
                serving: artworkServing
            )
        }
    }

    private var rowContent: some View {
        ZStack(alignment: .leading) {
            MediaRow(
                title: artist.name,
                artwork: artworkLoader.image,
                artworkAccessibilityLabel: L("%@ artist artwork", artist.name),
                placeholderSystemImage: "person.fill"
            )
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(
                        isSelected
                            ? MusicFreeColorTokens.accent
                            : MusicFreeColorTokens.foregroundTertiary
                    )
                    .background(
                        Circle()
                            .fill(MusicFreeColorTokens.backgroundPrimary)
                    )
                    .padding(.leading, MusicFreeSpacingTokens.small)
                    .accessibilityHidden(true)
            }
        }
    }

    private var artworkKey: String {
        "\(MediaSourceID.local.rawValue):\(artist.artworkID?.rawValue ?? "")"
    }
}
