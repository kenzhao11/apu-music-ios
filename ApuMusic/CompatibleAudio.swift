import AVFoundation
import Foundation

enum CompatibleAudio {
    static func localFile(from source: URL) async throws -> URL {
        let download = FileManager.default.temporaryDirectory.appendingPathComponent("apu-source-\(UUID().uuidString)")
        let conversion = Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: download) }
            try await downloadAudio(source, to: download)
            return try transcodeIfNeeded(download)
        }
        return try await withTaskCancellationHandler {
            try await conversion.value
        } onCancel: {
            conversion.cancel()
        }
    }

    private static func downloadAudio(_ source: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var offset: Int64 = 0
        var expectedTotal: Int64?
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw PlaybackError.unavailable("无法创建音频临时文件。")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        while expectedTotal.map({ offset < $0 }) ?? true {
            try Task.checkCancellation()
            var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("bytes=\(offset)-\(offset + 1_048_575)", forHTTPHeaderField: "Range")
            let (chunk, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), !chunk.isEmpty else {
                throw PlaybackError.unavailable("音频服务器无法提供完整文件（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
            }
            let rangeHeader = response.value(forHTTPHeaderField: "Content-Range")
            guard response.statusCode == 206, let rangeHeader,
                  let range = Self.parseContentRange(rangeHeader), range.start == offset,
                  Int64(chunk.count) == range.end - range.start + 1,
                  expectedTotal == nil || expectedTotal == range.total else {
                throw PlaybackError.unavailable("音频服务器返回了不连续的数据块，无法完成兼容转换。")
            }
            expectedTotal = range.total
            try output.write(contentsOf: chunk)
            offset += Int64(chunk.count)
        }
        guard let expectedTotal, offset == expectedTotal else {
            throw PlaybackError.unavailable("音频文件传输未完整结束。")
        }
    }

    private struct ByteRange {
        var start: Int64
        var end: Int64
        var total: Int64
    }

    private static func parseContentRange(_ header: String) -> ByteRange? {
        guard let match = header.range(of: #"^bytes (\d+)-(\d+)/(\d+)$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let values = header[match].dropFirst("bytes ".count).split { $0 == "-" || $0 == "/" }
        guard values.count == 3,
              let start = Int64(values[0]), let end = Int64(values[1]), let total = Int64(values[2]),
              start >= 0, end >= start, total > end else { return nil }
        return ByteRange(start: start, end: end, total: total)
    }

    private static func transcodeIfNeeded(_ download: URL) throws -> URL {
        try Task.checkCancellation()
        let reader = try FileHandle(forReadingFrom: download)
        defer { try? reader.close() }
        let header = try reader.read(upToCount: 12) ?? Data()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("apu-\(UUID().uuidString)")

        if header.starts(with: "fLaC".utf8) {
            let flac = temporary.appendingPathExtension("flac")
            let m4a = temporary.appendingPathExtension("m4a")
            try FileManager.default.moveItem(at: download, to: flac)
            defer { try? FileManager.default.removeItem(at: flac) }
            do {
                try convertFLAC(flac, to: m4a)
                return m4a
            } catch {
                try? FileManager.default.removeItem(at: m4a)
                throw error
            }
        }

        let fileExtension: String
        if header.dropFirst(4).starts(with: "ftyp".utf8) {
            fileExtension = "m4a"
        } else if header.starts(with: "ID3".utf8) ||
                    (header.count >= 2 && header[0] == 0xff && header[1] & 0xe0 == 0xe0) {
            fileExtension = header.count >= 2 && header[0] == 0xff && header[1] & 0xf6 == 0xf0 ? "aac" : "mp3"
        } else {
            throw PlaybackError.unavailable("音源未返回 iPhone 可读取的音频格式。")
        }
        let output = temporary.appendingPathExtension(fileExtension)
        try FileManager.default.moveItem(at: download, to: output)
        return output
    }

    private static func convertFLAC(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: false)
        let format = input.processingFormat
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey: 16
        ], commonFormat: .pcmFormatInt16, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw PlaybackError.unavailable("无法初始化音频转换。")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }
}
