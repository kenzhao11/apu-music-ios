import Foundation
import SwiftUI

enum MusicAPI {
    static let base: URL = {
        let environment = ProcessInfo.processInfo.environment
        if environment["UITEST_MODE"] == "1" || ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            if let local = environment["APU_API_BASE_URL"], let url = URL(string: local) {
                if url.host == "127.0.0.1" || url.host == "localhost" { return url }
            }
            return URL(string: "http://127.0.0.1:18765/api/v1")!
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
        var request = URLRequest(url: try endpoint(path), timeoutInterval: 10)
        request.httpShouldHandleCookies = true
        let (data, response) = try await URLSession.shared.data(for: request)
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

    static func send<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: try endpoint(path), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.httpShouldHandleCookies = true
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func createPlayback(_ body: PlaybackRequest) async throws -> PlaybackStatusResponse {
        var request = URLRequest(url: try endpoint("playbacks"), timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.httpShouldHandleCookies = true
        return try await playbackResponse(for: request)
    }

    static func searchTracks(_ query: String) async throws -> [Track] {
        var components = URLComponents(url: try endpoint("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "q", value: query), .init(name: "limit", value: "50")]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        if let tracks = try? JSONDecoder().decode([Track].self, from: data) { return tracks }
        return try JSONDecoder().decode(SearchResponse.self, from: data).tracks
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
    /// Reported by the backend when no source can ever play this song. The
    /// website marks such a track and steps over it, so the app does the same.
    case unplayable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .unplayable(let message): return message
        }
    }

    var isUnplayable: Bool {
        if case .unplayable = self { return true }
        return false
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
    /// Other platform rows the backend matched for this song. Metadata only:
    /// the website never retries a second platform for one song, so nothing in
    /// the app may turn these into playback fallbacks.
    var alternateCandidates: [PlaybackCandidate]?
    var playable: Bool?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, song, singer, album, duration, cover, playable, status
        case sourceId = "source_id"
        case selectedId = "selected_id"
        case alternateCandidates = "candidates"
        case playbackCandidates = "playback_candidates"
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
        alternateCandidates = try values.decodeIfPresent([PlaybackCandidate].self, forKey: .alternateCandidates)
            ?? values.decodeIfPresent([PlaybackCandidate].self, forKey: .playbackCandidates)
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
        try values.encodeIfPresent(alternateCandidates, forKey: .alternateCandidates)
        try values.encodeIfPresent(playable, forKey: .playable)
        try values.encodeIfPresent(status, forKey: .status)
    }

    init(id: String, platform: String, song: String, singer: String,
         album: String? = nil, duration: Double? = nil, cover: String? = nil,
         sourceId: String? = nil, selectedId: String? = nil, alternateCandidates: [PlaybackCandidate]? = nil,
         playable: Bool? = nil, status: String? = nil) {
        self.id = id
        self.platform = platform
        self.song = song
        self.singer = singer
        self.album = album
        self.duration = duration
        self.cover = cover
        self.sourceId = sourceId
        self.selectedId = selectedId
        self.alternateCandidates = alternateCandidates
        self.playable = playable
        self.status = status
    }

    /// The website queues every row the API returned and only learns at play
    /// time whether a source exists; the one thing it never does is play a row
    /// the backend explicitly marked `playable: false`. So the app asks for any
    /// row except that one — including rows whose import match is recorded as
    /// missing, because the backend can still resolve them by row id (two of
    /// the 21 "missing" rows in the Spotify playlist play on the website).
    var canPlay: Bool {
        playable != false
    }
    /// The row id the API returned for this song. The website posts exactly
    /// this value as `selected_id` (`trackFromSearch` sets `selected_id:
    /// item.id`), so both clients ask the backend for the same matched row.
    var playbackSelectionID: String { selectedId ?? id }
    /// Rows shown for previews and debugging. Playback must only use
    /// `playbackSelectionID`; these are never playback fallbacks.
    var metadataSources: [PlaybackCandidate] {
        var candidates = alternateCandidates ?? []
        let primary = PlaybackCandidate(platform: platform, selectedID: playbackSelectionID, sourceID: sourceId)
        if !platform.isEmpty, !candidates.contains(primary) { candidates.insert(primary, at: 0) }
        return candidates
    }
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
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PlaybackCandidate: Codable, Hashable {
    var platform: String
    var selectedID: String
    var sourceID: String?

    init(platform: String, selectedID: String, sourceID: String? = nil) {
        self.platform = platform
        self.selectedID = selectedID
        self.sourceID = sourceID
    }

    enum CodingKeys: String, CodingKey { case platform, id, selectedID = "selected_id", sourceID = "source_id" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        platform = try values.decode(String.self, forKey: .platform)
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
        if let selected = try values.decodeIfPresent(String.self, forKey: .selectedID) {
            selectedID = selected
        } else if let sourceID {
            selectedID = sourceID
        } else {
            selectedID = String(try values.decode(Int64.self, forKey: .id))
        }
    }
}

enum TrackDeduplicator {
    static func merge(_ tracks: [Track]) -> [Track] {
        var result: [Track] = []
        for track in tracks {
            guard let index = result.firstIndex(where: { sameSong($0, track) }) else {
                result.append(track)
                continue
            }
            let existing = result[index]
            var candidates = existing.metadataSources
            for candidate in track.metadataSources {
                if let match = candidates.firstIndex(where: {
                    $0.platform == candidate.platform && $0.selectedID == candidate.selectedID
                }) {
                    if candidates[match].sourceID == nil { candidates[match].sourceID = candidate.sourceID }
                } else {
                    candidates.append(candidate)
                }
            }
            result[index].alternateCandidates = candidates
            if (existing.cover?.isEmpty != false), let cover = track.cover, !cover.isEmpty {
                result[index].cover = cover
            }
            if (existing.album?.isEmpty != false), let album = track.album, !album.isEmpty {
                result[index].album = album
            }
            if existing.duration == nil { result[index].duration = track.duration }
            result[index].playable = existing.playable != false && track.playable != false
        }
        return result
    }

    private static func sameSong(_ lhs: Track, _ rhs: Track) -> Bool {
        if lhs.platform == rhs.platform && lhs.playbackSelectionID == rhs.playbackSelectionID { return true }
        guard TrackText.normalized(lhs.song) == TrackText.normalized(rhs.song),
              TrackText.normalized(lhs.singer) == TrackText.normalized(rhs.singer),
              let leftDuration = lhs.duration, let rightDuration = rhs.duration else { return false }
        return abs(leftDuration - rightDuration) <= 3
    }

}

enum SearchGrouping {
    static func groups(for tracks: [Track], query: String) -> [SearchGroup] {
        let normalizedQuery = TrackText.normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let best = tracks.first {
            TrackText.normalized($0.song) == normalizedQuery || TrackText.normalized($0.singer) == normalizedQuery
        } ?? tracks.first
        return [
            SearchGroup(title: "最佳匹配", tracks: best.map { [$0] } ?? []),
            SearchGroup(title: "歌曲", tracks: tracks),
            SearchGroup(title: "专辑", names: unique(tracks.compactMap(\.album))),
            SearchGroup(title: "歌手", names: unique(tracks.map(\.singer)))
        ].filter { !$0.tracks.isEmpty || !$0.names.isEmpty }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let name = TrackText.normalized($0)
            return !name.isEmpty && seen.insert(name).inserted
        }
    }
}

struct SearchGroup: Identifiable {
    var title: String
    var tracks: [Track] = []
    var names: [String] = []
    var id: String { title }
}

private enum TrackText {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_Hans_CN"))
            .split(whereSeparator: {
                $0.unicodeScalars.allSatisfy {
                    CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols).contains($0)
                }
            })
            .joined()
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

struct SearchResponse: Decodable {
    var tracks: [Track]
    init(from decoder: Decoder) throws {
        if let tracks = try? [Track](from: decoder) { self.tracks = tracks; return }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try container.decodeIfPresent([Track].self, forKey: .tracks) {
            tracks = items
        } else if let items = try container.decodeIfPresent([Track].self, forKey: .songs) {
            tracks = items
        } else {
            tracks = []
        }
    }
    private enum CodingKeys: String, CodingKey { case tracks, songs }
}
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
/// The quality tiers the website offers (`stores/status.js` + the listening
/// settings select). The default is `high`, exactly like the website, and the
/// app sends this value unchanged as the request's `quality`.
enum PlaybackQuality: String, CaseIterable, Identifiable {
    case standard, high, lossless, hires

    static let storageKey = "apu.playback.quality"
    static var preferred: PlaybackQuality {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PlaybackQuality.init(rawValue:)) ?? .high
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "标准"
        case .high: return "高品质"
        case .lossless: return "无损"
        case .hires: return "Hi-Res"
        }
    }
}

struct PlaybackRequest: Encodable {
    var platform: String
    var query: String
    var selectedId: String
    var quality: String
    var streamingMode: String? = nil
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
        try values.encodeIfPresent(streamingMode, forKey: .streamingMode)
        try values.encode(false, forKey: .includeCover)
    }
}
struct PlaybackTask: Decodable {
    var id: String
    var status: String
    var platform: String?
    var trackId: String?
    var selectedId: String?
    var duration: Double?
    var audioURL: String?
    var streamingURL: String?
    var streamingMode: String?
    var alacSourceURL: String?
    var quality: String?
    var bitrate: Int?
    var byteSize: Int64?
    var contentType: String?
    var format: String?
    var errorCode: String?
    var error: String?
    enum CodingKeys: String, CodingKey {
        case id, status, error, quality, format, bitrate, duration, platform
        case trackId = "track_id"
        case selectedId = "selected_id"
        case byteSize = "byte_size"
        case contentType = "content_type"
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
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        trackId = try container.decodeIfPresent(String.self, forKey: .trackId)
        selectedId = try container.decodeIfPresent(String.self, forKey: .selectedId)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        audioURL = try container.decodeIfPresent(String.self, forKey: .audioURL)
        streamingURL = try container.decodeIfPresent(String.self, forKey: .streamingURL)
        streamingMode = try container.decodeIfPresent(String.self, forKey: .streamingMode)
        alacSourceURL = try container.decodeIfPresent(String.self, forKey: .alacSourceURL)
        quality = try container.decodeIfPresent(String.self, forKey: .quality)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    /// The website's `waitForReady` gate, re-read for a client without the
    /// WebAssembly ALAC decoder: a finished task is ready, and a growing task
    /// only once its bytes are already decodable on their own (plain FLAC or
    /// MP3) and it is not the packet transport the app cannot read.
    var isReadyForNativePlayback: Bool {
        if status == "completed" { return true }
        guard status == "streaming", streamingMode != "wasm_alac" else { return false }
        let tier = quality?.lowercased() ?? ""
        let container = format?.lowercased() ?? ""
        let progressive = container == "flac" || container == "mp3"
        if ["lossless", "hires", "hi-res"].contains(tier), !progressive { return false }
        return true
    }

    func nativeAudioURL(relativeTo base: URL) -> URL? {
        guard isReadyForNativePlayback else { return nil }
        // The website's native path always plays `audio_url`. `alac_source_url`
        // only feeds its WebAssembly packet transport, which the app never
        // requests, so it must never become the app's audio URL.
        guard let path = audioURL, !path.isEmpty else { return nil }
        let root = base.appendingPathComponent("")
        guard let url = URL(string: path, relativeTo: root)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil, url.user == nil else { return nil }
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
        set { try? saveFavorites(newValue) }
    }
    static var playlists: [LocalPlaylist] {
        get { decode(LocalPlaylist.self, key: playlistsKey) }
        set { try? encode(newValue, key: playlistsKey) }
    }
    static func saveFavorites(_ tracks: [Track]) throws {
        try encode(tracks, key: favoritesKey)
    }
    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
    private static func encode<T: Encodable>(_ items: [T], key: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(items), forKey: key)
    }
}

@MainActor
final class FavoriteLibrary: ObservableObject {
    @Published private(set) var tracks = LibraryStore.favorites
    @Published var errorMessage: String?

    func contains(_ track: Track) -> Bool { tracks.contains(track) }

    /// The heart fills immediately, exactly like Apple Music. A failed write
    /// restores the previous list and says so, so the button never lies.
    func toggle(_ track: Track) {
        let previous = tracks
        if let index = tracks.firstIndex(of: track) { tracks.remove(at: index) }
        else { tracks.insert(track, at: 0) }
        commit(previous)
    }
    func add(_ track: Track) {
        guard !contains(track) else { return }
        let previous = tracks
        tracks.insert(track, at: 0)
        commit(previous)
    }
    func remove(at offsets: IndexSet) {
        let previous = tracks
        tracks.remove(atOffsets: offsets)
        commit(previous)
    }
    func refresh() { tracks = LibraryStore.favorites }

    private func commit(_ previous: [Track]) {
        do { try LibraryStore.saveFavorites(tracks) }
        catch {
            tracks = previous
            errorMessage = "没能保存到「喜欢的歌曲」，请重试。"
        }
    }
}
struct LocalPlaylist: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var tracks: [Track]
}

struct DownloadedTrack: Codable, Identifiable {
    var track: Track
    var filename: String
    var id: String { track.id }
}

enum DownloadStore {
    private static let key = "apu.downloaded.tracks"
    private static var records: [DownloadedTrack] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([DownloadedTrack].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
    static var tracks: [DownloadedTrack] { records.filter { FileManager.default.fileExists(atPath: fileURL($0).path) } }
    static func fileURL(_ item: DownloadedTrack) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(item.filename)
    }
    static func localURL(for track: Track) -> URL? {
        guard let item = tracks.first(where: { $0.track.id == track.id }) else { return nil }
        return fileURL(item)
    }
    static func add(_ track: Track, file: URL) throws {
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
        try FileManager.default.copyItem(at: file, to: destination)
        records.removeAll { $0.track.id == track.id }
        records.insert(DownloadedTrack(track: track, filename: destination.lastPathComponent), at: 0)
    }
    static func remove(_ item: DownloadedTrack) {
        try? FileManager.default.removeItem(at: fileURL(item))
        records.removeAll { $0.id == item.id }
    }
}
