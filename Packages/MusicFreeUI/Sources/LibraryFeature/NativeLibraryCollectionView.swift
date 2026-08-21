import DesignSystem
import SwiftUI
import UIKit

struct NativeLibraryCollectionItem {
    let id: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let accessibilityValue: String?

    init(
        id: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        accessibilityValue: String? = nil
    ) {
        self.id = id
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.accessibilityValue = accessibilityValue
    }
}

struct NativeLibraryCollectionSection {
    let id: String
    let headerTitle: String?
    let items: [NativeLibraryCollectionItem]
}

enum NativeLibraryCollectionLayout {
    case list
    case grid(columns: Int)
}

struct NativeLibraryContextMenuContents {
    let primaryActions: [UIMenuElement]
    let secondaryActions: [UIMenuElement]

    init(
        primaryActions: [UIMenuElement] = [],
        secondaryActions: [UIMenuElement] = []
    ) {
        self.primaryActions = primaryActions
        self.secondaryActions = secondaryActions
    }
}

/// A native collection-view surface for library collections such as albums,
/// artists, genres, and folders. UIKit owns selection, the two-finger gesture,
/// and long-press menus; SwiftUI only renders the item content.
struct NativeLibraryCollectionView: UIViewRepresentable {
    let sections: [NativeLibraryCollectionSection]
    let layout: NativeLibraryCollectionLayout
    let header: AnyView?
    let footer: AnyView?
    let optionsAccessibilityPrefix: String
    let isEditing: Bool
    let selectedIDs: Set<String>
    let isDisabled: Bool
    let rowContent: (NativeLibraryCollectionItem, Bool, Bool) -> AnyView
    let activateAction: (NativeLibraryCollectionItem) -> Void
    let contextMenu: (NativeLibraryCollectionItem) -> NativeLibraryContextMenuContents?
    let shareText: ((NativeLibraryCollectionItem) -> String?)?
    let onSelectionChanged: (Set<String>) -> Void
    let onEditingChanged: (Bool) -> Void
    let onLastItemDisplayed: (String) -> Void

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
        private static let globalHeaderKind = "musicfree.native-library-collection.header"
        private static let globalFooterKind = "musicfree.native-library-collection.footer"

        private var parent: NativeLibraryCollectionView
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<String, String>!
        private var cellRegistration: UICollectionView.CellRegistration<UICollectionViewCell, String>!
        private var sectionHeaderRegistration: UICollectionView.SupplementaryRegistration<NativeLibraryCollectionSupplementaryView>!
        private var globalHeaderRegistration: UICollectionView.SupplementaryRegistration<NativeLibraryCollectionSupplementaryView>!
        private var globalFooterRegistration: UICollectionView.SupplementaryRegistration<NativeLibraryCollectionSupplementaryView>!
        private var itemByID: [String: NativeLibraryCollectionItem] = [:]
        private var sectionIDs: [String] = []
        private var itemIDs: [String] = []
        private var isNativeMultipleSelectionActive = false
        private var isNativeMultipleSelectionGestureActive = false
        private var hasDeferredSnapshot = false
        private var deferredLastItemID: String?
        private var lastPublishedSelectionIDs: Set<String>
        private var nativeGestureSelectionIDs: Set<String> = []
        private var hasScheduledMultipleSelectionEnd = false

        init(parent: NativeLibraryCollectionView) {
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
            collectionView.accessibilityIdentifier = "library.nativeCollection"
            self.collectionView = collectionView
            configureRegistrations(for: collectionView)
            applySnapshot(to: collectionView)
            synchronizeSelection(in: collectionView)
            return collectionView
        }

        func update(parent: NativeLibraryCollectionView, collectionView: UICollectionView) {
            let didReceiveSelectionUpdate = parent.selectedIDs != self.parent.selectedIDs
            let didExitEditing = self.parent.isEditing && !parent.isEditing
            self.parent = parent
            self.collectionView = collectionView
            if didExitEditing {
                isNativeMultipleSelectionActive = false
                isNativeMultipleSelectionGestureActive = false
                hasDeferredSnapshot = false
                deferredLastItemID = nil
                hasScheduledMultipleSelectionEnd = false
                lastPublishedSelectionIDs = parent.selectedIDs
                nativeGestureSelectionIDs = []
            } else if didReceiveSelectionUpdate,
                      !isNativeMultipleSelectionGestureActive
            {
                lastPublishedSelectionIDs = parent.selectedIDs
                nativeGestureSelectionIDs = parent.selectedIDs
            }
            itemByID = Dictionary(
                uniqueKeysWithValues: parent.sections.flatMap(\.items).map { ($0.id, $0) }
            )

            let currentSectionIDs = parent.sections.map(\.id)
            let currentItemIDs = parent.sections.flatMap(\.items).map(\.id)
            if currentSectionIDs != sectionIDs || currentItemIDs != itemIDs {
                if isNativeMultipleSelectionGestureActive {
                    // A diffable update changes index paths while UIKit is
                    // walking them for the two-finger selection interaction.
                    // Keep the live snapshot and layout stable until the
                    // gesture ends. Reconfiguring a visible hosting cell here
                    // can make UIKit skip cells in the drag path as well.
                    hasDeferredSnapshot = true
                } else {
                    applySnapshot(to: collectionView)
                }
            } else if !isNativeMultipleSelectionGestureActive {
                reconfigureVisibleCells(in: collectionView)
            }
            synchronizeSelection(in: collectionView)
        }

        private func configureRegistrations(for collectionView: UICollectionView) {
            cellRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> {
                [weak self] cell, indexPath, itemID in
                guard let self, let item = self.itemByID[itemID] else { return }
                self.configure(cell: cell, item: item, indexPath: indexPath)
            }

            sectionHeaderRegistration = UICollectionView.SupplementaryRegistration<NativeLibraryCollectionSupplementaryView>(
                elementKind: UICollectionView.elementKindSectionHeader
            ) { [weak self] view, _, indexPath in
                guard let self,
                      self.parent.sections.indices.contains(indexPath.section)
                else { return }
                view.setContent(self.sectionHeaderContent(self.parent.sections[indexPath.section].headerTitle))
            }

            globalHeaderRegistration = UICollectionView.SupplementaryRegistration<NativeLibraryCollectionSupplementaryView>(
                elementKind: Self.globalHeaderKind
            ) { [weak self] view, _, _ in
                view.setContent(self?.parent.header ?? AnyView(EmptyView()))
            }

            globalFooterRegistration = UICollectionView.SupplementaryRegistration<NativeLibraryCollectionSupplementaryView>(
                elementKind: Self.globalFooterKind
            ) { [weak self] view, _, _ in
                view.setContent(self?.parent.footer ?? AnyView(EmptyView()))
            }

            dataSource = UICollectionViewDiffableDataSource<String, String>(
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
            cell: UICollectionViewCell,
            item: NativeLibraryCollectionItem,
            indexPath: IndexPath
        ) {
            let isSelectionModeActive = parent.isEditing || isNativeMultipleSelectionActive
            let selectedIDs = isNativeMultipleSelectionActive
                ? lastPublishedSelectionIDs
                : parent.selectedIDs
            let isSelected = selectedIDs.contains(item.id)
            cell.contentConfiguration = UIHostingConfiguration {
                self.parent.rowContent(item, isSelectionModeActive, isSelected)
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.accessibilityLabel = item.accessibilityLabel
            cell.accessibilityHint = isSelectionModeActive
                ? L("选择项目")
                : item.accessibilityHint
            cell.accessibilityValue = isSelectionModeActive
                ? (isSelected ? L("已选择") : L("未选择"))
                : item.accessibilityValue
            var accessibilityTraits: UIAccessibilityTraits = [.button]
            if isSelectionModeActive, isSelected {
                accessibilityTraits.insert(.selected)
            }
            cell.accessibilityTraits = accessibilityTraits
            cell.accessibilityIdentifier = "\(parent.optionsAccessibilityPrefix).\(isSelectionModeActive ? "select" : "open").\(item.id)"

        }

        private func applySnapshot(to collectionView: UICollectionView) {
            let preservedSelectionIDs = isNativeMultipleSelectionActive
                ? lastPublishedSelectionIDs
                : parent.selectedIDs.union(selectedItemIDs(in: collectionView))
            itemByID = Dictionary(
                uniqueKeysWithValues: parent.sections.flatMap(\.items).map { ($0.id, $0) }
            )
            sectionIDs = parent.sections.map(\.id)
            itemIDs = parent.sections.flatMap(\.items).map(\.id)

            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            for section in parent.sections {
                snapshot.appendSections([section.id])
                snapshot.appendItems(section.items.map(\.id), toSection: section.id)
            }
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                guard !self.isNativeMultipleSelectionGestureActive else { return }
                self.lastPublishedSelectionIDs = preservedSelectionIDs
                self.synchronizeSelection(in: collectionView)
                self.flushDeferredLastItem()
            }
            collectionView.collectionViewLayout.invalidateLayout()
        }

        private func reconfigureVisibleCells(in collectionView: UICollectionView) {
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath),
                      let itemID = dataSource.itemIdentifier(for: indexPath),
                      let item = itemByID[itemID]
                else { continue }
                configure(cell: cell, item: item, indexPath: indexPath)
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
                for itemIndex in parent.sections[sectionIndex].items.indices {
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
            let section: NSCollectionLayoutSection
            switch parent.layout {
            case .list:
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.showsSeparators = true
                configuration.headerMode = parent.sections.indices.contains(sectionIndex)
                    && parent.sections[sectionIndex].headerTitle != nil
                    ? .supplementary
                    : .none
                section = NSCollectionLayoutSection.list(
                    using: configuration,
                    layoutEnvironment: environment
                )
            case .grid(let requestedColumns):
                let horizontalInset = MusicFreeSpacingTokens.medium
                let interItemSpacing = MusicFreeSpacingTokens.medium
                let minimumGridItemWidth: CGFloat = 220
                let availableWidth = environment.container.effectiveContentSize.width
                let adaptiveColumns: Int
                if availableWidth > 0 {
                    let contentWidth = max(0, availableWidth - horizontalInset * 2)
                    adaptiveColumns = max(
                        1,
                        Int(
                            floor(
                                (contentWidth + interItemSpacing)
                                    / (minimumGridItemWidth + interItemSpacing)
                            )
                        )
                    )
                } else {
                    adaptiveColumns = 1
                }
                // Two columns are the compact-library baseline. On wider
                // containers, add columns instead of allowing album artwork
                // to grow into an oversized card.
                let columns = max(1, requestedColumns, adaptiveColumns)
                // The caller owns the product decision about column count. Do
                // not derive it from the transient container width: during a
                // hosted SwiftUI layout pass that width can be zero or stale,
                // which makes album cards jump between one and two columns.
                // Keep the grid geometry stable while UIKit is walking the
                // collection for native two-finger selection. Self-sizing
                // hosted SwiftUI content can otherwise change the row height
                // after artwork or metadata arrives and move the drag path.
                let itemHeight: CGFloat
                if availableWidth > 0 {
                    let contentWidth = max(0, availableWidth - horizontalInset * 2)
                    let itemWidth = max(
                        0,
                        (contentWidth - interItemSpacing * CGFloat(columns - 1))
                            / CGFloat(columns)
                    )
                    // The tile reserves two title lines, optional artist text,
                    // and the spacing between them. This keeps the row stable
                    // without leaving the old fixed-height tail under every
                    // album card.
                    let artworkWidth = max(0, itemWidth - interItemSpacing)
                    itemHeight = max(220, artworkWidth + 72)
                } else {
                    itemHeight = 244
                }
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                    heightDimension: .absolute(itemHeight)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                item.contentInsets = NSDirectionalEdgeInsets(
                    top: 0,
                    leading: interItemSpacing / 2,
                    bottom: 0,
                    trailing: interItemSpacing / 2
                )
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1),
                        heightDimension: .absolute(itemHeight)
                    ),
                    subitems: Array(repeating: item, count: columns)
                )
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = MusicFreeSpacingTokens.xLarge
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: MusicFreeSpacingTokens.medium,
                    leading: horizontalInset,
                    bottom: 0,
                    trailing: horizontalInset
                )
            }

            if case .list = parent.layout {
                // Rows already include their own horizontal and vertical
                // spacing. Keep the list section from contributing an opaque
                // tail below the last row.
                section.contentInsets = .zero
            }

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
                  parent.sections[indexPath.section].items.indices.contains(indexPath.item)
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
            // resize the collection view mid-gesture, which can skip cells.
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
                        self.applySnapshot(to: collectionView)
                    } else {
                        self.flushDeferredLastItem()
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
            guard let item = item(at: indexPath), !parent.isDisabled else { return }

            if parent.isEditing || isNativeMultipleSelectionActive {
                if isNativeMultipleSelectionGestureActive {
                    nativeGestureSelectionIDs.insert(item.id)
                    lastPublishedSelectionIDs = nativeGestureSelectionIDs
                } else {
                    lastPublishedSelectionIDs = selectedItemIDs(in: collectionView)
                }
                if !isNativeMultipleSelectionGestureActive {
                    publishSelection(from: collectionView)
                }
            } else {
                collectionView.deselectItem(at: indexPath, animated: true)
                parent.activateAction(item)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard parent.isEditing || isNativeMultipleSelectionActive,
                  item(at: indexPath) != nil,
                  !parent.isDisabled
            else { return }

            if isNativeMultipleSelectionGestureActive,
               let item = item(at: indexPath)
            {
                nativeGestureSelectionIDs.remove(item.id)
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
            guard let item = item(at: indexPath) else { return }
            if isNativeMultipleSelectionGestureActive {
                deferredLastItemID = item.id
            } else {
                parent.onLastItemDisplayed(item.id)
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

        private func contextMenuConfiguration(for indexPath: IndexPath) -> UIContextMenuConfiguration? {
            guard !parent.isDisabled,
                  !parent.isEditing,
                  !isNativeMultipleSelectionActive,
                  let item = item(at: indexPath)
            else { return nil }

            let configuration = UIContextMenuConfiguration(
                identifier: NSString(string: item.id),
                previewProvider: nil
            ) { [weak self] _ in
                self?.makeMenu(for: item, at: indexPath)
            }
            if #available(iOS 16.0, *) {
                configuration.preferredMenuElementOrder = .fixed
            }
            return configuration
        }

        private func makeMenu(
            for item: NativeLibraryCollectionItem,
            at indexPath: IndexPath
        ) -> UIMenu? {
            guard let contents = parent.contextMenu(item) else { return nil }
            var primaryActions = contents.primaryActions
            if parent.shareText != nil {
                primaryActions.insert(
                    UIAction(
                        title: L("分享"),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { [weak self] _ in
                        self?.presentShareSheet(for: item, at: indexPath)
                    },
                    at: 0
                )
            }

            var menus: [UIMenu] = []
            if !primaryActions.isEmpty {
                menus.append(
                    UIMenu(
                        title: "",
                        options: [.displayAsPalette, .displayInline],
                        preferredElementSize: .large,
                        children: primaryActions
                    )
                )
            }
            if !contents.secondaryActions.isEmpty {
                menus.append(
                    UIMenu(
                        title: "",
                        options: [.displayInline],
                        children: contents.secondaryActions
                    )
                )
            }
            guard !menus.isEmpty else { return nil }
            return UIMenu(title: "", children: menus)
        }

        private func item(at indexPath: IndexPath) -> NativeLibraryCollectionItem? {
            guard let itemID = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return itemByID[itemID]
        }

        private func selectedItemIDs(in collectionView: UICollectionView) -> Set<String> {
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

        private func flushDeferredLastItem() {
            guard !isNativeMultipleSelectionGestureActive,
                  let deferredLastItemID
            else { return }
            self.deferredLastItemID = nil
            parent.onLastItemDisplayed(deferredLastItemID)
        }

        private func presentShareSheet(
            for item: NativeLibraryCollectionItem,
            at indexPath: IndexPath
        ) {
            guard let collectionView,
                  let shareText = parent.shareText?(item),
                  let presenter = collectionView.window?.rootViewController?.nativeLibraryTopViewController
            else { return }

            let activityViewController = UIActivityViewController(
                activityItems: [shareText],
                applicationActivities: nil
            )
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = collectionView.cellForItem(at: indexPath) ?? collectionView
                popover.sourceRect = collectionView.cellForItem(at: indexPath)?.bounds
                    ?? CGRect(
                        x: collectionView.bounds.midX,
                        y: collectionView.bounds.midY,
                        width: 1,
                        height: 1
                    )
            }
            presenter.present(activityViewController, animated: true)
        }
    }
}

private final class NativeLibraryCollectionSupplementaryView: UICollectionReusableView {
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
    var nativeLibraryTopViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.nativeLibraryTopViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.nativeLibraryTopViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.nativeLibraryTopViewController
        }
        return self
    }
}
