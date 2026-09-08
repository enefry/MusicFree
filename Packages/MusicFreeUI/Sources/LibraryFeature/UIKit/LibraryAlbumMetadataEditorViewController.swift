import AppServices
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PhotosUI
import UIKit

/// Native UIKit album metadata editor.
@MainActor
public final class LibraryAlbumMetadataEditorViewController: UIViewController,
    PHPickerViewControllerDelegate,
    UITextFieldDelegate
{
    private let metadataEnrichment: (any MetadataEnrichmentServing)?
    private let artworkServing: (any ArtworkServing)?
    private let album: Album
    private let library: any LibraryServing
    private let onSaved: (Album) -> Void
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let titleField = UITextField()
    private let artistField = UITextField()
    private let yearField = UITextField()
    private let artworkPreview = MusicFreeUIKitArtworkView(
        accessibilityLabel: "Album artwork",
        placeholderSystemImage: "music.note"
    )
    private let artworkStatusLabel = UILabel()
    private let refreshButton = UIButton(type: .system)
    private let refreshProgressView = UIProgressView(progressViewStyle: .default)
    private let refreshStatusLabel = UILabel()
    private let loadingView = MusicFreeUIKitLoadingStateView(label: L("加载专辑艺人信息"))
    private var originalArtistNames: [String]?
    private var artworkEdit: ArtworkEdit = .keep
    private var isRelatedNamesLoaded = false
    private var relatedNamesLoadFailed = false
    private var isSaving = false
    private var isRefreshing = false
    private var loadTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var baseContentInset = UIEdgeInsets.zero
    private var baseScrollIndicatorInsets = UIEdgeInsets.zero

    public init(
        album: Album,
        library: any LibraryServing,
        artworkServing: (any ArtworkServing)? = nil,
        metadataEnrichment: (any MetadataEnrichmentServing)? = nil,
        onSaved: @escaping (Album) -> Void
    ) {
        self.metadataEnrichment = metadataEnrichment
        self.artworkServing = artworkServing
        self.album = album
        self.library = library
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        title = L("编辑专辑")
        restorationIdentifier = "library.albumEditor.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "library.albumEditor"
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
        installKeyboardHandling()
        loadTask = Task { @MainActor [weak self] in
            await self?.loadRelatedNames()
        }
        artworkLoadTask = Task { @MainActor [weak self] in
            await self?.loadArtwork()
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        artworkLoadTask?.cancel()
        saveTask?.cancel()
        refreshTask?.cancel()
        removeKeyboardHandling()
    }

    deinit {
        loadTask?.cancel()
        artworkLoadTask?.cancel()
        saveTask?.cancel()
        refreshTask?.cancel()
    }

    private func configureContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.accessibilityIdentifier = "library.albumEditor.scroll"
        contentStack.axis = .vertical
        contentStack.spacing = MusicFreeSpacingTokens.large
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        titleField.configureEditorField(placeholder: L("未设置"), value: album.title)
        artistField.configureEditorField(placeholder: L("未设置"))
        yearField.configureEditorField(
            placeholder: L("未设置"),
            value: album.releaseYear.map(String.init),
            keyboard: .numberPad
        )
        titleField.accessibilityIdentifier = "library.albumEditor.title"
        artistField.accessibilityIdentifier = "library.albumEditor.artist"
        yearField.accessibilityIdentifier = "library.albumEditor.year"
        [titleField, artistField, yearField].forEach {
            $0.delegate = self
            $0.inputAccessoryView = makeKeyboardToolbar()
        }

        artworkPreview.translatesAutoresizingMaskIntoConstraints = false
        artworkPreview.accessibilityIdentifier = "library.albumEditor.coverPreview"
        artworkPreview.cornerRadius = 12
        artworkPreview.isLoading = album.artworkID != nil && artworkServing != nil
        artworkStatusLabel.font = MusicFreeUIFontTokens.caption
        artworkStatusLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        artworkStatusLabel.numberOfLines = 0
        artworkStatusLabel.textAlignment = .center
        artworkStatusLabel.text = album.artwork == nil ? L("当前没有封面") : L("当前封面将保留")

        refreshProgressView.isHidden = true
        refreshProgressView.accessibilityIdentifier = "library.albumEditor.refreshProgress"
        refreshProgressView.progressTintColor = MusicFreeUIColorTokens.accent
        refreshProgressView.trackTintColor = MusicFreeUIColorTokens.surfaceElevated
        refreshStatusLabel.font = MusicFreeUIFontTokens.caption
        refreshStatusLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        refreshStatusLabel.numberOfLines = 0
        refreshStatusLabel.text = L("重新匹配该专辑下全部歌曲的远端资料")

        contentStack.addArrangedSubview(makeFormSection(
            title: L("基本信息"),
            rows: [
                makeFieldRow(label: L("专辑名称"), field: titleField),
                makeFieldRow(label: L("专辑艺人"), field: artistField)
            ]
        ))
        contentStack.addArrangedSubview(makeFormSection(
            title: L("发行信息"),
            rows: [makeFieldRow(label: L("年份"), field: yearField)]
        ))
        contentStack.addArrangedSubview(makeFormSection(
            title: L("封面"),
            content: makeArtworkContent()
        ))
        if metadataEnrichment != nil {
            contentStack.addArrangedSubview(makeFormSection(
                title: L("远端源信息"),
                content: makeRefreshContent()
            ))
        }

        let noteLabel = UILabel()
        noteLabel.font = MusicFreeUIFontTokens.caption
        noteLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        noteLabel.numberOfLines = 0
        noteLabel.text = L("修改将应用到该专辑下的全部歌曲，仅覆盖 App 资料库，不会改写原始音频标签。")
        contentStack.addArrangedSubview(noteLabel)

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: MusicFreeSpacingTokens.contentInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -MusicFreeSpacingTokens.contentInset
            ),
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: MusicFreeSpacingTokens.large
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -MusicFreeSpacingTokens.large
            ),
            contentStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -2 * MusicFreeSpacingTokens.contentInset
            ),
            artworkPreview.widthAnchor.constraint(equalToConstant: 180),
            artworkPreview.heightAnchor.constraint(equalTo: artworkPreview.widthAnchor)
        ])
        baseContentInset = scrollView.contentInset
        baseScrollIndicatorInsets = scrollView.verticalScrollIndicatorInsets

        loadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let dismissKeyboardTap = UITapGestureRecognizer(
            target: self,
            action: #selector(dismissKeyboard)
        )
        dismissKeyboardTap.cancelsTouchesInView = false
        view.addGestureRecognizer(dismissKeyboardTap)
    }

    private func makeFormSection(title: String, rows: [UIView]) -> UIView {
        let content = UIView()
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        for index in 0..<(rows.count - 1) {
            let separator = UIView()
            separator.backgroundColor = MusicFreeUIColorTokens.separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
                separator.topAnchor.constraint(equalTo: rows[index].bottomAnchor)
            ])
        }
        return makeSectionContainer(title: title, content: makeFormCard(content: content))
    }

    private func makeFormSection(title: String, content: UIView) -> UIView {
        makeSectionContainer(title: title, content: makeFormCard(content: content))
    }

    private func makeSectionContainer(title: String, content: UIView) -> UIView {
        let stack = UIStackView(arrangedSubviews: [sectionLabel(title), content])
        stack.axis = .vertical
        stack.spacing = MusicFreeSpacingTokens.small
        return stack
    }

    private func makeFormCard(content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        card.layer.cornerRadius = 12
        card.layer.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func makeFieldRow(label: String, field: UITextField) -> UIView {
        let row = UIView()
        let labelView = UILabel()
        labelView.font = MusicFreeUIFontTokens.body
        labelView.textColor = MusicFreeUIColorTokens.foregroundPrimary
        labelView.text = label
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addSubview(labelView)
        row.addSubview(field)
        labelView.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            labelView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            labelView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.leadingAnchor.constraint(greaterThanOrEqualTo: labelView.trailingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget)
        ])
        return row
    }

    private func makeArtworkContent() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = MusicFreeSpacingTokens.small
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.addArrangedSubview(artworkPreview)

        let pickButton = UIButton(type: .system)
        pickButton.setTitle(L("选择封面"), for: .normal)
        pickButton.setImage(UIImage(systemName: "photo.badge.plus"), for: .normal)
        pickButton.tintColor = MusicFreeUIColorTokens.accent
        pickButton.addTarget(self, action: #selector(pickArtwork), for: .touchUpInside)
        pickButton.accessibilityIdentifier = "library.albumEditor.coverPicker"

        let removeButton = UIButton(type: .system)
        removeButton.setTitle(L("删除封面"), for: .normal)
        removeButton.setImage(UIImage(systemName: "trash"), for: .normal)
        removeButton.tintColor = MusicFreeUIColorTokens.destructive
        removeButton.addTarget(self, action: #selector(removeArtwork), for: .touchUpInside)
        removeButton.accessibilityIdentifier = "library.albumEditor.coverRemove"

        let actionStack = UIStackView(arrangedSubviews: [pickButton, removeButton])
        actionStack.axis = .horizontal
        actionStack.spacing = MusicFreeSpacingTokens.medium
        stack.addArrangedSubview(actionStack)
        stack.addArrangedSubview(artworkStatusLabel)
        return stack
    }

    private func makeRefreshContent() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = MusicFreeSpacingTokens.small
        stack.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.isLayoutMarginsRelativeArrangement = true
        refreshButton.setTitle(L("刷新专辑源信息"), for: .normal)
        refreshButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refreshButton.tintColor = MusicFreeUIColorTokens.accent
        refreshButton.contentHorizontalAlignment = .leading
        refreshButton.addTarget(self, action: #selector(refreshSourceMetadata), for: .touchUpInside)
        refreshButton.accessibilityIdentifier = "library.albumEditor.refreshSource"
        stack.addArrangedSubview(refreshButton)
        stack.addArrangedSubview(refreshProgressView)
        stack.addArrangedSubview(refreshStatusLabel)
        return stack
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = MusicFreeUIFontTokens.secondary
        label.textColor = MusicFreeUIColorTokens.foregroundSecondary
        label.text = text
        label.accessibilityTraits = [.header]
        return label
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
            originalArtistNames = names
            artistField.text = TrackMetadataEditorRelationshipNames.displayNames(names)
            isRelatedNamesLoaded = true
            loadingView.isLoading = false
            updateSaveAvailability()
        } catch is CancellationError {
            return
        } catch {
            relatedNamesLoadFailed = true
            loadingView.isLoading = false
            updateSaveAvailability()
            presentMessage(
                title: L("无法读取专辑艺人信息"),
                message: L("无法读取专辑艺人信息，未保存任何修改。")
            )
        }
    }

    private func loadArtwork() async {
        guard let artworkID = album.artworkID, let artworkServing else {
            artworkPreview.image = nil
            artworkPreview.isLoading = false
            return
        }
        let cachedImage = LibraryArtworkImagePipeline.shared.cachedImage(
            artworkID: artworkID,
            sourceID: .local,
            maximumPixelDimension: 1_024
        )
        artworkPreview.image = cachedImage
        artworkPreview.isLoading = cachedImage == nil
        do {
            let image = await LibraryArtworkImagePipeline.shared.image(
                artworkID: artworkID,
                sourceID: .local,
                maximumPixelDimension: 1_024,
                serving: artworkServing
            )
            try Task.checkCancellation()
            artworkPreview.image = image
            artworkPreview.isLoading = false
            if image == nil {
                artworkStatusLabel.text = L("当前封面无法读取")
            }
        } catch is CancellationError {
            return
        } catch {
            artworkPreview.isLoading = false
            artworkStatusLabel.text = L("当前封面无法读取")
        }
    }

    private func updateSaveAvailability() {
        navigationItem.rightBarButtonItem?.isEnabled = isRelatedNamesLoaded
            && !relatedNamesLoadFailed
            && !isSaving
            && !isRefreshing
        refreshButton.isEnabled = !isSaving && !isRefreshing
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
        provider.loadDataRepresentation(forTypeIdentifier: "public.image") { [weak self] data, _ in
            guard let data, !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                artworkEdit = .replace(data)
                artworkPreview.isLoading = true
                artworkStatusLabel.text = L("正在载入新封面")
                do {
                    artworkPreview.image = try await ArtworkImageDecoding.image(
                        from: .inMemory(data),
                        maximumPixelDimension: 1_024
                    )
                    artworkPreview.isLoading = false
                    artworkStatusLabel.text = L("已选择新封面")
                } catch is CancellationError {
                    return
                } catch {
                    artworkPreview.isLoading = false
                    artworkStatusLabel.text = L("新封面无法读取")
                }
            }
        }
    }

    @objc private func removeArtwork() {
        artworkEdit = .remove
        artworkPreview.image = nil
        artworkPreview.isLoading = false
        artworkStatusLabel.text = L("保存后删除当前封面")
    }

    @objc private func refreshSourceMetadata() {
        guard let metadataEnrichment, !isSaving, !isRefreshing else { return }
        let alert = UIAlertController(
            title: L("刷新专辑源信息"),
            message: L("将使用当前专辑名称重新匹配该专辑下全部歌曲，并覆盖远端返回的歌曲资料。远端没有返回的字段会保留当前值。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("刷新"), style: .default) { [weak self] _ in
            guard let self else { return }
            isRefreshing = true
            refreshProgressView.isHidden = false
            refreshProgressView.progress = 0
            refreshStatusLabel.text = L("正在读取专辑歌曲")
            updateSaveAvailability()
            refreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    isRefreshing = false
                    updateSaveAvailability()
                }
                do {
                    let tracks = try await loadAllAlbumTracks()
                    guard !tracks.isEmpty else {
                        refreshProgressView.isHidden = true
                        refreshStatusLabel.text = L("该专辑没有可刷新的歌曲")
                        return
                    }
                    let latestAlbumName: String
                    if let editedAlbumName = titleField.text?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !editedAlbumName.isEmpty
                    {
                        latestAlbumName = editedAlbumName
                    } else {
                        latestAlbumName = album.title
                    }
                    refreshStatusLabel.text = L("正在刷新 0/%d 首歌曲", tracks.count)
                    let progressHandler: @Sendable (MetadataEnrichmentRefreshProgress) -> Void = {
                        [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            refreshProgressView.progress = progress.total == 0
                                ? 0
                                : Float(progress.processed) / Float(progress.total)
                            refreshStatusLabel.text = L(
                                "正在刷新 %d/%d 首歌曲",
                                progress.processed,
                                progress.total
                            )
                        }
                    }
                    let result = try await metadataEnrichment.refresh(
                        itemIDs: Set(tracks.map(\.id)),
                        albumName: latestAlbumName,
                        progress: progressHandler
                    )
                    refreshProgressView.progress = 1
                    refreshStatusLabel.text = L("刷新完成，共处理 %d 首歌曲", result.total)
                    presentMessage(
                        title: L("专辑源信息已刷新"),
                        message: L(
                            "已匹配 %d 首，未匹配 %d 首，结果不明确 %d 首，失败 %d 首，跳过 %d 首。",
                            result.matched,
                            result.noMatch,
                            result.ambiguous,
                            result.failed,
                            result.skipped
                        )
                    )
                } catch is CancellationError {
                    return
                } catch {
                    refreshStatusLabel.text = L("刷新失败")
                    presentMessage(title: L("无法刷新专辑源信息"), message: error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func loadAllAlbumTracks() async throws -> [Track] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var seenCursors = Set<LibraryCursor>()
        var tracks: [Track] = []
        while true {
            try Task.checkCancellation()
            let page = try await library.browseTracks(
                matching: TrackQuery(sourceID: .local, albumID: album.id),
                page: request
            )
            try Task.checkCancellation()
            tracks.append(contentsOf: page.elements)
            guard let nextRequest = try page.nextPage(limit: request.limit) else {
                return tracks
            }
            guard let cursor = nextRequest.cursor,
                  seenCursors.insert(cursor).inserted
            else {
                throw AlbumMetadataRefreshLoadError.repeatedCursor
            }
            request = nextRequest
        }
    }

    @objc private func save() {
        guard isRelatedNamesLoaded, !relatedNamesLoadFailed, !isSaving, !isRefreshing else { return }
        let normalizedTitle = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedTitle.isEmpty else {
            presentMessage(title: L("无法保存专辑"), message: L("专辑名称不能为空。"))
            return
        }
        let yearText = yearField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard yearText.isEmpty || (Int(yearText).map { (1...9_999).contains($0) } == true) else {
            presentMessage(title: L("无法保存专辑"), message: L("年份必须是有效数字。"))
            return
        }
        dismissKeyboard()
        let update = AlbumMetadataUpdate(
            albumID: album.id,
            title: normalizedTitle,
            artistNames: TrackMetadataEditorRelationshipNames.forUpdate(
                originalNames: originalArtistNames,
                currentValue: artistField.text ?? ""
            ),
            releaseYear: yearText.isEmpty ? nil : Int(yearText),
            artwork: artworkEdit
        )
        isSaving = true
        updateSaveAvailability()
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                isSaving = false
                updateSaveAvailability()
            }
            do {
                let updated = try await library.updateAlbumMetadata(update)
                onSaved(updated)
                dismiss(animated: true)
            } catch is CancellationError {
                return
            } catch {
                presentMessage(title: L("无法保存专辑"), message: error.localizedDescription)
            }
        }
    }

    @objc private func dismissEditor() {
        guard !isSaving, !isRefreshing else { return }
        dismissKeyboard()
        dismiss(animated: true)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func makeKeyboardToolbar() -> UIToolbar {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(
                title: L("完成"),
                style: .done,
                target: self,
                action: #selector(dismissKeyboard)
            )
        ]
        return toolbar
    }

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func installKeyboardHandling() {
        let center = NotificationCenter.default
        keyboardObservers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = keyboardFrameChange(from: notification) else { return }
            Task { @MainActor [weak self, change] in
                self?.handleKeyboardFrameChange(change)
            }
        })
        keyboardObservers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let change = keyboardFrameChange(from: notification) else { return }
            Task { @MainActor [weak self, change] in
                self?.handleKeyboardFrameChange(change)
            }
        })
    }

    private func removeKeyboardHandling() {
        let center = NotificationCenter.default
        keyboardObservers.forEach(center.removeObserver)
        keyboardObservers.removeAll()
    }

    private func handleKeyboardFrameChange(_ change: KeyboardFrameChange) {
        let keyboardFrame = view.convert(change.frame, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        var contentInset = baseContentInset
        contentInset.bottom += overlap
        var indicatorInsets = baseScrollIndicatorInsets
        indicatorInsets.bottom += overlap
        let options = UIView.AnimationOptions(rawValue: change.curveRawValue << 16)
        UIView.animate(
            withDuration: change.duration,
            delay: 0,
            options: [options, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.scrollView.contentInset = contentInset
            self.scrollView.verticalScrollIndicatorInsets = indicatorInsets
            if overlap > 0, let responder = self.view.firstResponderDescendant {
                let rect = responder.convert(responder.bounds, to: self.scrollView)
                self.scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -16), animated: false)
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }

    public override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        scrollView
    }
}

private struct KeyboardFrameChange: Sendable {
    let frame: CGRect
    let duration: TimeInterval
    let curveRawValue: UInt
}

private func keyboardFrameChange(from notification: Notification) -> KeyboardFrameChange? {
    guard let userInfo = notification.userInfo,
          let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
    else { return nil }
    return KeyboardFrameChange(
        frame: frameValue.cgRectValue,
        duration: (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)
            .map { $0.doubleValue } ?? 0.25,
        curveRawValue: (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)
            .map { $0.uintValue } ?? 7
    )
}

private enum RelatedNamesLoadError: Error {
    case missingRelationship
}

private enum AlbumMetadataRefreshLoadError: LocalizedError {
    case repeatedCursor

    var errorDescription: String? {
        L("读取专辑歌曲分页失败，请稍后重试。")
    }
}

private extension UITextField {
    func configureEditorField(
        placeholder: String,
        value: String? = nil,
        keyboard: UIKeyboardType = .default
    ) {
        borderStyle = .none
        backgroundColor = .clear
        self.placeholder = placeholder
        text = value
        keyboardType = keyboard
        clearButtonMode = .whileEditing
        textAlignment = .right
        adjustsFontSizeToFitWidth = true
        minimumFontSize = 12
        font = MusicFreeUIFontTokens.body
        textColor = MusicFreeUIColorTokens.foregroundPrimary
        tintColor = MusicFreeUIColorTokens.accent
    }
}

private extension UIView {
    var firstResponderDescendant: UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.firstResponderDescendant {
                return responder
            }
        }
        return nil
    }
}
