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
    private let mediaShareResolver: LibraryMediaShareResolver?
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
    private let lyricsTitleLabel = UILabel()
    private let lyricsLabel = UILabel()
    private let informationView = LibraryDetailInfoView()
    private var statusView: UIView?
    private var loadTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?
    private var track: Track?
    private var artistNames: [ArtistID: String] = [:]
    private var albumTitle: String?
    private var albumArtistNames: [String] = []
    private var genreNames: [String] = []
    private var dateAdded: Date?
    private var isSavingFavorite = false
    private var isDeleting = false

    public init(
        trackID: MediaItemID,
        library: any LibraryServing,
        artworkServing: (any ArtworkServing)? = nil,
        mediaSourceResolver: (any MediaSourceResolving)? = nil
    ) {
        self.trackID = trackID
        self.library = library
        self.artworkServing = artworkServing
        mediaShareResolver = mediaSourceResolver.map {
            LibraryMediaShareResolver(sourceResolver: $0)
        }
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
        shareTask?.cancel()
    }

    deinit {
        loadTask?.cancel()
        artworkTask?.cancel()
        shareTask?.cancel()
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
        titleLabel.numberOfLines = 0
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

        let actionStack = UIStackView(arrangedSubviews: [playButton])
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

        let artworkContainer = UIView()
        artworkContainer.addSubview(artworkView)
        let artworkWidth = artworkView.widthAnchor.constraint(equalTo: artworkContainer.widthAnchor)
        artworkWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            artworkWidth
        ])
        contentStack.addArrangedSubview(artworkContainer)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(artistLabel)
        contentStack.addArrangedSubview(albumLabel)
        contentStack.addArrangedSubview(durationLabel)
        contentStack.addArrangedSubview(actionStack)
        contentStack.addArrangedSubview(informationView)
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
        let favorite = UIAction(
            title: track?.isFavorite == true ? L("取消收藏") : L("收藏"),
            image: UIImage(systemName: track?.isFavorite == true ? "star.slash" : "star"),
            attributes: track == nil || isSavingFavorite || isDeleting ? [.disabled] : [],
            state: track?.isFavorite == true ? .on : .off
        ) { [weak self] _ in self?.toggleFavorite() }
        let share = UIAction(
            title: L("分享"),
            image: UIImage(systemName: "square.and.arrow.up"),
            attributes: track == nil || mediaShareResolver == nil || shareTask != nil || isDeleting
                ? [.disabled] : []
        ) { [weak self] _ in self?.shareTrack() }
        let add = UIAction(
            title: L("添加到播放列表"),
            image: UIImage(systemName: "text.badge.plus"),
            attributes: track == nil || onAddToPlaylist == nil || isDeleting ? [.disabled] : []
        ) { [weak self] _ in self?.addToPlaylist() }
        let edit = UIAction(
            title: L("编辑歌曲"),
            image: UIImage(systemName: "pencil"),
            attributes: track == nil || isDeleting ? [.disabled] : []
        ) { [weak self] _ in self?.editTrack() }
        let delete = UIAction(
            title: L("删除歌曲"),
            image: UIImage(systemName: "trash"),
            attributes: track == nil || isDeleting ? [.destructive, .disabled] : [.destructive]
        ) { [weak self] _ in self?.requestDelete() }
        let menuItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIMenu(
                    title: "",
                    options: [.displayAsPalette, .displayInline],
                    preferredElementSize: .large,
                    children: [favorite, share]
                ),
                UIMenu(title: "", options: [.displayInline], children: [add, edit]),
                UIMenu(title: "", options: [.displayInline], children: [delete]),
            ])
        )
        menuItem.accessibilityLabel = L("更多选项")
        menuItem.accessibilityIdentifier = "library.trackDetail.menu"
        navigationItem.rightBarButtonItems = [menuItem]
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
        lyricsLabel.text = track.lyrics?.displayText ?? L("无歌词")
        lyricsTitleLabel.superview?.isHidden = false
        renderInformation(track)
        playButton.isEnabled = onPlayTrack != nil
        configureNavigationItems()

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
            await loadRelationshipNames(for: loadedTrack)
            dateAdded = try? await library.trackDateAdded(id: trackID)
            try Task.checkCancellation()
            renderLoaded()
        } catch is CancellationError {
            return
        } catch {
            renderFailure(L(error.localizedDescription))
        }
    }

    private func loadRelationshipNames(for track: Track) async {
        let album: Album?
        if let id = track.albumID {
            album = try? await LibraryAlbumLoader.load(albumID: id, sourceID: track.id.sourceID, from: library)
        } else {
            album = nil
        }
        let names = (try? await LibraryArtistNameLoader.load(
            artistIDs: Set(track.artistIDs + (album?.artistIDs ?? [])),
            sourceID: track.id.sourceID, from: library
        )) ?? [:]
        let genres = (try? await LibraryGenreNameLoader.load(
            genreIDs: Set(track.genreIDs), sourceID: track.id.sourceID, from: library
        )) ?? [:]
        guard !Task.isCancelled else { return }
        artistNames = names
        albumArtistNames = album?.artistIDs.compactMap { names[$0] } ?? []
        albumTitle = album?.title
        genreNames = track.genreIDs.compactMap { genres[$0] }
    }

    private func renderInformation(_ track: Track) {
        func text(_ value: String?) -> String { value?.isEmpty == false ? value! : L("未知") }
        func names(_ values: [String]) -> String { text(values.joined(separator: "、")) }
        let details = track.details
        let technical = track.technicalInfo
        var music: [LibraryDetailInfoRow] = [
            .init(title: L("主要艺人"), value: names(track.artistIDs.compactMap { artistNames[$0] }), symbol: "mic"),
            .init(title: L("其他艺人"), value: details?.additionalArtists.isEmpty == false ? names(details!.additionalArtists) : L("无"), symbol: "person.2"),
            .init(title: L("作曲者"), value: names(details?.composers ?? []), symbol: "music.note"),
            .init(title: L("专辑"), value: text(albumTitle), symbol: "square.stack"),
            .init(title: L("专辑艺人"), value: names(albumArtistNames), symbol: "person"),
            .init(title: L("流派"), value: names(genreNames), symbol: "guitars"),
            .init(title: L("年份"), value: track.year.map(String.init) ?? L("未知"), symbol: "calendar"),
            .init(title: L("曲目号"), value: track.trackNumber.map(String.init) ?? L("未知"), symbol: "number"),
            .init(title: L("碟片号"), value: track.discNumber.map(String.init) ?? L("未知"), symbol: "opticaldisc"),
            .init(title: L("内容分级"), value: LibraryMetadataForm.ratingTitle(details?.contentRating ?? .unknown), symbol: "exclamationmark.bubble")
        ]
        if let comment = track.comment {
            music.append(.init(title: L("评论"), value: comment, symbol: "text.bubble"))
        }
        var file: [LibraryDetailInfoRow] = [
            .init(title: L("时长"), value: LibraryMetadataForm.durationText(track.duration), symbol: "clock"),
            .init(title: L("格式"), value: text(technical?.container), symbol: "waveform"),
            .init(title: L("编码"), value: text(technical?.codec), symbol: "waveform.path"),
            .init(title: L("大小"), value: technical?.fileSizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L("未知"), symbol: "internaldrive"),
            .init(title: L("采样率"), value: technical?.sampleRate.map { String(format: "%.1f kHz", Double($0) / 1_000) } ?? L("未知"), symbol: "waveform.path.ecg"),
            .init(title: L("位深"), value: technical?.bitDepth.map { "\($0) bit" } ?? L("未知"), symbol: "slider.horizontal.3"),
            .init(title: L("声道"), value: technical?.channels.map(String.init) ?? L("未知"), symbol: "speaker.wave.2"),
            .init(title: L("比特率"), value: (technical?.bitRate ?? technical?.primaryAudioStream?.bitRate).map { "\($0 / 1_000) kbps" } ?? L("未知"), symbol: "speedometer"),
            .init(title: L("添加日期"), value: dateAdded?.formatted(date: .abbreviated, time: .shortened) ?? L("未知"), symbol: "calendar.badge.plus"),
            .init(title: L("来源"), value: track.id.sourceID == .local ? L("文件") : track.id.sourceID.rawValue, symbol: "tray.and.arrow.down"),
            .init(title: L("存储位置"), value: track.id.sourceID == .local ? L("本地资料库") : L("远端资料库"), symbol: "externaldrive"),
            .init(title: L("文件名"), value: text(track.fileName), symbol: "doc")
        ]
        if let path = track.folderPath { file.append(.init(title: L("文件夹"), value: path, symbol: "folder")) }
        informationView.configure([
            .init(title: L("歌曲信息"), rows: music),
            .init(title: L("文件信息"), rows: file),
            .init(title: L("播放记录"), rows: [
                .init(title: L("播放次数"), value: String(track.statistics.playCount), symbol: "play.circle"),
                .init(title: L("上次播放"), value: track.statistics.lastPlayedAt?.formatted(date: .abbreviated, time: .shortened) ?? L("尚未播放"), symbol: "clock.arrow.circlepath")
            ])
        ])
    }

    @objc private func toggleFavorite() {
        guard let track, !isSavingFavorite, !isDeleting else { return }
        isSavingFavorite = true
        configureNavigationItems()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isSavingFavorite = false
                self.configureNavigationItems()
            }
            do {
                self.track = try await self.library.setFavorite(!track.isFavorite, for: track.id)
                self.renderLoaded()
            } catch {
                self.presentMessage(title: L("无法更新收藏"), message: L(error.localizedDescription))
            }
        }
    }

    private func shareTrack() {
        guard let track, let mediaShareResolver, shareTask == nil, !isDeleting,
              presentedViewController == nil else { return }
        shareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.shareTask = nil
                self.configureNavigationItems()
            }
            do {
                let urls = try await mediaShareResolver.urls(for: [track])
                try Task.checkCancellation()
                let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.barButtonItem = self.navigationItem.rightBarButtonItem
                }
                self.present(activity, animated: true)
            } catch is CancellationError {
                return
            } catch {
                self.presentMessage(title: L("无法分享"), message: L(error.localizedDescription))
            }
        }
        configureNavigationItems()
    }

    @objc private func addToPlaylist() {
        guard let track else { return }
        onAddToPlaylist?([track.id])
    }

    @objc private func editTrack() {
        guard let track, presentedViewController == nil else { return }

        let editor = LibraryTrackMetadataEditorViewController(
            track: track,
            library: library,
            artworkServing: artworkServing
        ) { [weak self] updatedTrack in
            guard let self else { return }
            self.track = updatedTrack
            self.renderLoaded()
            self.loadTask?.cancel()
            self.loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadRelationshipNames(for: updatedTrack)
                guard !Task.isCancelled else { return }
                self.renderLoaded()
            }
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
        configureNavigationItems()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isDeleting = false
                self.configureNavigationItems()
            }
            do {
                _ = try await self.library.delete([track.id])
                self.onDeleted?()
                self.navigationController?.popViewController(animated: true)
            } catch {
                self.presentMessage(title: L("无法删除歌曲"), message: L(error.localizedDescription))
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
