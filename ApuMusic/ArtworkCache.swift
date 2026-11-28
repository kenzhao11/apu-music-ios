import ImageIO
import UIKit

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var imageMisses: [String: Date] = [:]
    private var detailCoverURLs: [String: URL] = [:]
    private var detailCoverMisses: [String: Date] = [:]
    private var detailCoverTasks: [String: Task<URL?, Never>] = [:]
    private var previewKeysByURL: [String: [String]] = [:]

    init() {
        memory.totalCostLimit = 32 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                          diskCapacity: 80 * 1024 * 1024,
                                          directory: nil)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    func artworkURL(for track: Track, tier: String, forceDetailLookup: Bool = false) async -> URL? {
        if !forceDetailLookup, let url = track.artworkURL(tier: tier) { return url }
        let key = "\(track.platform):\(track.id)"
        if let cached = detailCoverURLs[key] { return trackURL(cached, tier: tier) }
        if let missedAt = detailCoverMisses[key], Date().timeIntervalSince(missedAt) < 300 { return nil }
        detailCoverMisses[key] = nil
        if let pending = detailCoverTasks[key] { let found = await pending.value; return found.flatMap { trackURL($0, tier: tier) } }
        let task = Task<URL?, Never> {
            do {
                let detail = try await MusicAPI.trackDetail(platform: track.platform, id: track.id)
                return detail.artwork
            } catch { return nil }
        }
        detailCoverTasks[key] = task
        let found = await task.value
        detailCoverTasks[key] = nil
        if let found { detailCoverURLs[key] = found; if detailCoverURLs.count > 1000 { detailCoverURLs.removeAll(keepingCapacity: true) }; return trackURL(found, tier: tier) }
        detailCoverMisses[key] = Date(); if detailCoverMisses.count > 1000 { detailCoverMisses = detailCoverMisses.filter { Date().timeIntervalSince($0.value) < 300 } }
        return nil
    }

    private func trackURL(_ url: URL, tier: String) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        return Track(id: "art", platform: "", song: "", singer: "", cover: components.url?.absoluteString).artworkURL(tier: tier)
    }

    func cachedImage(for url: URL, pixelSize: Int) -> UIImage? {
        let bucket = pixelSize >= 500 ? 640 : (pixelSize >= 200 ? 300 : 64)
        return memory.object(forKey: "\(bucket):\(pixelSize):\(url.absoluteString)" as NSString)
    }

    func cachedPreviewImage(for url: URL) -> UIImage? {
        let keys = previewKeysByURL[url.absoluteString] ?? []
        return keys.compactMap { memory.object(forKey: $0 as NSString) }
            .max { ($0.cgImage?.width ?? 0) < ($1.cgImage?.width ?? 0) }
    }

    func storeImage(_ image: UIImage, for url: URL, pixelSize: Int) {
        let bucket = pixelSize >= 500 ? 640 : (pixelSize >= 200 ? 300 : 64)
        let key = "\(bucket):\(pixelSize):\(url.absoluteString)"
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        memory.setObject(image, forKey: key as NSString, cost: cost)
        var keys = previewKeysByURL[url.absoluteString, default: []].filter { memory.object(forKey: $0 as NSString) != nil && $0 != key }
        keys.append(key)
        previewKeysByURL[url.absoluteString] = keys
    }

    func image(for url: URL, pixelSize: Int) async -> UIImage? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let bucket = pixelSize >= 500 ? 640 : (pixelSize >= 200 ? 300 : 64)
        let key = "\(bucket):\(pixelSize):\(url.absoluteString)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let missedAt = imageMisses[key], Date().timeIntervalSince(missedAt) < 300 { return nil }
        imageMisses[key] = nil
        if let pending = inFlight[key] { return await pending.value }

        let pending = Task.detached(priority: .utility) { [session] () -> UIImage? in
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }
        inFlight[key] = pending
        let image = await pending.value
        inFlight[key] = nil
        if let image, let bitmap = image.cgImage {
            storeImage(image, for: url, pixelSize: pixelSize)
        } else {
            imageMisses[key] = Date()
            if imageMisses.count > 1000 { imageMisses = imageMisses.filter { Date().timeIntervalSince($0.value) < 300 } }
        }
        return image
    }
}
