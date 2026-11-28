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
    @Published private(set) var availabilityNotice = ""
    @Published private(set) var unavailableTrackIDs = Set<String>()
    private var noticeTask: Task<Void, Never>?
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
    private var attemptedFailureIDs = Set<String>()
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

    func isUnavailable(_ track: Track) -> Bool {
        unavailableTrackIDs.contains(track.id)
    }

    func markUnavailable(_ track: Track) {
        // A disabled row must not interrupt the song already playing or open a sheet.
        availabilityNotice = "此歌曲暂不可用"
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.availabilityNotice = ""
        }
    }

    func setQueue(_ tracks: [Track], start: Track) {
        attemptedFailureIDs.removeAll()
        playbackQueue = PlaybackQueue(tracks: tracks, startingAt: start, excluding: unavailableTrackIDs)
        queue = playbackQueue.tracks
        currentIndex = playbackQueue.index
        guard !queue.isEmpty else {
            markUnavailable(start)
            return
        }
        prepareCurrent()
    }

    private func prepareCurrent() {
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        guard track.canPlay, !isUnavailable(track) else {
            pause()
            markUnavailable(track)
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
                    prepared = try await Self.prepareWithBoundedRetries(track)
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

    private static func prepareWithBoundedRetries(_ track: Track) async throws -> PreparedPlayback {
        var lastError: Error = PlaybackError.unavailable("无法播放当前歌曲")
        for attempt in 0..<2 {
            do { return try await PlaybackResolver.prepare(track: track, quality: .siteQuality) }
            catch {
                lastError = error
                if Task.isCancelled { throw CancellationError() }
                if (error as? PlaybackError)?.isUnplayable == true { break }
                if attempt == 0 { try await Task.sleep(for: .milliseconds(350)) }
            }
        }
        if (lastError as? PlaybackError)?.isUnplayable == true { throw lastError }
        throw PlaybackError.unavailable("无法播放当前歌曲")
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
                        self.attemptedFailureIDs.removeAll()
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
        Self.logger.error("AVPlayerItem failed selected_id=\((self.current?.playbackSelectionID ?? ""), privacy: .private) taskID=\(self.activePlaybackTaskID, privacy: .private) domain=\((failure as NSError).domain, privacy: .public) code=\(errorCode)")
        clearEngine()
        let startupTimedOut = (failure as? PlaybackError)?.localizedDescription.contains("超时") == true
        if (PlaybackFailure.isNetwork(failure) || startupTimedOut), networkPlaybackRetries == 0,
           let current, current.canPlay {
            networkPlaybackRetries += 1
            playbackMessage = "网络连接不稳定，正在重试…"
            resolveAudio(for: current, selection: selection)
            return
        }
        reportPlaybackFailure(failure, skipToNext: true)
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

    private func reportPlaybackFailure(_ error: Error, skipToNext: Bool = false) {
        let definitive = (error as? PlaybackError)?.isUnplayable == true
        playbackFailed = true
        wantsPlayback = false
        if (error as? PlaybackError)?.isUnplayable == true {
            playbackMessage = "此歌曲暂不可用"
        } else if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
            playbackMessage = "无法播放当前歌曲"
        } else {
            playbackMessage = "无法播放当前歌曲"
        }
        Self.logger.error("Playback failed: \(String(reflecting: error as NSError), privacy: .private)")
        updateLockScreen()
        if definitive {
            if let current {
                unavailableTrackIDs.insert(current.id)
                playbackQueue.markUnavailable(current)
                queue = playbackQueue.tracks
            }
        }
        else if !skipToNext { wantsPlayback = false; return }
        guard !queue.isEmpty else { wantsPlayback = false; return }
        if let current { attemptedFailureIDs.insert(current.id) }
        consecutiveFailures += 1
        wantsPlayback = true
        // Explicit unavailable tasks and mid-play AVPlayer failures advance;
        // transient preparation errors stay visible and require a user retry.
        let selected = selection
        let failureCount = consecutiveFailures
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.selection == selected else { return }
            guard self.consecutiveFailures == failureCount else { return }
            guard self.playbackQueue.advanceAfterFailure(attemptedIDs: self.attemptedFailureIDs) != nil else {
                self.wantsPlayback = false
                self.playbackMessage = "无法播放当前歌曲"
                return
            }
            self.currentIndex = self.playbackQueue.index
            self.queue = self.playbackQueue.tracks
            self.prepareCurrent()
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
            guard let randomIndex = playbackQueue.tracks.indices.filter({ playbackQueue.tracks[$0].canPlay }).randomElement(),
                  playbackQueue.advance(shuffledIndex: randomIndex) != nil else { pause(); return }
        } else {
            if playbackQueue.advance(repeatsPlaylist: repeatMode == 1) == nil {
                let selected = selection
                await appendContinuation(selection: selected)
                guard selection == selected else { return }
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
        guard playbackQueue.retreat() != nil else { pause(); return }
        queue = playbackQueue.tracks
        currentIndex = playbackQueue.index
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
        playbackQueue.append(response.tracks, excluding: unavailableTrackIDs)
        queue = playbackQueue.tracks
        currentIndex = playbackQueue.index
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
        var previewQueue = playbackQueue
        guard let next = previewQueue.advance(repeatsPlaylist: repeatMode == 1),
              next.id != current?.id, !isUnavailable(next) else { return }
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
        guard let artworkURL = track.artworkURL(tier: "large"),
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
