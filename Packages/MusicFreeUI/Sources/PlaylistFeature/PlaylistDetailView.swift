import DesignSystem
import MusicDomain
import SwiftUI

struct PlaylistDetailView: View {
    let trackCandidates: [PlaylistTrackCandidate]
    let trackCandidateLoadState: PlaylistFeatureLoadState
    let retryTrackCandidates: (@MainActor () -> Void)?
    let onPlaylistChanged: @MainActor (Playlist) -> Void
    let onRoute: PlaylistRouteAction?

    @State private var viewModel: PlaylistDetailViewModel
    @State private var candidateCache: [MediaItemID: PlaylistTrackCandidate]
    @State private var isAddSheetPresented = false
    @State private var editMode: EditMode = .inactive
    @State private var loadTask: Task<Void, Never>?

    init(
        playlist: Playlist,
        store: any PlaylistFeatureStore,
        playback: any PlaylistFeaturePlaybackServing,
        viewModel: PlaylistDetailViewModel? = nil,
        trackCandidates: [PlaylistTrackCandidate] = [],
        trackCandidateLoadState: PlaylistFeatureLoadState? = nil,
        retryTrackCandidates: (@MainActor () -> Void)? = nil,
        onPlaylistChanged: @escaping @MainActor (Playlist) -> Void = { _ in },
        onRoute: PlaylistRouteAction? = nil
    ) {
        self.trackCandidates = trackCandidates
        self.trackCandidateLoadState = trackCandidateLoadState
            ?? (trackCandidates.isEmpty ? .idle : .loaded)
        self.retryTrackCandidates = retryTrackCandidates
        self.onPlaylistChanged = onPlaylistChanged
        self.onRoute = onRoute
        _candidateCache = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: trackCandidates.map { ($0.id, $0) }
            )
        )
        _viewModel = State(
            initialValue: viewModel
                ?? PlaylistDetailViewModel(
                    playlist: playlist,
                    store: store,
                    playback: playback
                )
        )
    }

    var body: some View {
        stateContent
        .navigationTitle(viewModel.playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("playlists.detail")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isEditing, !viewModel.selectedTrackIDs.isEmpty {
                removeSelectionBar
            }
        }
        .environment(\.editMode, $editMode)
        .overlay(alignment: .top) {
            if viewModel.isLoading, !viewModel.entries.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(MusicFreeSpacingTokens.small)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(Text(L("正在刷新歌曲")))
            }
        }
        .onAppear {
            startLoadingIfNeeded()
        }
        .onDisappear {
            cancelLoading()
        }
        .onChange(of: viewModel.playlist) { _, playlist in
            onPlaylistChanged(playlist)
        }
        .onChange(of: trackCandidates) { _, candidates in
            for candidate in candidates {
                candidateCache[candidate.id] = candidate
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddToPlaylistSheet(
                candidates: trackCandidates,
                existingIDs: Set(viewModel.itemIDs),
                onSubmit: { itemIDs in
                    for itemID in itemIDs {
                        if let candidate = trackCandidates.first(where: { $0.id == itemID }) {
                            candidateCache[itemID] = candidate
                        }
                    }
                    return await viewModel.addTracks(itemIDs)
                }
            )
        }
        .confirmationDialog(
            L("移除所选歌曲？"),
            isPresented: removeConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button(L("移除"), role: .destructive) {
                guard case .removeTracks(let trackIDs) = viewModel.confirmation else {
                    return
                }
                viewModel.cancelConfirmation()
                Task { await viewModel.remove(trackIDs: trackIDs) }
            }
            Button(L("取消"), role: .cancel) {
                viewModel.cancelConfirmation()
            }
        } message: {
            Text(L("歌曲会从当前歌单移除，资料库中的原曲不会被删除。"))
        }
        .alert(
            L("操作失败"),
            isPresented: mutationFailureBinding
        ) {
            Button(L("好"), role: .cancel) {
                viewModel.clearMutationState()
            }
        } message: {
            Text(viewModel.mutationState.failureMessage ?? L("请重试。"))
        }
        .alert(
            L("播放失败"),
            isPresented: commandFailureBinding
        ) {
            Button(L("好"), role: .cancel) {
                viewModel.clearCommandState()
            }
        } message: {
            Text(viewModel.commandState.failureMessage ?? L("请重试。"))
        }
    }

    private var stateContent: AnyView {
        if !viewModel.entries.isEmpty {
            return AnyView(entryList)
        }

        if viewModel.loadState == .loading {
            return AnyView(
                ProgressView(L("加载歌曲"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
        if let message = viewModel.loadState.failureMessage {
            return AnyView(
                ErrorStateView(
                    title: L("歌单加载失败"),
                    message: message,
                    retryTitle: L("重试"),
                    retry: reload
                )
            )
        }
        if viewModel.loadState == .empty {
            return AnyView(emptyPlaylistContent)
        }
        return AnyView(
            ProgressView(L("加载歌曲"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                presentAddFlow()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(Text(L("添加歌曲")))
            .help(L("添加歌曲"))
            .disabled(!canPresentAddFlow)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    sendPlayback(.playAll)
                } label: {
                    Label(L("播放全部"), systemImage: "play.fill")
                }
                Button {
                    sendPlayback(.shuffle)
                } label: {
                    Label(L("随机播放"), systemImage: "shuffle")
                }
                Button {
                    sendPlayback(.playNext)
                } label: {
                    Label(L("下一首播放"), systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    sendPlayback(.enqueue)
                } label: {
                    Label(L("加入队列"), systemImage: "text.append")
                }
            } label: {
                Image(systemName: "play.circle")
            }
            .accessibilityLabel(Text(L("播放选项")))
            .disabled(viewModel.entries.isEmpty || viewModel.isSendingCommand)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                toggleEditing()
            } label: {
                Image(systemName: viewModel.isEditing ? "checkmark" : "pencil")
            }
            .accessibilityLabel(Text(viewModel.isEditing ? L("完成编辑") : L("编辑歌单")))
            .help(viewModel.isEditing ? L("完成编辑") : L("编辑歌单"))
            .disabled(viewModel.isLoading || viewModel.isMutating)
        }
    }

    private var removeSelectionBar: some View {
        Button(role: .destructive) {
            viewModel.requestRemoveSelected()
        } label: {
            Label(L("移除所选"), systemImage: "trash")
                .font(.headline)
                .frame(
                    maxWidth: .infinity,
                    minHeight: MusicFreeLayoutMetrics.minimumHitTarget
                )
        }
        .buttonStyle(.bordered)
        .tint(MusicFreeColorTokens.destructive)
        .disabled(viewModel.isLoading || viewModel.isMutating)
        .accessibilityIdentifier("playlists.removeSelected")
        .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
        .padding(.vertical, MusicFreeSpacingTokens.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var entryList: some View {
        List {
            playlistHeader

            if onRoute == nil, trackCandidateLoadState == .loading {
                Section {
                    HStack(spacing: MusicFreeSpacingTokens.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("正在加载歌曲信息"))
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    }
                }
            } else if onRoute == nil,
                      let message = trackCandidateLoadState.failureMessage,
                      let retryTrackCandidates {
                Section {
                    VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
                        Label(L("歌曲信息加载失败"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(MusicFreeColorTokens.destructive)
                        Text(message)
                            .font(MusicFreeTypographyTokens.secondary)
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        Button(L("重试"), action: retryTrackCandidates)
                    }
                }
            }
            Section {
                ForEach(Array(viewModel.orderedEntries.enumerated()), id: \.element.trackID) { offset, entry in
                    Button {
                        if viewModel.isEditing {
                            viewModel.toggleSelection(for: entry.trackID)
                        } else {
                            Task { await viewModel.play(itemID: entry.trackID) }
                        }
                    } label: {
                        PlaylistEntryRow(
                            position: offset,
                            title: title(for: entry.trackID),
                            subtitle: subtitle(for: entry.trackID),
                            isSelected: viewModel.selectedTrackIDs.contains(entry.trackID),
                            isEditing: viewModel.isEditing
                        )
                    }
                    .buttonStyle(.plain)
                    .tag(entry.trackID)
                }
                .onMove { source, destination in
                    viewModel.move(from: source, to: destination)
                }
            } header: {
                HStack {
                    Text(L("歌曲"))
                    Spacer(minLength: MusicFreeSpacingTokens.small)
                    Text("\(viewModel.entries.count)")
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
        .refreshable {
            await viewModel.load()
        }
    }

    private var playlistHeader: some View {
        Section {
            VStack(spacing: MusicFreeSpacingTokens.medium) {
                ArtworkView(
                    accessibilityLabel: L("%@ playlist artwork", viewModel.playlist.name),
                    placeholderSystemImage: "music.note.list",
                    placeholderTitle: viewModel.playlist.name,
                    fillsAvailableWidth: true
                )
                .frame(width: 128, height: 128)

                VStack(spacing: MusicFreeSpacingTokens.xSmall) {
                    Text(viewModel.playlist.name)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(L("%d tracks", viewModel.entries.count))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }

                MusicFreeDetailActionBar(
                    isEnabled: !viewModel.entries.isEmpty,
                    playAccessibilityIdentifier: "playlists.playAll",
                    shuffleAccessibilityIdentifier: "playlists.shuffle",
                    playAction: { sendPlayback(.playAll) },
                    shuffleAction: { sendPlayback(.shuffle) }
                )
                .accessibilityIdentifier("playlists.playbackActions")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MusicFreeSpacingTokens.large)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playlists.detail.header")
        }
    }

    private var emptyPlaylistContent: some View {
        ScrollView {
            VStack(spacing: MusicFreeSpacingTokens.large) {
                ArtworkView(
                    accessibilityLabel: L("%@ playlist artwork", viewModel.playlist.name),
                    placeholderSystemImage: "music.note.list",
                    placeholderTitle: viewModel.playlist.name,
                    fillsAvailableWidth: true
                )
                .frame(width: 128, height: 128)

                VStack(spacing: MusicFreeSpacingTokens.xSmall) {
                    Text(viewModel.playlist.name)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(L("%d tracks", 0))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }

                Text(emptyPlaylistMessage)
                    .font(MusicFreeTypographyTokens.body)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .multilineTextAlignment(.center)

                if onRoute == nil, trackCandidateLoadState == .loading {
                    HStack(spacing: MusicFreeSpacingTokens.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("正在加载可添加的歌曲"))
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    }
                } else if onRoute == nil,
                          let message = trackCandidateLoadState.failureMessage {
                    VStack(spacing: MusicFreeSpacingTokens.small) {
                        Label(L("歌曲信息加载失败"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(MusicFreeColorTokens.destructive)
                        Text(message)
                            .font(MusicFreeTypographyTokens.secondary)
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                            .multilineTextAlignment(.center)
                        if let retryTrackCandidates {
                            Button(L("重试"), action: retryTrackCandidates)
                        }
                    }
                }

                MusicFreePillActionButton(
                    title: L("添加歌曲"),
                    systemImage: "plus",
                    action: presentAddFlow
                )
                .frame(maxWidth: 260)
                .disabled(!canPresentAddFlow)
                .accessibilityIdentifier("playlists.addTracks.emptyAction")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
            .padding(.vertical, MusicFreeSpacingTokens.xxLarge)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playlists.detail.header")
        }
        .background(MusicFreeColorTokens.backgroundGrouped)
    }

    private var canPresentAddFlow: Bool {
        !viewModel.isLoading
            && !viewModel.isMutating
            && (onRoute != nil || trackCandidateLoadState == .loaded || trackCandidateLoadState == .empty)
    }

    private var emptyPlaylistMessage: String {
        if trackCandidateLoadState == .empty {
            return L("资料库中暂无可添加的歌曲。")
        }
        return L("添加歌曲后，就能从这里开始播放。")
    }

    private var removeConfirmationBinding: Binding<Bool> {
        Binding(
            get: {
                if case .removeTracks = viewModel.confirmation {
                    return true
                }
                return false
            },
            set: { isPresented in
                if !isPresented {
                    viewModel.cancelConfirmation()
                }
            }
        )
    }

    private var mutationFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.mutationState.failureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearMutationState()
                }
            }
        )
    }

    private var commandFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.commandState.failureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearCommandState()
                }
            }
        )
    }

    private func presentAddFlow() {
        if let onRoute {
            onRoute(.addTracks(viewModel.playlistID))
        } else if trackCandidateLoadState == .loaded || trackCandidateLoadState == .empty {
            isAddSheetPresented = true
        }
    }

    private func toggleEditing() {
        if viewModel.isEditing {
            Task { @MainActor in
                let saved = await viewModel.saveReorder()
                if saved {
                    editMode = .inactive
                }
            }
        } else {
            viewModel.beginEditing()
            editMode = .active
        }
    }

    private func sendPlayback(_ intent: PlaylistPlaybackIntent) {
        Task { await viewModel.sendPlayback(intent) }
    }

    private func reload() {
        Task { await viewModel.load() }
    }

    private func startLoadingIfNeeded() {
        loadTask?.cancel()
        let viewModel = viewModel
        loadTask = Task {
            await viewModel.loadIfNeeded()
        }
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func title(for trackID: MediaItemID) -> String {
        candidateCache[trackID]?.title ?? trackID.externalID
    }

    private func subtitle(for trackID: MediaItemID) -> String? {
        candidateCache[trackID]?.subtitle
    }
}

private struct PlaylistEntryRow: View {
    let position: Int
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let isEditing: Bool

    var body: some View {
        HStack(spacing: MusicFreeSpacingTokens.small) {
            Text("\(position + 1)")
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                .frame(width: MusicFreeLayoutMetrics.minimumHitTarget, alignment: .center)

            MediaRow(
                title: title,
                subtitle: subtitle,
                showsArtwork: false,
                accessory: {
                    if isEditing {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                isSelected
                                    ? MusicFreeColorTokens.accent
                                    : MusicFreeColorTokens.foregroundTertiary
                            )
                            .accessibilityHidden(true)
                    }
                }
            )
        }
        .contentShape(Rectangle())
        .padding(.trailing, MusicFreeSpacingTokens.contentInset)
        .accessibilityValue(Text(isEditing ? (isSelected ? L("已选择") : L("未选择")) : L("Track %d", position + 1)))
    }
}
