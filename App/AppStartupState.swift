enum AppStartupIssue: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case cacheUnavailable
    case settingsCorrupted
    case libraryStoreUnavailable
    case playbackUnavailable
    case dependencyUnavailable

    var id: String { rawValue }

    var diagnosticCode: String { "startup.\(rawValue)" }

    var title: String {
        switch self {
        case .cacheUnavailable:
            "缓存不可用"
        case .settingsCorrupted:
            "设置需要恢复"
        case .libraryStoreUnavailable:
            "资料库不可用"
        case .playbackUnavailable:
            "播放暂不可用"
        case .dependencyUnavailable:
            "应用服务不可用"
        }
    }

    var message: String {
        switch self {
        case .cacheUnavailable:
            "缓存无法重建，应用将继续使用现有数据。"
        case .settingsCorrupted:
            "设置数据无法读取，原数据会被保留。"
        case .libraryStoreUnavailable:
            "资料库无法打开，不会自动删除资料。"
        case .playbackUnavailable:
            "资料库仍可浏览，但当前播放能力不可用。"
        case .dependencyUnavailable:
            "部分应用服务尚未准备完成。"
        }
    }

    var systemImage: String {
        switch self {
        case .cacheUnavailable, .settingsCorrupted:
            "exclamationmark.triangle"
        case .libraryStoreUnavailable:
            "externaldrive.badge.exclamationmark"
        case .playbackUnavailable:
            "play.slash"
        case .dependencyUnavailable:
            "wrench.and.screwdriver"
        }
    }
}

enum AppStartupState: Equatable, Sendable {
    case loading
    case ready
    case degraded([AppStartupIssue])
    case recoveryRequired([AppStartupIssue])

    static func degraded(_ issue: AppStartupIssue) -> AppStartupState {
        .degraded([issue])
    }

    static func recoveryRequired(_ issue: AppStartupIssue) -> AppStartupState {
        .recoveryRequired([issue])
    }

    var issues: [AppStartupIssue] {
        switch self {
        case .loading, .ready:
            []
        case let .degraded(issues), let .recoveryRequired(issues):
            issues
        }
    }

    var isUsable: Bool {
        switch self {
        case .ready, .degraded:
            true
        case .loading, .recoveryRequired:
            false
        }
    }

    var title: String {
        switch self {
        case .loading:
            "正在启动"
        case .ready:
            "MusicFree"
        case .degraded:
            "部分功能不可用"
        case .recoveryRequired:
            "需要恢复"
        }
    }

    var message: String {
        switch self {
        case .loading:
            "正在准备应用。"
        case .ready:
            ""
        case .degraded:
            "资料库仍可使用，部分能力暂时不可用。"
        case .recoveryRequired:
            "应用未能安全完成启动，请先处理显示的问题。"
        }
    }

    var systemImage: String {
        switch self {
        case .loading:
            "ellipsis.circle"
        case .ready:
            "music.note.list"
        case let .degraded(issues), let .recoveryRequired(issues):
            issues.first?.systemImage ?? "exclamationmark.triangle"
        }
    }
}
