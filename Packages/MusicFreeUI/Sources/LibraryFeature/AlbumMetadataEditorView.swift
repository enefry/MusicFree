import AppServices
import DesignSystem
import LibraryAPI
import MusicDomain
import SwiftUI

struct AlbumMetadataEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let album: Album
    let library: any LibraryServing
    let onSaved: (Album) -> Void

    @State private var title: String
    @State private var artistName: String
    @State private var year: String
    @State private var isSaving = false
    @State private var isLoadingRelatedNames = true
    @State private var isRelatedNamesLoaded = false
    @State private var relatedNamesLoadFailed = false
    @State private var originalArtistNames: [String]?
    @State private var errorMessage: String?

    init(
        album: Album,
        library: any LibraryServing,
        onSaved: @escaping (Album) -> Void
    ) {
        self.album = album
        self.library = library
        self.onSaved = onSaved
        _title = State(initialValue: album.title)
        _artistName = State(initialValue: "")
        _year = State(initialValue: album.releaseYear.map(String.init) ?? "")
    }

    var body: some View {
        Form {
            Section(L("基本信息")) {
                TextField(L("专辑名称"), text: $title)
                    .accessibilityIdentifier("library.albumEditor.title")
                TextField(L("专辑艺人"), text: $artistName)
                    .accessibilityIdentifier("library.albumEditor.artist")
            }

            Section(L("发行信息")) {
                TextField(L("年份"), text: $year)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("library.albumEditor.year")
            }

            Section {
                Text(L("修改将应用到该专辑下的全部歌曲，仅覆盖 App 资料库，不会改写原始音频标签。"))
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }
        }
        .navigationTitle(L("编辑专辑"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("取消")) { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L("保存")) { save() }
                    .disabled(
                        isSaving
                            || isLoadingRelatedNames
                            || !isRelatedNamesLoaded
                            || relatedNamesLoadFailed
                    )
            }
        }
        .alert(
            L("无法保存专辑"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L("好"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? L("请稍后重试。"))
        }
        .task {
            await loadRelatedNames()
        }
    }

    private func loadRelatedNames() async {
        do {
            let names: [String]
            if album.artistIDs.isEmpty {
                names = []
            } else {
                let resolved = try await LibraryArtistNameLoader.load(
                    artistIDs: Set(album.artistIDs),
                    sourceID: .local,
                    from: library
                )
                guard resolved.count == Set(album.artistIDs).count else {
                    throw RelatedNamesLoadError.missingRelationship
                }
                names = album.artistIDs.compactMap { resolved[$0] }
            }
            artistName = TrackMetadataEditorRelationshipNames.displayNames(names)
            originalArtistNames = names
            isRelatedNamesLoaded = true
            isLoadingRelatedNames = false
        } catch is CancellationError {
            isRelatedNamesLoaded = false
        } catch {
            isRelatedNamesLoaded = false
            isLoadingRelatedNames = false
            relatedNamesLoadFailed = true
            errorMessage = L("无法读取专辑艺人信息，未保存任何修改。")
        }
    }

    private func save() {
        guard !isSaving,
              !isLoadingRelatedNames,
              isRelatedNamesLoaded,
              !relatedNamesLoadFailed
        else { return }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            errorMessage = L("专辑名称不能为空。")
            return
        }
        guard isValidOptionalYear(year) else {
            errorMessage = L("年份必须是有效数字。")
            return
        }

        let updatedArtistNames = TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: originalArtistNames,
            currentValue: artistName
        )
        let update = AlbumMetadataUpdate(
            albumID: album.id,
            title: normalizedTitle,
            artistNames: updatedArtistNames,
            releaseYear: parseYear(year)
        )

        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let updated = try await library.updateAlbumMetadata(update)
                onSaved(updated)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isValidOptionalYear(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        guard let year = Int(normalized) else { return false }
        return (1...9_999).contains(year)
    }

    private func parseYear(_ value: String) -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard let year = Int(normalized), (1...9_999).contains(year) else { return nil }
        return year
    }

    private enum RelatedNamesLoadError: Error {
        case missingRelationship
    }
}
