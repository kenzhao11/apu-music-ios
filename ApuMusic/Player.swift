import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class Player: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var repeatMode = 0
    @Published var shuffled = false
    @Published private(set) var lyricText = ""
    @Published private(set) var lyricLines: [LyricLine] = []
    private var engine: AVPlayer?
    private var tick: Any?
    private var station = ""
    private var lockScreenArtwork: MPMediaItemArtwork?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        MPRemoteCommandCenter.shared().nextTrackCommand.addTarget { [weak self] _ in Task { await self?.next() }; return .success }
        MPRemoteCommandCenter.shared().previousTrackCommand.addTarget { [weak self] _ in Task { await self?.previous() }; return .success }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
        NotificationCenter.default.addObserver(self, selector: #selector(ended), name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    func setQueue(_ tracks: [Track], start: Track) {
        queue = tracks.isEmpty ? [start] : tracks.filter(\.canPlay)
        if !queue.contains(start) { queue.insert(start, at: 0) }
        currentIndex = queue.firstIndex(of: start) ?? 0
        Task { await prepareCurrent() }
    }

    private func prepareCurrent() async {
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        current = track
        lyricText = ""
        lyricLines = []
        lockScreenArtwork = nil
        isPlaying = false
        engine?.pause()
        do {
            let body = PlaybackRequest(platform: track.platform, query: track.song, selectedId: track.id)
            let task: PlaybackTask = try await MusicAPI.post("playbacks", body: body)
            let ready = try await poll(task)
            guard ready.errorCode != "unplayable", let audio = ready.audioURL,
                  let url = URL(string: audio.hasPrefix("http") ? audio : "https://kenmusic.kdns.fr\(audio)") else { return }
            engine = AVPlayer(playerItem: AVPlayerItem(url: url))
            engine?.play()
            isPlaying = true
            observeTime()
            updateLockScreen()
            Task { await loadLockScreenArtwork(for: track) }
            loadLyrics(track)
        } catch {
            if queue.count > 1 { await next() }
        }
    }

    private func poll(_ initial: PlaybackTask) async throws -> PlaybackTask {
        var task = initial
        for _ in 0..<90 {
            if task.status == "completed" || task.status == "streaming" || task.status == "failed" { return task }
            try await Task.sleep(for: .seconds(1))
            let status: PlaybackStatusResponse = try await MusicAPI.get("playbacks/\(task.id)")
            task = status.task
        }
        throw URLError(.timedOut)
    }

    private func observeTime() {
        if let tick { engine?.removeTimeObserver(tick) }
        tick = engine?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                self.duration = self.engine?.currentItem?.duration.seconds.isFinite == true ? self.engine!.currentItem!.duration.seconds : 0
                self.updateLyricLine()
                self.updateLockScreen()
            }
        }
    }

    func play() { engine?.play(); isPlaying = true; updateLockScreen() }
    func pause() { engine?.pause(); isPlaying = false; updateLockScreen() }
    func toggle() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) { engine?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); position = seconds }
    func next() async {
        guard !queue.isEmpty else { return }
        if shuffled {
            currentIndex = Int.random(in: queue.indices)
        } else if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else if repeatMode == 1 {
            currentIndex = 0
        } else {
            await appendContinuation()
            guard currentIndex + 1 < queue.count else { pause(); return }
            currentIndex += 1
        }
        await prepareCurrent()
    }
    func previous() async {
        if position > 3 { seek(to: 0); return }
        guard !queue.isEmpty else { return }
        currentIndex = (currentIndex - 1 + queue.count) % queue.count
        await prepareCurrent()
    }
    private func appendContinuation() async {
        guard let current else { return }
        let request = ContinueRequest(
            platform: current.platform,
            seedId: current.id,
            seedIds: Array(queue.suffix(4).map(\.id)),
            station: station.isEmpty ? nil : station,
            exclude: queue.map(\.id)
        )
        guard let response: ContinueResponse = try? await MusicAPI.post("recommendations/continue", body: request) else { return }
        station = response.station ?? station
        let known = Set(queue)
        queue.append(contentsOf: response.tracks.filter { $0.canPlay && !known.contains($0) })
    }
    func move(from source: IndexSet, to destination: Int) { queue.move(fromOffsets: source, toOffset: destination) }

    @objc private func ended() {
        Task {
            if repeatMode == 2 { seek(to: 0); play() }
            else if currentIndex + 1 < queue.count || repeatMode == 1 { await next() }
            else { pause() }
        }
    }

    private func loadLyrics(_ track: Track) {
        let source = track.sourceId ?? String(track.id.split(separator: "--").dropLast().last ?? "")
        guard !source.isEmpty,
              var url = URLComponents(url: MusicAPI.base.appending(path: "lyrics"), resolvingAgainstBaseURL: false) else { return }
        url.queryItems = [.init(name: "platform", value: track.platform), .init(name: "track_id", value: source),
                          .init(name: "title", value: track.song), .init(name: "artist", value: track.singer)]
        Task {
            guard let endpoint = url.url,
                  let (data, _) = try? await URLSession.shared.data(from: endpoint),
                  let lyrics = try? JSONDecoder().decode(Lyrics.self, from: data), lyrics.available else { return }
            lyricLines = lyrics.words ?? []
            lyricText = lyrics.plain?.isEmpty == false ? lyrics.plain! : (lyrics.translation ?? "")
        }
    }

    private func updateLyricLine() {
        guard let line = lyricLines.first(where: { $0.start <= position && $0.end >= position }) else {
            lyricText = ""
            return
        }
        lyricText = line.words.map(\.text).joined()
    }

    private func updateLockScreen() {
        guard let current else { return }
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: current.song,
            MPMediaItemPropertyArtist: current.singer,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0
        ]
        if let lockScreenArtwork { information[MPMediaItemPropertyArtwork] = lockScreenArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = information
    }

    private func loadLockScreenArtwork(for track: Track) async {
        guard let artworkURL = track.artwork,
              let (data, _) = try? await URLSession.shared.data(from: artworkURL),
              let image = UIImage(data: data), current == track else { return }
        lockScreenArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateLockScreen()
    }
}
