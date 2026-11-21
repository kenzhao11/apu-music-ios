import Foundation
import OSLog

/// One song's playback request, built from the website's own source:
/// `App.vue` `createPlayback()` → `apis/music.js` `POST /api/v1/playbacks`.
///
/// The row id the API returned is posted as `selected_id` (see
/// `utils/track.js` `trackFromSearch`), the matched platform as `platform`,
/// the song title as `query`, and the website's chosen tier as `quality`.
/// One song is one request: no re-search, no other platform row, no version
/// switch. `include_cover` is always false, exactly like the web client.
struct PlaybackTarget: Equatable {
    var platform: String
    var query: String
    var selectedId: String
    var quality: PlaybackQuality
    var streamingMode: String?

    init(track: Track, quality: PlaybackQuality = .siteQuality) {
        self.platform = track.platform
        self.query = track.song
        self.selectedId = track.playbackSelectionID
        self.quality = quality
        // The app always uses the backend's native `audio_url` and never the
        // website's WebAssembly packet transport, so it asks for the default
        // transport. This is the same native request the website makes when
        // its own player cannot use the ALAC packet stream (App.vue:339-348).
        self.streamingMode = nil
    }

    var request: PlaybackRequest {
        PlaybackRequest(platform: platform, query: query, selectedId: selectedId,
                        quality: quality.rawValue, streamingMode: streamingMode)
    }
}

/// The task and the exact audio URL the website would open for it.
struct PreparedPlayback {
    var task: PlaybackTask
    var audioURL: URL
}

enum PlaybackResolver {
    private static let logger = Logger(subsystem: "ApuMusic", category: "playback")

    static func prepare(track: Track, quality: PlaybackQuality = .siteQuality, forDownload: Bool = false) async throws -> PreparedPlayback {
        guard track.canPlay else {
            throw PlaybackError.unplayable("这首歌暂时无法播放。")
        }
        let target = PlaybackTarget(track: track, quality: quality)
        let created = try await MusicAPI.createPlayback(target.request).task
        let ready = try await waitUntilReady(created, forDownload: forDownload)
        // `audio_url` only: `alac_source_url` is the web player's packet
        // transport, and no transcoding or substitute URL is used here.
        guard let url = ready.nativeAudioURL(relativeTo: MusicAPI.base) else {
            throw PlaybackError.unavailable(ready.error ?? "服务器没有返回可播放的音频地址。")
        }
        // One line per prepared playback, for on-device diagnosis.
        logger.info("selected_id=\(target.selectedId, privacy: .private) task=\(ready.id, privacy: .private) 音频已就绪")
        return PreparedPlayback(task: ready, audioURL: url)
    }

    /// App.vue:330-380 `waitForReady`: `failed` is final; otherwise long-poll
    /// the same task until the task is completed or its stream is natively
    /// decodable by the website's own rule. The website gives up after 240s.
    static func waitUntilReady(_ initial: PlaybackTask, forDownload: Bool = false) async throws -> PlaybackTask {
        var task = initial
        let deadline = ContinuousClock.now + .seconds(240)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if task.status == "failed" {
                // Every explicit backend failure is final, regardless of its
                // internal error_code. Never expose provider details to users.
                throw PlaybackError.unplayable("这首歌暂时无法播放。")
            }
            if forDownload ? task.status == "completed" : task.isReadyForNativePlayback { return task }
            let next = try await MusicAPI.playbackStatus(id: task.id, since: task.status).task
            if next.status == task.status { try await Task.sleep(for: .milliseconds(350)) }
            task = next
        }
        throw URLError(.timedOut)
    }
}
