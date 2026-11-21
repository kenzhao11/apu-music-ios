import Foundation
import OSLog

/// Downloads original bytes. Playback continues to use the backend's native URL.
enum CompatibleAudio {
    static func localFile(from source: URL, track: Track? = nil,
                          onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await BackgroundAudioDownload.shared.download(source, track: track, onProgress: onProgress)
    }

    static func validate(_ file: URL, response: HTTPURLResponse) throws -> String {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard let count = size?.int64Value, count > 0 else {
            throw PlaybackError.unavailable("音频文件为空，请重新下载。")
        }
        if response.statusCode == 206 {
            // Only accept a whole-object range response; a truncated resumed
            // response is not a complete download task result.
            guard let header = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = parseContentRange(header), range.end + 1 == range.total,
                  count == range.total else {
                throw PlaybackError.unavailable("音频文件没有下载完整，请重新下载。")
            }
        } else if response.statusCode == 200 {
            // Content-Length is comparable because the request asks for the
            // identity representation.
            if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
               encoding.lowercased() != "identity" {
                throw PlaybackError.unavailable("音频服务器返回的文件长度无法校验，请稍后重试。")
            }
            guard let header = response.value(forHTTPHeaderField: "Content-Length"),
                  let expected = Int64(header), expected > 0 else {
                throw PlaybackError.unavailable("音频服务器未提供完整文件大小，请稍后重试。")
            }
            guard count == expected else {
                throw PlaybackError.unavailable("音频文件没有下载完整，请重新下载。")
            }
        } else {
            throw PlaybackError.unavailable("音频地址暂时无法下载，请稍后重试。")
        }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let header = try reader.read(upToCount: 16) ?? Data()
        // Magic wins over MIME: some real upstreams serve audio as text/html.
        if header.starts(with: "fLaC".utf8) { return "flac" }
        if header.starts(with: "OggS".utf8) { return "ogg" }
        if header.dropFirst(4).starts(with: "ftyp".utf8) { return "m4a" }
        if header.starts(with: "RIFF".utf8), header.dropFirst(8).starts(with: "WAVE".utf8) { return "wav" }
        if header.starts(with: "ID3".utf8) { return "mp3" }
        if header.count >= 2, header[0] == 0xff, header[1] & 0xe0 == 0xe0 {
            return header[1] & 0xf6 == 0xf0 ? "aac" : "mp3"
        }
        // Never accept an HTML/JSON error merely because a MIME claims audio.
        throw PlaybackError.unavailable("服务器返回的文件不是可识别的音频，请稍后重试。")
    }

    private static func parseContentRange(_ header: String) -> (end: Int64, total: Int64)? {
        guard header.range(of: #"^bytes \d+-\d+/\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let parts = header.dropFirst(6).split { $0 == "-" || $0 == "/" }
        guard parts.count == 3, let start = Int64(parts[0]), let end = Int64(parts[1]),
              let total = Int64(parts[2]), start >= 0, end >= start, total > end else { return nil }
        return (end, total)
    }
}

/// The OS writes straight to a temporary file, including while suspended.
/// All mutable job state and delegate callbacks run on one serial queue.
final class BackgroundAudioDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundAudioDownload()
    static let sessionIdentifier = "fr.kdns.kenmusic.apu.original-downloads"
    private static let logger = Logger(subsystem: "ApuMusic", category: "download")
    private let queue = DispatchQueue(label: "ApuMusic.download")
    private var jobs: [UUID: Job] = [:]
    private var cancelledBeforeStart = Set<UUID>()
    private var backgroundCompletion: (() -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private struct Metadata: Codable {
        var id: UUID
        var track: Track?
        var attempt: Int
        var validationFailure: String? = nil
    }

    private final class Job {
        let continuation: CheckedContinuation<URL, Error>
        let onProgress: (@Sendable (Double) -> Void)?
        var task: URLSessionDownloadTask
        var file: URL?
        var fileError: Error?
        init(_ continuation: CheckedContinuation<URL, Error>, progress: (@Sendable (Double) -> Void)?, task: URLSessionDownloadTask) {
            self.continuation = continuation
            self.onProgress = progress
            self.task = task
        }
    }

    func reconnect(completion: (() -> Void)? = nil) {
        queue.async {
            self.backgroundCompletion = completion
            self.session.getAllTasks { _ in }
        }
    }

    func download(_ source: URL, track: Track?, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                queue.async {
                    if self.cancelledBeforeStart.remove(id) != nil {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let task = self.session.downloadTask(with: request)
                    self.setMetadata(Metadata(id: id, track: track, attempt: 0), on: task)
                    self.jobs[id] = Job(continuation, progress: onProgress, task: task)
                    task.resume()
                }
            }
        } onCancel: {
            self.queue.async {
                guard let job = self.jobs.removeValue(forKey: id) else {
                    self.cancelledBeforeStart.insert(id)
                    return
                }
                job.task.cancel()
                if let file = job.file { try? FileManager.default.removeItem(at: file) }
                job.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func metadata(_ task: URLSessionTask) -> Metadata? {
        guard let data = task.taskDescription?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func setMetadata(_ value: Metadata, on task: URLSessionTask) {
        task.taskDescription = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let metadata = metadata(downloadTask), totalBytesExpectedToWrite > 0 else { return }
        jobs[metadata.id]?.onProgress?(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard var metadata = metadata(downloadTask) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let ext = try CompatibleAudio.validate(location, response: response)
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("apu-\(metadata.id).\(ext)")
            try FileManager.default.moveItem(at: location, to: saved)
            if let job = jobs[metadata.id] {
                job.file = saved
            } else if let track = metadata.track {
                // Relaunched by iOS after a background transfer completed.
                // Persist before acknowledging background session events.
                do { try DownloadStore.add(track, file: saved) }
                catch {
                    try? FileManager.default.removeItem(at: saved)
                    throw error
                }
            } else {
                try? FileManager.default.removeItem(at: saved)
            }
        } catch {
            if let job = jobs[metadata.id] {
                job.fileError = error
            } else {
                metadata.validationFailure = PlaybackFailure.message(error)
                setMetadata(metadata, on: downloadTask)
            }
            Self.logger.error("下载校验失败 code=\((error as NSError).code)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard var metadata = metadata(task) else { return }
        let job = jobs[metadata.id]
        if job == nil, metadata.attempt == 0,
           (error as NSError?)?.code != NSURLErrorCancelled,
           let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            metadata.attempt = 1
            let retry = session.downloadTask(withResumeData: resumeData)
            setMetadata(metadata, on: retry)
            retry.resume()
            return
        }
        let failure = job?.fileError ?? error ?? metadata.validationFailure.map { PlaybackError.unavailable($0) }
        if job == nil, let failure {
            if metadata.attempt == 0, (failure as NSError).code != NSURLErrorCancelled,
               let original = task.originalRequest {
                metadata.attempt = 1
                metadata.validationFailure = nil
                let resumeData = (failure as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                let retry: URLSessionDownloadTask
                if let resumeData { retry = session.downloadTask(withResumeData: resumeData) }
                else { retry = session.downloadTask(with: original) }
                setMetadata(metadata, on: retry)
                retry.resume()
                return
            }
            if let track = metadata.track {
                DownloadStore.recordFailure(for: track, message: PlaybackFailure.message(failure))
            }
            return
        }
        if let failure, metadata.attempt == 0,
           (failure as NSError).code != NSURLErrorCancelled,
           let original = task.originalRequest {
            metadata.attempt = 1
            let resumeData = (failure as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let retry: URLSessionDownloadTask
            if let resumeData { retry = session.downloadTask(withResumeData: resumeData) }
            else { retry = session.downloadTask(with: original) }
            setMetadata(metadata, on: retry)
            job?.fileError = nil
            if let file = job?.file { try? FileManager.default.removeItem(at: file) }
            job?.file = nil
            job?.task = retry
            retry.resume()
            return
        }
        guard let job = jobs.removeValue(forKey: metadata.id) else { return }
        if let failure {
            if let file = job.file { try? FileManager.default.removeItem(at: file) }
            job.continuation.resume(throwing: failure)
        } else if let file = job.file {
            job.continuation.resume(returning: file)
        } else {
            job.continuation.resume(throwing: PlaybackError.unavailable("音频文件没有保存成功，请重新下载。"))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        DispatchQueue.main.async { completion?() }
    }
}
