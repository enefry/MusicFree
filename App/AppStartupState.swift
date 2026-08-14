import DesignSystem

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
            L("startup.cacheUnavailable.title")
        case .settingsCorrupted:
            L("startup.settingsCorrupted.title")
        case .libraryStoreUnavailable:
            L("startup.libraryStoreUnavailable.title")
        case .playbackUnavailable:
            L("startup.playbackUnavailable.title")
        case .dependencyUnavailable:
            L("startup.dependencyUnavailable.title")
        }
    }

    var message: String {
        switch self {
        case .cacheUnavailable:
            L("startup.cacheUnavailable.message")
        case .settingsCorrupted:
            L("startup.settingsCorrupted.message")
        case .libraryStoreUnavailable:
            L("startup.libraryStoreUnavailable.message")
        case .playbackUnavailable:
            L("startup.playbackUnavailable.message")
        case .dependencyUnavailable:
            L("startup.dependencyUnavailable.message")
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
            L("正在启动")
        case .ready:
            "MusicFree"
        case .degraded:
            L("部分功能不可用")
        case .recoveryRequired:
            L("需要恢复")
        }
    }

    var message: String {
        switch self {
        case .loading:
            L("正在准备应用。")
        case .ready:
            ""
        case .degraded:
            L("资料库仍可使用，部分能力暂时不可用。")
        case .recoveryRequired:
            L("应用未能安全完成启动，请先处理显示的问题。")
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
