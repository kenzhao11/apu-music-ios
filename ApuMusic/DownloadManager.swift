import Foundation
import SwiftUI

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published var alertMessage: String?
    private var tasks: [String: Task<Void, Never>] = [:]

    func download(_ track: Track) {
        guard tasks[track.id] == nil else { return }
        // A row the backend already reported as unplayable is never requested.
        guard track.canPlay else {
            errors[track.id] = "这首歌暂时无法播放。"
            alertMessage = "下载失败：这首歌暂时无法播放。"
            return
        }
        errors[track.id] = nil
        progress[track.id] = 0
        tasks[track.id] = Task {
            defer {
                tasks[track.id] = nil
                if DownloadStore.localURL(for: track) != nil { progress[track.id] = 1 }
                else { progress[track.id] = nil }
            }
            do {
                // Identical request to playback: same site quality tier,
                // same matched row, same audio URL.
                let prepared = try await PlaybackResolver.prepare(track: track)
                progress[track.id] = 0.01
                let local = try await CompatibleAudio.localFile(from: prepared.audioURL) { [weak self] value in
                    Task { @MainActor in self?.progress[track.id] = 0.01 + value * 0.98 }
                }
                defer { try? FileManager.default.removeItem(at: local) }
                try DownloadStore.add(track, file: local)
                progress[track.id] = 1
            } catch {
                errors[track.id] = error.localizedDescription
                alertMessage = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    func cancel(_ track: Track) { tasks[track.id]?.cancel(); tasks[track.id] = nil; progress[track.id] = nil }
}
