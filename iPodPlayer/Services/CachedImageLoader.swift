import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Artwork is shared across album copies, reflections and Now Playing.
/// Only this loader owns downloads, so a disappearing cell cannot cancel a
/// request another cell (or a neighbouring-album prefetch) is still using.
@MainActor
final class CachedImageLoader {
    static let shared = CachedImageLoader()

    /// Covers are never displayed larger than a couple of hundred points. Decoding
    /// the source file at that size keeps both the cache and the render pass small:
    /// full-size album art cost tens of milliseconds per cover on the main thread,
    /// which showed up as a stutter exactly when the artwork appeared.
    private nonisolated static let maxPixelSize: CGFloat = 640

    /// Album art comes from one CDN host, and the default session allows only six
    /// connections to it. Cover Flow shows a ring of covers at once, so it queued
    /// behind that limit and looked like slow album loading. A dedicated session
    /// raises the pool and keeps covers on disk, so re-entering the screen is
    /// instant instead of re-downloading the same images.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1_024 * 1_024,
                                          diskCapacity: 256 * 1_024 * 1_024,
                                          directory: nil)
        return URLSession(configuration: configuration)
    }()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: (id: UUID, task: Task<UIImage?, Never>)] = [:]
    /// A dead URL used to be requested again every time its row scrolled back into
    /// view. Remembering the failure briefly turns that scroll into a local miss.
    private var failedUntil: [URL: Date] = [:]
    private static let failureLifetime: TimeInterval = 30

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func cachedImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cachedImage(for: url) { return image }
        if let failedAt = failedUntil[url], failedAt > Date() { return nil }
        if let request = inFlight[url] { return await request.task.value }

        let id = UUID()
        // The body is not main-actor isolated: the download, the resize and the
        // decode all happen off the main thread. Only the finished image is used
        // by the UI.
        let task = Task<UIImage?, Never>(priority: .userInitiated) {
            guard let image = await Self.loadAndDecode(url) else { return nil }
            let pixels = image.cgImage
            let cost = (pixels?.bytesPerRow ?? 0) * (pixels?.height ?? 0)
            #if DEBUG
            // Confirms the decoded cover is near its display size. A cover stretched
            // to 640 px costs about 1.6 MB and would evict the whole cache.
            print("[Artwork] cost=\(cost) \(url.lastPathComponent)")
            #endif
            CachedImageLoader.shared.cache.setObject(image, forKey: url as NSURL, cost: cost)
            return image
        }
        inFlight[url] = (id, task)
        let image = await task.value
        // A newer request may have replaced this one while it was awaited.
        if inFlight[url]?.id == id { inFlight[url] = nil }
        failedUntil[url] = image == nil ? Date().addingTimeInterval(Self.failureLifetime) : nil
        return image
    }

    func prefetch(_ urls: [URL]) async {
        // Start both neighbours before waiting; these requests share inFlight
        // with visible artwork and continue if the scroll position changes.
        let requests = Set(urls).map { url in
            Task { @MainActor in _ = await image(for: url) }
        }
        for request in requests { await request.value }
    }

    /// Network plus an ImageIO thumbnail, so the decoded bitmap is already the size
    /// the view draws and Core Animation never has to unpack the original file.
    private nonisolated static func loadAndDecode(_ url: URL) async -> UIImage? {
        do {
            let (data, response) = try await Self.session.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), !data.isEmpty else { return nil }
            return decode(data)
        } catch {
            // The visible consumer may retry once; failures are not cached.
            return nil
        }
    }

    private nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        // ImageIO stretches a smaller source up to the requested thumbnail size, so a
        // 640 px limit on the ~300 px covers both sources return produced a 1.6 MB
        // bitmap that filled the cache in about forty covers. Never ask for more than
        // the source actually has.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longestSide = max(sourceWidth, sourceHeight)
        let targetPixelSize = longestSide > 0 ? min(maxPixelSize, longestSide) : maxPixelSize
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: thumbnail)
    }
}

/// One load can supply any number of renderings of the same image.
@MainActor
struct CachedArtwork<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image?) -> Content

    @State private var loadedImage: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        let image = loadedURL == url ? loadedImage : CachedImageLoader.shared.cachedImage(for: url)
        content(image.map { Image(uiImage: $0) })
            .task(id: url) {
                loadedImage = CachedImageLoader.shared.cachedImage(for: url)
                loadedURL = url
                guard let url else { return }
                let image = await CachedImageLoader.shared.image(for: url)
                // An older URL's task may finish after this view has been
                // reused. It can warm the cache without replacing new art.
                guard !Task.isCancelled, loadedURL == url else { return }
                // A failed load must never blank a cover that is already on screen:
                // a flaky CDN retry then looks like the artwork flickering away.
                if let image { loadedImage = image }
                guard image == nil else { return }
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                } catch { return }
                guard !Task.isCancelled, loadedURL == url else { return }
                let retriedImage = await CachedImageLoader.shared.image(for: url)
                guard !Task.isCancelled, loadedURL == url else { return }
                if let retriedImage { loadedImage = retriedImage }
            }
    }
}
