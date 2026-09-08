import DesignSystem
import MusicDomain
import UIKit

@MainActor
final class PlaylistAddTracksViewController: UITableViewController {
    private let candidates: [PlaylistTrackCandidate]
    private let existingIDs: Set<MediaItemID>
    private let onSubmit: @MainActor ([MediaItemID]) async -> Bool
    private var selectedIDs = Set<MediaItemID>()
    private var isSubmitting = false

    var onDismiss: (() -> Void)?

    init(
        candidates: [PlaylistTrackCandidate],
        existingIDs: Set<MediaItemID>,
        onSubmit: @escaping @MainActor ([MediaItemID]) async -> Bool
    ) {
        self.candidates = candidates
        self.existingIDs = existingIDs
        self.onSubmit = onSubmit
        super.init(style: .insetGrouped)
        title = L("添加歌曲")
        restorationIdentifier = "playlists.addTracks.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "playlists.addTracks"
        tableView.register(
            PlaylistAddTrackCell.self,
            forCellReuseIdentifier: "PlaylistAddTrackCell"
        )
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        // The SwiftUI sheet exposes its List through the sheet's stable
        // identifier, so make the UIKit table the queryable container too.
        // A controller root view is not always emitted as an accessibility
        // container when presented inside a form sheet.
        tableView.accessibilityIdentifier = "playlists.addTracks"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L("取消"),
            style: .plain,
            target: self,
            action: #selector(cancel)
        )
        let done = UIBarButtonItem(
            title: L("添加"),
            style: .done,
            target: self,
            action: #selector(submit)
        )
        done.accessibilityIdentifier = "playlists.addTracks.submit"
        navigationItem.rightBarButtonItem = done

        if candidates.isEmpty {
            let empty = MusicFreeUIKitEmptyStateView(
                title: L("没有可添加的歌曲"),
                message: L("先将歌曲导入资料库，再回到这里添加。"),
                systemImage: "music.note"
            )
            empty.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                empty.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                empty.topAnchor.constraint(equalTo: view.topAnchor),
                empty.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            tableView.isHidden = true
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        candidates.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "PlaylistAddTrackCell",
            for: indexPath
        )
        guard let cell = cell as? PlaylistAddTrackCell else {
            return cell
        }
        let candidate = candidates[indexPath.row]
        let isExisting = existingIDs.contains(candidate.id)
        let isSelected = selectedIDs.contains(candidate.id)
        cell.configure(
            title: candidate.title,
            subtitle: candidate.subtitle,
            identifier: "playlists.addTrack.\(candidate.id.externalID)",
            isExisting: isExisting,
            isSelected: isSelected,
            onActivate: { [weak self] in
                self?.toggle(candidate.id, at: indexPath)
            }
        )
        return cell
    }

    private func toggle(_ id: MediaItemID, at indexPath: IndexPath) {
        guard !existingIDs.contains(id), !isSubmitting else { return }
        if !selectedIDs.insert(id).inserted {
            selectedIDs.remove(id)
        }
        if tableView.indexPathsForVisibleRows?.contains(indexPath) == true {
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func submit() {
        guard !isSubmitting, !selectedIDs.isEmpty else {
            if selectedIDs.isEmpty {
                let alert = UIAlertController(
                    title: L("请选择歌曲"),
                    message: nil,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L("好"), style: .default))
                present(alert, animated: true)
            }
            return
        }
        isSubmitting = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let ids = candidates.map(\.id).filter { selectedIDs.contains($0) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let saved = await onSubmit(ids)
            guard !Task.isCancelled else { return }
            isSubmitting = false
            navigationItem.rightBarButtonItem?.isEnabled = true
            if saved {
                dismiss(animated: true)
            } else {
                let alert = UIAlertController(
                    title: L("操作失败"),
                    message: L("歌曲添加失败，请重试。"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L("好"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}

@MainActor
private final class PlaylistAddTrackCell: UITableViewCell {
    private let rowView = MusicFreeUIKitMediaRowView(
        title: "",
        subtitle: nil,
        showsArtwork: false
    )
    private let selectionImageView = UIImageView()
    private let activationButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        selectionImageView.translatesAutoresizingMaskIntoConstraints = false
        selectionImageView.contentMode = .scaleAspectFit
        selectionImageView.tintColor = MusicFreeUIColorTokens.accent
        selectionImageView.accessibilityElementsHidden = true

        rowView.translatesAutoresizingMaskIntoConstraints = false
        rowView.showsArtwork = false
        rowView.isUserInteractionEnabled = false
        rowView.exposesTextAccessibility = true
        rowView.accessoryView = selectionImageView
        rowView.titleNumberOfLines = 2

        // Keep the same Button -> StaticText hierarchy as the SwiftUI
        // `AddToPlaylistSheet`: the transparent button owns activation while
        // the row's title and artist remain independently discoverable.
        activationButton.translatesAutoresizingMaskIntoConstraints = false
        activationButton.backgroundColor = .clear
        activationButton.setTitleColor(.clear, for: .normal)
        activationButton.addTarget(
            self,
            action: #selector(activate),
            for: .touchUpInside
        )

        contentView.addSubview(rowView)
        contentView.addSubview(activationButton)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rowView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            activationButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            activationButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            activationButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            activationButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        subtitle: String?,
        identifier: String,
        isExisting: Bool,
        isSelected: Bool,
        onActivate: @escaping () -> Void
    ) {
        rowView.titleText = title
        rowView.subtitleText = subtitle
        activationButton.setTitle(title, for: .normal)
        activationButton.accessibilityLabel = title
        activationButton.accessibilityIdentifier = identifier
        activationButton.accessibilityValue = isExisting
            ? L("已在歌单中")
            : (isSelected ? L("已选择") : L("未选择"))
        activationButton.accessibilityTraits = [.button]
        activationButton.isEnabled = !isExisting
        onPrimaryAction = onActivate
        rowView.alpha = isExisting ? 0.45 : 1
        selectionImageView.image = UIImage(
            systemName: isSelected ? "checkmark.circle.fill" : "circle"
        )
        selectionImageView.tintColor = isSelected
            ? MusicFreeUIColorTokens.accent
            : MusicFreeUIColorTokens.foregroundTertiary
    }

    @objc private func activate() {
        onPrimaryAction?()
    }

    private var onPrimaryAction: (() -> Void)?
}
