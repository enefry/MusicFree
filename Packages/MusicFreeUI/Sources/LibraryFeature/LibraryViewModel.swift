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

/// Owns library query tasks, pagination cursors, search generations, selection,
/// navigation and import task lifetime on the main actor.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var selection: LibrarySection
    @Published public private(set) var searchText = ""
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
    @Published public private(set) var isSearchDebouncing = false

    let library: any AppServices.LibraryServing
    private let importer: (any AppServices.ImportServing)?
    private let refreshPreparation: (@MainActor @Sendable () async -> Void)?
    private let pageSize: Int
    private let searchDebounceNanoseconds: UInt64

    private var nextCursors: [LibrarySection: LibraryCursor?] = [:]
    private var loadSequences: [LibrarySection: UInt64] = [:]
    private var activeLoadTokens: [LibrarySection: UInt64] = [:]
    private var loadTasks: [LibrarySection: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
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
        refreshPreparation: (@MainActor @Sendable () async -> Void)? = nil,
        selection: LibrarySection = .tracks,
        pageSize: Int = 50,
        searchDebounceNanoseconds: UInt64 = 250_000_000
    ) {
        self.library = library
        self.importer = importer
        self.refreshPreparation = refreshPreparation
        self.selection = selection
        self.pageSize = min(max(1, pageSize), LibraryPageRequest.maximumLimit)
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
        self.states = Dictionary(uniqueKeysWithValues: LibrarySection.allCases.map { ($0, .idle) })
    }

    deinit {
        loadTasks.values.forEach { $0.cancel() }
        searchTask?.cancel()
        importTask?.cancel()
        overviewTask?.cancel()
        changeTask?.cancel()
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

        let preparation = refreshPreparation
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
            reset: reset,
            expectedSearchGeneration: searchGeneration
        )
    }

    public func loadNextPage(for section: LibrarySection? = nil) {
        let section = section ?? selection
        guard hasNextPage(for: section), !isLoading(section) else { return }
        startLoad(
            section: section,
            reset: false,
            expectedSearchGeneration: searchGeneration
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
        tracks.removeAll { $0.id == itemID }
        favoriteTracks.removeAll { $0.id == itemID }
        recentTracks.removeAll { $0.id == itemID }
        playbackHistory.removeAll { $0.track.id == itemID }

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
    }

    public func select(_ section: LibrarySection) {
        guard selection != section else { return }

        let previousSection = selection
        selection = section
        searchTask?.cancel()
        searchTask = nil
        isSearchDebouncing = false
        cancelLoad(for: previousSection)
    }

    public func updateSearchText(_ text: String) {
        guard text != searchText else { return }

        searchText = text
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        cancelLoad(for: selection)

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            isSearchDebouncing = false
            load(section: selection, reset: true)
            return
        }

        isSearchDebouncing = true
        let generation = searchGeneration
        let section = selection
        let delay = searchDebounceNanoseconds
        searchTask = Task { @MainActor [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                guard let self,
                      self.searchGeneration == generation,
                      self.selection == section
                else { return }
                self.isSearchDebouncing = false
                self.startLoad(
                    section: section,
                    reset: true,
                    expectedSearchGeneration: generation
                )
            } catch is CancellationError {
                // A newer query owns the next search task.
            } catch {
                // Task.sleep has no other expected failure; keep the current query intact.
            }
        }
    }

    public func navigate(to destination: LibraryDestination) {
        navigationPath.append(destination)
    }

    public func dismissNavigation() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
    }

    func updateNavigationPath(_ path: [LibraryDestination]) {
        navigationPath = path
    }

    public func startImport(urls: [URL]) async {
        guard let importer,
              !urls.isEmpty,
              importTask == nil,
              importState.isIdle
        else { return }

        let request = MediaImportRequest(
            importID: UUID(),
            urls: urls,
            // The local content-addressed importer currently has one
            // executable first-version policy: skip an existing hash. The
            // settings enum reserves replacement/duplicate-copy semantics
            // until the library model can represent them safely.
            duplicatePolicy: .skip
        )
        currentImportID = request.importID
        importState = .importing(ImportEventMapper.initialSnapshot(for: request))

        let stream: AsyncThrowingStream<MediaImportEvent, Error>
        do {
            stream = try await importer.start(request)
        } catch {
            importState = .failed(message(for: error))
            currentImportID = nil
            return
        }

        importTask = Task { @MainActor [weak self] in
            do {
                var receivedTerminalEvent = false
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.applyImportEvent(event)
                    receivedTerminalEvent = event.isTerminal
                }
                guard let self, !Task.isCancelled else { return }
                self.importTask = nil
                guard !receivedTerminalEvent else { return }
                self.importState = .failed(L("导入服务提前结束，未返回结果。"))
            } catch is CancellationError {
                // Explicit cancellation is represented by the service's cancelled event.
            } catch {
                self?.importTask = nil
                self?.importState = .failed(self?.message(for: error) ?? L("import.failed.message"))
            }
        }
    }

    public func cancelImport() {
        guard case .importing(let progress) = importState,
              let importer,
              let importID = currentImportID
        else { return }

        importState = .cancelling(progress)
        Task { @MainActor [weak self] in
            await importer.cancel(importID)
            guard let self,
                  case .cancelling = self.importState
            else { return }
        }
    }

    public func dismissImport() {
        switch importState {
        case .importing, .cancelling:
            cancelImport()
        case .idle, .completed, .failed:
            importTask?.cancel()
            importTask = nil
            currentImportID = nil
            importState = .idle
        }
    }

    public func handlePickerFailure(_ message: String) {
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
        reset: Bool,
        expectedSearchGeneration: UInt64
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
                        token: token,
                        searchGeneration: expectedSearchGeneration
                    )
                case .albums:
                    let page = try await service.browseAlbums(matching: query.albums, page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token,
                        searchGeneration: expectedSearchGeneration
                    )
                case .artists:
                    let page = try await service.browseArtists(matching: query.artists, page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token,
                        searchGeneration: expectedSearchGeneration
                    )
                case .genres:
                    let page = try await service.browseGenres(matching: query.genres, page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token,
                        searchGeneration: expectedSearchGeneration
                    )
                case .folders:
                    let page = try await service.browseFolders(page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token,
                        searchGeneration: expectedSearchGeneration
                    )
                case .recent:
                    let page = try await service.recentHistory(page: request)
                    guard let self, !Task.isCancelled else { return }
                    self.apply(
                        page,
                        to: section,
                        reset: reset,
                        token: token,
                        searchGeneration: expectedSearchGeneration
                    )
                }
            } catch is CancellationError {
                // Cancellation is expected for a newer search or a discarded view.
            } catch {
                self?.apply(
                    error,
                    to: section,
                    token: token,
                    searchGeneration: expectedSearchGeneration
                )
            }
            self?.finishLoad(section: section, token: token)
        }
        loadTasks[section] = task
    }

    private func query(for section: LibrarySection) -> LibraryQuerySet {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchText = text.isEmpty ? nil : text
        let favorite: LibraryFavoriteFilter = section == .favorites ? .favorite : .any
        return LibraryQuerySet(
            tracks: TrackQuery(
                searchText: searchText,
                sourceID: .local,
                favorite: favorite
            ),
            albums: AlbumQuery(
                searchText: searchText,
                sourceID: .local,
                sort: albumSortDescriptor
            ),
            artists: ArtistQuery(searchText: searchText, sourceID: .local),
            genres: GenreQuery(searchText: searchText, sourceID: .local)
        )
    }

    private func apply(
        _ page: LibraryPage<Track>,
        to section: LibrarySection,
        reset: Bool,
        token: UInt64,
        searchGeneration: UInt64
    ) {
        guard canApply(section: section, token: token, searchGeneration: searchGeneration) else { return }
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
        token: UInt64,
        searchGeneration: UInt64
    ) {
        guard section == .recent,
              canApply(section: section, token: token, searchGeneration: searchGeneration)
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
        token: UInt64,
        searchGeneration: UInt64
    ) {
        guard canApply(section: section, token: token, searchGeneration: searchGeneration) else { return }
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
        token: UInt64,
        searchGeneration: UInt64
    ) {
        guard canApply(section: section, token: token, searchGeneration: searchGeneration) else { return }
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
        token: UInt64,
        searchGeneration: UInt64
    ) {
        guard canApply(section: section, token: token, searchGeneration: searchGeneration) else { return }
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
        token: UInt64,
        searchGeneration: UInt64
    ) {
        guard canApply(section: section, token: token, searchGeneration: searchGeneration) else { return }
        if reset { folders.removeAll(keepingCapacity: true) }
        folders = mergeUnique(folders, with: page.elements, by: \.id)
        nextCursors[section] = page.nextCursor
        states[section] = folders.isEmpty ? .empty : .loaded
        paginationErrors[section] = nil
    }

    private func apply(
        _ error: Error,
        to section: LibrarySection,
        token: UInt64,
        searchGeneration: UInt64
    ) {
        guard canApply(section: section, token: token, searchGeneration: searchGeneration) else { return }
        let message = message(for: error)
        if itemsCount(for: section) == 0 {
            states[section] = .failed(message: message)
        } else {
            paginationErrors[section] = message
        }
    }

    private func canApply(
        section: LibrarySection,
        token: UInt64,
        searchGeneration: UInt64
    ) -> Bool {
        activeLoadTokens[section] == token && self.searchGeneration == searchGeneration
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
        case .discovered, .hashing, .probing, .copying, .persisting, .itemFailed:
            guard let progress = importState.progress else { return }
            let updated = ImportEventMapper.apply(event, to: progress)
            switch importState {
            case .cancelling:
                importState = .cancelling(updated)
            case .importing:
                importState = .importing(updated)
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
        if change.categories.contains(.playbackHistory),
           change.categories.isDisjoint(with: contentCategories) {
            cancelLoad(for: .recent)
            nextCursors[.recent] = nil
            paginationErrors[.recent] = nil
            if selection == .recent {
                load(section: .recent, reset: true)
            } else {
                states[.recent] = .idle
            }
            return
        }

        guard !change.categories.isDisjoint(with: contentCategories) else { return }

        for section in LibrarySection.allCases {
            cancelLoad(for: section)
            nextCursors[section] = nil
            paginationErrors[section] = nil
            if section != selection {
                states[section] = .idle
            }
        }

        load(section: selection, reset: true)
        refreshOverview()
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
            ?? favoriteTracks.first(where: { $0.id == track.id }) {
            return visible.isFavorite
        }
        return track.isFavorite
    }

    private func applyFavorite(_ track: Track) {
        tracks = tracks.map { $0.id == track.id ? track : $0 }
        recentTracks = recentTracks.map { $0.id == track.id ? track : $0 }
        playbackHistory = playbackHistory.map { item in
            item.track.id == track.id ? item.replacingTrack(track) : item
        }
        if track.isFavorite {
            if let index = favoriteTracks.firstIndex(where: { $0.id == track.id }) {
                favoriteTracks[index] = track
            } else {
                favoriteTracks.append(track)
            }
        } else {
            favoriteTracks.removeAll { $0.id == track.id }
        }
    }

    private func replacingFavorite(in track: Track, with isFavorite: Bool) -> Track {
        Track(
            id: track.id,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            folderPath: track.folderPath,
            duration: track.duration,
            technicalInfo: track.technicalInfo,
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

private func mergeUnique<Element, ID: Hashable>(
    _ existing: [Element],
    with newElements: [Element],
    by id: (Element) -> ID
) -> [Element] {
    var result = existing
    var identifiers = Set(existing.map(id))
    for element in newElements where identifiers.insert(id(element)).inserted {
        result.append(element)
    }
    return result
}
