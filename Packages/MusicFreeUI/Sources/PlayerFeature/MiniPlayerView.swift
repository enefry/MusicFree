import AppServices
import DesignSystem
import MusicDomain
import PlaybackAPI
import SwiftUI

@MainActor
public struct MiniPlayerView: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var bottomAccessoryPlacement
    @StateObject private var viewModel: PlayerViewModel
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var carouselWidth: CGFloat = 0
    @State private var isCommittingSwipe = false
    private let onPresentPlayer: () -> Void
    private let artworkServing: (any ArtworkServing)?
    private let library: (any LibraryServing)?
    @State private var previewDisplays: [UUID: PlaybackDisplaySnapshot] = [:]

    private static let fallbackEntryID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    public init() {
        self.init(serving: PlayerStore())
    }

    init(
        viewModel: PlayerViewModel,
        onPresentPlayer: @escaping () -> Void = {},
        artworkServing: (any ArtworkServing)? = nil,
        library: (any LibraryServing)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onPresentPlayer = onPresentPlayer
        self.artworkServing = artworkServing
        self.library = library
    }

    public init(
        serving: any PlaybackServing,
        audioServing: (any PlayerAudioServing)? = nil,
        artworkServing: (any ArtworkServing)? = nil,
        library: (any LibraryServing)? = nil,
        onPresentPlayer: @escaping () -> Void = {}
    ) {
        self.init(
            viewModel: PlayerViewModel(serving: serving, audioServing: audioServing),
            onPresentPlayer: onPresentPlayer,
            artworkServing: artworkServing,
            library: library
        )
    }

    public var body: some View {
        Group {
            if viewModel.isMiniPlayerVisible,
               let currentItem = viewModel.snapshot.currentItem {
                if isNativeTabAccessory {
                    content(currentItem: currentItem)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: bottomAccessoryPlacement == .inline ? 44 : 56
                        )
                } else {
                    content(currentItem: currentItem)
                        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(.bar)
                        .overlay(alignment: .top) {
                            Divider()
                                .overlay(MusicFreeColorTokens.separator.opacity(0.32))
                                .accessibilityHidden(true)
                        }
                }
            } else {
                Color.clear
                    .frame(height: 0)
                    .accessibilityHidden(true)
            }
        }
        .task(id: queuePreviewKey) {
            await loadPreviewDisplays()
        }
    }

    private var isNativeTabAccessory: Bool {
        bottomAccessoryPlacement != nil
    }

    private func content(
        currentItem: PlaybackDisplaySnapshot
    ) -> some View {
        HStack(spacing: MusicFreeSpacingTokens.rowGap) {
            miniPlayerCarousel(currentItem: currentItem)

            PlaybackControlButton(
                systemImage: viewModel.snapshot.phase == .playing
                    ? "pause.fill"
                    : "play.fill",
                accessibilityLabel: viewModel.snapshot.phase == .playing
                    ? L("暂停")
                    : L("播放"),
                isLoading: viewModel.presentationState == .loading
                    || viewModel.presentationState == .buffering,
                foregroundColor: MusicFreeColorTokens.foregroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 44,
                action: viewModel.togglePlayback
            )

            PlaybackControlButton(
                systemImage: "forward.fill",
                accessibilityLabel: L("下一首"),
                isEnabled: viewModel.canGoNext,
                foregroundColor: MusicFreeColorTokens.foregroundPrimary,
                backgroundColor: .clear,
                showsBackground: false,
                controlSize: 44,
                action: viewModel.next
            )
        }
        .padding(
            .horizontal,
            isNativeTabAccessory
                ? MusicFreeSpacingTokens.small
                : MusicFreeSpacingTokens.contentInset
        )
        .accessibilityElement(children: .contain)
    }

    private func miniPlayerCarousel(
        currentItem: PlaybackDisplaySnapshot
    ) -> some View {
        let items = carouselItems(currentItem: currentItem)
        let currentIndex = items.firstIndex(where: \.isCurrent) ?? 0

        return GeometryReader { proxy in
            let pageWidth = max(proxy.size.width, 1)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        miniPlayerItem(item)
                            .frame(width: pageWidth, alignment: .leading)
                    }
                }
                .offset(
                    x: -CGFloat(currentIndex) * pageWidth + horizontalDragOffset
                )
            }
            .frame(width: pageWidth, height: proxy.size.height, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .onAppear { carouselWidth = pageWidth }
            .onChange(of: pageWidth) { _, newValue in
                carouselWidth = newValue
            }
            .highPriorityGesture(miniPlayerSwipeGesture)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    @ViewBuilder
    private func miniPlayerItem(_ item: MiniPlayerCarouselItem) -> some View {
        let itemBody = HStack(spacing: MusicFreeSpacingTokens.rowGap) {
            if shouldShowArtwork {
                ArtworkResourceView(
                    artworkID: item.display.artworkID,
                    sourceID: item.itemID.sourceID,
                    serving: artworkServing,
                    accessibilityLabel: item.display.artworkID == nil ? L("暂无封面") : L("封面"),
                    placeholderTitle: item.display.title,
                    fillsAvailableWidth: true,
                    cornerRadius: 5
                )
                .frame(width: 30, height: 30)
                .accessibilityIdentifier("player.mini.artwork")
            }

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(item.display.title)
                    .font(MusicFreeTypographyTokens.rowTitle)
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .lineLimit(1)

                if shouldShowArtwork, let artist = item.display.artist {
                    Text(artist)
                        .font(MusicFreeTypographyTokens.rowSubtitle)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }

        if item.isCurrent {
            itemBody
                .contentShape(Rectangle())
                .onTapGesture(perform: onPresentPlayer)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onPresentPlayer() }
                .accessibilityIdentifier("player.mini")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            itemBody
            .accessibilityHidden(true)
        }
    }

    private var shouldShowArtwork: Bool {
        // Inline accessory content is hosted inside the tab bar and omits
        // artwork; expanded and standalone rows retain the artwork.
        bottomAccessoryPlacement != .inline
    }

    private var miniPlayerSwipeGesture: some Gesture {
        DragGesture(minimumDistance: MiniPlayerSwipePolicy.minimumDragDistance)
            .onChanged { value in
                guard !isCommittingSwipe else { return }
                horizontalDragOffset = MiniPlayerSwipePolicy.displayOffset(
                    for: value.translation,
                    canGoPrevious: viewModel.canGoPrevious,
                    canGoNext: viewModel.canGoNext
                )
            }
            .onEnded { value in
                let action = MiniPlayerSwipePolicy.action(
                    for: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    canGoPrevious: viewModel.canGoPrevious,
                    canGoNext: viewModel.canGoNext,
                    activationDistance: MiniPlayerSwipePolicy.activationDistance(
                        for: carouselWidth
                    )
                )

                switch action {
                case .previous:
                    commitSwipe(.previous)
                case .next:
                    commitSwipe(.next)
                case nil:
                    withAnimation(.snappy(duration: 0.22)) {
                        horizontalDragOffset = 0
                    }
                }
            }
    }

    private func commitSwipe(_ action: MiniPlayerSwipeAction) {
        guard !isCommittingSwipe else { return }
        isCommittingSwipe = true
        let targetOffset = MiniPlayerSwipePolicy.commitOffset(
            for: action,
            pageWidth: carouselWidth
        )

        withAnimation(.snappy(duration: 0.22)) {
            horizontalDragOffset = targetOffset
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            switch action {
            case .previous:
                viewModel.previous()
            case .next:
                viewModel.next()
            }

            withAnimation(.snappy(duration: 0.22)) {
                horizontalDragOffset = 0
            }
            isCommittingSwipe = false
        }
    }

    private var queuePreviewKey: String {
        let entries = viewModel.snapshot.queue.entries
            .map { entry in
                guard let itemID = entry.itemID else {
                    return "\(entry.id.uuidString):logical:\(entry.logicalTrackID.rawValue)"
                }
                return "\(entry.id.uuidString):\(itemID.sourceID.rawValue):\(itemID.externalID)"
            }
            .joined(separator: ",")
        return "\(viewModel.snapshot.currentItemID?.description ?? "none")|\(viewModel.snapshot.queue.currentEntryID?.uuidString ?? "none")|\(viewModel.snapshot.queue.repeatMode.rawValue)|\(entries)"
    }

    private func carouselItems(
        currentItem: PlaybackDisplaySnapshot
    ) -> [MiniPlayerCarouselItem] {
        guard let currentItemID = viewModel.snapshot.currentItemID else {
            return []
        }

        let currentEntryID = viewModel.snapshot.queue.currentEntryID ?? Self.fallbackEntryID
        let previous = carouselItem(
            entry: viewModel.adjacentQueueEntry(direction: -1),
            currentEntryID: currentEntryID
        )
        let current = MiniPlayerCarouselItem(
            entryID: currentEntryID,
            itemID: currentItemID,
            display: currentItem,
            isCurrent: true
        )
        let next = carouselItem(
            entry: viewModel.adjacentQueueEntry(direction: 1),
            currentEntryID: currentEntryID
        )
        return [previous, .some(current), next].compactMap { $0 }
    }

    private func carouselItem(
        entry: PlaybackQueueEntry?,
        currentEntryID: UUID
    ) -> MiniPlayerCarouselItem? {
        guard let entry, entry.id != currentEntryID else { return nil }
        guard let itemID = entry.itemID else { return nil }
        guard let display = previewDisplays[entry.id] else { return nil }
        return MiniPlayerCarouselItem(
            entryID: entry.id,
            itemID: itemID,
            display: display,
            isCurrent: false
        )
    }

    private func loadPreviewDisplays() async {
        let entries = [
            viewModel.adjacentQueueEntry(direction: -1),
            viewModel.adjacentQueueEntry(direction: 1)
        ].compactMap { $0 }

        guard !entries.isEmpty, let library else {
            previewDisplays = [:]
            return
        }

        var loadedTracks: [UUID: Track] = [:]
        for entry in entries {
            guard !Task.isCancelled else { return }
            guard let itemID = entry.itemID else { continue }
            if let track = try? await library.track(id: itemID) {
                loadedTracks[entry.id] = track
            }
        }

        let artistNames = (try? await QueueArtistNameLoader.load(
            for: Array(loadedTracks.values),
            from: library
        )) ?? [:]
        guard !Task.isCancelled else { return }

        previewDisplays = loadedTracks.reduce(into: [:]) { result, element in
            let (entryID, track) = element
            result[entryID] = PlaybackDisplaySnapshot(
                title: track.title,
                artist: QueueArtistNameLoader.subtitle(
                    for: track,
                    artistNames: artistNames
                ),
                artworkID: track.artworkID,
                duration: track.duration
            )
        }
    }
}

private struct MiniPlayerCarouselItem: Identifiable {
    let entryID: UUID
    let itemID: MediaItemID
    let display: PlaybackDisplaySnapshot
    let isCurrent: Bool

    var id: UUID { entryID }
}

enum MiniPlayerSwipeAction: Equatable {
    case previous
    case next
}

enum MiniPlayerSwipePolicy {
    static let minimumDragDistance: CGFloat = 12
    static let baseActivationDistance: CGFloat = 52
    static let maximumDisplayOffset: CGFloat = 72
    static let unavailableDirectionResistance: CGFloat = 0.28

    static func commitOffset(
        for action: MiniPlayerSwipeAction,
        pageWidth: CGFloat
    ) -> CGFloat {
        let width = max(pageWidth, 1)
        return action == .next ? -width : width
    }

    static func action(
        for translation: CGSize,
        predictedEndTranslation _: CGSize,
        canGoPrevious: Bool,
        canGoNext: Bool,
        activationDistance: CGFloat = baseActivationDistance
    ) -> MiniPlayerSwipeAction? {
        guard isHorizontal(translation),
              abs(translation.width) >= max(1, activationDistance)
        else { return nil }

        if translation.width > 0 {
            return canGoPrevious ? .previous : nil
        }
        return canGoNext ? .next : nil
    }

    static func activationDistance(for carouselWidth: CGFloat) -> CGFloat {
        max(baseActivationDistance, carouselWidth * 0.12)
    }

    static func displayOffset(
        for translation: CGSize,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) -> CGFloat {
        guard isHorizontal(translation) else { return 0 }

        let isAvailable = translation.width > 0 ? canGoPrevious : canGoNext
        let resistance = isAvailable ? 1 : unavailableDirectionResistance
        return min(abs(translation.width) * resistance, maximumDisplayOffset)
            * (translation.width < 0 ? -1 : 1)
    }

    private static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }
}
