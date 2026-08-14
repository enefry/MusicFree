import DesignSystem
import MusicDomain
import SwiftUI

struct AddToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss

    let candidates: [PlaylistTrackCandidate]
    let existingIDs: Set<MediaItemID>
    let onSubmit: @MainActor ([MediaItemID]) async -> Bool

    @State private var searchText = ""
    @State private var selectedIDs = Set<MediaItemID>()
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Group {
                if filteredCandidates.isEmpty {
                    EmptyStateView(
                        title: L("没有可添加的歌曲"),
                        message: searchText.isEmpty ? L("资料库中暂无可用歌曲。") : L("没有匹配的歌曲。"),
                        systemImage: "music.note"
                    )
                } else {
                    List(filteredCandidates) { candidate in
                        Button {
                            toggle(candidate.id)
                        } label: {
                            MediaRow(
                                title: candidate.title,
                                subtitle: candidate.subtitle,
                                showsArtwork: false,
                                accessory: {
                                    Image(systemName: selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(
                                            selectedIDs.contains(candidate.id)
                                                ? MusicFreeColorTokens.accent
                                                : MusicFreeColorTokens.foregroundTertiary
                                        )
                                    .accessibilityHidden(true)
                                }
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(existingIDs.contains(candidate.id))
                        .opacity(existingIDs.contains(candidate.id) ? 0.45 : 1)
                        .accessibilityIdentifier("playlists.addTrack.\(candidate.id.externalID)")
                        .accessibilityValue(
                            Text(existingIDs.contains(candidate.id) ? L("已在歌单中") : (selectedIDs.contains(candidate.id) ? L("已选择") : L("未选择")))
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(L("添加歌曲"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: L("搜索歌曲"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("添加")) {
                        submit()
                    }
                    .disabled(selectedIDs.isEmpty || isSubmitting)
                    .accessibilityIdentifier("playlists.addTracks.submit")
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView(L("添加中"))
                        .padding(MusicFreeSpacingTokens.large)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .accessibilityIdentifier("playlists.addTracks")
        }
    }

    private var filteredCandidates: [PlaylistTrackCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return candidates
        }
        let normalizedQuery = query.localizedLowercase
        return candidates.filter { candidate in
            candidate.title.localizedLowercase.contains(normalizedQuery)
                || candidate.subtitle?.localizedLowercase.contains(normalizedQuery) == true
                || candidate.id.externalID.localizedLowercase.contains(normalizedQuery)
        }
    }

    private func toggle(_ id: MediaItemID) {
        guard !existingIDs.contains(id), !isSubmitting else {
            return
        }
        var updatedSelection = selectedIDs
        if !updatedSelection.insert(id).inserted {
            updatedSelection.remove(id)
        }
        selectedIDs = updatedSelection
    }

    private func submit() {
        guard !selectedIDs.isEmpty, !isSubmitting else {
            return
        }
        let orderedIDs = candidates.map(\.id).filter { selectedIDs.contains($0) }
        isSubmitting = true
        Task { @MainActor in
            let saved = await onSubmit(orderedIDs)
            isSubmitting = false
            if saved {
                dismiss()
            }
        }
    }
}
