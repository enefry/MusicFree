import DesignSystem
import MusicDomain
import SwiftUI
import UIKit

struct NativeTrackCollectionSection {
    let id: String
    let headerTitle: String?
    let tracks: [Track]
}

/// UIKit owns the interaction surface here. SwiftUI is only used to render the
/// row and page header inside native collection-view cells and supplements.
struct NativeTrackCollectionView: UIViewRepresentable {
    let sections: [NativeTrackCollectionSection]
    let header: AnyView?
    let footer: AnyView?
    let optionsAccessibilityPrefix: String
    let isEditing: Bool
    let selectedIDs: Set<MediaItemID>
    let isDisabled: Bool
    let rowContent: (Track, Bool, Bool) -> AnyView
    let playAction: (Track) -> Void
    let detailAction: (Track) -> Void
    let favoriteAction: (Track) -> Void
    let requestDelete: (Track) -> Void
    let shareText: (Track) -> String
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?
    let isPlayEnabled: (Track) -> Bool
    let isFavoriteEnabled: (Track) -> Bool
    let isDeleting: (Track) -> Bool
    let onSelectionChanged: (Set<MediaItemID>) -> Void
    let onEditingChanged: (Bool) -> Void
    let onLastTrackDisplayed: (MediaItemID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(parent: self, collectionView: collectionView)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        private static let globalHeaderKind = "musicfree.native-track-collection.header"
        private static let globalFooterKind = "musicfree.native-track-collection.footer"

        private var parent: NativeTrackCollectionView
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<String, MediaItemID>!
        private var cellRegistration: UICollectionView.CellRegistration<UICollectionViewListCell, MediaItemID>!
        private var sectionHeaderRegistration: UICollectionView.SupplementaryRegistration<NativeTrackCollectionSupplementaryView>!
        private var globalHeaderRegistration: UICollectionView.SupplementaryRegistration<NativeTrackCollectionSupplementaryView>!
        private var globalFooterRegistration: UICollectionView.SupplementaryRegistration<NativeTrackCollectionSupplementaryView>!
        private var trackByID: [MediaItemID: Track] = [:]
        private var sectionIDs: [String] = []
        private var itemIDs: [MediaItemID] = []
        private var isNativeMultipleSelectionActive = false
        private var isNativeMultipleSelectionGestureActive = false
        private var hasDeferredSnapshot = false
        private var deferredLastTrackID: MediaItemID?
        private var lastPublishedSelectionIDs: Set<MediaItemID>
        private var nativeGestureSelectionIDs: Set<MediaItemID> = []
        private var hasScheduledMultipleSelectionEnd = false

        init(parent: NativeTrackCollectionView) {
            self.parent = parent
            self.lastPublishedSelectionIDs = parent.selectedIDs
        }

        func makeCollectionView() -> UICollectionView {
            let layoutConfiguration = UICollectionViewCompositionalLayoutConfiguration()
            layoutConfiguration.scrollDirection = .vertical
            // SwiftUI/TabView already owns the safe-area reduction. The
            // compositional layout defaults to a safe-area content reference,
            // which adds another bottom tail to every section.
            layoutConfiguration.contentInsetsReference = .none
            let layout = UICollectionViewCompositionalLayout(
                sectionProvider: { [weak self] sectionIndex, environment in
                    self?.layoutSection(at: sectionIndex, environment: environment)
                },
                configuration: layoutConfiguration
            )
            let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
            collectionView.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? .black
                    : UIColor.systemBackground
            }
            // SwiftUI has already reduced this view's frame for the navigation
            // and TabView accessory safe areas. Automatic UIKit adjustment would
            // add the same bottom clearance a second time.
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.contentInset = .zero
            collectionView.scrollIndicatorInsets = .zero
            // A collection view scrolls naturally when its content is taller
            // than the viewport. Forced bounce keeps XCTest and UIKit's native
            // selection interaction busy at the end of a short collection.
            collectionView.alwaysBounceVertical = false
            collectionView.allowsSelection = true
            // UIKit's native two-finger selection interaction is only offered
            // when multiple selection is enabled before the gesture begins.
            collectionView.allowsMultipleSelection = true
            collectionView.delegate = self
            collectionView.accessibilityIdentifier = "library.nativeTrackCollection"
            self.collectionView = collectionView
            configureRegistrations(for: collectionView)
            applySnapshot(to: collectionView, force: true)
            synchronizeSelection(in: collectionView)
            return collectionView
        }

        func update(parent: NativeTrackCollectionView, collectionView: UICollectionView) {
            let didReceiveSelectionUpdate = parent.selectedIDs != self.parent.selectedIDs
            let didExitEditing = self.parent.isEditing && !parent.isEditing
            self.parent = parent
            self.collectionView = collectionView
            if didExitEditing {
                isNativeMultipleSelectionActive = false
                isNativeMultipleSelectionGestureActive = false
                hasDeferredSnapshot = false
                deferredLastTrackID = nil
                hasScheduledMultipleSelectionEnd = false
                lastPublishedSelectionIDs = parent.selectedIDs
                nativeGestureSelectionIDs = []
            } else if didReceiveSelectionUpdate,
                      !isNativeMultipleSelectionGestureActive
            {
                lastPublishedSelectionIDs = parent.selectedIDs
                nativeGestureSelectionIDs = parent.selectedIDs
            }
            trackByID = Dictionary(
                uniqueKeysWithValues: parent.sections.flatMap(\.tracks).map { ($0.id, $0) }
            )

            let currentSectionIDs = parent.sections.map(\.id)
            let currentItemIDs = parent.sections.flatMap(\.tracks).map(\.id)
            if currentSectionIDs != sectionIDs || currentItemIDs != itemIDs {
                if isNativeMultipleSelectionGestureActive {
                    // A diffable update changes index paths while UIKit is
                    // walking them for the two-finger selection interaction.
                    // Keep the live snapshot and layout stable until the
                    // gesture ends. Reconfiguring a visible hosting cell here
                    // can make UIKit skip cells in the drag path as well.
                    hasDeferredSnapshot = true
                } else {
                    applySnapshot(to: collectionView, force: true)
                }
            } else if !isNativeMultipleSelectionGestureActive {
                reconfigureVisibleCells(in: collectionView)
            }
            synchronizeSelection(in: collectionView)
        }

        private func configureRegistrations(for collectionView: UICollectionView) {
            cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, MediaItemID> {
                [weak self] cell, indexPath, itemID in
                guard let self, let track = self.trackByID[itemID] else { return }
                self.configure(cell: cell, track: track, indexPath: indexPath)
            }

            sectionHeaderRegistration = UICollectionView.SupplementaryRegistration<NativeTrackCollectionSupplementaryView>(
                elementKind: UICollectionView.elementKindSectionHeader
            ) { [weak self] view, _, indexPath in
                guard let self,
                      self.parent.sections.indices.contains(indexPath.section)
                else { return }
                view.setContent(self.sectionHeaderContent(self.parent.sections[indexPath.section].headerTitle))
            }

            globalHeaderRegistration = UICollectionView.SupplementaryRegistration<NativeTrackCollectionSupplementaryView>(
                elementKind: Self.globalHeaderKind
            ) { [weak self] view, _, _ in
                view.setContent(self?.parent.header ?? AnyView(EmptyView()))
            }

            globalFooterRegistration = UICollectionView.SupplementaryRegistration<NativeTrackCollectionSupplementaryView>(
                elementKind: Self.globalFooterKind
            ) { [weak self] view, _, _ in
                view.setContent(self?.parent.footer ?? AnyView(EmptyView()))
            }

            dataSource = UICollectionViewDiffableDataSource<String, MediaItemID>(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, itemID in
                guard let self else { return nil }
                return collectionView.dequeueConfiguredReusableCell(
                    using: self.cellRegistration,
                    for: indexPath,
                    item: itemID
                )
            }

            dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                guard let self else { return nil }
                switch kind {
                case UICollectionView.elementKindSectionHeader:
                    return collectionView.dequeueConfiguredReusableSupplementary(
                        using: self.sectionHeaderRegistration,
                        for: indexPath
                    )
                case Self.globalHeaderKind:
                    return collectionView.dequeueConfiguredReusableSupplementary(
                        using: self.globalHeaderRegistration,
                        for: indexPath
                    )
                case Self.globalFooterKind:
                    return collectionView.dequeueConfiguredReusableSupplementary(
                        using: self.globalFooterRegistration,
                        for: indexPath
                    )
                default:
                    return nil
                }
            }
        }

        private func configure(
            cell: UICollectionViewListCell,
            track: Track,
            indexPath: IndexPath
        ) {
            let isSelectionModeActive = parent.isEditing || isNativeMultipleSelectionActive
            let selectedIDs = isNativeMultipleSelectionActive
                ? lastPublishedSelectionIDs
                : parent.selectedIDs
            let isSelected = selectedIDs.contains(track.id)
            cell.contentConfiguration = UIHostingConfiguration {
                self.parent.rowContent(track, isSelectionModeActive, isSelected)
            }
            .margins(.all, 0)
            // The row has one native interaction surface: long press opens the
            // UICollectionView context menu. During native multi-selection,
            // UIKit owns the selection accessory as well.
            cell.accessories = isSelectionModeActive
                ? [.multiselect(displayed: .always)]
                : []
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.accessibilityLabel = track.title
            cell.accessibilityHint = L(
                isSelectionModeActive
                    ? "选择歌曲"
                    : "播放歌曲，按住显示更多歌曲操作"
            )
            cell.accessibilityValue = isSelectionModeActive
                ? (isSelected ? L("已选择") : L("未选择"))
                : nil
            var accessibilityTraits: UIAccessibilityTraits = [.button]
            if isSelectionModeActive, isSelected {
                accessibilityTraits.insert(.selected)
            }
            cell.accessibilityTraits = accessibilityTraits
            cell.accessibilityIdentifier = "\(parent.optionsAccessibilityPrefix).\(isSelectionModeActive ? "select" : "play").\(track.id.externalID)"

        }

        private func applySnapshot(to collectionView: UICollectionView, force: Bool) {
            let preservedSelectionIDs = isNativeMultipleSelectionActive
                ? lastPublishedSelectionIDs
                : parent.selectedIDs.union(selectedItemIDs(in: collectionView))
            trackByID = Dictionary(
                uniqueKeysWithValues: parent.sections.flatMap(\.tracks).map { ($0.id, $0) }
            )
            sectionIDs = parent.sections.map(\.id)
            itemIDs = parent.sections.flatMap(\.tracks).map(\.id)

            var snapshot = NSDiffableDataSourceSnapshot<String, MediaItemID>()
            for section in parent.sections {
                snapshot.appendSections([section.id])
                snapshot.appendItems(section.tracks.map(\.id), toSection: section.id)
            }

            if force {
                dataSource.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    guard !self.isNativeMultipleSelectionGestureActive else { return }
                    self.lastPublishedSelectionIDs = preservedSelectionIDs
                    self.synchronizeSelection(in: collectionView)
                    self.flushDeferredLastTrack()
                }
            }
            collectionView.collectionViewLayout.invalidateLayout()
        }

        private func reconfigureVisibleCells(in collectionView: UICollectionView) {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
                      let itemID = dataSource.itemIdentifier(for: indexPath),
                      let track = trackByID[itemID]
                else { continue }
                configure(cell: cell, track: track, indexPath: indexPath)
            }
        }

        private func synchronizeSelection(in collectionView: UICollectionView) {
            guard !isNativeMultipleSelectionGestureActive else { return }
            let isSelectionModeActive = parent.isEditing || isNativeMultipleSelectionActive
            let selectedIDs = isNativeMultipleSelectionActive
                ? lastPublishedSelectionIDs
                : parent.selectedIDs
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                guard let itemID = dataSource.itemIdentifier(for: indexPath) else { continue }
                if !selectedIDs.contains(itemID) || !isSelectionModeActive {
                    collectionView.deselectItem(at: indexPath, animated: false)
                }
            }

            guard isSelectionModeActive else { return }

            for sectionIndex in parent.sections.indices {
                for itemIndex in parent.sections[sectionIndex].tracks.indices {
                    let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
                    guard let itemID = dataSource.itemIdentifier(for: indexPath),
                          selectedIDs.contains(itemID),
                          collectionView.indexPathsForSelectedItems?.contains(indexPath) != true
                    else { continue }
                    collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
                }
            }
        }

        private func layoutSection(
            at sectionIndex: Int,
            environment: NSCollectionLayoutEnvironment
        ) -> NSCollectionLayoutSection {
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = true
            if parent.sections.indices.contains(sectionIndex),
               parent.sections[sectionIndex].headerTitle != nil
            {
                configuration.headerMode = .supplementary
            } else {
                configuration.headerMode = .none
            }

            let section = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            // Rows already include their own horizontal and vertical spacing.
            // Avoid a list-section tail below the last track.
            section.contentInsets = .zero
            var boundaryItems: [NSCollectionLayoutBoundarySupplementaryItem] = []

            if sectionIndex == 0, parent.header != nil {
                boundaryItems.append(
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1),
                            heightDimension: .estimated(220)
                        ),
                        elementKind: Self.globalHeaderKind,
                        alignment: .top
                    )
                )
            }
            if sectionIndex == parent.sections.count - 1, parent.footer != nil {
                boundaryItems.append(
                    NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1),
                            heightDimension: .absolute(44)
                        ),
                        elementKind: Self.globalFooterKind,
                        alignment: .bottom
                    )
                )
            }
            section.boundarySupplementaryItems = boundaryItems
            return section
        }

        private func sectionHeaderContent(_ title: String?) -> AnyView {
            guard let title else { return AnyView(EmptyView()) }
            return AnyView(
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .textCase(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
                    .padding(.top, MusicFreeSpacingTokens.small)
                    .padding(.bottom, MusicFreeSpacingTokens.xSmall)
                    .background(MusicFreeColorTokens.backgroundPrimary)
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) -> Bool {
            guard !parent.isDisabled,
                  parent.sections.indices.contains(indexPath.section),
                  parent.sections[indexPath.section].tracks.indices.contains(indexPath.item)
            else { return false }
            return true
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) {
            isNativeMultipleSelectionActive = true
            isNativeMultipleSelectionGestureActive = true
            hasDeferredSnapshot = false
            hasScheduledMultipleSelectionEnd = false
            nativeGestureSelectionIDs = selectedItemIDs(in: collectionView)
            lastPublishedSelectionIDs = nativeGestureSelectionIDs
            // Do not update SwiftUI while UIKit is walking the drag path. The
            // selection bar is a safe-area inset and appearing here would
            // resize the collection view mid-gesture, which can skip rows.
        }

        func collectionViewDidEndMultipleSelectionInteraction(_ collectionView: UICollectionView) {
            guard !hasScheduledMultipleSelectionEnd else { return }
            hasScheduledMultipleSelectionEnd = true
            // UIKit can deliver the final selection callbacks in the same event
            // turn as this delegate callback. Read its index paths one turn later
            // so the last cells crossed by a fast drag are included.
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView,
                      self.isNativeMultipleSelectionGestureActive
                else { return }

                // UIKit can deliver the last select/deselect callbacks in the
                // next run-loop turn. Waiting one additional turn prevents a
                // fast drag from publishing a partial selection set.
                DispatchQueue.main.async { [weak self, weak collectionView] in
                    guard let self, let collectionView,
                          self.isNativeMultipleSelectionGestureActive
                    else { return }
                    self.hasScheduledMultipleSelectionEnd = false
                    self.isNativeMultipleSelectionGestureActive = false
                    // Keep selections delivered by UIKit's callbacks even if
                    // its index-path snapshot is briefly incomplete while the
                    // two-finger interaction crosses a layout boundary.
                    self.nativeGestureSelectionIDs.formUnion(
                        self.selectedItemIDs(in: collectionView)
                    )
                    let selectedIDs = self.nativeGestureSelectionIDs
                    self.lastPublishedSelectionIDs = selectedIDs
                    self.parent.onEditingChanged(true)
                    self.parent.onSelectionChanged(selectedIDs)
                    if self.hasDeferredSnapshot {
                        self.hasDeferredSnapshot = false
                        self.applySnapshot(to: collectionView, force: true)
                    } else {
                        self.flushDeferredLastTrack()
                    }
                }
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            shouldSelectItemAt indexPath: IndexPath
        ) -> Bool {
            !parent.isDisabled
        }

        func collectionView(
            _ collectionView: UICollectionView,
            shouldDeselectItemAt indexPath: IndexPath
        ) -> Bool {
            !parent.isDisabled
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard let track = track(at: indexPath), !parent.isDisabled else { return }

            if parent.isEditing || isNativeMultipleSelectionActive {
                if isNativeMultipleSelectionGestureActive {
                    nativeGestureSelectionIDs.insert(track.id)
                    lastPublishedSelectionIDs = nativeGestureSelectionIDs
                } else {
                    lastPublishedSelectionIDs = selectedItemIDs(in: collectionView)
                }
                if !isNativeMultipleSelectionGestureActive {
                    publishSelection(from: collectionView)
                }
            } else {
                collectionView.deselectItem(at: indexPath, animated: true)
                if parent.isPlayEnabled(track) {
                    parent.playAction(track)
                }
            }
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard parent.isEditing || isNativeMultipleSelectionActive,
                  track(at: indexPath) != nil,
                  !parent.isDisabled
            else { return }

            if isNativeMultipleSelectionGestureActive,
               let track = track(at: indexPath)
            {
                nativeGestureSelectionIDs.remove(track.id)
                lastPublishedSelectionIDs = nativeGestureSelectionIDs
            } else {
                lastPublishedSelectionIDs = selectedItemIDs(in: collectionView)
            }
            if !isNativeMultipleSelectionGestureActive {
                publishSelection(from: collectionView)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            guard let track = track(at: indexPath) else { return }
            if isNativeMultipleSelectionGestureActive {
                deferredLastTrackID = track.id
            } else {
                parent.onLastTrackDisplayed(track.id)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard indexPaths.count == 1, let indexPath = indexPaths.first else { return nil }
            return contextMenuConfiguration(for: indexPath)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemAt indexPath: IndexPath,
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            contextMenuConfiguration(for: indexPath)
        }

        private func contextMenuConfiguration(
            for indexPath: IndexPath
        ) -> UIContextMenuConfiguration? {
            guard !parent.isDisabled,
                  !parent.isEditing,
                  !isNativeMultipleSelectionActive,
                  let track = track(at: indexPath)
            else { return nil }

            let configuration = UIContextMenuConfiguration(
                identifier: NSString(string: track.id.externalID),
                previewProvider: nil
            ) { [weak self] _ in
                self?.makeMenu(
                    for: track,
                    at: indexPath
                )
            }
            if #available(iOS 16.0, *) {
                configuration.preferredMenuElementOrder = .fixed
            }
            return configuration
        }

        private func makeMenu(
            for track: Track,
            at indexPath: IndexPath
        ) -> UIMenu {
            let favorite = UIAction(
                title: track.isFavorite ? L("取消收藏") : L("收藏"),
                image: UIImage(systemName: track.isFavorite ? "star.slash" : "star"),
                attributes: parent.isFavoriteEnabled(track) ? [] : [.disabled],
                state: track.isFavorite ? .on : .off
            ) { [weak self] _ in
                self?.parent.favoriteAction(track)
            }
            let share = UIAction(
                title: L("分享"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in
                self?.presentShareSheet(for: track, at: indexPath)
            }
            let delete = UIAction(
                title: L("删除"),
                image: UIImage(systemName: "trash"),
                attributes: parent.isDeleting(track)
                    ? [.disabled, .destructive]
                    : [.destructive]
            ) { [weak self] _ in
                self?.parent.requestDelete(track)
            }

            var secondaryActions: [UIMenuElement] = [
                UIAction(
                    title: L("播放"),
                    image: UIImage(systemName: "play.fill"),
                    attributes: parent.isPlayEnabled(track) ? [] : [.disabled]
                ) { [weak self] _ in
                    self?.parent.playAction(track)
                },
                UIAction(
                    title: L("查看歌曲详情"),
                    image: UIImage(systemName: "info.circle")
                ) { [weak self] _ in
                    self?.parent.detailAction(track)
                }
            ]

            secondaryActions.append(
                UIAction(
                    title: L("下一首播放"),
                    image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                    attributes: parent.enqueueNextTracks == nil ? [.disabled] : []
                ) { [weak self] _ in
                    self?.parent.enqueueNextTracks?([track.id])
                }
            )
            secondaryActions.append(
                UIAction(
                    title: L("加入队列"),
                    image: UIImage(systemName: "text.append"),
                    attributes: parent.enqueueTracks == nil ? [.disabled] : []
                ) { [weak self] _ in
                    self?.parent.enqueueTracks?([track.id])
                }
            )
            if parent.addToPlaylist != nil {
                secondaryActions.append(
                    UIAction(
                        title: L("添加到播放列表"),
                        image: UIImage(systemName: "text.badge.plus")
                    ) { [weak self] _ in
                        self?.parent.addToPlaylist?([track.id])
                    }
                )
            }

            // UIMenu owns the presentation. displayAsPalette is the UIKit
            // context-menu action row shown above the ordinary menu items.
            let quickActions = UIMenu(
                title: "",
                options: [.displayAsPalette, .displayInline],
                preferredElementSize: .large,
                children: [favorite, share, delete]
            )
            let secondaryMenu = UIMenu(
                title: "",
                options: [.displayInline],
                children: secondaryActions
            )
            return UIMenu(
                title: "",
                children: [quickActions, secondaryMenu]
            )
        }

        private func track(at indexPath: IndexPath) -> Track? {
            guard let itemID = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return trackByID[itemID]
        }

        private func selectedItemIDs(in collectionView: UICollectionView) -> Set<MediaItemID> {
            Set(
                (collectionView.indexPathsForSelectedItems ?? []).compactMap {
                    dataSource.itemIdentifier(for: $0)
                }
            )
        }

        private func publishSelection(from collectionView: UICollectionView) {
            let selectedIDs = isNativeMultipleSelectionActive
                ? lastPublishedSelectionIDs
                : selectedItemIDs(in: collectionView)
            lastPublishedSelectionIDs = selectedIDs
            parent.onSelectionChanged(selectedIDs)
        }

        private func flushDeferredLastTrack() {
            guard !isNativeMultipleSelectionGestureActive,
                  let deferredLastTrackID
            else { return }
            self.deferredLastTrackID = nil
            parent.onLastTrackDisplayed(deferredLastTrackID)
        }

        private func presentShareSheet(for track: Track, at indexPath: IndexPath) {
            guard let collectionView,
                  let presenter = collectionView.window?.rootViewController?.topViewController
            else { return }

            let activityViewController = UIActivityViewController(
                activityItems: [parent.shareText(track)],
                applicationActivities: nil
            )
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = collectionView.cellForItem(at: indexPath) ?? collectionView
                popover.sourceRect = collectionView.cellForItem(at: indexPath)?.bounds
                    ?? CGRect(x: collectionView.bounds.midX, y: collectionView.bounds.midY, width: 1, height: 1)
            }
            presenter.present(activityViewController, animated: true)
        }
    }
}

private final class NativeTrackCollectionSupplementaryView: UICollectionReusableView {
    private var hostingController: UIHostingController<AnyView>?

    func setContent(_ content: AnyView) {
        hostingController?.view.removeFromSuperview()

        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        hostingController = controller
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingController?.view.removeFromSuperview()
        hostingController = nil
    }
}

private extension UIViewController {
    var topViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topViewController
        }
        return self
    }
}
