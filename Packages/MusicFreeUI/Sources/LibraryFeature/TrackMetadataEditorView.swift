import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import PhotosUI
import SwiftUI
import MusicDomain

struct TrackMetadataEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let track: Track
    let library: any LibraryServing
    let onSaved: (Track) -> Void

    @State private var title: String
    @State private var artistName: String
    @State private var albumArtistName: String
    @State private var albumName: String
    @State private var genreName: String
    @State private var trackNumber: String
    @State private var discNumber: String
    @State private var year: String
    @State private var comment: String
    @State private var lyrics: String
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotoLoadID = UUID()
    @State private var isLoadingArtwork = false
    @State private var artworkEdit: ArtworkEdit = .keep
    @State private var isSaving = false
    @State private var isLoadingRelatedNames = true
    @State private var isRelatedNamesLoaded = false
    @State private var relatedNamesLoadFailed = false
    @State private var originalArtistNames: [String]?
    @State private var originalAlbumArtistNames: [String]?
    @State private var originalGenreNames: [String]?
    @State private var errorMessage: String?

    init(
        track: Track,
        library: any LibraryServing,
        onSaved: @escaping (Track) -> Void
    ) {
        self.track = track
        self.library = library
        self.onSaved = onSaved
        _title = State(initialValue: track.title)
        _artistName = State(initialValue: "")
        _albumArtistName = State(initialValue: "")
        _albumName = State(initialValue: "")
        _genreName = State(initialValue: "")
        _trackNumber = State(initialValue: track.trackNumber.map(String.init) ?? "")
        _discNumber = State(initialValue: track.discNumber.map(String.init) ?? "")
        _year = State(initialValue: track.year.map(String.init) ?? "")
        _comment = State(initialValue: track.comment ?? "")
        _lyrics = State(initialValue: track.lyrics?.rawText ?? "")
    }

    var body: some View {
        Form {
            Section(L("基本信息")) {
                TextField(L("标题"), text: $title)
                    .accessibilityIdentifier("library.trackEditor.title")
                TextField(L("艺人"), text: $artistName)
                TextField(L("专辑艺人"), text: $albumArtistName)
                TextField(L("专辑"), text: $albumName)
                TextField(L("流派"), text: $genreName)
            }

            Section(L("编号与年份")) {
                TextField(L("曲目号"), text: $trackNumber)
                    .keyboardType(.numberPad)
                TextField(L("碟片号"), text: $discNumber)
                    .keyboardType(.numberPad)
                TextField(L("年份"), text: $year)
                    .keyboardType(.numberPad)
            }

            Section(L("评论")) {
                TextEditor(text: $comment)
                    .frame(minHeight: 90)
            }

            Section {
                TextEditor(text: $lyrics)
                    .frame(minHeight: 180)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("library.trackEditor.lyrics")
            } header: {
                Text(L("歌词"))
            } footer: {
                Text(L("支持普通歌词和带时间轴的 LRC 文本。保存后仅覆盖 App 资料库，不会改写原始音频标签。"))
            }

            Section(L("封面")) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(L("选择封面"), systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("library.trackEditor.coverPicker")

                if track.artwork != nil || artworkEdit != .keep {
                    Button(L("移除封面"), role: .destructive) {
                        selectedPhoto = nil
                        selectedPhotoLoadID = UUID()
                        isLoadingArtwork = false
                        artworkEdit = .remove
                    }
                }

                if case .replace = artworkEdit {
                    Label(L("已选择新封面"), systemImage: "checkmark.circle")
                        .foregroundStyle(MusicFreeColorTokens.accent)
                } else if artworkEdit == .remove {
                    Label(L("保存后移除当前封面"), systemImage: "trash")
                        .foregroundStyle(MusicFreeColorTokens.destructive)
                } else if track.artwork != nil {
                    Text(L("当前封面将保留。"))
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }
            }
        }
        .navigationTitle(L("编辑歌曲"))
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
                            || isLoadingArtwork
                            || isLoadingRelatedNames
                            || !isRelatedNamesLoaded
                            || relatedNamesLoadFailed
                    )
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            selectedPhotoLoadID = UUID()
            isLoadingArtwork = item != nil
        }
        .task(id: selectedPhotoLoadID) {
            let loadID = selectedPhotoLoadID
            guard let item = selectedPhoto else {
                isLoadingArtwork = false
                return
            }

            isLoadingArtwork = true
            defer {
                if loadID == selectedPhotoLoadID {
                    isLoadingArtwork = false
                }
            }

            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      !data.isEmpty
                else { return }
                try Task.checkCancellation()
                guard loadID == selectedPhotoLoadID else { return }
                artworkEdit = .replace(data)
            } catch is CancellationError {
                return
            } catch {
                // A provider failure leaves the previous artwork choice intact.
            }
        }
        .alert(
            L("无法保存歌曲"),
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
            let resolvedArtistNames = try await loadArtistNames(for: track.artistIDs)
            var resolvedAlbumName: String?
            var resolvedAlbumArtistNames: [String]?

            if let albumID = track.albumID {
                guard let album = try await LibraryAlbumLoader.load(
                    albumID: albumID,
                    sourceID: track.id.sourceID,
                    from: library
                ) else {
                    throw RelatedNamesLoadError.missingRelationship
                }
                resolvedAlbumName = album.title
                resolvedAlbumArtistNames = try await loadArtistNames(for: album.artistIDs)
            }

            let resolvedGenreNames = try await loadGenreNames(for: track.genreIDs)

            artistName = TrackMetadataEditorRelationshipNames.displayNames(resolvedArtistNames)
            originalArtistNames = resolvedArtistNames
            albumName = resolvedAlbumName ?? ""
            originalAlbumArtistNames = resolvedAlbumArtistNames
            albumArtistName = TrackMetadataEditorRelationshipNames.displayNames(resolvedAlbumArtistNames ?? [])
            genreName = TrackMetadataEditorRelationshipNames.displayNames(resolvedGenreNames)
            originalGenreNames = resolvedGenreNames
            isRelatedNamesLoaded = true
            isLoadingRelatedNames = false
        } catch is CancellationError {
            // A cancelled lookup must never turn the editor into a destructive
            // save path with unresolved relationship names.
            isRelatedNamesLoaded = false
        } catch {
            isRelatedNamesLoaded = false
            isLoadingRelatedNames = false
            relatedNamesLoadFailed = true
            errorMessage = L("无法读取歌曲的艺人、专辑或流派信息，未保存任何修改。")
        }
    }

    private func loadArtistNames(for ids: [ArtistID]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let names = try await LibraryArtistNameLoader.load(
            artistIDs: Set(ids),
            sourceID: track.id.sourceID,
            from: library
        )
        guard names.count == Set(ids).count else {
            throw RelatedNamesLoadError.missingRelationship
        }
        return ids.compactMap { names[$0] }
    }

    private func loadGenreNames(for ids: [GenreID]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let names = try await LibraryGenreNameLoader.load(
            genreIDs: Set(ids),
            sourceID: track.id.sourceID,
            from: library
        )
        guard names.count == Set(ids).count else {
            throw RelatedNamesLoadError.missingRelationship
        }
        return ids.compactMap { names[$0] }
    }

    private func save() {
        guard !isSaving,
              !isLoadingRelatedNames,
              !isLoadingArtwork,
              isRelatedNamesLoaded,
              !relatedNamesLoadFailed
        else { return }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            errorMessage = L("标题不能为空。")
            return
        }

        guard isValidOptionalPositive(trackNumber),
              isValidOptionalPositive(discNumber),
              isValidOptionalYear(year)
        else {
            errorMessage = L("曲目号、碟片号和年份必须是有效数字。")
            return
        }

        let parsedTrackNumber = parsePositive(trackNumber)
        let parsedDiscNumber = parsePositive(discNumber)
        let parsedYear = parseYear(year)
        let updatedArtistNames = TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: originalArtistNames,
            currentValue: artistName
        )
        let updatedAlbumArtistNames = TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: originalAlbumArtistNames,
            currentValue: albumArtistName
        )
        let updatedGenreNames = TrackMetadataEditorRelationshipNames.forUpdate(
            originalNames: originalGenreNames,
            currentValue: genreName
        )

        isSaving = true
        let update = TrackMetadataUpdate(
            itemID: track.id,
            title: normalizedTitle,
            artistName: artistName,
            artistNames: updatedArtistNames,
            albumArtistName: albumArtistName,
            albumArtistNames: updatedAlbumArtistNames,
            albumName: albumName,
            genreName: genreName,
            genreNames: updatedGenreNames,
            trackNumber: parsedTrackNumber,
            discNumber: parsedDiscNumber,
            year: parsedYear,
            comment: comment,
            lyrics: lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : TrackLyrics(rawText: lyrics),
            artwork: artworkEdit
        )
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let updated = try await library.updateMetadata(update)
                onSaved(updated)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func parsePositive(_ value: String) -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty || (Int(normalized) ?? 0) > 0 else { return nil }
        return normalized.isEmpty ? nil : Int(normalized)
    }

    private func isValidOptionalPositive(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        guard let number = Int(normalized) else { return false }
        return number > 0
    }

    private func isValidOptionalYear(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        guard let year = Int(normalized) else { return false }
        return (1...9_999).contains(year)
    }

    private func parseYear(_ value: String) -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty else {
            guard let year = Int(normalized), (1...9_999).contains(year) else { return nil }
            return year
        }
        return nil
    }

    private enum RelatedNamesLoadError: Error {
        case missingRelationship
    }
}

enum TrackMetadataEditorRelationshipNames {
    static func forUpdate(
        originalNames: [String]?,
        currentValue: String
    ) -> [String]? {
        if let originalNames {
            guard displayNames(originalNames) != currentValue else {
                return originalNames
            }
            return split(currentValue)
        }

        // A missing album has no album-artist relationship to clear. Keep nil
        // for an untouched blank field so the service can apply its default
        // album-artist fallback when the user creates an album.
        let names = split(currentValue)
        return names.isEmpty ? nil : names
    }

    static func displayNames(_ names: [String]) -> String {
        names.joined(separator: " / ")
    }

    private static func split(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct TrackTechnicalDetailsView: View {
    let track: Track

    private var rows: [(String, String)] {
        var values: [(String, String)] = []
        if let container = track.technicalInfo?.container { values.append((L("容器"), container)) }
        if let codec = track.technicalInfo?.codec { values.append((L("编码"), codec)) }
        if let bitRate = track.technicalInfo?.bitRate { values.append((L("码率"), formatBitRate(bitRate))) }
        if let sampleRate = track.technicalInfo?.sampleRate { values.append((L("采样率"), "\(sampleRate) Hz")) }
        if let bitDepth = track.technicalInfo?.bitDepth { values.append((L("位深"), "\(bitDepth) bit")) }
        if let stream = track.technicalInfo?.primaryAudioStream,
           let channels = stream.channels {
            values.append((L("声道"), stream.channelLayout?.name ?? L("%d 声道", channels)))
        }
        if let size = track.technicalInfo?.fileSizeBytes {
            values.append((L("文件大小"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let relativePath = track.relativePath { values.append((L("文件位置"), relativePath)) }
        if let year = track.year { values.append((L("年份"), String(year))) }
        if let comment = track.comment { values.append((L("评论"), comment)) }
        return values
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
                Text(L("技术详情"))
                    .font(.headline)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: MusicFreeSpacingTokens.medium) {
                        Text(row.0)
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                            .frame(width: 82, alignment: .leading)
                        Text(row.1)
                            .foregroundStyle(MusicFreeColorTokens.foregroundPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MusicFreeSpacingTokens.medium)
            .background(MusicFreeColorTokens.backgroundSecondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func formatBitRate(_ value: Int) -> String {
        value >= 1_000_000
            ? String(format: "%.1f Mbps", Double(value) / 1_000_000)
            : String(format: "%.1f kbps", Double(value) / 1_000)
    }
}
