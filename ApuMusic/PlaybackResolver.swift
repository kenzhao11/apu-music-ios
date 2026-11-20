import Foundation

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
        // App.vue:195-198 + core/player/alac-support.js `canRequestAlacPlayback`:
        // wasm_alac only for Apple Music lossless tiers. This is the same
        // request the website posts; the app then uses the audio URL the
        // backend returns for that task (never a different representation).
        self.streamingMode = platform == "applemusic" && quality.isLossless ? "wasm_alac" : nil
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
    static func prepare(track: Track, quality: PlaybackQuality = .siteQuality) async throws -> PreparedPlayback {
        guard track.canPlay else {
            throw PlaybackError.unplayable("这首歌暂时无法播放。")
        }
        let created = try await MusicAPI.createPlayback(PlaybackTarget(track: track, quality: quality).request).task
        let ready = try await waitUntilReady(created)
        // `audio_url` only: `alac_source_url` is the web player's packet
        // transport, and no transcoding or substitute URL is used here.
        guard let url = ready.nativeAudioURL(relativeTo: MusicAPI.base) else {
            throw PlaybackError.unavailable(ready.error ?? "服务器没有返回可播放的音频地址。")
        }
        return PreparedPlayback(task: ready, audioURL: url)
    }

    /// App.vue:330-380 `waitForReady`: `failed` is final; otherwise long-poll
    /// the same task until the task is completed or its stream is natively
    /// decodable by the website's own rule. The website gives up after 240s.
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
            if task.isReadyForNativePlayback { return task }
            let next = try await MusicAPI.playbackStatus(id: task.id, since: task.status).task
            if next.status == task.status { try await Task.sleep(for: .milliseconds(350)) }
            task = next
        }
        throw PlaybackError.unavailable("等待音频准备超时，请稍后重试。")
    }
}
