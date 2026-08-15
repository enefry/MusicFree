import AppServices
import DesignSystem
import Foundation
import MusicDomain
import SwiftUI

struct PlaybackHistoryView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let playTrack: ((MediaItemID) -> Void)?
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?
    let artworkServing: (any ArtworkServing)?

    @State private var artistNames: [ArtistID: String] = [:]
    @State private var isClearConfirmationPresented = false
    @State private var pendingDeletionTrack: Track?
    @State private var deletionErrorMessage: String?
    @State private var deletingTrackID: MediaItemID?

    var body: some View {
        LibraryContentState(
            state: viewModel.state(for: .recent),
            hasContent: !viewModel.playbackHistory.isEmpty,
            emptyTitle: L("暂无播放历史"),
            emptyMessage: L("播放过的歌曲会按时间显示在这里。"),
            emptySystemImage: "clock.arrow.circlepath",
            retry: { viewModel.retry(section: .recent) }
        ) {
            List {
                ForEach(historySections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            PlaybackHistoryRow(
                                item: item,
                                subtitle: artistSubtitle(for: item.track),
                                artworkServing: artworkServing,
                                action: { playTrack?(item.track.id) },
                                requestDelete: { pendingDeletionTrack = item.track },
                                isDeleting: deletingTrackID == item.track.id,
                                enqueueNextTracks: enqueueNextTracks,
                                enqueueTracks: enqueueTracks,
                                addToPlaylist: addToPlaylist
                            )
                            .listRowInsets(EdgeInsets())
                            .onAppear {
                                if item.id == viewModel.playbackHistory.last?.id {
                                    viewModel.loadNextPage(for: .recent)
                                }
                            }
                        }
                    }
                }

                LibraryPageFooter(section: .recent, viewModel: viewModel)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(MusicFreeColorTokens.backgroundPrimary)
        }
        .accessibilityIdentifier("library.playbackHistory")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("清除"), role: .destructive) {
                    isClearConfirmationPresented = true
                }
                .disabled(
                    viewModel.playbackHistory.isEmpty
                        || viewModel.isClearingPlaybackHistory
                )
                .accessibilityIdentifier("library.playbackHistory.clear")
            }
        }
        .confirmationDialog(
            L("清除播放历史？"),
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(L("清除播放历史"), role: .destructive) {
                Task { await viewModel.clearPlaybackHistory() }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("歌曲仍会保留在资料库中，累计播放统计不会重置。"))
        }
        .alert(
            L("无法清除播放历史"),
            isPresented: Binding(
                get: { viewModel.playbackHistoryClearError != nil },
                set: { isPresented in
                    if !isPresented { viewModel.dismissPlaybackHistoryClearError() }
                }
            )
        ) {
            Button(L("好"), role: .cancel) {
                viewModel.dismissPlaybackHistoryClearError()
            }
        } message: {
            Text(viewModel.playbackHistoryClearError ?? L("请稍后重试。"))
        }
        .trackDeletionPresentation(
            pendingTrack: $pendingDeletionTrack,
            errorMessage: $deletionErrorMessage,
            isDeleting: deletingTrackID != nil,
            delete: deleteTrack
        )
        .task(id: historyMetadataKey) {
            await loadArtistNames()
        }
    }

    private var historySections: [PlaybackHistorySection] {
        PlaybackHistoryPresentation.sections(
            from: viewModel.playbackHistory,
            now: Date(),
            calendar: .autoupdatingCurrent
        )
    }

    private func artistSubtitle(for track: Track) -> String? {
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var historyMetadataKey: String {
        viewModel.playbackHistory.map { $0.id.uuidString }.joined(separator: "|")
    }

    private func loadArtistNames() async {
        do {
            artistNames = try await LibraryArtistNameLoader.load(
                for: viewModel.playbackHistory.map(\.track),
                from: viewModel.library
            )
        } catch is CancellationError {
            return
        } catch {
            artistNames = [:]
        }
    }

    private func deleteTrack(_ track: Track) {
        guard deletingTrackID == nil else { return }
        let itemID = track.id
        deletingTrackID = itemID
        Task { @MainActor in
            defer { deletingTrackID = nil }
            do {
                _ = try await viewModel.library.delete([itemID])
                viewModel.removeDeletedTrack(itemID)
            } catch is CancellationError {
                return
            } catch {
                deletionErrorMessage = error.localizedDescription
            }
        }
    }
}

struct PlaybackHistorySection: Identifiable, Equatable {
    let date: Date
    let title: String
    let items: [PlaybackHistoryItem]

    var id: Date { date }
}

enum PlaybackHistoryPresentation {
    static func sections(
        from items: [PlaybackHistoryItem],
        now: Date,
        calendar: Calendar
    ) -> [PlaybackHistorySection] {
        let grouped = Dictionary(grouping: items) {
            calendar.startOfDay(for: $0.lastEventAt)
        }
        return grouped.keys.sorted(by: >).map { date in
            PlaybackHistorySection(
                date: date,
                title: sectionTitle(for: date, now: now, calendar: calendar),
                items: (grouped[date] ?? []).sorted {
                    if $0.lastEventAt != $1.lastEventAt {
                        return $0.lastEventAt > $1.lastEventAt
                    }
                    return $0.sessionID.uuidString < $1.sessionID.uuidString
                }
            )
        }
    }

    static func sectionTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L("今天") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L("昨天")
        }
        return date.formatted(.dateTime.year().month().day())
    }
}

private struct PlaybackHistoryRow: View {
    let item: PlaybackHistoryItem
    let subtitle: String?
    let artworkServing: (any ArtworkServing)?
    let action: () -> Void
    let requestDelete: () -> Void
    let isDeleting: Bool
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?

    @StateObject private var artworkLoader = ArtworkImageLoader()

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                MediaRow(
                    title: item.track.title,
                    subtitle: subtitle,
                    artwork: artworkLoader.image,
                    artworkAccessibilityLabel: L("%@ album artwork", item.track.title)
                ) {
                    Text(item.lastEventAt, format: .dateTime.hour().minute())
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityHint(L("播放歌曲"))
            .accessibilityIdentifier("library.playbackHistory.play.\(item.sessionID.uuidString)")

            Menu {
                Button(L("播放"), systemImage: "play.fill", action: action)
                TrackQueueMenuActions(
                    trackID: item.track.id,
                    accessibilityPrefix: "library.playbackHistory.menu",
                    enqueueNextTracks: enqueueNextTracks,
                    enqueueTracks: enqueueTracks,
                    addToPlaylist: addToPlaylist
                )
                Divider()
                Button(role: .destructive, action: requestDelete) {
                    Label(L("删除歌曲"), systemImage: "trash")
                }
                .disabled(isDeleting)
                .accessibilityIdentifier(
                    "library.playbackHistory.menu.delete.\(item.sessionID.uuidString)"
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.semibold))
                    .frame(
                        width: MusicFreeLayoutMetrics.minimumHitTarget,
                        height: MusicFreeLayoutMetrics.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            .accessibilityLabel(L("歌曲选项"))
            .accessibilityIdentifier(
                "library.playbackHistory.menu.\(item.sessionID.uuidString)"
            )
            .padding(.trailing, MusicFreeSpacingTokens.contentInset)
        }
        .task(id: artworkKey) {
            await artworkLoader.load(
                artworkID: item.track.artworkID,
                sourceID: item.track.id.sourceID,
                serving: artworkServing
            )
        }
    }

    private var artworkKey: String {
        "\(item.track.id.sourceID.rawValue):\(item.track.artworkID?.rawValue ?? "")"
    }
}
