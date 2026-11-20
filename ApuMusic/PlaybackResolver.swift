import Foundation

/// One song's playback request, built the way the website builds it.
///
/// The web client (`App.vue` → `createPlayback`) posts exactly one
/// `POST /api/v1/playbacks` per song: the platform of the matched row, the row
/// id the API returned as `selected_id`, the song title as `query`, and the
/// quality tier the listener picked. It never searches again, never swaps in a
/// second platform row, and it lets the backend decide the source. The app
/// keeps the same contract so both clients ask for the same audio.
struct PlaybackTarget: Equatable {
    var platform: String
    var query: String
    var selectedId: String
    var quality: PlaybackQuality
    var streamingMode: String?

    init(track: Track, quality: PlaybackQuality) {
        self.platform = track.platform
        self.query = track.song
        self.selectedId = track.playbackSelectionID
        self.quality = quality
        // The website asks for `wasm_alac` only for Apple Music lossless, which
        // needs its WebAssembly packet decoder. iOS decodes ALAC natively, so
        // the app never requests that transport and instead waits for the
        // backend's compatible audio, the same representation the website keeps
        // for browsers that cannot run the decoder.
        self.streamingMode = nil
    }

    var request: PlaybackRequest {
        PlaybackRequest(platform: platform, query: query, selectedId: selectedId,
                        quality: quality.rawValue, streamingMode: streamingMode)
    }
}

/// A playable task: the resolved audio URL plus what the backend actually
/// served, which is what the player screen reports.
struct PreparedPlayback {
    var task: PlaybackTask
    var audioURL: URL
    var sourceLabel: String
}

enum PlaybackResolver {
    /// Creates the task and waits for audio the way the website's
    /// `resolveTrackSource` + `waitForReady` loop does.
    static func prepare(track: Track, quality: PlaybackQuality) async throws -> PreparedPlayback {
        let created = try await MusicAPI.createPlayback(PlaybackTarget(track: track, quality: quality).request).task
        let ready = try await waitUntilReady(created)
        guard let url = ready.nativeAudioURL(relativeTo: MusicAPI.base) else {
            throw PlaybackError.unavailable(ready.error ?? "服务器没有返回可播放的音频地址。")
        }
        return PreparedPlayback(task: ready, audioURL: url,
                                sourceLabel: PlatformLabel.name(for: ready.platform ?? track.platform))
    }

    /// `failed` is final: the website stops there and marks the song
    /// unplayable instead of trying another source. Otherwise it long-polls the
    /// same task until its own readiness rule is satisfied.
    static func waitUntilReady(_ initial: PlaybackTask) async throws -> PlaybackTask {
        var task = initial
        let deadline = ContinuousClock.now + .seconds(240)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if task.status == "failed" {
                if task.errorCode == "unplayable" {
                    throw PlaybackError.unplayable(task.error ?? "这首歌暂时无法播放。")
                }
                throw PlaybackError.unavailable(task.error ?? "服务器未能准备这首歌。")
            }
            if task.isReadyForNativePlayback, task.nativeAudioURL(relativeTo: MusicAPI.base) != nil {
                return task
            }
            if task.status == "completed" {
                throw PlaybackError.unavailable("服务器没有返回可播放的音频地址。")
            }
            let next = try await MusicAPI.playbackStatus(id: task.id, since: task.status).task
            if next.status == task.status { try await Task.sleep(for: .milliseconds(350)) }
            task = next
        }
        throw PlaybackError.unavailable("等待音频准备超时，请稍后重试。")
    }
}

/// Provider names for the playback screen. The API labels are the search-scope
/// labels from `/platforms`, so the source names here are the providers'.
enum PlatformLabel {
    static func name(for platform: String) -> String {
        switch platform.lowercased() {
        case "applemusic": return "Apple Music"
        case "tencent": return "QQ音乐"
        case "netease": return "网易云音乐"
        case "kugou": return "酷狗音乐"
        case "joox": return "JOOX"
        case "youtubemusic": return "YouTube Music"
        case "": return "未知音源"
        default: return platform
        }
    }
}

/// What the open audio response really is. The backend reports no bitrate
/// (`bitrate` is null and `format` empty for every probed song), so the app
/// reads the container and the real byte size from the audio response and
/// derives the average bitrate from the song length. The requested tier is
/// never shown as the actual quality.
struct AudioFacts: Equatable {
    var format: String
    var bitrate: Int?

    var label: String {
        guard let bitrate = self.bitrate, bitrate > 0 else { return format }
        return "\(format) \(bitrate)k"
    }
}

enum AudioProbe {
    /// Reads four bytes and the response headers. Following the backend's
    /// redirect gives the CDN answer that carries `Content-Range`.
    static func facts(for url: URL, duration: Double) async -> AudioFacts? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        guard let (head, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return facts(head: head, response: http, duration: duration)
    }

    static func facts(head: Data, response: HTTPURLResponse, duration: Double) -> AudioFacts? {
        let mime = response.mimeType?.lowercased() ?? ""
        let signature = String(decoding: head.prefix(4), as: UTF8.self)
        let format: String?
        if signature == "fLaC" || mime.contains("flac") {
            format = "FLAC"
        } else if signature.hasPrefix("ID3") || mime.contains("mpeg") || mime.contains("mp3") {
            format = "MP3"
        } else if mime.contains("mp4") || mime.contains("aac") || mime.contains("m4a") {
            format = "AAC"
        } else if head.count >= 2, head[0] == 0xff, head[1] & 0xe0 == 0xe0 {
            format = "AAC"
        } else if !mime.isEmpty {
            format = mime.replacingOccurrences(of: "audio/", with: "").uppercased()
        } else {
            format = nil
        }
        guard let format else { return nil }
        var bitrate: Int?
        if let total = totalBytes(response), duration > 0 {
            bitrate = Int((Double(total) * 8 / duration / 1000).rounded())
        }
        return AudioFacts(format: format, bitrate: bitrate)
    }

    static func totalBytes(_ response: HTTPURLResponse) -> Int64? {
        let range = response.value(forHTTPHeaderField: "Content-Range")
        if let total = range?.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 { return total }
        if let length = response.value(forHTTPHeaderField: "Content-Length"), let value = Int64(length), value > 0 { return value }
        return nil
    }
}
