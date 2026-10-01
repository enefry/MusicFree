import AppServices
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PhotosUI
import UIKit

@MainActor
public final class LibraryArtistMetadataEditorViewController: UIViewController, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate {
    private let artist: Artist
    private let library: any LibraryServing
    private let artworkServing: (any ArtworkServing)?
    private let onSaved: (Artist) -> Void
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let nameField = LibraryMetadataForm.field(nil, identifier: "library.artistEditor.name")
    private let originField = LibraryMetadataForm.field(nil, identifier: "library.artistEditor.origin")
    private let biographyView = LibraryMetadataForm.textView(nil, identifier: "library.artistEditor.biography")
    private let artworkView = MusicFreeUIKitArtworkView(placeholderSystemImage: "person")
    private let artworkStatusLabel = UILabel()
    private lazy var birthDateControl = LibraryMetadataDateControl(
        date: artist.details?.birthDate, title: L("出生日期"),
        identifier: "library.artistEditor.birthDate", maximumDate: Date()
    )
    private var artworkEdit: ArtworkEdit = .keep
    private var artworkVersion = UUID()
    private var artworkTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var isLoadingArtwork = false
    private var isSaving = false

    public init(
        artist: Artist,
        library: any LibraryServing,
        artworkServing: (any ArtworkServing)? = nil,
        onSaved: @escaping (Artist) -> Void
    ) {
        self.artist = artist
        self.library = library
        self.artworkServing = artworkServing
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
        title = L("编辑艺人")
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        artworkTask?.cancel()
        saveTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "library.artistEditor"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L("取消"), style: .plain, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L("保存"), style: .done, target: self, action: #selector(save)
        )
        nameField.text = artist.name
        originField.text = artist.details?.origin
        biographyView.text = artist.details?.biography
        contentStack.axis = .vertical
        contentStack.spacing = MusicFreeSpacingTokens.large
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("封面"), rows: [makeArtworkContent()]))
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("基本信息"), rows: [
            LibraryMetadataForm.row(L("艺人名称"), control: nameField),
            LibraryMetadataForm.row(L("国家 / 城市"), control: originField),
            birthDateControl
        ]))
        contentStack.addArrangedSubview(LibraryMetadataForm.section(L("简介"), rows: [biographyView]))
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.accessibilityIdentifier = "library.artistEditor.scroll"
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
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -2 * MusicFreeSpacingTokens.contentInset)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(endEditing))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    public override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? { scrollView }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        LibraryMetadataForm.shouldDismissKeyboard(for: touch)
    }

    private func makeArtworkContent() -> UIView {
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.cornerRadius = 80
        artworkView.accessibilityIdentifier = "library.artistEditor.coverPreview"
        let container = UIView()
        container.addSubview(artworkView)
        NSLayoutConstraint.activate([
            artworkView.widthAnchor.constraint(equalToConstant: 160),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
            artworkView.topAnchor.constraint(equalTo: container.topAnchor),
            artworkView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            artworkView.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])
        let pick = UIButton(type: .system)
        pick.setTitle(L("选择封面"), for: .normal)
        pick.setImage(UIImage(systemName: "photo.badge.plus"), for: .normal)
        pick.addTarget(self, action: #selector(pickArtwork), for: .touchUpInside)
        pick.accessibilityIdentifier = "library.artistEditor.coverPicker"
        let remove = UIButton(type: .system)
        remove.setTitle(L("移除封面"), for: .normal)
        remove.setImage(UIImage(systemName: "trash"), for: .normal)
        remove.tintColor = MusicFreeUIColorTokens.destructive
        remove.addTarget(self, action: #selector(removeArtwork), for: .touchUpInside)
        remove.accessibilityIdentifier = "library.artistEditor.coverRemove"
        artworkStatusLabel.font = MusicFreeUIFontTokens.caption
        artworkStatusLabel.textColor = MusicFreeUIColorTokens.foregroundSecondary
        artworkStatusLabel.textAlignment = .center
        artworkStatusLabel.numberOfLines = 0
        artworkStatusLabel.text = artist.artwork == nil ? L("当前没有封面") : L("当前封面将保留")
        let stack = UIStackView(arrangedSubviews: [container, pick, remove, artworkStatusLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        if let id = artist.artworkID, let artworkServing {
            artworkView.image = LibraryArtworkImagePipeline.shared.cachedImage(
                artworkID: id, sourceID: .local, maximumPixelDimension: 1_024
            )
            artworkTask = Task { @MainActor [weak self] in
                let image = try? await LibraryArtworkImagePipeline.shared.image(
                    artworkID: id, sourceID: .local, maximumPixelDimension: 1_024, serving: artworkServing
                )
                guard let self, !Task.isCancelled else { return }
                artworkView.image = image
            }
        }
        return stack
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
        guard let provider = results.first?.itemProvider else { return }
        artworkVersion = UUID()
        let version = artworkVersion
        isLoadingArtwork = true
        updateAvailability()
        provider.loadDataRepresentation(forTypeIdentifier: "public.image") { [weak self] data, _ in
            Task { @MainActor [weak self] in
                guard let self, artworkVersion == version else { return }
                artworkTask?.cancel()
                artworkTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        if artworkVersion == version { isLoadingArtwork = false; updateAvailability() }
                    }
                    do {
                        guard let data, !data.isEmpty, data.count <= ArtworkDataLimits.maximumByteCount else {
                            throw ArtistArtworkError.invalidImage
                        }
                        let image = try await ArtworkImageDecoding.image(from: .inMemory(data), maximumPixelDimension: 1_024)
                        guard !Task.isCancelled, artworkVersion == version else { return }
                        artworkEdit = .replace(data)
                        artworkView.image = image
                        artworkStatusLabel.text = L("已选择新封面")
                    } catch {
                        guard !Task.isCancelled, artworkVersion == version else { return }
                        presentError(L(error.localizedDescription))
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
        artworkView.image = nil
        artworkStatusLabel.text = L("保存后移除当前封面")
        updateAvailability()
    }

    private func updateAvailability() {
        navigationItem.rightBarButtonItem?.isEnabled = !isSaving && !isLoadingArtwork
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        isModalInPresentation = isSaving
        contentStack.isUserInteractionEnabled = !isSaving
    }

    @objc private func save() {
        guard !isSaving, !isLoadingArtwork else { return }
        let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { presentError(L("艺人名称不能为空。")); return }
        endEditing()
        let update = ArtistMetadataUpdate(
            artistID: artist.id, name: name,
            details: ArtistDetailMetadata(origin: originField.text, birthDate: birthDateControl.date, biography: biographyView.text),
            artwork: artworkEdit
        )
        isSaving = true
        updateAvailability()
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSaving = false; updateAvailability() }
            do {
                let updated = try await library.updateArtistMetadata(update)
                onSaved(updated)
                dismiss(animated: true)
            } catch is CancellationError {
                return
            } catch {
                presentError(L(error.localizedDescription))
            }
        }
    }

    @objc private func cancel() { guard !isSaving else { return }; dismiss(animated: true) }
    @objc private func endEditing() { view.endEditing(true) }

    private func presentError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: L("无法保存艺人"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }
}

private enum ArtistArtworkError: LocalizedError {
    case invalidImage
    var errorDescription: String? { L("图片为空、过大或无法读取。") }
}
