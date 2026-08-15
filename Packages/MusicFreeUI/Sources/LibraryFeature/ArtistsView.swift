import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

struct ArtistsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let artworkServing: (any ArtworkServing)?
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool
    let compactRoute: ((LibraryDestination) -> LibraryCompactRoute)?

    @State private var editMode: EditMode = .inactive
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
            List {
                ForEach(groupedArtistKeys, id: \.self) { key in
                    Section {
                        ForEach(artists(for: key)) { artist in
                            ArtistRow(
                                artist: artist,
                                artworkServing: artworkServing,
                                action: { navigate(.artist(artist.id)) },
                                selectionAction: { toggleSelection(for: artist.id) },
                                isSelected: selectedArtistIDs.contains(artist.id),
                                isEditing: isEditing,
                                destination: compactRoute.map {
                                    $0(.artist(artist.id))
                                }
                            )
                            .listRowInsets(EdgeInsets())
                            .onAppear {
                                if artist.id == orderedArtists.last?.id {
                                    viewModel.loadNextPage(for: .artists)
                                }
                            }
                            .contextMenu {
                                if !isEditing {
                                    let target = LibraryCollectionQueueTarget.artist(artist.id)
                                    LibraryCollectionQueueMenuActions(
                                        target: target,
                                        accessibilityPrefix: "library.artist.menu",
                                        enqueueNext: enqueueNextCollection,
                                        enqueue: enqueueCollection,
                                        isPending: isCollectionQueueActionPending(target)
                                    )
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
                LibraryPageFooter(section: .artists, viewModel: viewModel)
            }
            .listStyle(.plain)
            .listSectionIndexVisibility(groupedArtistKeys.isEmpty ? .hidden : .visible)
            .scrollContentBackground(.hidden)
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
            if horizontalSizeClass == .compact {
                Color.clear
                    .frame(height: MusicFreeLayoutMetrics.compactTabAccessoryClearance)
                    .accessibilityHidden(true)
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleEditing()
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
                .accessibilityLabel(Text(isEditing ? L("完成编辑") : L("编辑艺人")))
                .help(isEditing ? L("完成编辑") : L("编辑艺人"))
                .accessibilityIdentifier("library.artists.edit")
                .disabled(viewModel.isLoading(.artists) || isDeleting)
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

    private var isEditing: Bool {
        editMode.isEditing
    }

    private var pendingArtistDeletionPresentation: Binding<Bool> {
        Binding(
            get: { !pendingArtistDeletionIDs.isEmpty },
            set: { isPresented in
                if !isPresented { pendingArtistDeletionIDs.removeAll() }
            }
        )
    }

    private func toggleEditing() {
        guard !viewModel.isLoading(.artists), !isDeleting else { return }
        if isEditing {
            editMode = .inactive
            selectedArtistIDs.removeAll()
        } else {
            editMode = .active
        }
    }

    private func toggleSelection(for artistID: ArtistID) {
        guard isEditing, !isDeleting else { return }
        if !selectedArtistIDs.insert(artistID).inserted {
            selectedArtistIDs.remove(artistID)
        }
    }

    private func requestDeleteSelected() {
        guard isEditing, !isDeleting, !selectedArtistIDs.isEmpty else { return }
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
                editMode = .inactive
                selectedArtistIDs.removeAll()
                viewModel.load(section: .artists, reset: true)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct ArtistRow: View {
    let artist: Artist
    let artworkServing: (any ArtworkServing)?
    let action: () -> Void
    let selectionAction: () -> Void
    let isSelected: Bool
    let isEditing: Bool
    let destination: LibraryCompactRoute?

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        Group {
            if !isEditing, let destination {
                NavigationLink(value: destination) {
                    rowContent
                }
            } else {
                Button(action: isEditing ? selectionAction : action) {
                    rowContent
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(artist.name))
        .accessibilityValue(Text(isEditing ? (isSelected ? L("已选择") : L("未选择")) : L("艺人")))
        .accessibilityIdentifier(
            "library.artist.\(isEditing ? "select" : "open").\(artist.id.rawValue)"
        )
        .accessibilityHint(
            L(isEditing ? "选择艺人" : "打开艺人，按住显示播放队列操作")
        )
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
