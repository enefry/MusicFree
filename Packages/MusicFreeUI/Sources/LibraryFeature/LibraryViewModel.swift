import Combine
import DesignSystem
import Foundation
import AppServices
import LibraryAPI
import MediaSourceAPI
import MusicDomain

public enum LibraryLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(message: String)
}

/// Keeps a picked URL's sandbox authorization alive.
///
/// The document picker's URLs must stay authorized for the whole import, not
/// just for the delegate callback: the importer enumerates and copies files from
/// a detached task long after the picker is gone. The scope also lives on the
/// exact URL object the picker delivered, because a derived copy loses it.
private final class PickedURLAccess {
    private let url: URL
    private var didStart: Bool

    init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        guard didStart else { return }
        url.stopAccessingSecurityScopedResource()
        didStart = false
    }

    deinit {
        stop()
    }
}

/// Owns library query tasks, pagination cursors, search generations, selection,
/// navigation and import task lifetime on the main actor.
@MainActor
public final class LibraryViewModel: ObservableObject {
    private static let importLogger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "library-import"
    )
    @Published public var selection: LibrarySection
    @Published public private(set) var searchText = ""
    @Published public private(set) var searchTracks: [Track] = []
    @Published public private(set) var searchAlbums: [Album] = []
    @Published public private(set) var searchArtists: [Artist] = []
    @Published public private(set) var searchState: LibraryLoadState = .idle
    @Published public private(set) var albumSortDescriptor: AlbumSortDescriptor = .default
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var favoriteTracks: [Track] = []
    @Published public private(set) var albums: [Album] = []
    @Published public private(set) var artists: [Artist] = []
    @Published public private(set) var genres: [Genre] = []
    @Published public private(set) var folders: [LibraryFolder] = []
    @Published public private(set) var recentTracks: [Track] = []
    @Published public private(set) var playbackHistory: [PlaybackHistoryItem] = []
    @Published public private(set) var isClearingPlaybackHistory = false
    @Published public private(set) var playbackHistoryClearError: String?
    @Published public private(set) var recentAlbums: [Album] = []
    @Published public private(set) var overviewState: LibraryLoadState = .idle
    @Published public private(set) var states: [LibrarySection: LibraryLoadState]
    @Published public private(set) var paginationErrors: [LibrarySection: String] = [:]
    @Published public private(set) var navigationPath: [LibraryDestination] = []
    @Published public private(set) var importState: LibraryImportState = .idle
    @Published public private(set) var importFailures: [LibraryImportFailure] = []
    @Published public private(set) var isSearchDebouncing = false

    let library: any AppServices.LibraryServing
    private let importer: (any AppServices.ImportServing)?
    private let initialPreparation: (@MainActor @Sendable () async -> Void)?
    private let refreshPreparation: (@MainActor @Sendable () async -> Void)?
    private let pageSize: Int
    private let searchResultLimit: Int
    private let searchDebounceNanoseconds: UInt64

    private var nextCursors: [LibrarySection: LibraryCursor?] = [:]
    private var loadSequences: [LibrarySection: UInt64] = [:]
    private var activeLoadTokens: [LibrarySection: UInt64] = [:]
    private var loadTasks: [LibrarySection: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchRefreshPending = false
    private var importTask: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?
    private var overviewRefreshTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var trackRefreshTask: Task<Void, Never>?
    private var pendingTrackRefreshIDs: Set<MediaItemID> = []
    private var pendingTrackRefreshIncludesDeletions = false
    private var initialPreparationTask: Task<Void, Never>?
    private var currentImportID: UUID?
    private var initialPreparationFinished = false
    private var searchGeneration: UInt64 = 0
    private var overviewLoadID: UInt64 = 0
    private var changeObservationID: UUID?
    private struct FavoriteRequest {
        let version: UInt64
        let value: Bool
        let fallback: Track
    }
    private var favoriteVersions: [MediaItemID: UInt64] = [:]
    private var favoriteRequests: [MediaItemID: FavoriteRequest] = [:]
    private var favoriteTasks: [MediaItemID: Task<Void, Never>] = [:]

    public init(
        library: any AppServices.LibraryServing,
        importer: (any AppServices.ImportServing)? = nil,
        initialPreparation: (@MainActor @Sendable () async -> Void)? = nil,
        refreshPreparation: (@MainActor @Sendable () async -> Void)? = nil,
        selection: LibrarySection = .tracks,
        // Local libraries are normally small enough for one fetch. Keeping a
        // large bounded page removes the visible 50-row loading cadence while
        // retaining a safety valve for unusually large libraries.
        pageSize: Int = 500,
        searchResultLimit: Int = 100,
        searchDebounceNanoseconds: UInt64 = 250_000_000
    ) {
        self.library = library
        self.importer = importer
        self.initialPreparation = initialPreparation
        self.refreshPreparation = refreshPreparation
        self.selection = selection
        self.pageSize = min(max(1, pageSize), LibraryPageRequest.maximumLimit)
        self.searchResultLimit = min(
            max(1, searchResultLimit),
            LibraryPageRequest.maximumLimit
        )
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
        self.states = Dictionary(uniqueKeysWithValues: LibrarySection.allCases.map { ($0, .idle) })
    }

    deinit {
        loadTasks.values.forEach { $0.cancel() }
        searchTask?.cancel()
        importTask?.cancel()
        overviewTask?.cancel()
        overviewRefreshTask?.cancel()
        changeTask?.cancel()
        trackRefreshTask?.cancel()
        initialPreparationTask?.cancel()
        favoriteTasks.values.forEach { $0.cancel() }
    }

    public var canImport: Bool { importer != nil }

    public func state(for section: LibrarySection) -> LibraryLoadState {
        states[section] ?? .idle
    }

    public func paginationError(for section: LibrarySection) -> String? {
        paginationErrors[section]
    }

    public func tracks(for section: LibrarySection) -> [Track] {
        switch section {
        case .favorites:
            return favoriteTracks
        case .recent:
            return recentTracks
        default:
            return tracks
        }
    }

    public func isLoading(_ section: LibrarySection) -> Bool {
        activeLoadTokens[section] != nil
    }

    public func hasNextPage(for section: LibrarySection) -> Bool {
        guard let cursor = nextCursors[section] ?? nil else { return false }
        return !cursor.isEmpty
    }

    public func loadIfNeeded(for section: LibrarySection? = nil) {
        let section = section ?? selection
        guard state(for: section) == .idle else { return }
        load(section: section, reset: true)
    }

    /// Gives launch-time Documents import one shared completion point for views
    /// that have not already started a query from the persisted library.
    public func prepareForInitialLoad() async {
        guard !initialPreparationFinished else { return }

        if let initialPreparationTask {
            await initialPreparationTask.value
            return
        }

        let preparation = initialPreparation ?? refreshPreparation
        let task = Task { @MainActor in
            if let preparation {
                await preparation()
            }
        }
        initialPreparationTask = task
        await task.value
        initialPreparationFinished = true
        initialPreparationTask = nil
    }

    public func prepareForFirstLoad(of section: LibrarySection) async {
        await prepareForInitialLoad()
        guard !Task.isCancelled else { return }
        loadIfNeeded(for: section)
    }

    public func load(section: LibrarySection? = nil, reset: Bool = true) {
        startLoad(
            section: section ?? selection,
            reset: reset
        )
    }

    public func loadNextPage(for section: LibrarySection? = nil) {
        let section = section ?? selection
        guard hasNextPage(for: section), !isLoading(section) else { return }
        startLoad(
            section: section,
            reset: false
        )
    }

    public func retry(section: LibrarySection? = nil) {
        let section = section ?? selection
        let reset = itemsCount(for: section) == 0
        load(section: section, reset: reset)
    }

    public func refreshCurrentSection() {
        cancelLoad(for: selection)
        load(section: selection, reset: true)
    }

    public func refresh(section: LibrarySection) {
        cancelLoad(for: section)
        load(section: section, reset: true)
    }

    public func toggleFavorite(_ track: Track) {
        let requestedValue = !favoriteValue(for: track)
        let version = favoriteVersions[track.id, default: 0] &+ 1
        favoriteVersions[track.id] = version
        favoriteRequests[track.id] = FavoriteRequest(
            version: version,
            value: requestedValue,
            fallback: track
        )
        applyFavorite(replacingFavorite(in: track, with: requestedValue))

        guard favoriteTasks[track.id] == nil else { return }
        favoriteTasks[track.id] = Task { @MainActor [weak self] in
            await self?.runFavoriteMutations(for: track.id)
        }
    }

    public func waitForFavoriteMutations() async {
        let tasks = Array(favoriteTasks.values)
        for task in tasks {
            await task.value
        }
    }

    public func loadOverviewIfNeeded() {
        guard overviewState == .idle else { return }
        startOverviewLoad()
    }

    public func refreshOverview() {
        overviewTask?.cancel()
        overviewTask = nil
        startOverviewLoad()
    }

    public func refreshOverviewCheckingForImports() async {
        await refreshPreparation?()
        refreshOverview()
    }

    public func setAlbumSort(_ descriptor: AlbumSortDescriptor) {
        guard albumSortDescriptor != descriptor else { return }
        albumSortDescriptor = descriptor
        guard state(for: .albums) != .idle else { return }
        cancelLoad(for: .albums)
        load(section: .albums, reset: true)
    }

    public func refreshCheckingForImports(section: LibrarySection) async {
        await refreshPreparation?()
        cancelLoad(for: section)
        load(section: section, reset: true)
    }

    public func removeDeletedTrack(_ itemID: MediaItemID) {
        removeDeletedTracks([itemID])
    }

    public func removeDeletedTracks(_ itemIDs: Set<MediaItemID>) {
        guard !itemIDs.isEmpty else { return }

        let nextTracks = tracks.filter { !itemIDs.contains($0.id) }
        if nextTracks != tracks { tracks = nextTracks }
        let nextFavorites = favoriteTracks.filter { !itemIDs.contains($0.id) }
        if nextFavorites != favoriteTracks { favoriteTracks = nextFavorites }
        let nextRecent = recentTracks.filter { !itemIDs.contains($0.id) }
        if nextRecent != recentTracks { recentTracks = nextRecent }
        let nextSearchTracks = searchTracks.filter { !itemIDs.contains($0.id) }
        if nextSearchTracks != searchTracks { searchTracks = nextSearchTracks }
        let nextHistory = playbackHistory.filter { !itemIDs.contains($0.track.id) }
        if nextHistory != playbackHistory { playbackHistory = nextHistory }
        if searchState == .loaded, searchTracks.isEmpty, searchAlbums.isEmpty {
            searchState = .empty
        }

        for itemID in itemIDs {
            favoriteRequests[itemID] = nil
            favoriteVersions[itemID] = nil
            favoriteTasks[itemID]?.cancel()
            favoriteTasks[itemID] = nil
        }

        for section in [LibrarySection.tracks, .favorites, .recent]
            where itemsCount(for: section) == 0
        {
            switch state(for: section) {
            case .loaded, .empty:
                states[section] = .empty
            case .idle, .loading, .failed:
                // Do not turn an unqueried section into an empty result. It
                // still needs to perform its first load when selected.
                break
            }
        }
    }

    public func clearPlaybackHistory() async {
        guard !playbackHistory.isEmpty, !isClearingPlaybackHistory else { return }
        isClearingPlaybackHistory = true
        playbackHistoryClearError = nil
        defer { isClearingPlaybackHistory = false }

        do {
            try await library.clearPlaybackHistory()
            guard !Task.isCancelled else { return }
            cancelLoad(for: .recent)
            playbackHistory.removeAll(keepingCapacity: true)
            recentTracks.removeAll(keepingCapacity: true)
            nextCursors[.recent] = nil
            paginationErrors[.recent] = nil
            states[.recent] = .empty
        } catch is CancellationError {
            return
        } catch {
            playbackHistoryClearError = message(for: error)
        }
    }

    public func dismissPlaybackHistoryClearError() {
        playbackHistoryClearError = nil
    }

    public func startObservingChanges() async {
        guard changeTask == nil, changeObservationID == nil else { return }

        let service = library
        let observationID = UUID()
        changeObservationID = observationID
        let stream = await service.makeChangeStream()
        guard changeObservationID == observationID else { return }

        changeTask = Task { @MainActor [weak self] in
            for await change in stream {
                guard let self, !Task.isCancelled else { return }
                self.applyLibraryChange(change)
            }
            self?.finishChangeObservation(observationID)
        }
    }

    public func stopObservingChanges() {
        changeObservationID = nil
        changeTask?.cancel()
        changeTask = nil
        trackRefreshTask?.cancel()
        trackRefreshTask = nil
        pendingTrackRefreshIDs.removeAll()
        pendingTrackRefreshIncludesDeletions = false
    }

    public func select(_ section: LibrarySection) {
        guard selection != section else { return }

        let previousSection = selection
        if !navigationPath.isEmpty {
            navigationPath.removeAll(keepingCapacity: true)
        }
        selection = section
        cancelLoad(for: previousSection)
    }

    public func updateSearchText(_ text: String) {
        guard text != searchText else { return }

        searchText = text
        searchRefreshPending = false
        scheduleSearch(
            for: text,
            delay: searchDebounceNanoseconds,
            clearsResults: true
        )
    }

    public func retrySearch() {
        searchRefreshPending = false
        scheduleSearch(for: searchText, delay: 0, clearsResults: true)
    }

    private func scheduleSearch(
        for text: String,
        delay: UInt64,
        clearsResults: Bool
    ) {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        if clearsResults {
            searchTracks.removeAll(keepingCapacity: true)
            searchAlbums.removeAll(keepingCapacity: true)
            searchArtists.removeAll(keepingCapacity: true)
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            isSearchDebouncing = false
            searchState = .idle
            return
        }

        isSearchDebouncing = true
        searchState = .loading
        let generation = searchGeneration
        let searchResultLimit = searchResultLimit
        let service = library
        searchTask = Task { @MainActor [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                guard let self,
                      self.searchGeneration == generation
                else { return }
                self.isSearchDebouncing = false

                let results = try await service.searchLibrary(
                    LibrarySearchRequest(
                        searchText: normalizedText,
                        sourceID: .local,
                        limit: searchResultLimit
                    )
                )

                guard !Task.isCancelled,
                      self.searchGeneration == generation
                else { return }
                self.searchTracks = results.tracks.map(self.favoriteAdjusted)
                self.searchAlbums = results.albums
                self.searchArtists = results.artists
                self.searchState = self.searchTracks.isEmpty && self.searchAlbums.isEmpty
                    ? .empty
                    : .loaded
            } catch is CancellationError {
                // A newer query owns the next search task.
            } catch {
                guard let self,
                      self.searchGeneration == generation
                else { return }
                self.isSearchDebouncing = false
                self.searchState = .failed(message: self.message(for: error))
            }
            guard let self,
                  self.searchGeneration == generation
            else { return }
            self.searchTask = nil
            guard self.searchRefreshPending else { return }
            self.searchRefreshPending = false
            self.scheduleSearch(
                for: self.searchText,
                delay: self.searchDebounceNanoseconds,
                clearsResults: false
            )
        }
    }

    private func scheduleSearchRefreshAfterLibraryChange() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard searchTask == nil else {
            searchRefreshPending = true
            return
        }
        scheduleSearch(
            for: searchText,
            delay: searchDebounceNanoseconds,
            clearsResults: false
        )
    }

    public func navigate(to destination: LibraryDestination) {
        navigationPath.append(destination)
    }

    public func dismissNavigation() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
    }

    func updateNavigationPath(_ path: [LibraryDestination]) {
        guard navigationPath != path else { return }
        navigationPath = path
    }

    public func startImport(urls: [URL]) async {
        guard let importer else {
            Self.importLogger.error("import rejected reason=missing_importer")
            return
        }
        guard !urls.isEmpty else {
            Self.importLogger.error("import rejected reason=empty_selection")
            return
        }
        if importTask != nil {
            switch importState {
            case .importing, .awaitingConfirmation, .cancelling:
                Self.importLogger.warning("import rejected reason=already_active_task")
                return
            case .idle, .completed, .failed:
                // The terminal event can reach the UI before the stream
                // consumer gets its final scheduling turn. The service has
                // already closed the import session, so release this stale
                // UI-side task reference and allow an immediate retry.
                importTask = nil
            }
        }
        switch importState {
        case .idle, .completed, .failed:
            // A previous terminal result must not block a new picker import.
            // Starting a new request replaces the old result below.
            break
        case .importing, .awaitingConfirmation, .cancelling:
            Self.importLogger.warning("import rejected reason=already_active_state")
            return
        }

        let request = MediaImportRequest(
            importID: UUID(),
            urls: urls,
            // The local content-addressed importer currently has one
            // executable first-version policy: skip an existing hash. The
            // settings enum reserves replacement/duplicate-copy semantics
            // until the library model can represent them safely.
            duplicatePolicy: .skip,
            allowsFolderFailureConfirmation: true
        )
        currentImportID = request.importID
        importFailures = []
        Self.importLogger.info(
            "import request started id=\(request.importID.uuidString) inputCount=\(urls.count)"
        )
        importState = .importing(ImportEventMapper.initialSnapshot(for: request))

        // Held until the import stream terminates; see `PickedURLAccess`.
        let accesses = urls.map(PickedURLAccess.init(url:))

        let stream: AsyncThrowingStream<MediaImportEvent, Error>
        do {
            stream = try await importer.start(request)
            Self.importLogger.debug("import service accepted id=\(request.importID.uuidString)")
        } catch {
            Self.importLogger.error(
                "import service start failed id=\(request.importID.uuidString) error=\(String(describing: error))"
            )
            accesses.forEach { $0.stop() }
            importState = .failed(message(for: error))
            currentImportID = nil
            return
        }

        importTask = Task { @MainActor [weak self] in
            defer { accesses.forEach { $0.stop() } }
            do {
                var receivedTerminalEvent = false
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    if case .itemFailed(_, let url, let error) = event {
                        Self.importLogger.error(
                            "import item failed id=\(event.importID.uuidString) file=\(url.lastPathComponent) code=\(error.diagnosticCode)"
                        )
                    } else if case .confirmationRequired = event {
                        Self.importLogger.info(
                            "import confirmation event received id=\(event.importID.uuidString)"
                        )
                    } else if case .completed(_, let result) = event {
                        Self.importLogger.info(
                            "import completed id=\(result.importID.uuidString) imported=\(result.imported) duplicate=\(result.duplicate) skipped=\(result.skipped) failed=\(result.failed)"
                        )
                    } else if case .cancelled(_, let result) = event {
                        Self.importLogger.warning(
                            "import cancelled id=\(result.importID.uuidString) imported=\(result.imported) failed=\(result.failed)"
                        )
                    }
                    self.applyImportEvent(event)
                    if case .confirmationRequired = event {
                        Self.importLogger.info(
                            "import state updated id=\(event.importID.uuidString) awaitingConfirmation=\(self.importState.confirmationProgress != nil) failureCount=\(self.importState.confirmationProgress?.failures.count ?? 0)"
                        )
                    }
                    receivedTerminalEvent = event.isTerminal
                }
                guard let self, !Task.isCancelled else { return }
                guard self.currentImportID == request.importID else { return }
                self.importTask = nil
                guard !receivedTerminalEvent else { return }
                self.importState = .failed(L("导入服务提前结束，未返回结果。"))
            } catch is CancellationError {
                // Explicit cancellation is represented by the service's cancelled event.
            } catch {
                Self.importLogger.error(
                    "import stream failed id=\(request.importID.uuidString) error=\(String(describing: error))"
                )
                guard let self, self.currentImportID == request.importID else { return }
                self.importTask = nil
                self.importState = .failed(self.message(for: error))
            }
        }
    }

    public func cancelImport() {
        guard let importer, let importID = currentImportID else { return }
        let progress: ImportProgressSnapshot
        switch importState {
        case .importing(let value), .awaitingConfirmation(let value):
            progress = value
        case .idle, .cancelling, .completed, .failed:
            return
        }

        importState = .cancelling(progress)
        Task { @MainActor [weak self] in
            await importer.cancel(importID)
            guard let self,
                  case .cancelling = self.importState
            else { return }
        }
    }

    public func continueImport() {
        guard case .awaitingConfirmation = importState,
              let importer,
              let importID = currentImportID
        else { return }

        if case .awaitingConfirmation(let progress) = importState {
            importState = .importing(progress)
        }
        Task { await importer.continueImport(importID) }
    }

    public func dismissImport() {
        switch importState {
        case .importing, .awaitingConfirmation, .cancelling:
            cancelImport()
        case .idle, .completed, .failed:
            importTask?.cancel()
            importTask = nil
            currentImportID = nil
            importFailures = []
            importState = .idle
        }
    }

    public func handlePickerFailure(_ message: String) {
        importFailures = []
        importState = .failed(message.isEmpty ? L("无法打开文件选择器。") : message)
    }

    private func startOverviewLoad() {
        guard overviewTask == nil else { return }

        let request: LibraryPageRequest
        do {
            request = try LibraryPageRequest(limit: min(pageSize, 10))
        } catch {
            overviewState = .failed(message: message(for: error))
            return
        }

        overviewLoadID &+= 1
        let loadID = overviewLoadID
        let service = library
        overviewState = .loading

        overviewTask = Task { @MainActor [weak self] in
            do {
                let query = AlbumQuery(
                    sourceID: .local,
                    sort: AlbumSortDescriptor(key: .dateAdded, direction: .descending)
                )
                let page = try await service.browseAlbums(matching: query, page: request)
                guard let self,
                      !Task.isCancelled,
                      self.overviewLoadID == loadID
                else { return }

                self.recentAlbums = page.elements
                self.overviewState = page.elements.isEmpty ? .empty : .loaded
            } catch is CancellationError {
                // A newer refresh owns the overview result.
            } catch {
                guard let self, self.overviewLoadID == loadID else { return }
                self.overviewState = self.recentAlbums.isEmpty
                    ? .failed(message: self.message(for: error))
                    : .loaded
            }

            guard let self, self.overviewLoadID == loadID else { return }
            self.overviewTask = nil
        }
    }

    private func startLoad(
        section: LibrarySection,
        reset: Bool
    ) {
        guard activeLoadTokens[section] == nil else { return }

        if !reset && !hasNextPage(for: section) { return }

        let cursor = reset ? nil : nextCursors[section] ?? nil
        let request: LibraryPageRequest
        do {
            request = try LibraryPageRequest(limit: pageSize, cursor: cursor)
        } catch {
            states[section] = .failed(message: message(for: error))
            return
        }

        let query = query(for: section)
        if reset {
            clearResults(for: section)
            states[section] = .loading
        } else if itemsCount(for: section) == 0 {
            states[section] = .loading
        }

        paginationErrors[section] = nil
        let token = (loadSequences[section] ?? 0) &+ 1
        loadSequences[section] = token
        activeLoadTokens[section] = token
        let service = library

        let task = Task { @MainActor [weak self] in
            do {
                switch section {
                case .tracks, .favorites:
                    let page = try await service.browseTracks(matching: query.tracks, page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token
                    )
                case .albums:
                    let page = try await service.browseAlbums(matching: query.albums, page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token
                    )
                case .artists:
                    let page = try await service.browseArtists(matching: query.artists, page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token
                    )
                case .genres:
                    let page = try await service.browseGenres(matching: query.genres, page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token
                    )
                case .folders:
                    let page = try await service.browseFolders(page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token
                    )
                case .recent:
                    let page = try await service.recentHistory(page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token
                    )
                }
            } catch is CancellationError {
                // Cancellation is expected for a newer search or a discarded view.
            } catch {
                self?.apply(
                    error,
                    to: section,
                    token: token
                )
            }
            self?.finishLoad(section: section, token: token)
        }
        loadTasks[section] = task
    }

    private func query(for section: LibrarySection) -> LibraryQuerySet {
        let favorite: LibraryFavoriteFilter = section == .favorites ? .favorite : .any
        return LibraryQuerySet(
            tracks: TrackQuery(
                sourceID: .local,
                favorite: favorite
            ),
            albums: AlbumQuery(
                sourceID: .local,
                sort: albumSortDescriptor
            ),
            artists: ArtistQuery(sourceID: .local),
            genres: GenreQuery(sourceID: .local)
        )
    }

    private func apply(
        _ page: LibraryPage<Track>,
        to section: LibrarySection,
        reset: Bool,
        token: UInt64
    ) {
        guard canApply(section: section, token: token) else { return }
        let elements = page.elements.map(favoriteAdjusted)
        switch section {
        case .favorites:
            if reset { favoriteTracks.removeAll(keepingCapacity: true) }
            favoriteTracks = mergeUnique(
                favoriteTracks,
                with: elements.filter(\.isFavorite),
                by: \.id
            )
        case .recent:
            if reset { recentTracks.removeAll(keepingCapacity: true) }
            recentTracks = mergeUnique(recentTracks, with: elements, by: \.id)
        case .tracks:
            if reset { tracks.removeAll(keepingCapacity: true) }
            tracks = mergeUnique(tracks, with: elements, by: \.id)
        case .albums, .artists, .genres, .folders:
            return
        }
        nextCursors[section] = page.nextCursor
        states[section] = itemsCount(for: section) == 0 ? .empty : .loaded
        paginationErrors[section] = nil
    }

    private func apply(
        _ page: LibraryPage<PlaybackHistoryItem>,
        to section: LibrarySection,
        reset: Bool,
        token: UInt64
    ) {
        guard section == .recent,
              canApply(section: section, token: token)
        else { return }

        let elements = page.elements.map { item in
            item.replacingTrack(favoriteAdjusted(item.track))
        }
        if reset { playbackHistory.removeAll(keepingCapacity: true) }
        playbackHistory = mergeUnique(playbackHistory, with: elements, by: \.id)
        recentTracks = playbackHistory.map(\.track)
        nextCursors[section] = page.nextCursor
        states[section] = playbackHistory.isEmpty ? .empty : .loaded
        paginationErrors[section] = nil
    }

    private func apply(
        _ page: LibraryPage<Album>,
        to section: LibrarySection,
        reset: Bool,
        token: UInt64
    ) {
        guard canApply(section: section, token: token) else { return }
        if reset { albums.removeAll(keepingCapacity: true) }
        albums = mergeUnique(albums, with: page.elements, by: \.id)
        nextCursors[section] = page.nextCursor
        states[section] = albums.isEmpty ? .empty : .loaded
        paginationErrors[section] = nil
    }

    private func apply(
        _ page: LibraryPage<Artist>,
        to section: LibrarySection,
        reset: Bool,
        token: UInt64
    ) {
        guard canApply(section: section, token: token) else { return }
        if reset { artists.removeAll(keepingCapacity: true) }
        artists = mergeUnique(artists, with: page.elements, by: \.id)
        nextCursors[section] = page.nextCursor
        states[section] = artists.isEmpty ? .empty : .loaded
        paginationErrors[section] = nil
    }

    private func apply(
        _ page: LibraryPage<Genre>,
        to section: LibrarySection,
        reset: Bool,
        token: UInt64
    ) {
        guard canApply(section: section, token: token) else { return }
        if reset { genres.removeAll(keepingCapacity: true) }
        genres = mergeUnique(genres, with: page.elements, by: \.id)
        nextCursors[section] = page.nextCursor
        states[section] = genres.isEmpty ? .empty : .loaded
        paginationErrors[section] = nil
    }

    private func apply(
        _ page: LibraryPage<LibraryFolder>,
        to section: LibrarySection,
        reset: Bool,
        token: UInt64
    ) {
        guard canApply(section: section, token: token) else { return }
        if reset { folders.removeAll(keepingCapacity: true) }
        folders = mergeUnique(folders, with: page.elements, by: \.id)
        nextCursors[section] = page.nextCursor
        states[section] = folders.isEmpty ? .empty : .loaded
        paginationErrors[section] = nil
    }

    private func apply(
        _ error: Error,
        to section: LibrarySection,
        token: UInt64
    ) {
        guard canApply(section: section, token: token) else { return }
        let message = message(for: error)
        if itemsCount(for: section) == 0 {
            states[section] = .failed(message: message)
        } else {
            paginationErrors[section] = message
        }
    }

    private func canApply(
        section: LibrarySection,
        token: UInt64
    ) -> Bool {
        activeLoadTokens[section] == token
    }

    private func finishLoad(section: LibrarySection, token: UInt64) {
        guard activeLoadTokens[section] == token else { return }
        activeLoadTokens[section] = nil
        loadTasks[section] = nil
    }

    private func cancelLoad(for section: LibrarySection) {
        loadTasks[section]?.cancel()
        loadTasks[section] = nil
        loadSequences[section] = (loadSequences[section] ?? 0) &+ 1
        activeLoadTokens[section] = nil
        // A cancelled request must not leave a section permanently marked as
        // loading. The next navigation into that section should be able to
        // issue a fresh first-page request.
        if states[section] == .loading {
            states[section] = .idle
        }
    }

    private func clearResults(for section: LibrarySection) {
        nextCursors[section] = nil
        paginationErrors[section] = nil
        switch section {
        case .tracks: tracks.removeAll(keepingCapacity: true)
        case .favorites: favoriteTracks.removeAll(keepingCapacity: true)
        case .recent:
            recentTracks.removeAll(keepingCapacity: true)
            playbackHistory.removeAll(keepingCapacity: true)
        case .albums: albums.removeAll(keepingCapacity: true)
        case .artists: artists.removeAll(keepingCapacity: true)
        case .genres: genres.removeAll(keepingCapacity: true)
        case .folders: folders.removeAll(keepingCapacity: true)
        }
    }

    private func itemsCount(for section: LibrarySection) -> Int {
        switch section {
        case .tracks: return tracks.count
        case .favorites: return favoriteTracks.count
        case .recent: return playbackHistory.count
        case .albums: return albums.count
        case .artists: return artists.count
        case .genres: return genres.count
        case .folders: return folders.count
        }
    }

    private func applyImportEvent(_ event: MediaImportEvent) {
        guard event.importID == currentImportID else { return }

        switch event {
        case .completed(_, let result), .cancelled(_, let result):
            importState = .completed(result)
        case .confirmationRequired:
            guard let progress = importState.progress else { return }
            let updated = ImportEventMapper.apply(event, to: progress)
            importFailures = updated.failures
            importState = .awaitingConfirmation(updated)
        case .discovered, .hashing, .probing, .copying, .persisting, .itemFailed:
            guard let progress = importState.progress else { return }
            let updated = ImportEventMapper.apply(event, to: progress)
            importFailures = updated.failures
            switch importState {
            case .cancelling:
                importState = .cancelling(updated)
            case .importing:
                importState = .importing(updated)
            case .awaitingConfirmation:
                importState = .awaitingConfirmation(updated)
            case .idle, .completed, .failed:
                break
            }
        }
    }

    private func applyLibraryChange(_ change: LibraryChange) {
        let contentCategories: Set<LibraryChangeCategory> = [
            .tracks,
            .albums,
            .artists,
            .genres,
            .artwork,
            .deletions
        ]
        let categories = change.categories
        let affected = change.affectedIDs

        if categories.contains(.playbackHistory) {
            invalidateOrReload(.recent)
        }

        let trackCategories: Set<LibraryChangeCategory> = [
            .tracks,
            .artwork,
            .deletions
        ]
        if !affected.trackIDs.isEmpty && !categories.isDisjoint(with: trackCategories) {
            queueTrackRefresh(
                ids: affected.trackIDs,
                includesDeletions: categories.contains(.deletions)
            )
        } else if !categories.isDisjoint(with: trackCategories) {
            // A producer without typed IDs may still have introduced or
            // removed rows. Refresh only the active track-like section and
            // leave other sections untouched until they are selected.
            if selection == .tracks || selection == .favorites || selection == .recent {
                invalidateOrReload(selection)
            }
        }

        if !affected.albumIDs.isEmpty || categories.contains(.albums) {
            invalidateOrReload(.albums)
        }
        if !affected.artistIDs.isEmpty || categories.contains(.artists) {
            invalidateOrReload(.artists)
        }
        if !affected.genreIDs.isEmpty || categories.contains(.genres) {
            invalidateOrReload(.genres)
        }
        if categories.contains(.deletions) {
            invalidateOrReload(.folders)
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !categories.isDisjoint(with: contentCategories) {
            scheduleSearchRefreshAfterLibraryChange()
        }

        guard !categories.isDisjoint(with: contentCategories),
              overviewState != .idle
        else { return }
        scheduleOverviewRefresh()
    }

    private func invalidateOrReload(_ section: LibrarySection) {
        let known = state(for: section) != .idle || itemsCount(for: section) > 0
        guard known else { return }

        cancelLoad(for: section)
        if section == selection {
            load(section: section, reset: true)
        } else {
            // Keep the old value for any still-attached controller, but mark
            // it stale so the next visit performs a first-page query.
            if states[section] != .idle {
                states[section] = .idle
            }
        }
    }

    private func scheduleOverviewRefresh() {
        overviewRefreshTask?.cancel()
        overviewRefreshTask = Task { @MainActor [weak self] in
            do {
                // Metadata imports commonly emit one commit per item. Delay
                // the overview query until that burst settles.
                try await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                self.overviewRefreshTask = nil
                self.refreshOverview()
            } catch is CancellationError {
                // A newer change owns the coalescing window.
            } catch {
                // Task.sleep has no other expected failure.
            }
        }
    }

    private func queueTrackRefresh(
        ids: Set<MediaItemID>,
        includesDeletions: Bool
    ) {
        pendingTrackRefreshIDs.formUnion(ids)
        pendingTrackRefreshIncludesDeletions =
            pendingTrackRefreshIncludesDeletions || includesDeletions
        guard trackRefreshTask == nil else { return }

        trackRefreshTask = Task { @MainActor [weak self] in
            do {
                // Coalesce per-item metadata commits without delaying the
                // normal empty-section refresh path.
                try await Task.sleep(nanoseconds: 30_000_000)
                guard let self, !Task.isCancelled else { return }

                let ids = self.pendingTrackRefreshIDs
                let includesDeletions = self.pendingTrackRefreshIncludesDeletions
                self.pendingTrackRefreshIDs.removeAll()
                self.pendingTrackRefreshIncludesDeletions = false
                let service = self.library

                let results = await withTaskGroup(
                    of: TrackRefreshResult.self,
                    returning: [TrackRefreshResult].self
                ) { group in
                    for id in ids {
                        group.addTask {
                            do {
                                return TrackRefreshResult(
                                    id: id,
                                    track: try await service.track(id: id),
                                    succeeded: true
                                )
                            } catch {
                                return TrackRefreshResult(
                                    id: id,
                                    track: nil,
                                    succeeded: false
                                )
                            }
                        }
                    }

                    var values: [TrackRefreshResult] = []
                    values.reserveCapacity(ids.count)
                    for await result in group {
                        values.append(result)
                    }
                    return values
                }

                var needsTracksReload = false
                var needsFavoritesReload = false
                var needsRecentReload = false

                for result in results {
                    if let track = result.track {
                        let wasCached = self.hasCachedTrack(track.id)
                        self.applyTrackUpdate(track)
                        if !wasCached {
                            needsTracksReload = self.state(for: .tracks) != .idle
                            needsFavoritesReload = self.state(for: .favorites) != .idle
                            needsRecentReload = self.state(for: .recent) != .idle
                        }
                    } else if result.succeeded && includesDeletions {
                        self.removeDeletedTrack(result.id)
                    }
                }

                // A newly imported track is not appended to every cached
                // collection. Invalidate each already-known section once per
                // coalesced burst so its own query decides membership/order.
                if needsTracksReload { self.invalidateOrReload(.tracks) }
                if needsFavoritesReload { self.invalidateOrReload(.favorites) }
                if needsRecentReload { self.invalidateOrReload(.recent) }

                self.trackRefreshTask = nil
                if !self.pendingTrackRefreshIDs.isEmpty {
                    self.queueTrackRefresh(ids: [], includesDeletions: false)
                }
            } catch is CancellationError {
                guard let self else { return }
                self.trackRefreshTask = nil
            } catch {
                guard let self else { return }
                self.trackRefreshTask = nil
            }
        }
    }

    private func hasCachedTrack(_ itemID: MediaItemID) -> Bool {
        tracks.contains(where: { $0.id == itemID })
            || favoriteTracks.contains(where: { $0.id == itemID })
            || recentTracks.contains(where: { $0.id == itemID })
            || searchTracks.contains(where: { $0.id == itemID })
            || playbackHistory.contains(where: { $0.track.id == itemID })
    }

    @discardableResult
    private func applyTrackUpdate(_ track: Track) -> Bool {
        var didChange = false

        if let index = tracks.firstIndex(where: { $0.id == track.id }),
           tracks[index] != track {
            tracks[index] = track
            didChange = true
        }
        if let index = recentTracks.firstIndex(where: { $0.id == track.id }),
           recentTracks[index] != track {
            recentTracks[index] = track
            didChange = true
        }
        if let index = searchTracks.firstIndex(where: { $0.id == track.id }),
           searchTracks[index] != track {
            searchTracks[index] = track
            didChange = true
        }

        var updatedHistory = playbackHistory
        var historyChanged = false
        for index in updatedHistory.indices where updatedHistory[index].track.id == track.id {
            let updated = updatedHistory[index].replacingTrack(track)
            if updatedHistory[index] != updated {
                updatedHistory[index] = updated
                historyChanged = true
            }
        }
        if historyChanged {
            playbackHistory = updatedHistory
            didChange = true
        }

        if let index = favoriteTracks.firstIndex(where: { $0.id == track.id }) {
            if favoriteTracks[index] != track {
                favoriteTracks[index] = track
                didChange = true
            }
        } else if track.isFavorite,
                  (state(for: .favorites) == .loaded || state(for: .favorites) == .empty),
                  tracks.contains(where: { $0.id == track.id }) {
            // Only add a newly-favorite item to an already-loaded favorites
            // section when the item is also present in the loaded track cache.
            favoriteTracks.append(track)
            didChange = true
        }

        if !track.isFavorite,
           favoriteTracks.contains(where: { $0.id == track.id }) {
            favoriteTracks.removeAll { $0.id == track.id }
            didChange = true
        }
        return didChange
    }

    private func runFavoriteMutations(for itemID: MediaItemID) async {
        defer { favoriteTasks[itemID] = nil }
        while let request = favoriteRequests[itemID] {
            do {
                let track = try await library.setFavorite(request.value, for: itemID)
                guard !Task.isCancelled else { return }
                guard favoriteRequests[itemID]?.version == request.version else { continue }
                favoriteRequests[itemID] = nil
                applyFavorite(track)
            } catch {
                guard favoriteRequests[itemID]?.version == request.version else { continue }
                favoriteRequests[itemID] = nil
                let persisted = try? await library.track(id: itemID)
                applyFavorite(persisted ?? request.fallback)
            }
        }
    }

    private func favoriteAdjusted(_ track: Track) -> Track {
        guard let request = favoriteRequests[track.id] else { return track }
        return replacingFavorite(in: track, with: request.value)
    }

    private func favoriteValue(for track: Track) -> Bool {
        if let request = favoriteRequests[track.id] {
            return request.value
        }
        if let visible = tracks.first(where: { $0.id == track.id })
            ?? recentTracks.first(where: { $0.id == track.id })
            ?? searchTracks.first(where: { $0.id == track.id })
            ?? favoriteTracks.first(where: { $0.id == track.id }) {
            return visible.isFavorite
        }
        return track.isFavorite
    }

    private func applyFavorite(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
        }
        if let index = recentTracks.firstIndex(where: { $0.id == track.id }) {
            recentTracks[index] = track
        }
        if let index = searchTracks.firstIndex(where: { $0.id == track.id }) {
            searchTracks[index] = track
        }

        var updatedHistory = playbackHistory
        var historyChanged = false
        for index in updatedHistory.indices where updatedHistory[index].track.id == track.id {
            updatedHistory[index] = updatedHistory[index].replacingTrack(track)
            historyChanged = true
        }
        if historyChanged {
            playbackHistory = updatedHistory
        }
        if track.isFavorite {
            if let index = favoriteTracks.firstIndex(where: { $0.id == track.id }) {
                favoriteTracks[index] = track
            } else if state(for: .favorites) != .idle {
                favoriteTracks.append(track)
            }
        } else if favoriteTracks.contains(where: { $0.id == track.id }) {
            favoriteTracks.removeAll { $0.id == track.id }
        }
    }

    private func replacingFavorite(in track: Track, with isFavorite: Bool) -> Track {
        Track(
            id: track.id,
            logicalTrackID: track.logicalTrackID,
            assetID: track.assetID,
            playbackSelection: track.playbackSelection,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            trackTotal: track.trackTotal,
            discNumber: track.discNumber,
            discTotal: track.discTotal,
            fileName: track.fileName,
            folderPath: track.folderPath,
            duration: track.duration,
            technicalInfo: track.technicalInfo,
            year: track.year,
            comment: track.comment,
            lyrics: track.lyrics,
            artwork: track.artwork,
            isFavorite: isFavorite,
            statistics: track.statistics
        )
    }

    private func finishChangeObservation(_ observationID: UUID) {
        guard changeObservationID == observationID else { return }
        changeObservationID = nil
        changeTask = nil
    }

    private func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return L("资料库暂时无法加载，请稍后重试。")
    }
}

private struct LibraryQuerySet {
    let tracks: TrackQuery
    let albums: AlbumQuery
    let artists: ArtistQuery
    let genres: GenreQuery
}

private struct TrackRefreshResult: Sendable {
    let id: MediaItemID
    let track: Track?
    let succeeded: Bool
}

private func mergeUnique<Element, ID: Hashable>(
    _ existing: [Element],
    with newElements: [Element],
    by id: (Element) -> ID
) -> [Element] {
    var result = existing
    var indices: [ID: Int] = [:]
    for index in result.indices {
        indices[id(result[index])] = index
    }

    for element in newElements {
        let identifier = id(element)
        if let index = indices[identifier] {
            // A later page or a change-triggered refresh may carry richer
            // relationships for an already visible item. Keep its position,
            // but replace the stale value.
            result[index] = element
        } else {
            indices[identifier] = result.count
            result.append(element)
        }
    }
    return result
}
