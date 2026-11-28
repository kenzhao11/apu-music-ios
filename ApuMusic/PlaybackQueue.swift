import AVFoundation
import Foundation

struct PlaybackQueue {
    private(set) var tracks: [Track]
    private(set) var index: Int

    var current: Track? { tracks.indices.contains(index) ? tracks[index] : nil }
    var isEmpty: Bool { tracks.isEmpty }

    init() {
        tracks = []
        index = 0
    }

    init(tracks: [Track], startingAt track: Track, excluding unavailableIDs: Set<String> = []) {
        let playable = tracks.filter { $0.canPlay && !unavailableIDs.contains($0.id) }
        self.tracks = playable
        index = self.tracks.firstIndex(of: track) ?? 0
    }

    mutating func advanceAfterFailure(attemptedIDs: Set<String>) -> Track? {
        guard !tracks.isEmpty, index + 1 < tracks.count else { return nil }
        for nextIndex in (index + 1)..<tracks.count {
            let candidate = tracks[nextIndex]
            guard candidate.canPlay, !attemptedIDs.contains(candidate.id) else { continue }
            index = nextIndex
            return candidate
        }
        return nil
    }

    mutating func markUnavailable(_ track: Track) {
        guard let position = tracks.firstIndex(of: track) else { return }
        tracks[position].playable = false
    }

    mutating func advance(shuffledIndex: Int? = nil, repeatsPlaylist: Bool = false) -> Track? {
        guard !tracks.isEmpty else { return nil }
        if let shuffledIndex {
            guard tracks.indices.contains(shuffledIndex) else { return nil }
            index = shuffledIndex
        } else if index + 1 < tracks.count {
            index += 1
        } else if repeatsPlaylist {
            index = 0
        } else {
            return nil
        }
        return current
    }

    mutating func move(from source: IndexSet, to destination: Int) {
        guard let current else { return }
        let selected = source.filter(tracks.indices.contains).sorted()
        guard !selected.isEmpty else { return }
        let moved = selected.map { tracks[$0] }
        let removedBeforeDestination = selected.filter { $0 < destination }.count
        for item in selected.reversed() {
            tracks.remove(at: item)
        }
        let adjustedDestination = min(max(0, destination - removedBeforeDestination), tracks.count)
        tracks.insert(contentsOf: moved, at: adjustedDestination)
        index = tracks.firstIndex(of: current) ?? 0
    }
}
