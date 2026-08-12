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
            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(enqueueNextTracks == nil)
        .accessibilityIdentifier(
            "\(accessibilityPrefix).playNext.\(trackID.externalID)"
        )

        Button {
            enqueueTracks?([trackID])
        } label: {
            Label("加入队列", systemImage: "text.append")
        }
        .disabled(enqueueTracks == nil)
        .accessibilityIdentifier(
            "\(accessibilityPrefix).enqueue.\(trackID.externalID)"
        )

        if let addToPlaylist {
            Button {
                addToPlaylist([trackID])
            } label: {
                Label("添加到播放列表", systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier(
                "\(accessibilityPrefix).addToPlaylist.\(trackID.externalID)"
            )
        }
    }
}
