import AppServices
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PhotosUI
import UIKit

/// Native UIKit track metadata editor. Relationship names are resolved before
/// saving so the complete-replacement service contract is preserved.
@MainActor
public final class LibraryTrackMetadataEditorViewController: UIViewController,
    PHPickerViewControllerDelegate,
    UITextViewDelegate
{
    private let track: Track
    private let library: any LibraryServing
    private let artworkServing: (any ArtworkServing)?
    private let onSaved: (Track) -> Void
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let titleField = UITextField()
    private let artistField = UITextField()
    private let albumArtistField = UITextField()
    private let albumField = UITextField()
    private let genreField = UITextField()
    private let trackNumberField = UITextField()
    private let discNumberField = UITextField()
    private let yearField = UITextField()
    private let composerField = UITextField()
    private let additionalArtistField = UITextField()
    private let ratingControl = UISegmentedControl(items: TrackContentRating.allCases.map { LibraryMetadataForm.ratingTitle($0) })
    private let commentView = UITextView()
    private let lyricsView = UITextView()
    private let artworkStatusLabel = UILabel()
    private let artworkPreview = MusicFreeUIKitArtworkView()
    private var artworkTask: Task<Void, Never>?
    private var artworkVersion = UUID()
    private var isLoadingArtwork = false
    private let loadingView = MusicFreeUIKitLoadingStateView(label: L("加载歌曲关系信息"))
    private var originalArtistNames: [String]?
    private var originalAlbumArtistNames: [String]?
    private var originalGenreNames: [String]?
    private var artworkEdit: ArtworkEdit = .keep
    private var isRelatedNamesLoaded = false
    private var relatedNamesLoadFailed = false
    private var isSaving = false
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    public init(
        track: Track,
        library: any LibraryServing,
        artworkServing: (any ArtworkServing)? = nil,
        onSaved: @escaping (Track) -> Void
    ) {
        self.track = track
        self.library = library
        self.artworkServing = artworkServing
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        title = L("编辑歌曲")
        restorationIdentifier = "library.trackEditor.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "library.trackEditor"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L("取消"),
            style: .plain,
            target: self,
            action: #selector(dismissEditor)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L("保存"),
            style: .done,
            target: self,
            action: #selector(save)
        )
        configureContent()
        loadTask = Task { @MainActor [weak self] in
            await self?.loadRelatedNames()
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        saveTask?.cancel()
        artworkTask?.cancel()
    }

    deinit {
        loadTask?.cancel()
        saveTask?.cancel()
        artworkTask?.cancel()
    }

    private func configureContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "library.trackEditor.scroll"
        contentStack.axis = .vertical
        contentStack.spacing = MusicFreeSpacingTokens.medium
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        configure(titleField, placeholder: L("标题"), value: track.title)
        configure(artistField, placeholder: L("艺人"))
        configure(albumArtistField, placeholder: L("专辑艺人"))
        configure(albumField, placeholder: L("专辑"))
        configure(genreField, placeholder: L("流派"))
        configure(trackNumberField, placeholder: L("曲目号"), keyboard: .numberPad)
        configure(discNumberField, placeholder: L("碟片号"), keyboard: .numberPad)
        configure(yearField, placeholder: L("年份"), keyboard: .numberPad)
        trackNumberField.text = track.trackNumber.map(String.init)
        discNumberField.text = track.discNumber.map(String.init)
        yearField.text = track.year.map(String.init)
        configure(composerField, placeholder: L("作曲者"), value: track.details?.composers.joined(separator: "、"))
        configure(additionalArtistField, placeholder: L("其他艺人"), value: track.details?.additionalArtists.joined(separator: "、"))
        composerField.accessibilityIdentifier = "library.trackEditor.composers"
        additionalArtistField.accessibilityIdentifier = "library.trackEditor.additionalArtists"
        ratingControl.selectedSegmentIndex = TrackContentRating.allCases.firstIndex(of: track.details?.contentRating ?? .unknown) ?? 0
        ratingControl.accessibilityIdentifier = "library.trackEditor.contentRating"
        titleField.accessibilityIdentifier = "library.trackEditor.title"
        artistField.accessibilityIdentifier = "library.trackEditor.artist"
        albumArtistField.accessibilityIdentifier = "library.trackEditor.albumArtist"
        albumField.accessibilityIdentifier = "library.trackEditor.album"
        genreField.accessibilityIdentifier = "library.trackEditor.genre"

        commentView.configureEditorTextView()
        commentView.accessibilityIdentifier = "library.trackEditor.comment"
        lyricsView.configureEditorTextView()
        lyricsView.accessibilityIdentifier = "library.trackEditor.lyrics"
        commentView.text = track.comment ?? ""
        lyricsView.text = track.lyrics?.rawText ?? ""

        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("封面"), rows: [makeArtworkActionRow()]))
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("基本信息"), rows: [
            LibraryMetadataForm.row(L("标题"), control: titleField),
            LibraryMetadataForm.row(L("主要艺人"), control: artistField),
            LibraryMetadataForm.row(L("其他艺人"), control: additionalArtistField),
            LibraryMetadataForm.row(L("作曲者"), control: composerField),
            LibraryMetadataForm.row(L("专辑艺人"), control: albumArtistField),
            LibraryMetadataForm.row(L("专辑"), control: albumField),
            LibraryMetadataForm.row(L("流派"), control: genreField)
        ]))
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("编号与年份"), rows: [
            LibraryMetadataForm.row(L("曲目号"), control: trackNumberField),
            LibraryMetadataForm.row(L("碟片号"), control: discNumberField),
            LibraryMetadataForm.row(L("年份"), control: yearField)
        ]))
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("内容分级"), rows: [ratingControl]))
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("评论"), rows: [commentView]))
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("歌词"), rows: [lyricsView]))

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: MusicFreeSpacingTokens.large),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -MusicFreeSpacingTokens.large),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * MusicFreeSpacingTokens.contentInset),
            commentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            lyricsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        artworkStatusLabel.text = track.artwork == nil ? L("当前没有封面") : L("当前封面将保留")
    }

    private func configure(
        _ field: UITextField,
        placeholder: String,
        value: String? = nil,
        keyboard: UIKeyboardType = .default
    ) {
        field.borderStyle = .none
        field.placeholder = L("未设置")
        field.text = value
        field.keyboardType = keyboard
        field.clearButtonMode = .whileEditing
        field.font = MusicFreeUIFontTokens.body
        field.textAlignment = .right
        field.accessibilityLabel = placeholder
        field.textColor = MusicFreeUIColorTokens.foregroundPrimary
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget).isActive = true
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = MusicFreeUIFontTokens.sectionTitle
        label.textColor = MusicFreeUIColorTokens.foregroundPrimary
        label.text = text
        label.accessibilityTraits = [.header]
        return label
    }

    private func makeArtworkActionRow() -> UIView {
        let pickButton = UIButton(type: .system)
        pickButton.setTitle(L("选择封面"), for: .normal)
        pickButton.setImage(UIImage(systemName: "photo.badge.plus"), for: .normal)
        pickButton.tintColor = MusicFreeUIColorTokens.accent
        pickButton.addTarget(self, action: #selector(pickArtwork), for: .touchUpInside)
        pickButton.accessibilityIdentifier = "library.trackEditor.coverPicker"

        let removeButton = UIButton(type: .system)
        removeButton.setTitle(L("移除封面"), for: .normal)
        removeButton.setImage(UIImage(systemName: "trash"), for: .normal)
        removeButton.tintColor = MusicFreeUIColorTokens.destructive
        removeButton.addTarget(self, action: #selector(removeArtwork), for: .touchUpInside)
        removeButton.accessibilityIdentifier = "library.trackEditor.coverRemove"

        artworkPreview.translatesAutoresizingMaskIntoConstraints = false
        artworkPreview.accessibilityIdentifier = "library.trackEditor.coverPreview"
        artworkPreview.placeholderTitle = track.title
        let previewContainer = UIView()
        previewContainer.addSubview(artworkPreview)
        NSLayoutConstraint.activate([
            artworkPreview.widthAnchor.constraint(equalToConstant: 160),
            artworkPreview.heightAnchor.constraint(equalTo: artworkPreview.widthAnchor),
            artworkPreview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            artworkPreview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            artworkPreview.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor)
        ])
        let stack = UIStackView(arrangedSubviews: [previewContainer, pickButton, removeButton, artworkStatusLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = MusicFreeSpacingTokens.small
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        artworkStatusLabel.numberOfLines = 0
        artworkStatusLabel.font = MusicFreeUIFontTokens.caption
        artworkStatusLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        if let artworkID = track.artworkID, let artworkServing {
            artworkPreview.image = LibraryArtworkImagePipeline.shared.cachedImage(
                artworkID: artworkID, sourceID: track.id.sourceID, maximumPixelDimension: 1_024
            )
            artworkTask = Task { @MainActor [weak self] in
                let image = try? await LibraryArtworkImagePipeline.shared.image(
                    artworkID: artworkID, sourceID: self?.track.id.sourceID ?? .local,
                    maximumPixelDimension: 1_024, serving: artworkServing
                )
                guard let self, !Task.isCancelled else { return }
                artworkPreview.image = image
            }
        }
        return stack
    }

    private func loadRelatedNames() async {
        do {
            let artists = try await loadArtistNames(for: track.artistIDs)
            var albumName = ""
            var albumArtists: [String]?
            if let albumID = track.albumID {
                guard let album = try await LibraryAlbumLoader.load(
                    albumID: albumID,
                    sourceID: track.id.sourceID,
                    from: library
                ) else { throw RelatedNamesLoadError.missingRelationship }
                albumName = album.title
                albumArtists = try await loadArtistNames(for: album.artistIDs)
            }
            let genres = try await loadGenreNames(for: track.genreIDs)
            originalArtistNames = artists
            originalAlbumArtistNames = albumArtists
            originalGenreNames = genres
            artistField.text = TrackMetadataEditorRelationshipNames.displayNames(artists)
            albumArtistField.text = TrackMetadataEditorRelationshipNames.displayNames(albumArtists ?? [])
            albumField.text = albumName
            genreField.text = TrackMetadataEditorRelationshipNames.displayNames(genres)
            isRelatedNamesLoaded = true
            loadingView.isLoading = false
            updateSaveAvailability()
        } catch is CancellationError {
            return
        } catch {
            relatedNamesLoadFailed = true
            loadingView.isLoading = false
            updateSaveAvailability()
            presentMessage(title: L("无法读取歌曲关系信息"), message: L("无法读取歌曲的艺人、专辑或流派信息，未保存任何修改。"))
        }
    }

    private func loadArtistNames(for ids: [ArtistID]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let names = try await LibraryArtistNameLoader.load(
            artistIDs: Set(ids), sourceID: track.id.sourceID, from: library
        )
        guard names.count == Set(ids).count else { throw RelatedNamesLoadError.missingRelationship }
        return ids.compactMap { names[$0] }
    }

    private func loadGenreNames(for ids: [GenreID]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let names = try await LibraryGenreNameLoader.load(
            genreIDs: Set(ids), sourceID: track.id.sourceID, from: library
        )
        guard names.count == Set(ids).count else { throw RelatedNamesLoadError.missingRelationship }
        return ids.compactMap { names[$0] }
    }

    private func updateSaveAvailability() {
        navigationItem.rightBarButtonItem?.isEnabled = isRelatedNamesLoaded && !relatedNamesLoadFailed && !isSaving && !isLoadingArtwork
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        isModalInPresentation = isSaving
        contentStack.isUserInteractionEnabled = !isSaving
    }

    @objc private func pickArtwork() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self)
        else { return }
        isLoadingArtwork = true
        artworkVersion = UUID()
        let version = artworkVersion
        updateSaveAvailability()
        provider.loadDataRepresentation(forTypeIdentifier: "public.image") { [weak self] data, _ in
            Task { @MainActor [weak self] in
                guard let self, artworkVersion == version else { return }
                artworkTask?.cancel()
                artworkTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        if artworkVersion == version { isLoadingArtwork = false; updateSaveAvailability() }
                    }
                    do {
                        guard let data, !data.isEmpty, data.count <= ArtworkDataLimits.maximumByteCount else {
                            throw TrackArtworkError.invalidImage
                        }
                        let image = try await ArtworkImageDecoding.image(from: .inMemory(data), maximumPixelDimension: 1_024)
                        guard !Task.isCancelled, artworkVersion == version else { return }
                        artworkEdit = .replace(data)
                        artworkPreview.image = image
                        artworkStatusLabel.text = L("已选择新封面")
                    } catch {
                        guard !Task.isCancelled, artworkVersion == version else { return }
                        presentMessage(title: L("无法读取封面"), message: error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc private func removeArtwork() {
        artworkVersion = UUID()
        artworkTask?.cancel()
        isLoadingArtwork = false
        artworkEdit = .remove
        artworkPreview.image = nil
        artworkStatusLabel.text = L("保存后移除当前封面")
        updateSaveAvailability()
    }

    @objc private func save() {
        guard isRelatedNamesLoaded, !relatedNamesLoadFailed, !isSaving, !isLoadingArtwork else { return }
        let normalizedTitle = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedTitle.isEmpty else {
            presentMessage(title: L("无法保存歌曲"), message: L("标题不能为空。"))
            return
        }
        let trackNumber = parsePositive(trackNumberField.text)
        let discNumber = parsePositive(discNumberField.text)
        let year = parseYear(yearField.text)
        let rawTrackNumber = trackNumberField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawDiscNumber = discNumberField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawYear = yearField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (rawTrackNumber.isEmpty || trackNumber != nil),
              (rawDiscNumber.isEmpty || discNumber != nil),
              (rawYear.isEmpty || year != nil)
        else {
            presentMessage(title: L("无法保存歌曲"), message: L("曲目号、碟片号和年份必须是有效数字。"))
            return
        }

        let update = TrackMetadataUpdate(
            itemID: track.id,
            title: normalizedTitle,
            artistName: artistField.text,
            artistNames: TrackMetadataEditorRelationshipNames.forUpdate(originalNames: originalArtistNames, currentValue: artistField.text ?? ""),
            albumArtistName: albumArtistField.text,
            albumArtistNames: TrackMetadataEditorRelationshipNames.forUpdate(originalNames: originalAlbumArtistNames, currentValue: albumArtistField.text ?? ""),
            albumName: albumField.text,
            genreName: genreField.text,
            genreNames: TrackMetadataEditorRelationshipNames.forUpdate(originalNames: originalGenreNames, currentValue: genreField.text ?? ""),
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            comment: commentView.text,
            lyrics: lyricsView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : TrackLyrics(rawText: lyricsView.text),
            artwork: artworkEdit,
            details: TrackDetailMetadata(
                composers: LibraryMetadataForm.names(composerField.text),
                additionalArtists: LibraryMetadataForm.names(additionalArtistField.text),
                contentRating: TrackContentRating.allCases[max(0, ratingControl.selectedSegmentIndex)]
            )
        )
        isSaving = true
        updateSaveAvailability()
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSaving = false; updateSaveAvailability() }
            do {
                let updated = try await library.updateMetadata(update)
                onSaved(updated)
                dismiss(animated: true)
            } catch is CancellationError {
                return
            } catch {
                presentMessage(title: L("无法保存歌曲"), message: error.localizedDescription)
            }
        }
    }

    private func parsePositive(_ value: String?) -> Int? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, let number = Int(text), number > 0 else { return nil }
        return number
    }

    private func parseYear(_ value: String?) -> Int? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, let number = Int(text), (1...9_999).contains(number) else { return nil }
        return number
    }

    @objc private func dismissEditor() {
        guard !isSaving else { return }
        dismiss(animated: true)
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }

    public override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
        scrollView
    }
}

private enum RelatedNamesLoadError: Error {
    case missingRelationship
}

private enum TrackArtworkError: LocalizedError {
    case invalidImage
    var errorDescription: String? { L("图片为空、过大或无法读取。") }
}

private extension UITextView {
    func configureEditorTextView() {
        font = MusicFreeUIFontTokens.body
        textColor = MusicFreeUIColorTokens.foregroundPrimary
        backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        layer.cornerRadius = 10
        layer.masksToBounds = true
        textContainerInset = UIEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            left: MusicFreeSpacingTokens.small,
            bottom: MusicFreeSpacingTokens.small,
            right: MusicFreeSpacingTokens.small
        )
    }
}
