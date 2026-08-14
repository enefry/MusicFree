import DesignSystem
import MusicDomain
import SwiftUI

struct TrackQueueMenuActions: View {
    let trackID: MediaItemID
    let accessibilityPrefix: String
    let enqueueNextTracks: (([MediaItemID]) -> Void)?
    let enqueueTracks: (([MediaItemID]) -> Void)?
    let addToPlaylist: (([MediaItemID]) -> Void)?

    init(
        trackID: MediaItemID,
        accessibilityPrefix: String,
        enqueueNextTracks: (([MediaItemID]) -> Void)?,
        enqueueTracks: (([MediaItemID]) -> Void)?,
        addToPlaylist: (([MediaItemID]) -> Void)? = nil
    ) {
        self.trackID = trackID
        self.accessibilityPrefix = accessibilityPrefix
        self.enqueueNextTracks = enqueueNextTracks
        self.enqueueTracks = enqueueTracks
        self.addToPlaylist = addToPlaylist
    }

    var body: some View {
        Button {
            enqueueNextTracks?([trackID])
        } label: {
            Label(L("下一首播放"), systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(enqueueNextTracks == nil)
        .accessibilityIdentifier(
            "\(accessibilityPrefix).playNext.\(trackID.externalID)"
        )

        Button {
            enqueueTracks?([trackID])
        } label: {
            Label(L("加入队列"), systemImage: "text.append")
        }
        .disabled(enqueueTracks == nil)
        .accessibilityIdentifier(
            "\(accessibilityPrefix).enqueue.\(trackID.externalID)"
        )

        if let addToPlaylist {
            Button {
                addToPlaylist([trackID])
            } label: {
                Label(L("添加到播放列表"), systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier(
                "\(accessibilityPrefix).addToPlaylist.\(trackID.externalID)"
            )
        }
    }
}

enum LibraryBatchDeletionScope: Sendable {
    case tracks
    case albums
    case artists

    var actionTitle: String {
        switch self {
        case .tracks: return L("删除所选歌曲")
        case .albums: return L("删除所选专辑")
        case .artists: return L("删除所选艺人")
        }
    }

    var confirmationTitle: String {
        switch self {
        case .tracks: return L("删除所选歌曲？")
        case .albums: return L("删除所选专辑？")
        case .artists: return L("删除所选艺人？")
        }
    }

    func countLabel(_ count: Int) -> String {
        switch self {
        case .tracks: return L("%d tracks", count)
        case .albums: return L("%d albums", count)
        case .artists: return L("%d artists", count)
        }
    }

    func confirmationMessage(_ count: Int) -> String {
        switch self {
        case .tracks:
            return L(
                "将从资料库和 App 托管存储中删除所选的 %d 首歌曲；Documents 中的原始文件不会被删除。",
                count
            )
        case .albums:
            return L(
                "将删除所选的 %d 张专辑及其中的歌曲；Documents 中的原始文件不会被删除。",
                count
            )
        case .artists:
            return L(
                "将删除所选的 %d 位艺人及其歌曲；Documents 中的原始文件不会被删除。",
                count
            )
        }
    }
}

struct TrackDeletionPresentationModifier: ViewModifier {
    @Binding var pendingTrack: Track?
    @Binding var errorMessage: String?
    let isDeleting: Bool
    let delete: (Track) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L("删除歌曲？"),
                isPresented: Binding(
                    get: { pendingTrack != nil },
                    set: { isPresented in
                        if !isPresented { pendingTrack = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(L("删除歌曲"), role: .destructive) {
                    guard let track = pendingTrack else { return }
                    pendingTrack = nil
                    delete(track)
                }
                .disabled(isDeleting)
                Button(L("取消"), role: .cancel) {}
            } message: {
                if let title = pendingTrack?.title {
                    Text(
                        L("将从资料库和 App 托管存储中删除“%@”；Documents 中的原始文件不会被删除。", title)
                    )
                } else {
                    Text(L("歌曲将从资料库和 App 托管存储中删除。"))
                }
            }
            .alert(
                L("无法删除歌曲"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { errorMessage = nil }
                    }
                )
            ) {
                Button(L("好"), role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? L("请稍后重试。"))
            }
    }
}

struct LibraryBatchDeletionPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let count: Int
    let scope: LibraryBatchDeletionScope
    let isDeleting: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                scope.confirmationTitle,
                isPresented: Binding(
                    get: { isPresented },
                    set: { isPresented in
                        if !isPresented { self.isPresented = false }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(scope.actionTitle, role: .destructive) {
                    action()
                    isPresented = false
                }
                .disabled(isDeleting)
                Button(L("取消"), role: .cancel) {}
            } message: {
                Text(scope.confirmationMessage(count))
            }
    }
}

struct LibraryDeletionErrorPresentationModifier: ViewModifier {
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content.alert(
            L("无法删除歌曲"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented { errorMessage = nil }
                }
            )
        ) {
            Button(L("好"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? L("请稍后重试。"))
        }
    }
}

extension View {
    func trackDeletionPresentation(
        pendingTrack: Binding<Track?>,
        errorMessage: Binding<String?>,
        isDeleting: Bool,
        delete: @escaping (Track) -> Void
    ) -> some View {
        modifier(
            TrackDeletionPresentationModifier(
                pendingTrack: pendingTrack,
                errorMessage: errorMessage,
                isDeleting: isDeleting,
                delete: delete
            )
        )
    }

    func batchTrackDeletionPresentation(
        pendingTrackIDs: Binding<Set<MediaItemID>>,
        isDeleting: Bool,
        delete: @escaping (Set<MediaItemID>) -> Void
    ) -> some View {
        modifier(
            LibraryBatchDeletionPresentationModifier(
                isPresented: Binding(
                    get: { !pendingTrackIDs.wrappedValue.isEmpty },
                    set: { isPresented in
                        if !isPresented { pendingTrackIDs.wrappedValue.removeAll() }
                    }
                ),
                count: pendingTrackIDs.wrappedValue.count,
                scope: .tracks,
                isDeleting: isDeleting,
                action: {
                    let trackIDs = pendingTrackIDs.wrappedValue
                    pendingTrackIDs.wrappedValue.removeAll()
                    delete(trackIDs)
                }
            )
        )
    }

    func batchDeletionPresentation(
        isPresented: Binding<Bool>,
        count: Int,
        scope: LibraryBatchDeletionScope,
        isDeleting: Bool,
        action: @escaping () -> Void
    ) -> some View {
        modifier(
            LibraryBatchDeletionPresentationModifier(
                isPresented: isPresented,
                count: count,
                scope: scope,
                isDeleting: isDeleting,
                action: action
            )
        )
    }

    func libraryDeletionErrorPresentation(
        errorMessage: Binding<String?>
    ) -> some View {
        modifier(
            LibraryDeletionErrorPresentationModifier(errorMessage: errorMessage)
        )
    }
}
