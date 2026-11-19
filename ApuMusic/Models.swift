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
    var playable: Bool?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, song, singer, album, duration, cover, playable, status
        case sourceId = "source_id"
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
        try values.encodeIfPresent(playable, forKey: .playable)
        try values.encodeIfPresent(status, forKey: .status)
    }

    init(id: String, platform: String, song: String, singer: String,
         album: String? = nil, duration: Double? = nil, cover: String? = nil,
         sourceId: String? = nil, playable: Bool? = nil, status: String? = nil) {
        self.id = id
        self.platform = platform
        self.song = song
        self.singer = singer
        self.album = album
        self.duration = duration
        self.cover = cover
        self.sourceId = sourceId
        self.playable = playable
        self.status = status
    }

    var canPlay: Bool { playable != false && status != "missing" && !platform.isEmpty }
    var artwork: URL? { cover.flatMap(URL.init(string:)) }

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
    var streamingMode: String? = nil
    var includeCover = true
    enum CodingKeys: String, CodingKey {
        case platform, query, quality
        case selectedId = "selected_id"
        case streamingMode = "streaming_mode"
        case includeCover = "include_cover"
    }
}
struct PlaybackTask: Decodable {
    var id: String
    var status: String
    var audioURL: String?
    var errorCode: String?
    var error: String?
    enum CodingKeys: String, CodingKey {
        case id, status, error
        case audioURL = "audio_url"
        case errorCode = "error_code"
    }
}
struct PlaybackStatusResponse: Decodable {
    var task: PlaybackTask
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        task = try container.decode(PlaybackTask.self)
    }
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
