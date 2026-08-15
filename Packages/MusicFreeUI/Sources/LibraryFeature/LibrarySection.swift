import DesignSystem
import MusicDomain

/// The browse destinations available in the first local-library experience.
public enum LibrarySection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case tracks
    case favorites
    case albums
    case artists
    case genres
    case folders
    case recent

    public var id: Self { self }

    public var title: String {
        switch self {
        case .tracks: return L("歌曲")
        case .favorites: return L("收藏列表")
        case .albums: return L("专辑")
        case .artists: return L("艺人")
        case .genres: return L("流派")
        case .folders: return L("文件夹")
        case .recent: return L("播放历史")
        }
    }

    public var systemImage: String {
        switch self {
        case .tracks: return "music.note.list"
        case .favorites: return "star"
        case .albums: return "square.stack"
        case .artists: return "person.2"
        case .genres: return "guitars"
        case .folders: return "folder"
        case .recent: return "clock"
        }
    }

    public var groupTitle: String {
        switch self {
        case .tracks, .favorites: return L("资料库")
        case .albums, .artists, .genres, .folders: return L("浏览")
        case .recent: return L("资料库")
        }
    }
}

/// Routes a selected library item to the App-owned navigation layer.
public enum LibraryDestination: Hashable, Sendable {
    case track(MediaItemID)
    case album(AlbumID)
    case artist(ArtistID)
    case genre(GenreID)
    case folder(String)
}

enum LibrarySectionGroup: String, CaseIterable, Identifiable {
    case library
    case browse

    var id: Self { self }

    var title: String {
        switch self {
        case .library: return L("资料库")
        case .browse: return L("浏览")
        }
    }

    var sections: [LibrarySection] {
        switch self {
        case .library: return [.tracks, .favorites, .recent]
        case .browse: return [.albums, .artists, .genres, .folders]
        }
    }
}
