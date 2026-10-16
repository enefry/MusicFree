import AppServices
import DesignSystem
import Observation
import PlaybackAPI
import SettingsAPI

public enum SettingsDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
    case general
    case playback
    case importing
    case storage
    case privacy
    case about

    public var id: Self { self }

    public var title: String {
        switch self {
        case .general: L("settings.category.general")
        case .playback: L("settings.category.playback")
        case .importing: L("settings.category.importing")
        case .storage: L("settings.category.storage")
        case .privacy: L("settings.category.privacy")
        case .about: L("settings.category.about")
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .playback: "play.circle"
        case .importing: "square.and.arrow.down"
        case .storage: "internaldrive"
        case .privacy: "hand.raised.circle"
        case .about: "info.circle"
        }
    }
}

public enum SettingsSceneLayout: Sendable {
    case compact
    case detail(SettingsDestination)
}

@MainActor
@Observable
public final class SettingsSceneModel {
    let viewModel: SettingsViewModel
    @ObservationIgnored private var initialLoadTask: Task<Void, Never>?

    /// Compact and regular UIKit surfaces share a single loaded settings model.
    func loadIfNeeded() async {
        if let initialLoadTask {
            await initialLoadTask.value
            return
        }
        guard viewModel.loadState == .idle else { return }
        let viewModel = viewModel
        let task = Task { await viewModel.load() }
        initialLoadTask = task
        await task.value
        initialLoadTask = nil
    }
    /// Presentation only; preserve configured preferences across resource/rate limits.
    public func observeTransitionCapabilities(_ stream: AsyncStream<PlaybackSessionSnapshot>) async {
        for await snapshot in stream {
            guard !Task.isCancelled else { return }
            if viewModel.transitionCapabilities != snapshot.capabilities {
                viewModel.transitionCapabilities = snapshot.capabilities
            }
        }
    }

    public init(
        settingsServing: any SettingsServing,
        storageMaintenance: (any StorageMaintenanceServing)? = nil,
        metadataEnrichment: (any MetadataEnrichmentServing)? = nil,
        lyricsServing: (any LyricsServing)? = nil
    ) {
        viewModel = SettingsViewModel(
            store: AppServicesSettingsStore(
                serving: settingsServing,
                storageMaintenance: storageMaintenance
            ),
            metadataEnrichment: metadataEnrichment,
            lyricsServing: lyricsServing
        )
    }

    init(
        store: any SettingsFeatureStore,
        metadataEnrichment: (any MetadataEnrichmentServing)? = nil,
        lyricsServing: (any LyricsServing)? = nil
    ) {
        viewModel = SettingsViewModel(
            store: store,
            metadataEnrichment: metadataEnrichment,
            lyricsServing: lyricsServing
        )
    }
}
