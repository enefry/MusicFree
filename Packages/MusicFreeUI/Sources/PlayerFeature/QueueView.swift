import DesignSystem
import AppServices
import LibraryAPI
import MusicDomain
import PlaybackAPI
import SwiftUI

struct QueueView: View {
  @ObservedObject private var viewModel: PlayerViewModel
  private let artworkServing: (any ArtworkServing)?
  private let library: (any LibraryServing)?
  @StateObject private var editor = QueueEditor()
  @StateObject private var historyLoader: NowPlayingHistoryLoader
  @State private var tracks: [MediaItemID: Track] = [:]
  @State private var artistNames: [ArtistID: String] = [:]
  @State private var isClearConfirmationPresented = false
  @State private var isHistoryClearConfirmationPresented = false
  @State private var hasAppliedInitialScrollPosition = false

  init(
    viewModel: PlayerViewModel,
    artworkServing: (any ArtworkServing)? = nil,
    library: (any LibraryServing)? = nil
  ) {
    self.viewModel = viewModel
    self.artworkServing = artworkServing
    self.library = library
    _historyLoader = StateObject(
      wrappedValue: NowPlayingHistoryLoader(library: library)
    )
  }

  var body: some View {
    Group {
      if historyLoader.state == .idle || historyLoader.state == .loading {
        ProgressView(L("正在载入播放历史"))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.snapshot.queue.entries.isEmpty,
         historyLoader.state == .empty {
        EmptyStateView(
          title: L("暂无播放记录"),
          message: L("播放歌曲后，历史和继续播放队列会显示在这里。"),
          systemImage: "clock.arrow.circlepath"
        )
      } else {
        GeometryReader { geometry in
          ScrollViewReader { proxy in
            List {
              historySection

              if let currentEntryID = viewModel.snapshot.queue.currentEntryID,
                 let currentEntry = viewModel.snapshot.queue.entries.first(where: { $0.id == currentEntryID }) {
                Section(L("正在播放")) {
                  queueRow(currentEntry, isCurrent: true)
                    .id(QueueScrollPosition.current)
                    .accessibilityIdentifier("player.queue.current")
                }
              }

              Section {
                PlaybackModeControls(viewModel: viewModel)
                  .listRowInsets(EdgeInsets())
                  .listRowBackground(Color.clear)
                  .listRowSeparator(.hidden)
              }

              Section(L("继续播放")) {
                if editor.isActive {
                  ForEach(editor.entries) { entry in
                    queueRow(entry, isCurrent: false)
                  }
                  .onMove(perform: editor.move)
                  .onDelete(perform: editor.remove)
                } else if upcomingEntries.isEmpty {
                  Text(L("队列末尾"))
                    .font(.subheadline)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .frame(minHeight: MusicFreeLayoutMetrics.minimumHitTarget)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                  ForEach(upcomingEntries) { entry in
                    queueRow(entry, isCurrent: false)
                  }
                }
              }

              queueTailSpacer(viewportHeight: geometry.size.height)
            }
            .accessibilityIdentifier("player.queue.list")
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(MusicFreeColorTokens.backgroundPrimary)
            .environment(\.editMode, editMode)
            .toolbar { queueToolbar }
            .onChange(of: historyLoader.state, initial: true) { _, state in
              applyInitialScrollPosition(after: state, using: proxy)
            }
          }
        }
      }
    }
    .navigationTitle(L("播放队列"))
    .navigationBarTitleDisplayMode(.inline)
    .interactiveDismissDisabled(editor.isActive)
    .confirmationDialog(
      L("清空播放队列？"),
      isPresented: $isClearConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(L("清空队列"), role: .destructive) {
        viewModel.clearQueue()
      }
      Button(L("取消"), role: .cancel) {}
    } message: {
      Text(L("当前播放也会停止，资料库中的歌曲不会被删除。"))
    }
    .confirmationDialog(
      L("清除播放历史？"),
      isPresented: $isHistoryClearConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(L("清除播放历史"), role: .destructive) {
        Task { await historyLoader.clear() }
      }
      Button(L("取消"), role: .cancel) {}
    } message: {
      Text(L("歌曲仍会保留在资料库中，累计播放统计不会重置。"))
    }
    .alert(
      L("无法更新播放队列"),
      isPresented: Binding(
        get: { editor.failureMessage != nil },
        set: { isPresented in
          if !isPresented { editor.dismissFailure() }
        }
      )
    ) {
      Button(L("好"), role: .cancel) { editor.dismissFailure() }
    } message: {
      Text(editor.failureMessage ?? L("请稍后重试。"))
    }
    .alert(
      L("播放历史不可用"),
      isPresented: Binding(
        get: { historyLoader.failureMessage != nil },
        set: { isPresented in
          if !isPresented { historyLoader.dismissFailure() }
        }
      )
    ) {
      Button(L("好"), role: .cancel) { historyLoader.dismissFailure() }
    } message: {
      Text(historyLoader.failureMessage ?? L("请稍后重试。"))
    }
    .task(id: queueKey) {
      await loadTracks()
    }
    .task(id: historyKey) {
      await historyLoader.load()
    }
    .task {
      await historyLoader.observeChanges()
    }
    .task {
      await observeLibraryChanges()
    }
    .onChange(of: viewModel.snapshot.queue) { _, queue in
      editor.synchronize(with: queue)
    }
  }

  @ViewBuilder
  private var historySection: some View {
    Section {
      switch historyLoader.state {
      case .idle, .loading:
        HStack(spacing: MusicFreeSpacingTokens.small) {
          ProgressView()
          Text(L("正在载入播放历史"))
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        }
        .frame(minHeight: MusicFreeLayoutMetrics.minimumHitTarget)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      case .failed:
        Button {
          Task { await historyLoader.load() }
        } label: {
          Label(L("载入失败，点击重试"), systemImage: "arrow.clockwise")
            .frame(maxWidth: .infinity, minHeight: MusicFreeLayoutMetrics.minimumHitTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
      case .empty:
        Text(L("暂无播放历史"))
          .font(MusicFreeTypographyTokens.secondary)
          .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
          .frame(minHeight: MusicFreeLayoutMetrics.minimumHitTarget)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      case .loaded:
        if displayedHistoryItems.isEmpty {
          Text(L("当前歌曲尚未形成历史记录"))
            .font(MusicFreeTypographyTokens.secondary)
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            .frame(minHeight: MusicFreeLayoutMetrics.minimumHitTarget)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
          ForEach(displayedHistoryItems) { item in
            historyRow(item)
          }
        }
      }
    } header: {
      HStack {
        Text(L("历史"))
        Spacer()
        Button(L("清除"), role: .destructive) {
          isHistoryClearConfirmationPresented = true
        }
        .disabled(historyLoader.items.isEmpty || historyLoader.isClearing)
        .textCase(nil)
        .accessibilityIdentifier("player.history.clear")
      }
      .font(.headline)
      .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
      .textCase(nil)
    }
  }

  private var displayedHistoryItems: [PlaybackHistoryItem] {
    NowPlayingHistoryPresentation.visibleItems(
      from: historyLoader.items,
      currentItemID: viewModel.snapshot.currentItemID
    )
  }

  private func historyRow(_ item: PlaybackHistoryItem) -> some View {
    Button {
      viewModel.send(.play(itemID: item.track.id))
    } label: {
      HStack(spacing: MusicFreeSpacingTokens.rowGap) {
        ArtworkResourceView(
          artworkID: item.track.artworkID,
          sourceID: item.track.id.sourceID,
          serving: artworkServing,
          accessibilityLabel: item.track.artworkID == nil ? L("暂无封面") : L("封面"),
          placeholderTitle: item.track.title
        )

        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
          Text(item.track.title)
            .font(MusicFreeTypographyTokens.rowTitle)
            .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
            .lineLimit(1)

          if let subtitle = QueueArtistNameLoader.subtitle(
            for: item.track,
            artistNames: historyLoader.artistNames
          ) {
            Text(subtitle)
              .font(MusicFreeTypographyTokens.rowSubtitle)
              .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
    .padding(.vertical, MusicFreeSpacingTokens.small)
    .frame(minHeight: MusicFreeLayoutMetrics.compactRowMinimumHeight)
    .accessibilityElement(children: .combine)
    .accessibilityHint(L("重新播放歌曲"))
    .accessibilityIdentifier("player.history.play.\(item.sessionID.uuidString)")
    .listRowBackground(Color.clear)
    .listRowSeparatorTint(MusicFreeColorTokens.separator.opacity(0.72))
  }

  private var upcomingEntries: [PlaybackQueueEntry] {
    let orderedEntries = viewModel.orderedQueueEntries
    guard let currentEntryID = viewModel.snapshot.queue.currentEntryID,
          let currentIndex = orderedEntries.firstIndex(where: { $0.id == currentEntryID })
    else {
      return orderedEntries
    }
    let startIndex = orderedEntries.index(after: currentIndex)
    guard startIndex < orderedEntries.endIndex else { return [] }
    return Array(orderedEntries[startIndex...])
  }

  private func queueRow(
    _ entry: PlaybackQueueEntry,
    isCurrent: Bool
  ) -> some View {
    let track = tracks[entry.itemID]
    let currentDisplay = entry.id == viewModel.snapshot.queue.currentEntryID
      ? viewModel.snapshot.currentItem
      : nil

    return HStack(spacing: MusicFreeSpacingTokens.rowGap) {
      ArtworkResourceView(
        artworkID: track?.artworkID ?? currentDisplay?.artworkID,
        sourceID: entry.itemID.sourceID,
        serving: artworkServing,
        accessibilityLabel: (track?.artworkID ?? currentDisplay?.artworkID) == nil
          ? L("暂无封面")
          : L("封面"),
        placeholderTitle: track?.title ?? currentDisplay?.title
      )

      VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
        Text(track?.title ?? currentDisplay?.title ?? entry.itemID.externalID)
          .font(MusicFreeTypographyTokens.rowTitle)
          .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
          .lineLimit(1)

        if let subtitle = QueueArtistNameLoader.subtitle(
          for: track,
          artistNames: artistNames
        ) {
          Text(subtitle)
            .font(MusicFreeTypographyTokens.rowSubtitle)
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)

      if isCurrent {
        Image(systemName: "speaker.wave.2.fill")
          .foregroundStyle(MusicFreeColorTokens.accent)
          .accessibilityHidden(true)
      } else if !editor.isActive {
        Image(systemName: "line.3.horizontal")
          .font(.title3)
          .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, MusicFreeSpacingTokens.small)
    .frame(minHeight: MusicFreeLayoutMetrics.compactRowMinimumHeight)
    .contentShape(Rectangle())
    .onTapGesture {
      guard !editor.isActive else { return }
      viewModel.selectQueueEntry(entry.id)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(editor.isActive ? [] : .isButton)
    .listRowBackground(Color.clear)
    .listRowSeparatorTint(MusicFreeColorTokens.separator.opacity(0.72))
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if !isCurrent, !editor.isActive {
        Button(role: .destructive) {
          viewModel.removeQueueEntry(entry.id)
        } label: {
          Label(L("移除"), systemImage: "trash")
        }
      }
    }
  }

  private var editMode: Binding<EditMode> {
    Binding(
      get: { editor.isActive ? .active : .inactive },
      set: { _ in }
    )
  }

  @ToolbarContentBuilder
  private var queueToolbar: some ToolbarContent {
    if editor.isActive {
      ToolbarItem(placement: .cancellationAction) {
        Button(L("取消")) {
          editor.cancel()
        }
        .disabled(editor.isSaving)
        .accessibilityIdentifier("player.queue.cancelEditing")
      }

      ToolbarItem(placement: .confirmationAction) {
        Button {
          Task { await editor.commit(using: viewModel) }
        } label: {
          if editor.isSaving {
            ProgressView()
              .accessibilityLabel(Text(L("正在保存播放顺序")))
          } else {
            Text(L("完成"))
          }
        }
        .disabled(editor.isSaving)
        .accessibilityIdentifier("player.queue.doneEditing")
      }
    } else {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          editor.begin(queue: viewModel.snapshot.queue)
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .disabled(upcomingEntries.isEmpty)
        .accessibilityLabel(Text(L("编辑播放顺序")))
        .accessibilityIdentifier("player.queue.edit")

        Menu {
          Button(role: .destructive) {
            isClearConfirmationPresented = true
          } label: {
            Label(L("清空播放队列"), systemImage: "trash")
          }
          .disabled(viewModel.snapshot.queue.entries.isEmpty)
          .accessibilityIdentifier("player.queue.clear")
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel(Text(L("更多队列操作")))
      }
    }
  }

  private var queueKey: String {
    viewModel.snapshot.queue.entries.map { $0.id.uuidString }.joined(separator: ",")
  }

  private var historyKey: String {
    "\(viewModel.snapshot.generation.rawValue):\(viewModel.snapshot.currentItemID?.externalID ?? "")"
  }

  @ViewBuilder
  private func queueTailSpacer(viewportHeight: CGFloat) -> some View {
    let visibleEntries = editor.isActive ? editor.entries.count : upcomingEntries.count
    let estimatedTailHeight = CGFloat(visibleEntries + 1)
      * MusicFreeLayoutMetrics.compactRowMinimumHeight
      + 180
    let spacerHeight = max(0, viewportHeight - estimatedTailHeight)

    if spacerHeight > 0 {
      Color.clear
        .frame(height: spacerHeight)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityHidden(true)
    }
  }

  private func applyInitialScrollPosition(
    after state: NowPlayingHistoryLoadState,
    using proxy: ScrollViewProxy
  ) {
    guard !hasAppliedInitialScrollPosition,
          state != .idle,
          state != .loading,
          viewModel.snapshot.queue.currentEntryID != nil
    else { return }

    hasAppliedInitialScrollPosition = true
    Task { @MainActor in
      await Task.yield()
      proxy.scrollTo(QueueScrollPosition.current, anchor: .top)
    }
  }

  private func loadTracks() async {
    guard let library else {
      tracks = [:]
      artistNames = [:]
      return
    }
    let expectedQueueKey = queueKey
    var loaded: [MediaItemID: Track] = [:]
    for entry in viewModel.snapshot.queue.entries {
      guard !Task.isCancelled else { return }
      if let track = try? await library.track(id: entry.itemID) {
        loaded[entry.itemID] = track
      }
    }
    guard !Task.isCancelled else { return }

    var loadedArtistNames: [ArtistID: String] = [:]
    do {
      loadedArtistNames = try await QueueArtistNameLoader.load(
        for: Array(loaded.values),
        from: library
      )
    } catch is CancellationError {
      return
    } catch {
      loadedArtistNames = [:]
    }

    guard !Task.isCancelled, queueKey == expectedQueueKey else { return }
    tracks = loaded
    artistNames = loadedArtistNames
  }

  private func observeLibraryChanges() async {
    guard let library else { return }
    let stream = await library.makeChangeStream()
    for await change in stream {
      guard !Task.isCancelled else { return }
      guard shouldReloadQueue(for: change) else { continue }
      await loadTracks()
    }
  }

  private func shouldReloadQueue(for change: LibraryChange) -> Bool {
    let queueIDs = Set(viewModel.snapshot.queue.entries.map(\.itemID))
    guard !queueIDs.isEmpty else { return false }
    if !queueIDs.isDisjoint(with: change.affectedIDs.trackIDs) {
      return true
    }

    let artworkIDs = Set(tracks.values.compactMap(\.artworkID))
    if !artworkIDs.isDisjoint(with: change.affectedIDs.artworkIDs) {
      return true
    }

    let artistIDs = Set(tracks.values.flatMap(\.artistIDs))
    return !artistIDs.isDisjoint(with: change.affectedIDs.artistIDs)
  }

}

private enum QueueScrollPosition: Hashable {
  case current
}

struct PlaybackModeControls: View {
  @ObservedObject private var viewModel: PlayerViewModel

  init(viewModel: PlayerViewModel) {
    self.viewModel = viewModel
  }

  var body: some View {
    HStack(spacing: MusicFreeSpacingTokens.controlGap) {
      Menu {
        ForEach(PlaybackRepeatMode.allCases, id: \.self) { mode in
          Button {
            viewModel.setRepeatMode(mode)
          } label: {
            Label(repeatTitle(mode), systemImage: repeatIcon(mode))
          }
        }
      } label: {
        Image(systemName: repeatIcon(viewModel.snapshot.queue.repeatMode))
          .frame(width: MusicFreeLayoutMetrics.minimumHitTarget, height: MusicFreeLayoutMetrics.minimumHitTarget)
      }
      .accessibilityLabel(Text(L("重复模式")))
      .accessibilityValue(Text(repeatTitle(viewModel.snapshot.queue.repeatMode)))

      Button {
        viewModel.setShuffle(viewModel.snapshot.queue.shuffleMode == .on ? .off : .on)
      } label: {
        Image(systemName: "shuffle")
          .frame(width: MusicFreeLayoutMetrics.minimumHitTarget, height: MusicFreeLayoutMetrics.minimumHitTarget)
      }
      .buttonStyle(.plain)
      .foregroundStyle(
        viewModel.snapshot.queue.shuffleMode == .on
          ? MusicFreeColorTokens.accent
          : MusicFreeColorTokens.foregroundPrimary
      )
      .accessibilityLabel(Text(L("随机播放")))
      .accessibilityValue(
        Text(viewModel.snapshot.queue.shuffleMode == .on ? L("已开启") : L("已关闭"))
      )
      .accessibilityAddTraits(
        viewModel.snapshot.queue.shuffleMode == .on ? .isSelected : []
      )
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, MusicFreeSpacingTokens.contentInset)
    .padding(.vertical, MusicFreeSpacingTokens.medium)
  }

  private func repeatIcon(_ mode: PlaybackRepeatMode) -> String {
    mode == .one ? "repeat.1" : "repeat"
  }

  private func repeatTitle(_ mode: PlaybackRepeatMode) -> String {
    switch mode {
    case .off:
      return L("关闭重复")
    case .one:
      return L("重复单曲")
    case .all:
      return L("重复队列")
    }
  }
}
