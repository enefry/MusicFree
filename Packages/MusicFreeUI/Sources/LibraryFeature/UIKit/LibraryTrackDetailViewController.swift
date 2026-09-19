import AppServices
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit

/// Native UIKit detail surface for one library track.
@MainActor
public final class LibraryTrackDetailViewController: UIViewController {
    public let trackID: MediaItemID
    public let library: any LibraryServing
    public let artworkServing: (any ArtworkServing)?
    public var onPlayTrack: ((MediaItemID) -> Void)?
    public var onAddToPlaylist: (([MediaItemID]) -> Void)?
    public var onDeleted: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let artworkView = MusicFreeUIKitArtworkView(fillsAvailableWidth: true)
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let albumLabel = UILabel()
    private let durationLabel = UILabel()
    private let playButton = MusicFreeUIKitPillActionButton(title: L("播放歌曲"), systemImage: "play.fill")
    private let favoriteButton = UIButton(type: .system)
    private let lyricsTitleLabel = UILabel()
    private let lyricsLabel = UILabel()
    private var statusView: UIView?
    private var loadTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var track: Track?
    private var artistNames: [ArtistID: String] = [:]
    private var albumTitle: String?
    private var isSavingFavorite = false
    private var isDeleting = false

    public init(
        trackID: MediaItemID,
        library: any LibraryServing,
        artworkServing: (any ArtworkServing)? = nil
    ) {
        self.trackID = trackID
        self.library = library
        self.artworkServing = artworkServing
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "library.trackDetail.uikit"
        title = L("歌曲详情")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.trackDetail"
        navigationItem.largeTitleDisplayMode = .never
        configureContent()
        configureNavigationItems()
        renderLoading()
        loadTask = Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    public override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        scrollView
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        artworkTask?.cancel()
    }

    deinit {
        loadTask?.cancel()
        artworkTask?.cancel()
    }

    private func configureContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "library.trackDetail.scroll"

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = MusicFreeSpacingTokens.large
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.setContentHuggingPriority(.required, for: .vertical)
        artworkView.accessibilityIdentifier = "library.trackDetail.artwork"

        titleLabel.font = MusicFreeUIFontTokens.screenTitle
        titleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 3
        titleLabel.accessibilityIdentifier = "library.trackDetail.title"

        artistLabel.font = MusicFreeUIFontTokens.sectionTitle
        artistLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        artistLabel.textAlignment = .center
        artistLabel.numberOfLines = 2
        artistLabel.accessibilityIdentifier = "library.trackDetail.artist"

        albumLabel.font = MusicFreeUIFontTokens.rowSubtitle
        albumLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        albumLabel.textAlignment = .center
        albumLabel.numberOfLines = 2
        albumLabel.accessibilityIdentifier = "library.trackDetail.album"

        durationLabel.font = MusicFreeUIFontTokens.rowSubtitle
        durationLabel.textColor = MusicFreeUIColorTokens.foregroundTertiary
        durationLabel.textAlignment = .center
        durationLabel.accessibilityIdentifier = "library.trackDetail.duration"

        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        favoriteButton.titleLabel?.font = MusicFreeUIFontTokens.rowTitle
        favoriteButton.configuration = .filled()
        favoriteButton.configuration?.cornerStyle = .capsule
        favoriteButton.configuration?.baseBackgroundColor = MusicFreeUIColorTokens.accentSoft
        favoriteButton.configuration?.baseForegroundColor = MusicFreeUIColorTokens.accent
        favoriteButton.addTarget(self, action: #selector(toggleFavorite), for: .touchUpInside)
        favoriteButton.accessibilityIdentifier = "library.trackDetail.favorite"
        favoriteButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        let actionStack = UIStackView(arrangedSubviews: [playButton, favoriteButton])
        actionStack.axis = .horizontal
        actionStack.spacing = MusicFreeSpacingTokens.small
        actionStack.distribution = .fillEqually
        playButton.onPrimaryAction = { [weak self] in
            guard let self else { return }
            self.onPlayTrack?(self.trackID)
        }

        lyricsTitleLabel.font = MusicFreeUIFontTokens.sectionTitle
        lyricsTitleLabel.textColor = MusicFreeUIColorTokens.foregroundPrimary
        lyricsTitleLabel.text = L("歌词")
        lyricsTitleLabel.accessibilityIdentifier = "library.trackDetail.lyrics.title"

        lyricsLabel.font = MusicFreeUIFontTokens.rowTitle
        lyricsLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        lyricsLabel.numberOfLines = 0
        lyricsLabel.lineBreakMode = .byWordWrapping
        lyricsLabel.accessibilityIdentifier = "library.trackDetail.lyrics"

        let lyricsStack = UIStackView(arrangedSubviews: [lyricsTitleLabel, lyricsLabel])
        lyricsStack.axis = .vertical
        lyricsStack.spacing = MusicFreeSpacingTokens.small
        lyricsStack.isLayoutMarginsRelativeArrangement = true
        lyricsStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.medium,
            leading: MusicFreeSpacingTokens.medium,
            bottom: MusicFreeSpacingTokens.medium,
            trailing: MusicFreeSpacingTokens.medium
        )
        lyricsStack.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        lyricsStack.layer.cornerRadius = 10
        lyricsStack.layer.masksToBounds = true

        contentStack.addArrangedSubview(artworkView)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(artistLabel)
        contentStack.addArrangedSubview(albumLabel)
        contentStack.addArrangedSubview(durationLabel)
        contentStack.addArrangedSubview(actionStack)
        contentStack.addArrangedSubview(lyricsStack)

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: MusicFreeSpacingTokens.contentInset),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -MusicFreeSpacingTokens.contentInset),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: MusicFreeSpacingTokens.large),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -MusicFreeSpacingTokens.large),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * MusicFreeSpacingTokens.contentInset),
            artworkView.widthAnchor.constraint(lessThanOrEqualToConstant: 310),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
            artworkView.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor),
            artworkView.heightAnchor.constraint(lessThanOrEqualToConstant: 310)
        ])
    }

    private func configureNavigationItems() {
        let addItem = UIBarButtonItem(
            image: UIImage(systemName: "text.badge.plus"),
            style: .plain,
            target: self,
            action: #selector(addToPlaylist)
        )
        addItem.accessibilityLabel = L("添加到播放列表")
        addItem.accessibilityIdentifier = "library.trackDetail.addToPlaylist"

        let editItem = UIBarButtonItem(
            image: UIImage(systemName: "pencil"),
            style: .plain,
            target: self,
            action: #selector(editTrack)
        )
        editItem.accessibilityLabel = L("编辑歌曲")
        editItem.accessibilityIdentifier = "library.trackDetail.edit"

        let deleteItem = UIBarButtonItem(
            barButtonSystemItem: .trash,
            target: self,
            action: #selector(requestDelete)
        )
        deleteItem.accessibilityLabel = L("删除歌曲")
        deleteItem.accessibilityIdentifier = "library.trackDetail.delete"
        // Keep the action order aligned with the reference: destructive
        // delete, metadata edit, then add-to-playlist.
        navigationItem.rightBarButtonItems = [deleteItem, editItem, addItem]
    }

    private func renderLoading() {
        installStatusView(MusicFreeUIKitLoadingStateView(label: L("加载歌曲")))
    }

    private func renderFailure(_ message: String) {
        installStatusView(
            MusicFreeUIKitErrorStateView(
                message: message,
                retryTitle: L("重试"),
                retry: { [weak self] in self?.reload() }
            )
        )
    }

    private func installStatusView(_ status: UIView) {
        statusView?.removeFromSuperview()
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.topAnchor.constraint(equalTo: view.topAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        statusView = status
        scrollView.isHidden = true
    }

    private func renderLoaded() {
        statusView?.removeFromSuperview()
        statusView = nil
        scrollView.isHidden = false
        guard let track else { return }

        title = track.title
        titleLabel.text = track.title
        let names = track.artistIDs.compactMap { artistNames[$0] }
        artistLabel.text = names.isEmpty ? nil : names.joined(separator: "、")
        artistLabel.isHidden = names.isEmpty
        albumLabel.text = albumTitle
        albumLabel.isHidden = albumTitle?.isEmpty != false
        if let duration = track.duration {
            let seconds = max(0, duration.components.seconds)
            durationLabel.text = L("时长 %@", String(format: "%d:%02d", seconds / 60, seconds % 60))
            durationLabel.isHidden = false
        } else {
            durationLabel.isHidden = true
        }
        lyricsLabel.text = track.lyrics?.displayText
        lyricsTitleLabel.superview?.isHidden = track.lyrics == nil
        playButton.isEnabled = onPlayTrack != nil
        favoriteButton.isEnabled = !isSavingFavorite
        favoriteButton.configuration?.title = track.isFavorite ? L("取消收藏") : L("收藏")
        favoriteButton.configuration?.image = UIImage(systemName: track.isFavorite ? "star.fill" : "star")
        favoriteButton.configuration?.imagePadding = MusicFreeSpacingTokens.xSmall

        artworkTask?.cancel()
        artworkView.placeholderTitle = track.title
        guard let artworkID = track.artworkID, let artworkServing else {
            artworkView.image = nil
            artworkView.isLoading = false
            return
        }
        let cachedImage = LibraryArtworkImagePipeline.shared.cachedImage(
            artworkID: artworkID,
            sourceID: track.id.sourceID,
            maximumPixelDimension: 1_024
        )
        artworkView.image = cachedImage
        artworkView.isLoading = cachedImage == nil
        artworkTask = Task { @MainActor [weak self] in
            do {
                let image = await LibraryArtworkImagePipeline.shared.image(
                    artworkID: artworkID,
                    sourceID: track.id.sourceID,
                    maximumPixelDimension: 1_024,
                    serving: artworkServing
                )
                guard let self, !Task.isCancelled, self.track?.id == track.id else { return }
                self.artworkView.isLoading = false
                self.artworkView.image = image
            } catch is CancellationError {
                return
            } catch {
                self?.artworkView.isLoading = false
            }
        }
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    private func load() async {
        renderLoading()
        do {
            guard let loadedTrack = try await library.track(id: trackID) else {
                throw TrackDetailError.notFound
            }
            try Task.checkCancellation()
            track = loadedTrack
            artistNames = (try? await LibraryArtistNameLoader.load(
                artistIDs: Set(loadedTrack.artistIDs),
                sourceID: loadedTrack.id.sourceID,
                from: library
            )) ?? [:]
            albumTitle = await resolveAlbumTitle(for: loadedTrack)
            try Task.checkCancellation()
            renderLoaded()
        } catch is CancellationError {
            return
        } catch {
            renderFailure(error.localizedDescription)
        }
    }

    private func resolveAlbumTitle(for track: Track) async -> String? {
        guard let albumID = track.albumID else { return nil }
        do {
            let page = try await library.browseAlbums(
                matching: AlbumQuery(sourceID: track.id.sourceID),
                page: try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            )
            return page.elements.first(where: { $0.id == albumID })?.title
        } catch {
            return nil
        }
    }

    @objc private func toggleFavorite() {
        guard let track, !isSavingFavorite else { return }
        isSavingFavorite = true
        favoriteButton.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSavingFavorite = false }
            do {
                self.track = try await self.library.setFavorite(!track.isFavorite, for: track.id)
                self.renderLoaded()
            } catch {
                self.presentMessage(title: L("无法更新收藏"), message: error.localizedDescription)
            }
        }
    }

    @objc private func addToPlaylist() {
        guard let track else { return }
        onAddToPlaylist?([track.id])
    }

    @objc private func editTrack() {
        guard let track, presentedViewController == nil else { return }

        let editor = LibraryTrackMetadataEditorViewController(
            track: track,
            library: library
        ) { [weak self] updatedTrack in
            guard let self else { return }
            self.track = updatedTrack
            self.renderLoaded()
        }
        let navigationController = UINavigationController(rootViewController: editor)
        navigationController.modalPresentationStyle = .pageSheet
        navigationController.navigationBar.prefersLargeTitles = false
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    @objc private func requestDelete() {
        guard let track, !isDeleting, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L("删除歌曲？"),
            message: L("删除后将从资料库移除这首歌曲。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            self?.deleteTrack(track)
        })
        present(alert, animated: true)
    }

    private func deleteTrack(_ track: Track) {
        guard !isDeleting else { return }
        isDeleting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isDeleting = false }
            do {
                _ = try await self.library.delete([track.id])
                self.onDeleted?()
                self.navigationController?.popViewController(animated: true)
            } catch {
                self.presentMessage(title: L("无法删除歌曲"), message: error.localizedDescription)
            }
        }
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }
}

private enum TrackDetailError: LocalizedError {
    case notFound

    var errorDescription: String? {
        L("找不到歌曲")
    }
}
