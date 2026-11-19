import Foundation

enum MusicAPI {
    static let base: URL = {
        let environment = ProcessInfo.processInfo.environment
        if environment["UITEST_MODE"] == "1",
           let local = environment["APU_API_BASE_URL"], let url = URL(string: local) {
            return url
        }
        return URL(string: "https://kenmusic.kdns.fr/api/v1")!
    }()

    static func endpoint(_ path: String) throws -> URL {
        let root = URL(string: base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/")!
        guard let url = URL(string: path, relativeTo: root)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.path.hasPrefix(base.path + "/") else {
            throw URLError(.badURL)
        }
        return url
    }

    static func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: endpoint(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func createPlayback(_ body: PlaybackRequest) async throws -> PlaybackStatusResponse {
        var request = URLRequest(url: try endpoint("playbacks"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await playbackResponse(for: request)
    }

    static func playbackStatus(id: String, since: String) async throws -> PlaybackStatusResponse {
        guard let segment = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%"))),
              var components = URLComponents(url: try endpoint("playbacks/\(segment)"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [.init(name: "since", value: since), .init(name: "wait_ms", value: "8000")]
        guard let url = components.url else { throw URLError(.badURL) }
        return try await playbackResponse(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    private static func playbackResponse(for request: URLRequest) async throws -> PlaybackStatusResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(PlaybackAPIError.self, from: data)
            let reason = payload?.detail ?? payload?.error
            let message = reason.flatMap { $0.isEmpty ? nil : $0 } ?? "服务器返回 HTTP \(http.statusCode)。"
            throw PlaybackError.unavailable(message)
        }
        do {
            return try JSONDecoder().decode(PlaybackStatusResponse.self, from: data)
        } catch {
            throw PlaybackError.unavailable("服务器返回的播放信息无法读取。")
        }
    }
}

private struct PlaybackAPIError: Decodable {
    var detail: String?
    var error: String?
}

enum PlaybackError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

struct Track: Codable, Identifiable, Hashable {
    var id: String
    var platform: String
    var song: String
    var singer: String
    var album: String?
    var duration: Double?
    var cover: String?
    var sourceId: String?
    var selectedId: String?
    var playable: Bool?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, song, singer, album, duration, cover, playable, status
        case sourceId = "source_id"
        case selectedId = "selected_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? values.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try values.decode(Int64.self, forKey: .id))
        }
        platform = try values.decode(String.self, forKey: .platform)
        song = try values.decode(String.self, forKey: .song)
        singer = try values.decode(String.self, forKey: .singer)
        album = try values.decodeIfPresent(String.self, forKey: .album)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        cover = try values.decodeIfPresent(String.self, forKey: .cover)
        sourceId = try values.decodeIfPresent(String.self, forKey: .sourceId)
        selectedId = try values.decodeIfPresent(String.self, forKey: .selectedId)
        playable = try values.decodeIfPresent(Bool.self, forKey: .playable)
        status = try values.decodeIfPresent(String.self, forKey: .status)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(platform, forKey: .platform)
        try values.encode(song, forKey: .song)
        try values.encode(singer, forKey: .singer)
        try values.encodeIfPresent(album, forKey: .album)
        try values.encodeIfPresent(duration, forKey: .duration)
        try values.encodeIfPresent(cover, forKey: .cover)
        try values.encodeIfPresent(sourceId, forKey: .sourceId)
        try values.encodeIfPresent(selectedId, forKey: .selectedId)
        try values.encodeIfPresent(playable, forKey: .playable)
        try values.encodeIfPresent(status, forKey: .status)
    }

    init(id: String, platform: String, song: String, singer: String,
         album: String? = nil, duration: Double? = nil, cover: String? = nil,
         sourceId: String? = nil, selectedId: String? = nil, playable: Bool? = nil, status: String? = nil) {
        self.id = id
        self.platform = platform
        self.song = song
        self.singer = singer
        self.album = album
        self.duration = duration
        self.cover = cover
        self.sourceId = sourceId
        self.selectedId = selectedId
        self.playable = playable
        self.status = status
    }

    var canPlay: Bool { playable != false && status != "missing" && !platform.isEmpty }
    var playbackSelectionID: String { selectedId ?? id.components(separatedBy: "--").dropFirst().first ?? id }
    var artwork: URL? { cover.flatMap(URL.init(string:)) }
    var thumbnail: URL? {
        guard let artwork else { return nil }
        guard var parts = URLComponents(url: artwork, resolvingAgainstBaseURL: false) else { return artwork }
        var path = parts.path
        for size in ["1200x1200", "1000x1000", "800x800", "600x600", "500x500", "400x400", "300x300"] {
            path = path.replacingOccurrences(of: size, with: "240x240")
        }
        parts.path = path
        if ["y.gtimg.cn", "isure.stream.qqmusic.qq.com"].contains(parts.host ?? "") {
            var query = parts.queryItems ?? []
            if let size = query.firstIndex(where: { $0.name == "size" }) {
                query[size].value = "240"
            } else {
                query.append(URLQueryItem(name: "size", value: "240"))
            }
            parts.queryItems = query
        }
        return parts.url
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.platform == rhs.platform && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(platform)
        hasher.combine(id)
    }
}

struct Platform: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
}

struct HomeResponse: Decodable {
    var tracks: [Track]
    var mood: String?
    var playlists: [HomePlaylist]?
}

struct HomePlaylist: Decodable, Identifiable {
    var id: String
    var name: String
    var cover: String?
    var platform: String?
    var url: String?
}

struct SearchResponse: Decodable { var tracks: [Track] }
struct ContinueResponse: Decodable { var tracks: [Track]; var station: String? }
struct ContinueRequest: Encodable {
    var platform: String
    var seedId: String
    var seedIds: [String]
    var station: String?
    var exclude: [String]
    var limit = 10
    enum CodingKeys: String, CodingKey {
        case platform, station, exclude, limit
        case seedId = "seed_id"
        case seedIds = "seed_ids"
    }
}
struct TracksResponse: Decodable { var items: [Track] }
struct PlaylistResponse: Decodable { var playlists: [PlaylistSummary] }
struct PlaylistSummary: Decodable, Identifiable {
    var id: String
    var name: String
    var cover: String?
    var trackCount: Int?
    enum CodingKeys: String, CodingKey { case id, name, cover; case trackCount = "track_count" }
}
struct PlaylistDetail: Decodable {
    var id: String
    var name: String
    var cover: String?
    var items: [Track]
    private enum CodingKeys: String, CodingKey { case id, name, cover, items }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        cover = try container.decodeIfPresent(String.self, forKey: .cover)
        if let direct = try? container.decode([Track].self, forKey: .items) {
            items = direct
        } else {
            items = try container.decode(TracksResponse.self, forKey: .items).items
        }
    }
}
struct PlaybackRequest: Encodable {
    var platform: String
    var query: String
    var selectedId: String
    var quality = "high"
    enum CodingKeys: String, CodingKey {
        case platform, query, quality
        case selectedId = "selected_id"
        case streamingMode = "streaming_mode"
        case includeCover = "include_cover"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(platform, forKey: .platform)
        try values.encode(query, forKey: .query)
        try values.encode(selectedId, forKey: .selectedId)
        try values.encode(quality, forKey: .quality)
        try values.encodeNil(forKey: .streamingMode)
        try values.encode(false, forKey: .includeCover)
    }
}
struct PlaybackTask: Decodable {
    var id: String
    var status: String
    var audioURL: String?
    var streamingURL: String?
    var streamingMode: String?
    var alacSourceURL: String?
    var quality: String?
    var format: String?
    var errorCode: String?
    var error: String?
    enum CodingKeys: String, CodingKey {
        case id, status, error, quality, format
        case audioURL = "audio_url"
        case streamingURL = "streaming_url"
        case streamingMode = "streaming_mode"
        case alacSourceURL = "alac_source_url"
        case errorCode = "error_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try container.decode(Int64.self, forKey: .id))
        }
        status = try container.decode(String.self, forKey: .status)
        audioURL = try container.decodeIfPresent(String.self, forKey: .audioURL)
        streamingURL = try container.decodeIfPresent(String.self, forKey: .streamingURL)
        streamingMode = try container.decodeIfPresent(String.self, forKey: .streamingMode)
        alacSourceURL = try container.decodeIfPresent(String.self, forKey: .alacSourceURL)
        quality = try container.decodeIfPresent(String.self, forKey: .quality)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    func nativeAudioURL(relativeTo base: URL) -> URL? {
        let nativeFormats = ["aac", "aacp", "m4a", "mp4", "mp3", "wav", "wave"]
        let isNativeFormat = nativeFormats.contains(format?.lowercased() ?? "")
        let isLossless = ["lossless", "hires", "hi-res"].contains(quality?.lowercased() ?? "")
        guard status == "completed" || (status == "streaming" && streamingMode != "wasm_alac" && isNativeFormat && !isLossless) else {
            return nil
        }
        let original = status == "completed" ? alacSourceURL : nil
        for path in [audioURL, original].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            let root = base.appendingPathComponent("")
            guard let url = URL(string: path, relativeTo: root)?.absoluteURL,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  components.host != nil, components.user == nil, components.password == nil,
                  !components.path.hasSuffix("/audio/stream") else { continue }
            let audioPath = "/playbacks/\(id)/audio"
            if url.host == base.host && url.port == base.port && url.scheme == base.scheme &&
                (components.path == base.path + audioPath || components.path == base.path + audioPath + "/source") {
                var items = components.queryItems ?? []
                items.removeAll { $0.name == "v" }
                items.append(URLQueryItem(name: "v", value: id))
                components.queryItems = items
            }
            return components.url
        }
        return nil
    }
}
struct PlaybackStatusResponse: Decodable {
    var task: PlaybackTask
    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let wrapped = try container.decodeIfPresent(PlaybackTask.self, forKey: .task)
            ?? container.decodeIfPresent(PlaybackTask.self, forKey: .playback) {
            task = wrapped
        } else {
            task = try PlaybackTask(from: decoder)
        }
    }
    private enum CodingKeys: String, CodingKey { case task, playback }
}
struct Lyrics: Decodable {
    var available: Bool
    var plain: String?
    var translation: String?
    var words: [LyricLine]?

    var timedLines: [LyricLine] {
        if let words, !words.isEmpty { return words }
        guard let plain, !plain.isEmpty else { return [] }
        let pattern = #"^\[([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,3}))?\](.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var lines: [LyricLine] = []
        let textLines = plain.components(separatedBy: .newlines)
        for (index, text) in textLines.enumerated() {
            let whole = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: whole),
                  let minutesRange = Range(match.range(at: 1), in: text),
                  let secondsRange = Range(match.range(at: 2), in: text),
                  let textRange = Range(match.range(at: 4), in: text),
                  let minutes = Double(text[minutesRange]),
                  let seconds = Double(text[secondsRange]) else { continue }
            var fraction = 0.0
            if let fractionRange = Range(match.range(at: 3), in: text) {
                let digits = String(text[fractionRange])
                fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
            }
            let start = minutes * 60 + seconds + fraction
            let nextStart = textLines.dropFirst(index + 1).compactMap { candidate -> Double? in
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                guard let candidateMatch = expression.firstMatch(in: candidate, range: range),
                      let candidateMinutes = Range(candidateMatch.range(at: 1), in: candidate),
                      let candidateSeconds = Range(candidateMatch.range(at: 2), in: candidate) else { return nil }
                let candidateFraction = Range(candidateMatch.range(at: 3), in: candidate).map { value in
                    let digits = String(candidate[value])
                    return (Double(digits) ?? 0) / pow(10, Double(digits.count))
                } ?? 0
                return (Double(candidate[candidateMinutes]) ?? 0) * 60 + (Double(candidate[candidateSeconds]) ?? 0) + candidateFraction
            }.first ?? start + 5
            let lyric = String(text[textRange]).trimmingCharacters(in: .whitespaces)
            lines.append(LyricLine(start: start, end: max(start, nextStart - 0.02), words: [LyricWord(start: start, end: nextStart, text: lyric)]))
        }
        return lines
    }
}
struct LyricLine: Decodable {
    var start: Double
    var end: Double
    var words: [LyricWord]
    var text: String { words.map(\.text).joined() }

    init(start: Double, end: Double, words: [LyricWord]) {
        self.start = start
        self.end = end
        self.words = words
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        if let timedWords = try? values.decode([LyricWord].self, forKey: .words) {
            words = timedWords
        } else {
            let plain = try values.decode(String.self, forKey: .text)
            words = [LyricWord(start: start, end: end, text: plain)]
        }
    }

    private enum CodingKeys: String, CodingKey { case start, end, words, text }
}
struct LyricWord: Decodable {
    var start: Double
    var end: Double
    var text: String
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        start = try container.decode(Double.self)
        end = try container.decode(Double.self)
        text = try container.decode(String.self)
    }

    init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

enum LibraryStore {
    private static let favoritesKey = "apu.favorite.tracks"
    private static let playlistsKey = "apu.playlists"
    static var favorites: [Track] {
        get { decode(Track.self, key: favoritesKey) }
        set { encode(newValue, key: favoritesKey) }
    }
    static var playlists: [LocalPlaylist] {
        get { decode(LocalPlaylist.self, key: playlistsKey) }
        set { encode(newValue, key: playlistsKey) }
    }
    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
    private static func encode<T: Encodable>(_ items: [T], key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }
}
struct LocalPlaylist: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var tracks: [Track]
}
