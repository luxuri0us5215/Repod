import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// The two pre-blurred renderings of a cover (3.1.15). Both used to be a live
/// SwiftUI `.blur` over the full-size cover, which the GPU re-ran on every frame
/// the screen composited — and Now Playing's backdrop also drifted forever, so that
/// was every frame. A blur of a tiny bitmap, scaled up, looks the same and costs
/// nothing after the one-time render.
enum ArtworkBlurStyle: Int, Sendable {
    /// The slow-drifting light that fills Now Playing (was `.blur(48)`, ×1.5 saturation).
    case backdrop
    /// The backlight behind a cover and the glow it spills onto the body
    /// (were `.blur(18)` / `.blur(22)` / `.blur(44)`).
    case glow

    /// Longest side of the blurred bitmap, in pixels.
    fileprivate var pixelSize: CGFloat { self == .backdrop ? 64 : 32 }
    /// Gaussian sigma at that size. Relative to the drawn frame it matches the old
    /// radii: 48pt over a ~620pt backdrop ≈ 3px of 64; 18pt over a 180pt cover ≈ 3px of 32.
    fileprivate var sigma: Double { 3 }
    fileprivate var saturation: Double { self == .backdrop ? 1.5 : 1.0 }
    /// A live blur spreads past the shape it blurs; the glow keeps that by fading out
    /// into transparent padding of three sigma on every side.
    fileprivate var padding: CGFloat { self == .glow ? CGFloat(sigma * 3) : 0 }

    /// How much larger than the cover a `.glow` image must be drawn so its centre
    /// lines up with the cover and the soft edge spills past it, as `.blur` did.
    static var glowFrameScale: CGFloat {
        (ArtworkBlurStyle.glow.pixelSize + 2 * ArtworkBlurStyle.glow.padding) / ArtworkBlurStyle.glow.pixelSize
    }
}

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

    /// What one download produced. Only an answer from the server that the image
    /// is not there is worth remembering; a dropped connection says nothing about
    /// the URL and is retried by the next request.
    private enum LoadOutcome: Sendable {
        case image(UIImage)
        case missing
        case transient
    }

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: (id: UUID, task: Task<LoadOutcome, Never>)] = [:]
    /// A dead URL used to be requested again every time its row scrolled back into
    /// view. Remembering the failure briefly turns that scroll into a local miss.
    /// 3.1.15: only for answers that say the image is not there. Network errors used
    /// to be remembered too, which turned `CachedArtwork`'s retry into a no-op and
    /// left covers blank for 30 seconds after any connection blip.
    private var failedUntil: [URL: Date] = [:]
    private static let failureLifetime: TimeInterval = 30

    /// Small pre-blurred bitmaps, keyed by style and URL. A few KB each.
    private let blurredCache = NSCache<NSString, UIImage>()
    private var blurredInFlight: [NSString: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 64 * 1_024 * 1_024
        blurredCache.countLimit = 48
    }

    func cachedImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cachedImage(for: url) { return image }
        if let failedAt = failedUntil[url] {
            if failedAt > Date() { return nil }
            failedUntil[url] = nil
        }
        if let request = inFlight[url] {
            let outcome = await request.task.value
            if case .image(let image) = outcome { return image }
            return nil
        }

        let id = UUID()
        // The body is not main-actor isolated: the download, the resize and the
        // decode all happen off the main thread. Only the finished image is used
        // by the UI.
        let task = Task<LoadOutcome, Never>(priority: .userInitiated) {
            let outcome = await Self.loadAndDecode(url)
            guard case .image(let image) = outcome else { return outcome }
            let pixels = image.cgImage
            let cost = (pixels?.bytesPerRow ?? 0) * (pixels?.height ?? 0)
            #if DEBUG
            // Confirms the decoded cover is near its display size. A cover stretched
            // to 640 px costs about 1.6 MB and would evict the whole cache.
            print("[Artwork] cost=\(cost) \(url.lastPathComponent)")
            #endif
            CachedImageLoader.shared.cache.setObject(image, forKey: url as NSURL, cost: cost)
            return outcome
        }
        inFlight[url] = (id, task)
        let outcome = await task.value
        // A newer request may have replaced this one while it was awaited.
        if inFlight[url]?.id == id { inFlight[url] = nil }
        switch outcome {
        case .image(let image):
            failedUntil[url] = nil
            return image
        case .missing:
            if failedUntil.count > 256 { failedUntil.removeAll() }
            failedUntil[url] = Date().addingTimeInterval(Self.failureLifetime)
            return nil
        case .transient:
            return nil
        }
    }

    func prefetch(_ urls: [URL]) async {
        // Start both neighbours before waiting; these requests share inFlight
        // with visible artwork and continue if the scroll position changes.
        let requests = Set(urls).map { url in
            Task { @MainActor in _ = await image(for: url) }
        }
        for request in requests { await request.value }
    }

    // MARK: Pre-blurred renderings

    private static func blurredKey(_ url: URL, _ style: ArtworkBlurStyle) -> NSString {
        "\(style.rawValue)|\(url.absoluteString)" as NSString
    }

    func cachedBlurred(for url: URL?, style: ArtworkBlurStyle) -> UIImage? {
        guard let url else { return nil }
        return blurredCache.object(forKey: Self.blurredKey(url, style))
    }

    /// Reuses the decoded cover (downloading it if needed), then renders the small
    /// blurred bitmap off the main thread, once per cover and style.
    func blurred(for url: URL, style: ArtworkBlurStyle) async -> UIImage? {
        let key = Self.blurredKey(url, style)
        if let cached = blurredCache.object(forKey: key) { return cached }
        if let running = blurredInFlight[key] { return await running.value }
        let task = Task<UIImage?, Never> { @MainActor in
            guard let source = await CachedImageLoader.shared.image(for: url) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                CachedImageLoader.renderBlurred(source, style: style)
            }.value
        }
        blurredInFlight[key] = task
        let image = await task.value
        blurredInFlight[key] = nil
        if let image { blurredCache.setObject(image, forKey: key) }
        return image
    }

    private nonisolated static func renderBlurred(_ image: UIImage, style: ArtworkBlurStyle) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var source = CIImage(cgImage: cgImage)
        if style == .glow {
            // The glow stands in for a cover that was clipped to its square first.
            let side = min(source.extent.width, source.extent.height)
            source = source.cropped(to: CGRect(x: source.extent.midX - side / 2,
                                               y: source.extent.midY - side / 2,
                                               width: side, height: side))
        }
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX,
                                                          y: -source.extent.minY))
        let longest = max(source.extent.width, source.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, style.pixelSize / longest)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var extent = small.extent.integral
        var output: CIImage
        if style.padding > 0 {
            // Blurred against transparency, so the edge fades out instead of stopping.
            extent = extent.insetBy(dx: -style.padding, dy: -style.padding)
            output = small.applyingGaussianBlur(sigma: style.sigma).cropped(to: extent)
        } else {
            // Edge pixels repeat outward, so the backdrop stays solid to its border.
            output = small.clampedToExtent()
                .applyingGaussianBlur(sigma: style.sigma)
                .cropped(to: extent)
        }
        if style.saturation != 1 {
            output = output.applyingFilter("CIColorControls",
                                           parameters: [kCIInputSaturationKey: style.saturation])
        }
        // One context per render: it happens once per cover change, off the main thread.
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let rendered = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    /// Network plus an ImageIO thumbnail, so the decoded bitmap is already the size
    /// the view draws and Core Animation never has to unpack the original file.
    private nonisolated static func loadAndDecode(_ url: URL) async -> LoadOutcome {
        do {
            let (data, response) = try await Self.session.data(from: url)
            guard let response = response as? HTTPURLResponse else { return .transient }
            // 5xx and 429 are the server having a bad moment, not a dead URL.
            if response.statusCode >= 500 || response.statusCode == 429 { return .transient }
            guard (200..<300).contains(response.statusCode), !data.isEmpty,
                  let image = decode(data) else { return .missing }
            return .image(image)
        } catch {
            return .transient
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
        ZStack {
            // 3.1.16: always present. Callers often draw nothing until the image exists
            // (`if let image { … }`), and SwiftUI never starts a `.task` attached to a
            // view that drew nothing — so an uncached cover was never requested.
            ArtworkLoadAnchor()
            content(image.map { Image(uiImage: $0) })
        }
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

/// `CachedArtwork` for the pre-blurred renderings: the closure gets a small,
/// already-blurred image (resizable, smoothly scaled), so no live `.blur` is
/// needed (3.1.15).
@MainActor
struct BlurredArtwork<Content: View>: View {
    let url: URL?
    let style: ArtworkBlurStyle
    @ViewBuilder let content: (Image?) -> Content

    @State private var loadedImage: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        let image = loadedURL == url ? loadedImage
            : CachedImageLoader.shared.cachedBlurred(for: url, style: style)
        ZStack {
            // See `CachedArtwork`: every caller draws nothing until the blurred image
            // exists, so without this the load never started and the backdrop stayed
            // black whenever the cover was not already cached.
            ArtworkLoadAnchor()
            content(image.map { Image(uiImage: $0).resizable().interpolation(.high) })
        }
            .task(id: url) {
                loadedImage = CachedImageLoader.shared.cachedBlurred(for: url, style: style)
                loadedURL = url
                guard let url else { return }
                let image = await CachedImageLoader.shared.blurred(for: url, style: style)
                guard !Task.isCancelled, loadedURL == url else { return }
                if let image {
                    loadedImage = image
                    return
                }
                // One quiet retry, as `CachedArtwork` does: a dropped connection is not
                // remembered by the loader, so the second ask really goes out.
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard !Task.isCancelled, loadedURL == url else { return }
                if let retried = await CachedImageLoader.shared.blurred(for: url, style: style),
                   !Task.isCancelled, loadedURL == url {
                    loadedImage = retried
                }
            }
    }
}

/// A zero-size view that is always drawn, so the artwork views' `.task` has
/// something to appear with even before there is an image. It takes no space and
/// is invisible to layout, hit testing and VoiceOver.
@MainActor
private struct ArtworkLoadAnchor: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
