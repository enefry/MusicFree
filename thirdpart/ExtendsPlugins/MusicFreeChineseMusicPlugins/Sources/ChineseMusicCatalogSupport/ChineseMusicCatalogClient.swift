// API fields and endpoints adapted from jitwxs/163MusicLyrics (Apache-2.0).
import DataPluginSupport
import Foundation
import MusicFreePluginAPI

private struct ServiceSong: Sendable {
    let candidate: CatalogCandidate
    let lyricID: String
    let artworkURL: URL?
    var track: PluginTrackQuery {
        .init(title: candidate.title, artist: candidate.artistName, album: candidate.albumName, durationSeconds: candidate.durationSeconds)
    }
}

/// Shared service transport; lyrics and metadata retain independent plugin
/// instances, preferences, permissions, and optional credentials.
public actor ChineseMusicCatalogClient {
    private let service: ChineseMusicService
    private let http: CatalogHTTPTransport
    private var songs: [String: ServiceSong] = [:]

    public init(service: ChineseMusicService, configuration: ChineseMusicConfiguration = .anonymous, session: URLSession? = nil) {
        self.service = service
        http = .init(service: service, configuration: configuration, session: session)
    }

    public func metadata(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        try context.requireNetwork()
        let records = try await search(query, fields: fields)
        return records.map { $0.candidate.pluginCandidate(fields: fields) }
    }

    public func artwork(reference: String, context: PluginOperationContext) async throws -> Data? {
        try context.requireNetwork()
        guard let url = songs[reference]?.artworkURL else { return nil }
        return try await http.request(url, artwork: true)
    }

    public func lyrics(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] {
        try context.requireNetwork()
        guard query.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return [] }
        let records = try await search(query, fields: []).filter { query.matches($0.track) }
        guard records.count <= 1 else { throw PluginError.ambiguous }
        guard let song = records.first else { return [] }
        let raw: String
        let translated: String
        let wordTimed: String?
        if service == .netEase {
            let response = try await netEase("/weapi/song/lyric", fields: ["id": song.lyricID, "os": "pc", "lv": "-1", "kv": "-1", "tv": "-1", "rv": "-1", "yv": "-1", "ytv": "-1", "yrv": "-1"])
            if response["nolyric"].bool == true || response["uncollected"].bool == true { return [] }
            raw = response["lrc"]["lyric"].string ?? ""
            translated = response["tlyric"]["lyric"].string ?? ""
            wordTimed = response["yrc"]["lyric"].string
        } else {
            let fields = ["songmid": song.lyricID, "g_tk": "5381", "loginUin": "0", "hostUin": "0", "format": "json", "inCharset": "utf8", "outCharset": "utf8", "notice": "0", "platform": "yqq", "needNewCode": "0"]
            let data = try await http.request(URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!, body: formData(fields), contentType: "application/x-www-form-urlencoded")
            let response = try CatalogJSON.decode(data)
            try checkCode(response["code"], success: 0)
            raw = try decodedLyrics(response["lyric"].string)
            translated = try decodedLyrics(response["trans"].string)
            wordTimed = nil
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [.init(id: song.candidate.catalogID, track: song.track, rawText: raw,
            lines: ServiceLyrics.lines(raw: raw, translation: translated, wordTimed: wordTimed))]
    }

    private func search(_ query: PluginTrackQuery, fields: Set<PluginMetadataField>) async throws -> [ServiceSong] {
        let terms = CatalogQuery(title: query.title, artistName: query.artist, albumName: query.album).searchTerms
        for term in terms.prefix(3) {
            try Task.checkCancellation()
            let rows: [CatalogJSON]
            if service == .netEase {
                let response = try await netEase("/weapi/cloudsearch/get/web", fields: ["s": term, "type": "1", "limit": "20", "offset": "0"])
                let result: [String: CatalogJSON]
                if response["abroad"].bool == true, let encoded = response["result"].string,
                   let decoded = try CatalogJSON.decode(NetEaseSearchDecoding.decode(encoded)).object {
                    result = decoded
                } else if let object = response["result"].object { result = object }
                else { throw PluginDataError.invalidResponse }
                if let found = result["songs"]?.array { rows = found }
                else if result["songCount"]?.integer == 0 { rows = [] }
                else { throw PluginDataError.invalidResponse }
            } else {
                // The desktop method now returns 2001 for anonymous requests.
                // The mobile method uses the same service and string parameters.
                let body: [String: Any] = ["req_1": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicMobile", "param": ["num_per_page": "20", "page_num": "1", "query": term, "search_type": "0"]]]
                let data = try await http.request(URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, body: JSONSerialization.data(withJSONObject: body), contentType: "application/json")
                let response = try CatalogJSON.decode(data)
                try checkCode(response["code"], success: 0)
                try checkCode(response["req_1"]["code"], success: 0)
                let result = response["req_1"]["data"]["body"]
                guard let found = result["item_song"].array ?? result["song"]["list"].array else { throw PluginDataError.invalidResponse }
                rows = found
            }
            var records = try rows.prefix(20).map(parseSong)
            if records.isEmpty { continue }
            if service == .netEase, !fields.isDisjoint(with: [.year, .trackNumber, .discNumber, .artwork]) {
                let ids = records.map { ["id": $0.lyricID] }
                let value = String(decoding: try JSONSerialization.data(withJSONObject: ids), as: UTF8.self)
                let response = try await netEase("/weapi/v3/song/detail", fields: ["c": value])
                guard let details = response["songs"].array else { throw PluginDataError.invalidResponse }
                let hydrated = try details.prefix(20).map(parseSong)
                let byID = Dictionary(hydrated.map { ($0.candidate.catalogID, $0) }, uniquingKeysWith: { first, _ in first })
                records = records.map { byID[$0.candidate.catalogID] ?? $0 }
            }
            if songs.count + records.count > 1_000 { songs.removeAll(keepingCapacity: true) }
            for record in records { songs[record.candidate.catalogID] = record }
            var seen = Set<String>()
            return records.filter { seen.insert($0.candidate.catalogID).inserted }
        }
        return []
    }

    private func netEase(_ path: String, fields: [String: String]) async throws -> CatalogJSON {
        var fields = fields
        fields["csrf_token"] = ""
        let data = try await http.request(URL(string: "https://music.163.com" + path + "?csrf_token=")!,
            body: NetEaseRequestEncryption.body(fields), contentType: "application/x-www-form-urlencoded")
        let response = try CatalogJSON.decode(data)
        try checkCode(response["code"], success: 200)
        return response
    }

    private func checkCode(_ value: CatalogJSON, success: Int) throws {
        guard let code = value.integer else { throw PluginDataError.invalidResponse }
        guard code != success else { return }
        if [301, 302, 50000005, 1000, 1001].contains(code) { throw PluginDataError.notAuthorized }
        if code == -460 { throw PluginDataError.rateLimited(retryAfterSeconds: nil, httpStatus: nil) }
        throw PluginDataError.requestFailed(code: "\(service.rawValue)_service_\(code)", httpStatus: nil)
    }

    private func parseSong(_ row: CatalogJSON) throws -> ServiceSong {
        let title = (row["title"].string ?? row["name"].string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty, let id = row["id"].identifier else { throw PluginDataError.invalidResponse }
        let artistRows = row[service == .netEase ? "ar" : "singer"].array ?? row["artists"].array ?? []
        let artist = artistRows.compactMap { $0["name"].string }.filter { !$0.isEmpty }.joined(separator: " / ")
        let album = row["al"].object != nil ? row["al"] : row["album"]
        let albumName = album["title"].string ?? album["name"].string
        let duration = service == .netEase ? (row["dt"].number ?? row["duration"].number).map { $0 / 1_000 } : row["interval"].number
        var artwork: URL?
        let year: Int?
        let lyricID: String
        if service == .netEase {
            lyricID = id
            if let value = album["picUrl"].string, var components = URLComponents(string: value) {
                if components.scheme == "http" { components.scheme = "https" }
                artwork = components.url
            }
            if let timestamp = row["publishTime"].number, timestamp > 0, timestamp < 253_402_300_800_000 {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                year = calendar.component(.year, from: Date(timeIntervalSince1970: timestamp / 1_000))
            } else { year = nil }
        } else {
            guard let mid = row["mid"].string, !mid.isEmpty else { throw PluginDataError.invalidResponse }
            lyricID = mid
            if let mid = album["mid"].string ?? album["pmid"].string, !mid.isEmpty,
               mid.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) {
                artwork = URL(string: "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(mid).jpg")
            }
            year = row["time_public"].string.flatMap { Int($0.prefix(4)) }
        }
        if let url = artwork, url.scheme != "https" || url.host.map(service.hosts.contains) != true { artwork = nil }
        let candidate = CatalogCandidate(catalogID: "\(service.rawValue):\(id)", title: title,
            artistName: artist.isEmpty ? nil : artist, albumName: albumName,
            trackNumber: positive(row["no"].integer ?? row["index_album"].integer),
            discNumber: service == .netEase ? positive(row["cd"].integer)
                : row["index_cd"].integer.flatMap { (0..<100).contains($0) ? $0 + 1 : nil }, year: positive(year),
            durationSeconds: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        return .init(candidate: candidate, lyricID: lyricID, artworkURL: artwork)
    }

    private func positive(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? $0 : nil } }
    private func decodedLyrics(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { return "" }
        guard let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8) else {
            throw PluginDataError.invalidResponse
        }
        return ServiceLyrics.unescape(text)
    }
}

/// A bounded JSON response accepts numeric IDs and string IDs used by the two
/// APIs without allowing malformed values to masquerade as empty search results.
private indirect enum CatalogJSON: Decodable {
    case object([String: CatalogJSON]), array([CatalogJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try container.decode([Self].self)) }
    }
    static func decode(_ data: Data) throws -> Self {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PluginDataError.invalidResponse }
    }
    subscript(_ key: String) -> Self { object?[key] ?? .null }
    var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { string.flatMap(Double.init) } }
    var integer: Int? { number.flatMap { $0.isFinite && $0 >= Double(Int.min) && $0 < Double(Int.max) && $0.rounded() == $0 ? Int($0) : nil } }
    var identifier: String? { string ?? integer.map(String.init) }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}
