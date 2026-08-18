import AppServices
import DesignSystem
import LibraryFeature
import MusicDomain
import PlayerFeature
import PlaylistFeature
import SettingsFeature
import SwiftUI

struct RootScene: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("musicfree.appearance") private var persistedAppearance = MusicFreeAppearance.system.rawValue
    @AppStorage(MusicFreeLocalization.languageStorageKey) private var persistedLanguage = MusicFreeLanguage.english.rawValue
    @State private var router: AppRouter
    @State private var sceneID = UUID()
    @State private var isSettingsResetConfirmationPresented = false

    @ObservedObject private var container: AppContainer

    init(container: AppContainer) {
        _container = ObservedObject(wrappedValue: container)
        _router = State(initialValue: container.router)
    }

    var body: some View {
        startupAwareContent
            .tint(MusicFreeColorTokens.accent)
            .preferredColorScheme(appearance.colorScheme)
            .environment(\.locale, language.locale)
            .task {
                await startServices()
            }
            .onAppear {
                container.sceneDidAppear(sceneID)
            }
            .onDisappear {
                container.sceneDidDisappear(sceneID)
            }
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                container.lifecycleCoordinator.handle(scenePhase: newPhase)
                if newPhase == .active {
                    Task { await scanDocumentsIfNeeded() }
                }
            }
            .onChange(of: router.selectedRoute, initial: true) { _, route in
                if route == .library {
                    Task { await scanDocumentsIfNeeded() }
                }
            }
            .confirmationDialog(
                L("恢复默认设置？"),
                isPresented: $isSettingsResetConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button(L("恢复默认设置"), role: .destructive) {
                    Task { await container.resetCorruptedSettings() }
                }
                Button(L("取消"), role: .cancel) {}
            } message: {
                Text(L("无法读取的设置数据将被替换，资料库和媒体文件不会被删除。"))
            }
    }

    @ViewBuilder
    private var startupAwareContent: some View {
        ZStack {
            switch container.startupState {
            case .loading:
                MusicFreeLaunchAnimation()
//                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .recoveryRequired:
                recoveryStatusView
                    .transition(.opacity)
            case .ready:
                appContent
                    .transition(.opacity)
            case .degraded:
                appContent
                    .safeAreaInset(edge: .top, spacing: 0) {
                        degradedNotice
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.28), value: container.startupState)
    }

    private var appContent: some View {
        Group {
            if let services = container.serviceContainer {
                configuredAppContent(services)
            } else {
                MusicFreeLaunchAnimation()
            }
        }
    }

    private func configuredAppContent(_ services: AppServiceContainer) -> some View {
        Group {
            if horizontalSizeClass == .regular {
                splitView(services: services)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        MiniPlayerView(
                            serving: services.playbackServing,
                            audioServing: services.playbackAudioServing,
                            artworkServing: services.artworkServing,
                            library: services.libraryServing,
                            onPresentPlayer: { router.present(.player) }
                        )
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }
            } else {
                compactContent(services: services)
            }
        }
        .background(MusicFreeColorTokens.backgroundPrimary.ignoresSafeArea())
        .sheet(item: $router.presented) { presentation in
            presentedView(for: presentation)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                // Keep the edge-to-edge player canvas opaque around the status bar.
                .presentationCornerRadius(0)
                .presentationBackground(MusicFreeColorTokens.backgroundPrimary)
        }
    }

    private func compactContent(services: AppServiceContainer) -> some View {
        TabView(selection: compactTabSelection) {
            ForEach(AppRouter.Route.allCases) { route in
                compactDestinationView(route, services: services)
                    .tabItem {
                        Label(route.title, systemImage: route.systemImage)
                    }
                    .tag(route.rawValue)
            }
        }
        .tabViewBottomAccessory {
            MiniPlayerView(
                serving: services.playbackServing,
                audioServing: services.playbackAudioServing,
                artworkServing: services.artworkServing,
                library: services.libraryServing,
                onPresentPlayer: { router.present(.player) }
            )
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .accessibilityIdentifier("app.tabBar")
        .background(MusicFreeColorTokens.backgroundPrimary.ignoresSafeArea())
    }

    @ViewBuilder
    private func compactDestinationView(
        _ route: AppRouter.Route,
        services: AppServiceContainer
    ) -> some View {
        switch route {
        case .library:
            LibraryScene(
                library: services.libraryServing,
                importer: container.importAvailable ? services.importServing : nil,
                refreshPreparation: { await scanDocumentsIfNeeded() },
                artworkServing: services.artworkServing,
                playTrack: { itemID in
                    Task { @MainActor in
                        await services.playbackServing.send(.play(itemID: itemID))
                    }
                },
                playTracks: { itemIDs, shuffle in
                    startPlayback(
                        itemIDs: itemIDs,
                        shuffle: shuffle,
                        services: services
                    )
                },
                enqueueNextTracks: { itemIDs in
                    Task { @MainActor in
                        await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
                    }
                },
                enqueueTracks: { itemIDs in
                    Task { @MainActor in
                        await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
                    }
                },
                playlistServing: services.playlistServing
            )
        case .playlists:
            PlaylistScene(
                playlistServing: services.playlistServing,
                playbackServing: services.playbackServing,
                libraryServing: services.libraryServing
            )
        case .settings:
            NavigationStack {
                SettingsScene(
                    settingsServing: services.settingsServing,
                    storageMaintenance: services.storageMaintenanceServing,
                    appearance: appearanceBinding,
                    language: languageBinding,
                    releaseInfoProvider: AppReleaseInfoProvider(),
                    diagnosticsProvider: AppDiagnosticsProvider(
                        exporter: container.diagnosticsExporter
                    ),
                    appIconOptions: appIconOptions,
                    appIconProvider: AppAlternateIconProvider(),
                    sleepTimerServing: services.sleepTimerServing,
                    metadataEnrichment: services.metadataEnrichmentServing,
                    additionContent: additionSettingsContent
                )
            }
        }
    }

    @ViewBuilder
    private func additionSettingsContent() -> some View {
    }

    private var compactTabSelection: Binding<String> {
        Binding(
            get: { router.selectedRoute.rawValue },
            set: { rawValue in
                guard let route = AppRouter.Route(rawValue: rawValue) else { return }
                router.select(route)
            }
        )
    }

    @ViewBuilder
    private func splitView(services: AppServiceContainer) -> some View {
        NavigationSplitView {
            List(selection: splitSelection) {
                ForEach(AppRouter.Route.allCases) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            .navigationTitle(L("app.name"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            NavigationStack {
                destinationView(router.selectedRoute, services: services)
            }
        }
    }

    private var splitSelection: Binding<AppRouter.Route?> {
        Binding(
            get: { router.selectedRoute },
            set: { newRoute in
                if let newRoute {
                    router.select(newRoute)
                }
            }
        )
    }

    @ViewBuilder
    private func destinationView(
        _ destination: AppRouter.Route,
        services: AppServiceContainer
    ) -> some View {
        switch destination {
        case .library:
            LibraryScene(
                library: services.libraryServing,
                importer: container.importAvailable ? services.importServing : nil,
                refreshPreparation: { await scanDocumentsIfNeeded() },
                artworkServing: services.artworkServing,
                playTrack: { itemID in
                    Task { @MainActor in
                        await services.playbackServing.send(.play(itemID: itemID))
                    }
                },
                playTracks: { itemIDs, shuffle in
                    startPlayback(
                        itemIDs: itemIDs,
                        shuffle: shuffle,
                        services: services
                    )
                },
                enqueueNextTracks: { itemIDs in
                    Task { @MainActor in
                        await services.playbackServing.send(.enqueueNext(itemIDs: itemIDs))
                    }
                },
                enqueueTracks: { itemIDs in
                    Task { @MainActor in
                        await services.playbackServing.send(.enqueueItems(itemIDs: itemIDs))
                    }
                },
                playlistServing: services.playlistServing
            )
        case .playlists:
            PlaylistScene(
                playlistServing: services.playlistServing,
                playbackServing: services.playbackServing,
                libraryServing: services.libraryServing
            )
        case .settings:
            SettingsScene(
                settingsServing: services.settingsServing,
                storageMaintenance: services.storageMaintenanceServing,
                appearance: appearanceBinding,
                language: languageBinding,
                releaseInfoProvider: AppReleaseInfoProvider(),
                diagnosticsProvider: AppDiagnosticsProvider(
                    exporter: container.diagnosticsExporter
                ),
                appIconOptions: appIconOptions,
                appIconProvider: AppAlternateIconProvider(),
                sleepTimerServing: services.sleepTimerServing,
                metadataEnrichment: services.metadataEnrichmentServing,
                additionContent: additionSettingsContent
            )
        }
    }

    @ViewBuilder
    private func presentedView(for presentation: AppRouter.Presentation) -> some View {
        switch presentation {
        case .player:
            NavigationStack {
                if let services = container.serviceContainer {
                    PlayerScene(
                        serving: services.playbackServing,
                        audioServing: services.playbackAudioServing,
                        artworkServing: services.artworkServing,
                        library: services.libraryServing
                    )
                } else {
                    PlayerScene(serving: PlayerStore())
                }
            }
        }
    }

    private func startPlayback(
        itemIDs: [MediaItemID],
        shuffle: Bool,
        services: AppServiceContainer
    ) {
        guard !itemIDs.isEmpty else { return }

        Task { @MainActor in
            await services.playbackServing.send(
                .playItems(itemIDs: itemIDs, shuffle: shuffle)
            )
        }
    }

    private var appearance: MusicFreeAppearance {
        MusicFreeAppearance(rawValue: persistedAppearance) ?? .system
    }

    private var language: MusicFreeLanguage {
        MusicFreeLanguage(rawValue: persistedLanguage) ?? .english
    }

    private var appearanceBinding: Binding<MusicFreeAppearance> {
        Binding(
            get: { appearance },
            set: { persistedAppearance = $0.rawValue }
        )
    }

    private var languageBinding: Binding<MusicFreeLanguage> {
        Binding(
            get: { language },
            set: { persistedLanguage = $0.rawValue }
        )
    }

    private var appIconOptions: [SettingsAppIconOption] {
        [
            SettingsAppIconOption(
                id: "default",
                title: L("经典"),
                alternateIconName: nil,
                previewAssetName: "AppIcon-preview"
            ),
            SettingsAppIconOption(
                id: "music",
                title: L("手写"),
                alternateIconName: "AppIcon-music",
                previewAssetName: "AppIcon-music-preview"
            ),
            SettingsAppIconOption(
                id: "circle",
                title: L("唱片"),
                alternateIconName: "AppIcon-cicle",
                previewAssetName: "AppIcon-cicle-preview"
            ),
            SettingsAppIconOption(
                id: "circle2",
                title: L("唱片2"),
                alternateIconName: "AppIcon-cicle2",
                previewAssetName: "AppIcon-cicle2-preview"
            ),
        ]
    }

    func startServices() async {
        if container.serviceContainer == nil {
            guard await container.retryComposition() else {
                return
            }
        }
        guard !Task.isCancelled else { return }
        guard let services = container.serviceContainer else { return }

        container.updateStartupState(.loading)

        do {
            let report = try await services.start()
            guard container.serviceContainer === services else {
                await services.stop()
                return
            }
            container.completeStartup(report)
        } catch is CancellationError {
            return
        } catch {
            await container.handleFailedServiceStart(services, error: error)
        }
    }

    @ViewBuilder
    private var recoveryStatusView: some View {
        VStack(spacing: MusicFreeSpacingTokens.large) {
            ContentUnavailableView(
                container.startupState.title,
                systemImage: container.startupState.systemImage,
                description: Text(container.startupState.message)
            )

            Button(L("重试启动"), systemImage: "arrow.clockwise") {
                Task { await startServices() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(MusicFreeSpacingTokens.large)
    }

    private var degradedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: container.startupState.systemImage)
            Text(container.startupState.title)
                .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .trailing) {
            HStack(spacing: MusicFreeSpacingTokens.small) {
                if container.startupState.issues.contains(.settingsCorrupted) {
                    Button(L("恢复设置"), systemImage: "arrow.counterclockwise") {
                        isSettingsResetConfirmationPresented = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(L("恢复默认设置"))
                }

                Button(L("重试"), systemImage: "arrow.clockwise") {
                    Task {
                        await container.stopServicesAndDiscardComposition()
                        await startServices()
                    }
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(L("重试启动"))
            }
            .padding(.trailing, MusicFreeSpacingTokens.medium)
        }
    }

    private func scanDocumentsIfNeeded(force: Bool = false) async {
        guard let scanner = container.documentsScanner else { return }
        do {
            _ = try await scanner.scanIfNeeded(force: force)
        } catch is CancellationError {
            return
        } catch {
            container.diagnosticsExporter.record(
                code: "import.documents.scan-failed",
                message: String(describing: error)
            )
        }
    }
}

private struct MusicFreeLaunchAnimation: View {
    var body: some View {
        ZStack {
            MusicFreeColorTokens.backgroundPrimary
                .ignoresSafeArea()
            Image(systemName: "music.note.list")
                .font(.system(size: 120, weight: .medium))
                .foregroundStyle(Color(red: 0, green: 150 / 255, blue: 1))
                .symbolEffect(.disappear)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("app.name"))
        .accessibilityValue(L("正在启动"))
    }
}
