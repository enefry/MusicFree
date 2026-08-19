import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI
import UIKit

struct FoldersView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool

    @State private var isEditing = false
    @State private var selectedFolderPaths: Set<String> = []
    @State private var pendingFolderDeletionPaths: Set<String> = []
    @State private var isDeleting = false
    @State private var deletionErrorMessage: String?

    init(
        viewModel: LibraryViewModel,
        navigate: @escaping (LibraryDestination) -> Void,
        enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isCollectionQueueActionPending: @escaping (LibraryCollectionQueueTarget) -> Bool = { _ in false }
    ) {
        self.viewModel = viewModel
        self.navigate = navigate
        self.enqueueNextCollection = enqueueNextCollection
        self.enqueueCollection = enqueueCollection
        self.isCollectionQueueActionPending = isCollectionQueueActionPending
    }

    private var orderedFolders: [LibraryFolder] {
        viewModel.folders.sorted { lhs, rhs in
            let left = LibrarySortSupport.normalizedSortValue(
                LibrarySortSupport.leafName(of: lhs.path)
            )
            let right = LibrarySortSupport.normalizedSortValue(
                LibrarySortSupport.leafName(of: rhs.path)
            )
            if left != right { return left < right }
            return lhs.path < rhs.path
        }
    }

    private var groupedFolderKeys: [String] {
        Array(Set(orderedFolders.map {
            LibrarySortSupport.sectionTitle(for: LibrarySortSupport.leafName(of: $0.path))
        }))
        .sorted(by: LibrarySortSupport.areSectionTitlesInAscendingOrder)
    }

    private func folders(for key: String) -> [LibraryFolder] {
        orderedFolders.filter {
            LibrarySortSupport.sectionTitle(for: LibrarySortSupport.leafName(of: $0.path)) == key
        }
    }

    var body: some View {
        LibraryContentState(
            state: viewModel.state(for: .folders),
            hasContent: !viewModel.folders.isEmpty,
            emptyTitle: L("暂无文件夹"),
            emptyMessage: L("按文件夹导入本地音频后会显示在这里。"),
            emptySystemImage: "folder",
            retry: { viewModel.retry(section: .folders) }
        ) {
            NativeLibraryCollectionView(
                sections: groupedFolderKeys.map { key in
                    NativeLibraryCollectionSection(
                        id: "library.folders.\(key)",
                        headerTitle: key,
                        items: folders(for: key).map { folder in
                            NativeLibraryCollectionItem(
                                id: folder.path,
                                accessibilityLabel: LibrarySortSupport.leafName(of: folder.path),
                                accessibilityHint: L("打开文件夹，按住显示更多操作")
                            )
                        }
                    )
                },
                layout: .list,
                header: nil,
                footer: viewModel.shouldShowPageFooter(for: .folders)
                    ? AnyView(LibraryPageFooter(section: .folders, viewModel: viewModel))
                    : nil,
                optionsAccessibilityPrefix: "library.folder",
                isEditing: isEditing,
                selectedIDs: selectedFolderPaths,
                isDisabled: isDeleting,
                rowContent: { item, editing, selected in
                    guard let folder = folder(for: item.id) else {
                        return AnyView(EmptyView())
                    }
                    return AnyView(
                        FolderCollectionRow(
                            folder: folder,
                            isSelected: selected,
                            isEditing: editing
                        )
                    )
                },
                activateAction: { item in
                    navigate(.folder(item.id))
                },
                contextMenu: { item in
                    guard let folder = folder(for: item.id) else { return nil }
                    return contextMenu(for: folder)
                },
                shareText: { item in item.id },
                onSelectionChanged: { selectedFolderPaths = $0 },
                onEditingChanged: { editing in
                    if editing {
                        isEditing = true
                    } else {
                        finishEditing()
                    }
                },
                onLastItemDisplayed: { itemID in
                    guard itemID == orderedFolders.last?.id else { return }
                    viewModel.loadNextPage(for: .folders)
                }
            )
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.folders")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing, !selectedFolderPaths.isEmpty {
                LibraryBatchDeletionBar(
                    count: selectedFolderPaths.count,
                    scope: .folders,
                    accessibilityIdentifier: "library.folders.deleteSelected",
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
                    .accessibilityLabel(Text(L("完成选择文件夹")))
                    .accessibilityIdentifier("library.folders.finishSelection")
                    .disabled(isDeleting)
                }
            }
        }
        .batchDeletionPresentation(
            isPresented: pendingFolderDeletionPresentation,
            count: pendingFolderDeletionPaths.count,
            scope: .folders,
            isDeleting: isDeleting,
            action: {
                let paths = pendingFolderDeletionPaths
                pendingFolderDeletionPaths.removeAll()
                deleteSelectedFolders(paths)
            }
        )
        .libraryDeletionErrorPresentation(errorMessage: $deletionErrorMessage)
    }

    private var pendingFolderDeletionPresentation: Binding<Bool> {
        Binding(
            get: { !pendingFolderDeletionPaths.isEmpty },
            set: { isPresented in
                if !isPresented { pendingFolderDeletionPaths.removeAll() }
            }
        )
    }

    private func finishEditing() {
        guard !isDeleting else { return }
        isEditing = false
        selectedFolderPaths.removeAll()
    }

    private func folder(for path: String) -> LibraryFolder? {
        viewModel.folders.first { $0.path == path }
    }

    private func requestDeleteSelected() {
        guard !isDeleting, !selectedFolderPaths.isEmpty else { return }
        pendingFolderDeletionPaths = selectedFolderPaths
    }

    private func deleteSelectedFolders(_ paths: Set<String>) {
        guard !paths.isEmpty, !isDeleting else { return }
        isDeleting = true
        Task { @MainActor in
            defer { isDeleting = false }
            do {
                let targets = Set(paths.map { LibraryCollectionQueueTarget.folder($0) })
                let itemIDs = try await LibraryCollectionTrackLoader.itemIDs(
                    for: targets,
                    from: viewModel.library
                )
                if !itemIDs.isEmpty {
                    _ = try await viewModel.library.delete(itemIDs)
                    viewModel.removeDeletedTracks(itemIDs)
                }
                finishEditing()
                viewModel.load(section: .folders, reset: true)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func contextMenu(for folder: LibraryFolder) -> NativeLibraryContextMenuContents {
        let target = LibraryCollectionQueueTarget.folder(folder.path)
        let delete = UIAction(
            title: L("删除"),
            image: UIImage(systemName: "trash"),
            attributes: isDeleting ? [.disabled, .destructive] : [.destructive]
        ) { _ in
            guard !isDeleting else { return }
            pendingFolderDeletionPaths = [folder.path]
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

private struct FolderCollectionRow: View {
    let folder: LibraryFolder
    let isSelected: Bool
    let isEditing: Bool

    var body: some View {
        HStack(spacing: MusicFreeSpacingTokens.medium) {
            Image(systemName: isEditing ? (isSelected ? "checkmark.circle.fill" : "circle") : "folder")
                .foregroundStyle(
                    isEditing && isSelected
                        ? MusicFreeColorTokens.accent
                        : MusicFreeColorTokens.foregroundTertiary
                )
                .frame(width: MusicFreeLayoutMetrics.minimumHitTarget)

            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                Text(LibrarySortSupport.leafName(of: folder.path))
                    .font(MusicFreeTypographyTokens.rowTitle)
                    .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let parentPath = LibrarySortSupport.parentPath(of: folder.path) {
                    Text(parentPath)
                        .font(MusicFreeTypographyTokens.rowSubtitle)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Text(L("%d tracks", folder.trackCount))
                .font(MusicFreeTypographyTokens.rowSubtitle)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .contentShape(Rectangle())
    }
}
