import Foundation

enum MusicAPI {
    static let base = URL(string: "https://kenmusic.kdns.fr/api/v1")!

    static func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: base.appending(path: path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
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
}
struct LyricLine: Decodable {
    var start: Double
    var end: Double
    var words: [LyricWord]
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
