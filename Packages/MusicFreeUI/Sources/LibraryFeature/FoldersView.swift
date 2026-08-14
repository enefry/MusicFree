import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

struct FoldersView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let navigate: (LibraryDestination) -> Void
    let enqueueNextCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueueCollection: ((LibraryCollectionQueueTarget) -> Void)?
    let isCollectionQueueActionPending: (LibraryCollectionQueueTarget) -> Bool

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
            List {
                ForEach(groupedFolderKeys, id: \.self) { key in
                    Section {
                        ForEach(folders(for: key)) { folder in
                            Button {
                                navigate(.folder(folder.path))
                            } label: {
                                HStack(spacing: MusicFreeSpacingTokens.medium) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(MusicFreeColorTokens.accent)
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

                                    Image(systemName: "chevron.forward")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                                .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .contextMenu {
                                let target = LibraryCollectionQueueTarget.folder(folder.path)
                                LibraryCollectionQueueMenuActions(
                                    target: target,
                                    accessibilityPrefix: "library.folder.menu",
                                    enqueueNext: enqueueNextCollection,
                                    enqueue: enqueueCollection,
                                    isPending: isCollectionQueueActionPending(target)
                                )
                            }
                            .accessibilityHint(L("打开文件夹，按住显示播放队列操作"))
                            .accessibilityIdentifier("library.folder.open.\(folder.id)")
                            .onAppear {
                                if folder.id == orderedFolders.last?.id {
                                    viewModel.loadNextPage(for: .folders)
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
                LibraryPageFooter(section: .folders, viewModel: viewModel)
            }
            .listStyle(.plain)
            .listSectionIndexVisibility(groupedFolderKeys.isEmpty ? .hidden : .visible)
            .scrollContentBackground(.hidden)
            .background(MusicFreeColorTokens.backgroundPrimary)
            .accessibilityIdentifier("library.folders")
        }
    }
}
