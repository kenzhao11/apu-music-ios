import ImageIO
import UIKit

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
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

    func image(for url: URL, pixelSize: Int) async -> UIImage? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let key = "\(pixelSize):\(url.absoluteString)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
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
            memory.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
        }
        return image
    }
}
