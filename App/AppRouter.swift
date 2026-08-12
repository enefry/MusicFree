struct AppRouter: Equatable, Sendable {
    enum Route: String, CaseIterable, Hashable, Identifiable, Sendable {
        case library
        case playlists
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .library:
                "资料库"
            case .playlists:
                "播放列表"
            case .settings:
                "设置"
            }
        }

        var systemImage: String {
            switch self {
            case .library:
                "music.note.list"
            case .playlists:
                "list.bullet.rectangle"
            case .settings:
                "gearshape"
            }
        }
    }

    enum Presentation: String, Hashable, Identifiable, Sendable {
        case player

        var id: Self { self }
    }

    var selectedRoute: Route
    var presented: Presentation?

    init(
        selectedRoute: Route = .library,
        presented: Presentation? = nil
    ) {
        self.selectedRoute = selectedRoute
        self.presented = presented
    }

    mutating func select(_ route: Route) {
        selectedRoute = route
    }

    mutating func present(_ presentation: Presentation) {
        presented = presentation
    }

    mutating func dismissPresentation() {
        presented = nil
    }
}
