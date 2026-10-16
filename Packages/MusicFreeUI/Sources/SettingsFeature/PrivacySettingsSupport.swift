import Foundation
import DesignSystem
import MediaSourceAPI
import MusicDomain
import SettingsAPI

enum PrivacyPolicyURLs {
    static let app = URL(
        string: "https://github.com/enefry/MusicFree/blob/main/Docs/PRIVACY_POLICY_v1.2.0.md"
    )!
}

enum PrivacyPolicyHTMLResources {
    static let lrclib = "PRIVACY_POLICY_LRCLIB"
}

struct PrivacyProviderDescriptor: Identifiable, Equatable {
    let id: String
    let title: String
    let service: String
    let data: String
    let purpose: String
    let policyURL: URL?
    let localHTMLResourceName: String?

    init(
        id: String,
        title: String,
        service: String,
        data: String,
        purpose: String,
        policyURL: URL?,
        localHTMLResourceName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.service = service
        self.data = data
        self.purpose = purpose
        self.policyURL = policyURL
        self.localHTMLResourceName = localHTMLResourceName
    }
}

enum PrivacyProviderCatalog {
    static func descriptor(for providerID: String) -> PrivacyProviderDescriptor {
        switch providerID {
        case MetadataProviderID.musicKit.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("MusicKit"),
                service: "Apple Music / MusicKit",
                data: L("歌曲名称、艺人和用于目录匹配的音乐信息。"),
                purpose: L("查询歌曲元数据和封面。"),
                policyURL: URL(string: "https://www.apple.com/legal/privacy/")
            )
        case MetadataProviderID.musicBrainz.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("MusicBrainz"),
                service: "MusicBrainz and Cover Art Archive",
                data: L("歌曲名称和艺人；匹配成功后使用 MusicBrainz 发布信息请求封面。"),
                purpose: L("查询开放音乐元数据和专辑封面。"),
                policyURL: URL(string: "https://metabrainz.org/privacy")
            )
        case MetadataProviderID.metadataServer.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("Metadata Server"),
                service: L("应用配置的 Metadata Server"),
                data: L("元数据查询发送歌曲名称和艺人；歌词查询可能附带专辑和时长。"),
                purpose: L("查询元数据、封面和歌词。"),
                policyURL: URL(string: "https://music.tools4me.win/privacy")
            )
        case MetadataProviderID.discogs.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: L("Discogs"),
                service: "Discogs API",
                data: L("歌曲名称和艺人。应用配置的 Discogs 访问令牌不会发送给其他服务。"),
                purpose: L("查询发行版本、曲目元数据和封面。"),
                policyURL: URL(string: "https://support.discogs.com/hc/en-us/articles/360007522313-Privacy-Policy")
            )
        case LyricsProviderID.lrclib.rawValue:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: "LRCLIB",
                service: "LRCLIB API",
                data: L("歌曲名称、艺人，以及可选的专辑和时长。"),
                purpose: L("查询歌词。"),
                policyURL: nil,
                localHTMLResourceName: PrivacyPolicyHTMLResources.lrclib
            )
        case "netEase", "qqMusic":
            return PrivacyProviderDescriptor(
                id: providerID,
                title: providerID == "netEase" ? L("网易云音乐") : L("QQ 音乐"),
                service: providerID == "netEase" ? "music.163.com" : "y.qq.com",
                data: L("歌曲名称、艺人，以及可选的专辑、时长和登录 Cookie。"),
                purpose: L("查询歌词、歌曲元数据和专辑封面。"),
                policyURL: URL(string: providerID == "netEase"
                    ? "https://music.163.com/m/rankmusic/privacy"
                    : "https://y.qq.com/m/client/privacy.html")
            )
        default:
            return PrivacyProviderDescriptor(
                id: providerID,
                title: providerID,
                service: providerID,
                data: L("用于匹配的歌曲元数据；具体字段取决于 Provider 实现。"),
                purpose: L("提供元数据或歌词服务。"),
                policyURL: nil
            )
        }
    }
}

enum PrivacyDisclosure: Identifiable {
    case application
    case provider(PrivacyProviderDescriptor)

    var id: String {
        switch self {
        case .application:
            return "application"
        case let .provider(descriptor):
            return "provider.\(descriptor.id)"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .application:
            return "settings.privacyDisclosure.application"
        case let .provider(descriptor):
            return "settings.privacyDisclosure.provider.\(descriptor.id)"
        }
    }
}

func isOnlineSourcePrivacyAccepted(_ configuration: OnlineSourceConfiguration) -> Bool {
    configuration.privacyPolicyVersion
        == configuration.providerKind.defaultPrivacyPolicyVersion
}

func onlineSourceProviderTitle(_ providerKind: OnlineProviderKind) -> String {
    switch providerKind {
    case .dsAudio: return "DS Audio"
    case .googleDrive: return "Google Drive"
    case .baiduPan: return L("百度网盘")
    case .gateway: return L("网关")
    default: return providerKind.rawValue
    }
}

func onlineSourceProviderSymbol(_ providerKind: OnlineProviderKind) -> String {
    switch providerKind {
    case .dsAudio: return "waveform"
    case .googleDrive: return "externaldrive"
    case .baiduPan: return "cloud"
    case .gateway: return "network"
    default: return "puzzlepiece.extension"
    }
}
