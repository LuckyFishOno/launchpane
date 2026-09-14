import AppCore
import AppKit

/// A main-actor facade around a thread-safe icon cache and background decoder.
///
/// Rendering code can synchronously consult ``cgImage(for:pointSize:scale:)`` without ever
/// touching the filesystem or decoding an image. Cache misses are fulfilled through
/// ``loadCGImage(for:pointSize:scale:)`` or ``warm(_:pointSize:scale:maximumConcurrentLoads:)``.
@MainActor
final class AppIconCache {
    private struct Request: Hashable, Sendable {
        let identity: ApplicationIdentity
        let path: String
        let pixelSize: Int

        var cacheKey: NSString {
            "\(identity)|\(path)" as NSString
        }
    }

    private final class CachedIcon {
        let requestedPixelSize: Int
        let image: CGImage

        init(requestedPixelSize: Int, image: CGImage) {
            self.requestedPixelSize = requestedPixelSize
            self.image = image
        }
    }

    private struct InFlightLoad {
        let id: UUID
        let task: Task<CGImage?, Never>
    }

    private enum Metrics {
        static let countLimit = 512
        static let totalCostLimit = 256 * 1024 * 1024
        static let defaultMaximumConcurrentLoads = 3
    }

    private let cache = NSCache<NSString, CachedIcon>()
    private var inFlightLoads: [Request: InFlightLoad] = [:]
    private let decode: @Sendable (String, Int) -> CGImage?

    init(decode: @escaping @Sendable (String, Int) -> CGImage? = { path, pixelSize in
        AppIconDecoder.decode(path: path, pixelSize: pixelSize)
    }) {
        self.decode = decode
        cache.countLimit = Metrics.countLimit
        cache.totalCostLimit = Metrics.totalCostLimit
    }

    /// Returns an already-decoded icon immediately. A cache miss never performs synchronous work.
    func cgImage(
        for application: ApplicationRecord,
        pointSize: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let request = makeRequest(
            for: application,
            pointSize: pointSize,
            scale: scale
        )
        return cachedImage(for: request)
    }

    /// Loads and decodes an icon away from the main actor, sharing identical in-flight work.
    func loadCGImage(
        for application: ApplicationRecord,
        pointSize: CGFloat,
        scale: CGFloat
    ) async -> CGImage? {
        let request = makeRequest(
            for: application,
            pointSize: pointSize,
            scale: scale
        )
        if let cachedImage = cachedImage(for: request) {
            return cachedImage
        }
        guard !Task.isCancelled else { return nil }

        let load = inFlightLoad(for: request)
        let image = await load.task.value
        finish(load, for: request, image: image)

        guard !Task.isCancelled else { return nil }
        return image
    }

    /// Warms a collection with bounded concurrency. Cancelling the caller stops scheduling new work.
    func warm(
        _ applications: [ApplicationRecord],
        pointSize: CGFloat,
        scale: CGFloat,
        maximumConcurrentLoads: Int = Metrics.defaultMaximumConcurrentLoads
    ) async {
        guard !applications.isEmpty, !Task.isCancelled else { return }

        let workerCount = min(
            max(1, maximumConcurrentLoads),
            applications.count
        )
        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0 ..< workerCount {
                group.addTask { [weak self] in
                    guard let self else { return }
                    var applicationIndex = workerIndex
                    while applicationIndex < applications.count, !Task.isCancelled {
                        _ = await loadCGImage(
                            for: applications[applicationIndex],
                            pointSize: pointSize,
                            scale: scale
                        )
                        applicationIndex += workerCount
                    }
                }
            }
            await group.waitForAll()
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        for load in inFlightLoads.values {
            load.task.cancel()
        }
        inFlightLoads.removeAll(keepingCapacity: true)
    }
}

private extension AppIconCache {
    private func cachedImage(for request: Request) -> CGImage? {
        guard let cached = cache.object(forKey: request.cacheKey),
              cached.requestedPixelSize >= request.pixelSize else { return nil }
        // Reuse the exact higher-resolution source image for smaller requests.
        // Do not compare its actual width against the requested point-derived
        // size: AppKit may return a larger representation than requested, and
        // that comparison could incorrectly reuse a 1x image for a 2x request.
        return cached.image
    }

    private func makeRequest(
        for application: ApplicationRecord,
        pointSize: CGFloat,
        scale: CGFloat
    ) -> Request {
        let proposedPixelSize = pointSize * scale
        let pixelSize = proposedPixelSize.isFinite
            ? max(1, Int(proposedPixelSize.rounded()))
            : 1
        return Request(
            identity: application.id,
            path: application.bundleURL.path,
            pixelSize: pixelSize
        )
    }

    private func inFlightLoad(for request: Request) -> InFlightLoad {
        if let existingLoad = inFlightLoads[request] {
            return existingLoad
        }

        let load = InFlightLoad(
            id: UUID(),
            task: Task.detached(priority: .utility) { [decode] in
                decode(request.path, request.pixelSize)
            }
        )
        inFlightLoads[request] = load
        return load
    }

    private func finish(
        _ load: InFlightLoad,
        for request: Request,
        image: CGImage?
    ) {
        guard inFlightLoads[request]?.id == load.id else { return }
        inFlightLoads[request] = nil
        guard let image else { return }

        // A slower small request must not replace a larger one which completed
        // first. Keep one original representation per app, with no resampling
        // or bit-depth/color conversion, across backing-scale changes.
        if let cached = cache.object(forKey: request.cacheKey),
           cached.requestedPixelSize >= request.pixelSize { return }

        let cost = image.bytesPerRow * image.height
        cache.setObject(
            CachedIcon(requestedPixelSize: request.pixelSize, image: image),
            forKey: request.cacheKey,
            cost: cost
        )
    }
}

private enum AppIconDecoder {
    static func decode(path: String, pixelSize: Int) -> CGImage? {
        guard !Task.isCancelled else { return nil }

        return autoreleasepool {
            guard
                let image = NSWorkspace.shared.icon(forFile: path).copy() as? NSImage,
                !Task.isCancelled
            else {
                return nil
            }

            var proposedRect = CGRect(
                x: 0,
                y: 0,
                width: pixelSize,
                height: pixelSize
            )
            let decodedImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            )
            return Task.isCancelled ? nil : decodedImage
        }
    }
}
