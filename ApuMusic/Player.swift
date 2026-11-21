import AVFoundation
import MediaPlayer
import OSLog
import SwiftUI
import UIKit

@MainActor
final class PlaybackProgress: ObservableObject {
    struct Timing: Equatable {
        var position: Double = 0
        var duration: Double = 0
    }

    @Published private(set) var timing = Timing()

    func update(position: Double, duration: Double) {
        let next = Timing(position: position, duration: duration)
        if next != timing { timing = next }
    }
}

@MainActor
final class PlaybackLyrics: ObservableObject {
    @Published var text = ""
    @Published var lines: [LyricLine] = []
    @Published var currentIndex = 0

    func follow(position: Double) {
        guard let index = lines.firstIndex(where: { $0.start <= position && $0.end >= position }),
              index != currentIndex else { return }
        currentIndex = index
    }
}

@MainActor
final class Player: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    var volume: Float = ProcessInfo.processInfo.arguments.contains("-ui-testing") ? 0 : 1 {
        didSet { engine?.volume = volume }
    }
    @Published private(set) var playbackMessage = ""
    @Published private(set) var playbackFailed = false
    @Published var repeatMode = 0
    @Published var shuffled = false
    let progress = PlaybackProgress()
    let lyrics = PlaybackLyrics()

    private static let logger = Logger(subsystem: "ApuMusic", category: "playback")
    private var playbackQueue = PlaybackQueue()
    private var engine: AVPlayer?
    private var itemStatusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var itemNotifications: [NSObjectProtocol] = []
    private var tick: Any?
    private var preparation: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var startupTimeout: Task<Void, Never>?
    private var lyricRequest: Task<Void, Never>?
    private var artworkRequest: Task<Void, Never>?
    private var selection = UUID()
    private var wantsPlayback = false
    private var startedPlaying = false
    private var prefetched: (key: String, playback: PreparedPlayback, time: ContinuousClock.Instant)?
    private var selectedAt = ContinuousClock.now
    private var loggedStart = false
    private var prefetchTrackID: String?
    private var consecutiveFailures = 0
    private var networkPlaybackRetries = 0
    private var activePlaybackTaskID = ""
    private var station = ""
    private var lockScreenArtwork: MPMediaItemArtwork?

    init() {
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in Task { await self?.play() }; return .success }
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in Task { await self?.pause() }; return .success }
        MPRemoteCommandCenter.shared().nextTrackCommand.addTarget { [weak self] _ in Task { await self?.next() }; return .success }
        MPRemoteCommandCenter.shared().previousTrackCommand.addTarget { [weak self] _ in Task { await self?.previous() }; return .success }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { await self?.seek(to: position) }
            return .success
        }
    }

    func setQueue(_ tracks: [Track], start: Track) {
        playbackQueue = PlaybackQueue(tracks: tracks, startingAt: start)
        queue = playbackQueue.tracks
        currentIndex = playbackQueue.index
        prepareCurrent()
    }

    private func prepareCurrent() {
        guard queue.indices.contains(currentIndex) else { return }
        var track = queue[currentIndex]
        // The queue already drops rows nobody can play; this is the last guard
        // before a request is posted.
        if !track.canPlay, playbackQueue.advance() != nil {
            queue = playbackQueue.tracks
            currentIndex = playbackQueue.index
            track = queue[currentIndex]
        }
        guard track.canPlay else {
            wantsPlayback = false
            playbackFailed = true
            playbackMessage = "这首歌暂时无法播放。"
            return
        }
        preparation?.cancel()
        prefetchTask?.cancel()
        prefetchTrackID = nil
        lyricRequest?.cancel()
        artworkRequest?.cancel()
        selection = UUID()
        let selected = selection
        selectedAt = .now
        loggedStart = false
        networkPlaybackRetries = 0
        activePlaybackTaskID = ""
        clearEngine()
        current = track
        playbackMessage = "正在准备音频…"
        playbackFailed = false
        wantsPlayback = true
        lyrics.text = ""
        lyrics.lines = []
        lyrics.currentIndex = 0
        progress.update(position: 0, duration: 0)
        lockScreenArtwork = nil
        updateLockScreen()
        loadLyrics(track, selection: selected)
        artworkRequest = Task { [weak self] in await self?.loadLockScreenArtwork(for: track, selection: selected) }
        if let local = DownloadStore.localURL(for: track) {
            installPlayer(source: local)
        } else {
            resolveAudio(for: track, selection: selected)
        }
        prefetchNextTrack()
    }

    /// One request for the matched row, exactly like the website. No second
    /// platform, no re-search, no other version of the song.
    private func resolveAudio(for track: Track, selection selected: UUID) {
        let key = Self.cacheKey(track: track)
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared: PreparedPlayback
                if let cached = prefetched, cached.key == key, cached.time.duration(to: .now) < .seconds(120) {
                    prefetched = nil
                    prepared = cached.playback
                } else {
                    prepared = try await PlaybackResolver.prepare(track: track)
                }
                guard !Task.isCancelled, self.selection == selected else { return }
                self.activePlaybackTaskID = prepared.task.id
                self.install(prepared)
            } catch {
                guard !Task.isCancelled, self.selection == selected else { return }
                Self.logger.error("Playback preparation failed: \(String(reflecting: error as NSError), privacy: .private)")
                self.reportPlaybackFailure(error)
            }
        }
    }

    private func install(_ prepared: PreparedPlayback) {
        // One URL only: the audio_url the backend returned for this task.
        // No probing request, no conversion, no alternate representation.
        installPlayer(source: prepared.audioURL)
    }

    private func installPlayer(source: URL) {
        let item = AVPlayerItem(url: source)
        item.preferredForwardBufferDuration = 3
        let engine = AVPlayer(playerItem: item)
        engine.automaticallyWaitsToMinimizeStalling = false
        self.engine = engine
        engine.volume = volume
        startedPlaying = false

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.engine?.currentItem === item else { return }
                if item.status == .failed {
                    self.handleItemFailure(item, error: item.error)
                }
            }
        }
        rateObservation = engine.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] engine, _ in
            Task { @MainActor in
                guard let self, self.engine === engine else { return }
                let playing = engine.timeControlStatus == .playing
                if playing {
                    if !self.startedPlaying {
                        self.consecutiveFailures = 0
                        self.prefetchNextTrack()
                    }
                    self.startedPlaying = true
                    self.startupTimeout?.cancel()
                    if !self.playbackMessage.isEmpty { self.playbackMessage = "" }
                }
                if self.isPlaying != playing { self.isPlaying = playing }
                self.updateLockScreen()
            }
        }
        let notifications = NotificationCenter.default
        itemNotifications = [
            notifications.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in
                    self?.handleItemFailure(item, error: error)
                }
            },
            notifications.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.engine?.currentItem === item else { return }
                    await self.ended()
                }
            }
        ]
        observeTime(on: engine)
        if wantsPlayback {
            play()
        } else {
            playbackMessage = ""
        }
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.wantsPlayback, !self.startedPlaying else { return }
            self.handleItemFailure(item, error: PlaybackError.unavailable("读取音频超时。"))
        }
    }

    /// A failed AVPlayer item is reported as-is: the website stops on a
    /// failed task and skips the song instead of retrying with converted
    /// bytes or a different source.
    private func handleItemFailure(_ item: AVPlayerItem, error: Error?) {
        guard engine?.currentItem === item else { return }
        let failure = item.error ?? error ?? engine?.error ?? URLError(.cannotDecodeContentData)
        let errorCode = (failure as NSError).code
        Self.logger.error("AVPlayerItem failed selected_id=\((current?.playbackSelectionID ?? ""), privacy: .private) taskID=\(activePlaybackTaskID, privacy: .private) domain=\((failure as NSError).domain, privacy: .public) code=\(errorCode)")
        clearEngine()
        if PlaybackFailure.isNetwork(failure), networkPlaybackRetries == 0,
           let current, current.canPlay {
            networkPlaybackRetries += 1
            playbackMessage = "网络连接不稳定，正在重试…"
            resolveAudio(for: current, selection: selection)
            return
        }
        reportPlaybackFailure(failure)
    }

    private func clearEngine() {
        startupTimeout?.cancel()
        startupTimeout = nil
        itemStatusObservation = nil
        rateObservation = nil
        for notification in itemNotifications { NotificationCenter.default.removeObserver(notification) }
        itemNotifications.removeAll()
        if let tick { engine?.removeTimeObserver(tick) }
        tick = nil
        engine?.pause()
        engine = nil
        if isPlaying { isPlaying = false }
    }

    private func reportPlaybackFailure(_ error: Error) {
        playbackFailed = true
        if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
            playbackMessage = "网络连接异常，请检查网络后重试。"
        } else {
            playbackMessage = PlaybackFailure.message(error)
        }
        Self.logger.error("Playback failed: \(String(reflecting: error as NSError), privacy: .private)")
        updateLockScreen()
        guard (error as? PlaybackError)?.isUnplayable == true, wantsPlayback else { return }
        consecutiveFailures += 1
        guard consecutiveFailures <= 5 else { wantsPlayback = false; return }
        // The website marks such a song and steps over it; do the same, once.
        let selected = selection
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.selection == selected else { return }
            await self.next()
        }
    }

    private func observeTime(on engine: AVPlayer) {
        tick = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self, weak engine] time in
            Task { @MainActor in
                guard let self, let engine, self.engine === engine else { return }
                let duration = engine.currentItem?.duration.seconds ?? 0
                let position = time.seconds.isFinite ? max(time.seconds, 0) : 0
                if position > 0, !self.loggedStart {
                    self.loggedStart = true
                    let elapsed = self.selectedAt.duration(to: .now)
                    Self.logger.info("Selection to first playback progress: \(String(describing: elapsed), privacy: .public)")
                }
                self.progress.update(position: position, duration: duration.isFinite ? max(duration, 0) : 0)
                self.lyrics.follow(position: position)
            }
        }
    }

    private func startEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            engine?.play()
        } catch {
            clearEngine()
            reportPlaybackFailure(error)
        }
    }

    func play() {
        if playbackFailed { prepareCurrent(); return }
        wantsPlayback = true
        guard engine != nil else { return }
        startEngine()
    }
    func pause() {
        wantsPlayback = false
        engine?.pause()
        if isPlaying { isPlaying = false }
        updateLockScreen()
    }
    func toggle() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) {
        guard let engine, seconds.isFinite else { return }
        engine.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        progress.update(position: seconds, duration: progress.timing.duration)
        lyrics.follow(position: seconds)
        updateLockScreen()
    }
    func next() async {
        guard !queue.isEmpty else { return }
        if shuffled {
            _ = playbackQueue.advance(shuffledIndex: Int.random(in: queue.indices))
        } else {
            if playbackQueue.advance(repeatsPlaylist: repeatMode == 1) == nil {
                let selected = selection
                await appendContinuation(selection: selected)
                guard selection == selected else { return }
                guard let current else { pause(); return }
                playbackQueue = PlaybackQueue(tracks: queue, startingAt: current)
                guard playbackQueue.advance() != nil else { pause(); return }
            }
        }
        queue = playbackQueue.tracks
        currentIndex = playbackQueue.index
        prepareCurrent()
    }
    func previous() async {
        if progress.timing.position > 3 { seek(to: 0); return }
        guard !queue.isEmpty else { return }
        currentIndex = (currentIndex - 1 + queue.count) % queue.count
        playbackQueue = PlaybackQueue(tracks: queue, startingAt: queue[currentIndex])
        prepareCurrent()
    }

    /// First-track swipe down: restart the current song instead of wrapping
    /// around to the last queue item.
    func restartCurrent() {
        seek(to: 0)
        if !isPlaying { play() }
    }

    private func appendContinuation(selection selected: UUID) async {
        guard let current else { return }
        let request = ContinueRequest(
            platform: current.platform,
            seedId: current.id,
            seedIds: Array(queue.suffix(4).map(\.id)),
            station: station.isEmpty ? nil : station,
            exclude: queue.map(\.id)
        )
        guard let response: ContinueResponse = try? await MusicAPI.post("recommendations/continue", body: request),
              selection == selected else { return }
        station = response.station ?? station
        let known = Set(queue)
        queue.append(contentsOf: response.tracks.filter { $0.canPlay && !known.contains($0) })
    }
    func move(from source: IndexSet, to destination: Int) {
        playbackQueue.move(from: source, to: destination)
        queue = playbackQueue.tracks
        currentIndex = playbackQueue.index
    }

    private func ended() async {
        if repeatMode == 2 { seek(to: 0); play() }
        else if currentIndex + 1 < queue.count || repeatMode == 1 { await next() }
        else { pause() }
    }

    private func loadLyrics(_ track: Track, selection selected: UUID) {
        let source = track.sourceId ?? track.playbackSelectionID
        guard var url = URLComponents(url: MusicAPI.base.appending(path: "lyrics"), resolvingAgainstBaseURL: false) else { return }
        url.queryItems = [.init(name: "platform", value: track.platform), .init(name: "track_id", value: source),
                          .init(name: "title", value: track.song), .init(name: "artist", value: track.singer)]
        lyricRequest = Task { [weak self] in
            guard let endpoint = url.url,
                  let (data, _) = try? await URLSession.shared.data(from: endpoint),
                  let decoded = try? JSONDecoder().decode(Lyrics.self, from: data), decoded.available,
                  let self, self.selection == selected else { return }
            self.lyrics.lines = decoded.timedLines
            self.lyrics.text = decoded.plain.flatMap { $0.isEmpty ? nil : $0 } ?? decoded.translation ?? ""
            self.lyrics.follow(position: self.progress.timing.position)
        }
    }

    private func prefetchNextTrack() {
        guard !shuffled, repeatMode != 2 else { return }
        let nextIndex = currentIndex + 1 < queue.count ? currentIndex + 1 : 0
        guard nextIndex != currentIndex, nextIndex != 0 || repeatMode == 1 else { return }
        let next = queue[nextIndex]
        guard next.canPlay else { return }
        guard prefetchTrackID != next.id else { return }
        let key = Self.cacheKey(track: next)
        if let cached = prefetched, cached.key == key, cached.time.duration(to: .now) < .seconds(120) { return }
        prefetchTask?.cancel()
        prefetchTrackID = next.id
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            guard let prepared = try? await PlaybackResolver.prepare(track: next),
                  !Task.isCancelled else { return }
            self.prefetched = (key, prepared, .now)
        }
    }

    private static func cacheKey(track: Track) -> String {
        "\(track.platform)|\(track.playbackSelectionID)|\(PlaybackQuality.siteQuality.rawValue)"
    }

    private func updateLockScreen() {
        guard let current else { return }
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: current.song,
            MPMediaItemPropertyArtist: current.singer,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine?.currentTime().seconds.finiteNonnegative ?? progress.timing.position,
            MPMediaItemPropertyPlaybackDuration: engine?.currentItem?.duration.seconds.finiteNonnegative ?? progress.timing.duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0
        ]
        if let lockScreenArtwork { information[MPMediaItemPropertyArtwork] = lockScreenArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = information
    }

    private func loadLockScreenArtwork(for track: Track, selection selected: UUID) async {
        guard let artworkURL = track.artwork,
              let image = await ArtworkCache.shared.image(for: artworkURL, pixelSize: 512),
              !Task.isCancelled, selection == selected else { return }
        lockScreenArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateLockScreen()
    }
}
private extension Double {
    var finiteNonnegative: Double? { isFinite && self >= 0 ? self : nil }
}
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
