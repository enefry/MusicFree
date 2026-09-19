import AppServices
import Combine
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit

/// Native local-library search surface hosted by `UISearchTab` on iPhone.
///
/// `UISearchTab.automaticallyActivatesSearch` moves this controller's system
/// search field into the floating tab bar and restores the previously selected
/// tab when the user cancels search.
@MainActor
public final class LibrarySearchViewController: UIViewController {
    public var onSelectAlbum: ((AlbumID) -> Void)? {
        didSet { resultsController.onSelectAlbum = onSelectAlbum }
    }
    public var onSelectTrack: ((MediaItemID) -> Void)? {
        didSet { resultsController.onSelectTrack = onSelectTrack }
    }
    public var onPlayTrack: ((MediaItemID) -> Void)? {
        didSet { resultsController.onPlayTrack = onPlayTrack }
    }
    public var onEnqueueNextTracks: (([MediaItemID]) -> Void)? {
        didSet { resultsController.onEnqueueNextTracks = onEnqueueNextTracks }
    }
    public var onEnqueueTracks: (([MediaItemID]) -> Void)? {
        didSet { resultsController.onEnqueueTracks = onEnqueueTracks }
    }
    public var onAddTracksToPlaylist: (([MediaItemID]) -> Void)? {
        didSet { resultsController.onAddTracksToPlaylist = onAddTracksToPlaylist }
    }

    private let viewModel: LibraryViewModel
    private let resultsController: LibrarySearchResultsViewController
    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: resultsController)
        controller.searchResultsUpdater = self
        controller.searchBar.delegate = self
        controller.searchBar.placeholder = L("library.search.placeholder")
        controller.searchBar.autocapitalizationType = .none
        controller.searchBar.autocorrectionType = .no
        controller.searchBar.returnKeyType = .search
        controller.searchBar.accessibilityIdentifier = "library.home.search"
        controller.searchBar.searchTextField.accessibilityIdentifier = "library.home.search"
        controller.obscuresBackgroundDuringPresentation = false
        return controller
    }()
    private var observations = Set<AnyCancellable>()

    public init(
        viewModel: LibraryViewModel,
        artworkServing: (any ArtworkServing)? = nil,
        mediaSourceResolver: (any MediaSourceResolving)? = nil
    ) {
        self.viewModel = viewModel
        resultsController = LibrarySearchResultsViewController(
            viewModel: viewModel,
            artworkServing: artworkServing,
            mediaSourceResolver: mediaSourceResolver
        )
        super.init(nibName: nil, bundle: nil)
        restorationIdentifier = "library.search.uikit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MusicFreeUIColorTokens.backgroundPrimary
        view.accessibilityIdentifier = "library.search"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .automatic
        if #available(iOS 26.0, *) {
            navigationItem.searchBarPlacementAllowsToolbarIntegration = true
        }
        definesPresentationContext = true

        observations.insert(
            viewModel.$searchText.sink { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self, self.searchController.searchBar.text != text else {
                        return
                    }
                    self.searchController.searchBar.text = text
                }
            }
        )
        setContentScrollView(resultsController.contentScrollView, for: .bottom)
    }

    public override func contentScrollView(
        for edge: NSDirectionalRectEdge
    ) -> UIScrollView? {
        resultsController.contentScrollView
    }
}

extension LibrarySearchViewController: UISearchBarDelegate {
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }

    public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        viewModel.updateSearchText("")
    }
}

extension LibrarySearchViewController: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        viewModel.updateSearchText(searchController.searchBar.text ?? "")
    }
}
