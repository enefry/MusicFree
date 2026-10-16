import AppServices
import DesignSystem
import MusicDomain
import UIKit

/// Native UIKit sheet for adding one or more library items to a playlist.
///
/// The view model remains shared with the former SwiftUI implementation so
/// pagination, duplicate filtering and service error semantics do not change.
@MainActor
public final class LibraryAddToPlaylistViewController: UIViewController,
    UITableViewDataSource,
    UITableViewDelegate,
    UISearchResultsUpdating
{
    private let viewModel: LibraryAddToPlaylistViewModel
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private let createButton = UIButton(type: .system)
    private let createHeaderStack = UIStackView()
    private let createContainer = UIView()
    private let createNameField = UITextField()
    private let createAndAddButton = UIButton(type: .system)
    private let loadingView = MusicFreeUIKitLoadingStateView(label: L("加载播放列表"))
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var isCreateFormVisible = false

    public init(itemIDs: [MediaItemID], playlistServing: any PlaylistServing) {
        viewModel = LibraryAddToPlaylistViewModel(
            itemIDs: itemIDs,
            playlistServing: playlistServing
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        restorationIdentifier = "library.addToPlaylist.uikit"
        title = L("添加到播放列表")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        view.accessibilityIdentifier = "library.addToPlaylist"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L("取消"),
            style: .plain,
            target: self,
            action: #selector(dismissSheet)
        )
        configureSearch()
        configureTableView()
        configureCreateForm()
        installLoadingView()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await viewModel.load()
            guard !Task.isCancelled else { return }
            render()
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loadTask?.cancel()
        actionTask?.cancel()
    }

    deinit {
        loadTask?.cancel()
        actionTask?.cancel()
    }

    public func updateSearchResults(for searchController: UISearchController) {
        tableView.reloadData()
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = L("搜索播放列表")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = MusicFreeUIColorTokens.backgroundGrouped
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PlaylistCell")
        tableView.accessibilityIdentifier = "library.addToPlaylist.list"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCreateFormLayout()
    }

    private func configureCreateForm() {
        createContainer.backgroundColor = MusicFreeUIColorTokens.backgroundSecondary
        createContainer.layer.cornerRadius = 10
        createContainer.layer.masksToBounds = true
        createContainer.translatesAutoresizingMaskIntoConstraints = false

        createNameField.placeholder = L("播放列表名称")
        createNameField.borderStyle = .roundedRect
        createNameField.clearButtonMode = .whileEditing
        createNameField.returnKeyType = .done
        createNameField.delegate = self
        createNameField.addTarget(self, action: #selector(createNameChanged), for: .editingChanged)
        createNameField.accessibilityIdentifier = "library.addToPlaylist.name"

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.cornerStyle = .capsule
        buttonConfiguration.baseBackgroundColor = MusicFreeUIColorTokens.accent
        buttonConfiguration.baseForegroundColor = MusicFreeUIColorTokens.onAccent
        buttonConfiguration.title = L("创建并添加")
        createAndAddButton.configuration = buttonConfiguration
        createAndAddButton.isEnabled = false
        createAndAddButton.addTarget(self, action: #selector(createAndAdd), for: .touchUpInside)
        createAndAddButton.accessibilityIdentifier = "library.addToPlaylist.createAndAdd"

        let formStack = UIStackView(arrangedSubviews: [createNameField, createAndAddButton])
        formStack.axis = .vertical
        formStack.distribution = .fill
        formStack.alignment = .fill
        formStack.spacing = MusicFreeSpacingTokens.small
        formStack.translatesAutoresizingMaskIntoConstraints = false
        createContainer.addSubview(formStack)
        NSLayoutConstraint.activate([
            formStack.leadingAnchor.constraint(equalTo: createContainer.leadingAnchor, constant: MusicFreeSpacingTokens.medium),
            formStack.trailingAnchor.constraint(equalTo: createContainer.trailingAnchor, constant: -MusicFreeSpacingTokens.medium),
            formStack.topAnchor.constraint(equalTo: createContainer.topAnchor, constant: MusicFreeSpacingTokens.medium),
            formStack.bottomAnchor.constraint(equalTo: createContainer.bottomAnchor, constant: -MusicFreeSpacingTokens.medium),
            createAndAddButton.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget),
            createNameField.heightAnchor.constraint(greaterThanOrEqualToConstant: MusicFreeLayoutMetrics.minimumHitTarget)
        ])

        createButton.setTitle(L("新建播放列表"), for: .normal)
        createButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
        createButton.tintColor = MusicFreeUIColorTokens.accent
        createButton.titleLabel?.font = MusicFreeUIFontTokens.rowTitle
        createButton.contentHorizontalAlignment = .leading
        createButton.addTarget(self, action: #selector(toggleCreateForm), for: .touchUpInside)
        createButton.accessibilityIdentifier = "library.addToPlaylist.create"
        createButton.translatesAutoresizingMaskIntoConstraints = false

        createHeaderStack.axis = .vertical
        createHeaderStack.spacing = MusicFreeSpacingTokens.small
        createHeaderStack.isLayoutMarginsRelativeArrangement = true
        createHeaderStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: MusicFreeSpacingTokens.small,
            leading: MusicFreeSpacingTokens.contentInset,
            bottom: MusicFreeSpacingTokens.small,
            trailing: MusicFreeSpacingTokens.contentInset
        )
        createHeaderStack.addArrangedSubview(createButton)
        createHeaderStack.addArrangedSubview(createContainer)
        createContainer.isHidden = true
        createButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        tableView.tableHeaderView = createHeaderStack
    }

    private func installLoadingView() {
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.topAnchor.constraint(equalTo: view.topAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func render() {
        switch viewModel.loadState {
        case .loading:
            loadingView.isLoading = true
            tableView.isHidden = true
        case .loaded:
            loadingView.isLoading = false
            tableView.isHidden = false
            updateCreateFormLayout()
            tableView.reloadData()
        case let .failed(message):
            loadingView.isLoading = false
            tableView.isHidden = true
            presentError(message)
        }
        createAndAddButton.isEnabled = viewModel.canCreatePlaylist
    }

    private func updateCreateFormLayout() {
        createContainer.isHidden = !isCreateFormVisible
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = createHeaderStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        guard abs(createHeaderStack.frame.height - size.height) > 0.5
                || abs(createHeaderStack.frame.width - width) > 0.5 else { return }
        createHeaderStack.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        tableView.tableHeaderView = createHeaderStack
    }

    @objc private func createNameChanged() {
        viewModel.newPlaylistName = createNameField.text ?? ""
        createAndAddButton.isEnabled = viewModel.canCreatePlaylist
    }

    private var filteredPlaylists: [Playlist] {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return viewModel.playlists }
        return viewModel.playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func submit(_ playlist: Playlist) {
        guard viewModel.isSubmitting == false else { return }
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await viewModel.add(to: playlist)
            guard !Task.isCancelled else { return }
            render()
            if succeeded {
                dismiss(animated: true)
            } else if let message = viewModel.noticeMessage {
                presentMessage(title: L("无需重复添加"), message: message)
                viewModel.noticeMessage = nil
            } else if let message = viewModel.errorMessage {
                presentMessage(title: L("无法添加"), message: message)
                viewModel.errorMessage = nil
            }
        }
    }

    @objc private func toggleCreateForm() {
        isCreateFormVisible.toggle()
        updateCreateFormLayout()
        if isCreateFormVisible {
            createHeaderStack.layoutIfNeeded()
            tableView.scrollRectToVisible(createHeaderStack.frame, animated: false)
            createNameField.becomeFirstResponder()
        } else {
            createNameField.resignFirstResponder()
        }
    }

    @objc private func createAndAdd() {
        guard viewModel.isSubmitting == false else { return }
        viewModel.newPlaylistName = createNameField.text ?? ""
        actionTask?.cancel()
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await viewModel.createAndAdd()
            guard !Task.isCancelled else { return }
            render()
            if succeeded {
                dismiss(animated: true)
            } else if let message = viewModel.errorMessage {
                presentMessage(title: L("无法添加"), message: message)
                viewModel.errorMessage = nil
            } else if let message = viewModel.noticeMessage {
                presentMessage(title: L("无需重复添加"), message: message)
                viewModel.noticeMessage = nil
            }
        }
    }

    @objc private func dismissSheet() {
        guard !viewModel.isSubmitting else { return }
        dismiss(animated: true)
    }

    private func presentError(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: L("播放列表加载失败"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("重试"), style: .default) { [weak self] _ in
            self?.loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await viewModel.load()
                render()
            }
        })
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .cancel))
        present(alert, animated: true)
    }

    public func numberOfSections(in _: UITableView) -> Int {
        1
    }

    public func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        filteredPlaylists.count
    }

    public func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PlaylistCell", for: indexPath)
        let playlist = filteredPlaylists[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = playlist.name
        content.image = UIImage(systemName: "music.note.list")
        content.imageProperties.tintColor = MusicFreeUIColorTokens.accent
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "library.addToPlaylist.playlist.\(playlist.id.rawValue)"
        return cell
    }

    public func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        submit(filteredPlaylists[indexPath.row])
    }
}

extension LibraryAddToPlaylistViewController: UITextFieldDelegate {
    public func textFieldShouldReturn(_: UITextField) -> Bool {
        createAndAdd()
        return false
    }
}
