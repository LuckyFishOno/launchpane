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

    // OPENLAUNCHPAD_FIRST_PAGE_PINNED_ICON_CACHE_V2
    // Only first-page standalone applications live here while the launcher is
    // hidden. Folder children and every other page stay in the transient cache.
    private var pinnedFirstPageIcons: [NSString: CachedIcon] = [:]

    // OPENLAUNCHPAD_FIRST_PAGE_FOLDER_MINIATURE_CACHE_V3
    // Closed folders only expose a 3x3 preview. Keep those tiny first-page
    // bitmaps separately so idle memory remains bounded even with many folders.
    private var pinnedFirstPageFolderMiniatures: [NSString: CachedIcon] = [:]

    private var inFlightLoads: [Request: InFlightLoad] = [:]
    private let decode: @Sendable (String, Int) -> CGImage?

    // OPENLAUNCHPAD_EXACT_TRANSIENT_ICON_BITMAPS_V6
    // Keep the transient visible-session cache at the exact backing-pixel size.
    // NSWorkspace may otherwise hand back 512/1024px representations for a
    // ~216px request, wasting cache budget and evicting folder icons too early.
    init(decode: @escaping @Sendable (String, Int) -> CGImage? = { path, pixelSize in
        AppIconDecoder.decodeExact(path: path, pixelSize: pixelSize)
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

    // OPENLAUNCHPAD_BEST_AVAILABLE_ICON_FALLBACK_V6
    /// Returns the best bitmap already resident even when it is smaller than the
    /// final request. Open-folder rendering uses this only as an immediate visual
    /// fallback; the normal HQ loader replaces it as soon as the exact image lands.
    func bestAvailableCGImage(
        for application: ApplicationRecord,
        pointSize: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let request = makeRequest(
            for: application,
            pointSize: pointSize,
            scale: scale
        )
        if let exact = cachedImage(for: request) {
            return exact
        }

        if let pinned = pinnedFirstPageIcons[request.cacheKey] {
            return pinned.image
        }
        if let miniature = pinnedFirstPageFolderMiniatures[request.cacheKey] {
            return miniature.image
        }
        return cache.object(forKey: request.cacheKey)?.image
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

    /// Makes the pinned set match the current first page before warming it.
    /// Removing stale keys prevents reorder/folder operations from accumulating
    /// old first-page icons across presentations.
    func retainPinnedFirstPageApplications(_ applications: [ApplicationRecord]) {
        let allowedKeys = Set(applications.map(cacheKey(for:)))
        pinnedFirstPageIcons = pinnedFirstPageIcons.filter {
            allowedKeys.contains($0.key)
        }
    }

    /// Warms only the tiny, persistent first-page cache. Unlike the transient
    /// cache, these images are rasterized to the exact requested pixel size so
    /// AppKit cannot leave a 512/1024px representation resident for a 192px use.
    func warmPinnedFirstPage(
        _ applications: [ApplicationRecord],
        pointSize: CGFloat,
        scale: CGFloat,
        maximumConcurrentLoads: Int = 2
    ) async {
        guard !applications.isEmpty, !Task.isCancelled else { return }

        let workerCount = min(max(1, maximumConcurrentLoads), applications.count)
        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0 ..< workerCount {
                group.addTask { [weak self] in
                    guard let self else { return }
                    var applicationIndex = workerIndex
                    while applicationIndex < applications.count, !Task.isCancelled {
                        _ = await loadPinnedFirstPageCGImage(
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

    /// Makes the persistent folder-preview set exactly match the first page.
    /// The caller already limits each folder to its nine visible preview slots.
    func retainPinnedFirstPageFolderMiniatures(_ applications: [ApplicationRecord]) {
        let allowedKeys = Set(applications.map(cacheKey(for:)))
        pinnedFirstPageFolderMiniatures = pinnedFirstPageFolderMiniatures.filter {
            allowedKeys.contains($0.key)
        }
    }

    /// Warms low-cost closed-folder previews at a fixed exact pixel size. A
    /// later visible request automatically upgrades through the transient cache
    /// only when its real backing-pixel requirement exceeds this bitmap.
    func warmPinnedFirstPageFolderMiniatures(
        _ applications: [ApplicationRecord],
        pixelSize: Int = 64,
        maximumConcurrentLoads: Int = 2
    ) async {
        guard pixelSize > 0, !applications.isEmpty, !Task.isCancelled else { return }

        let workerCount = min(max(1, maximumConcurrentLoads), applications.count)
        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0 ..< workerCount {
                group.addTask { [weak self] in
                    guard let self else { return }
                    var applicationIndex = workerIndex
                    while applicationIndex < applications.count, !Task.isCancelled {
                        _ = await loadPinnedFirstPageFolderMiniature(
                            for: applications[applicationIndex],
                            pixelSize: pixelSize
                        )
                        applicationIndex += workerCount
                    }
                }
            }
            await group.waitForAll()
        }
    }

    /// Drops visible-session icons while preserving the small first-page cache.
    func removeTransient() {
        cache.removeAllObjects()
        for load in inFlightLoads.values {
            load.task.cancel()
        }
        inFlightLoads.removeAll(keepingCapacity: true)
    }

    func removeAll() {
        removeTransient()
        pinnedFirstPageIcons.removeAll(keepingCapacity: false)
        pinnedFirstPageFolderMiniatures.removeAll(keepingCapacity: false)
    }
}

private extension AppIconCache {
    private func cachedImage(for request: Request) -> CGImage? {
        // Pinned first-page icons win over the transient cache. A 2x pinned
        // image can therefore satisfy a later 1x external-display request too.
        if let pinned = pinnedFirstPageIcons[request.cacheKey],
           pinned.requestedPixelSize >= request.pixelSize {
            return pinned.image
        }
        if let miniature = pinnedFirstPageFolderMiniatures[request.cacheKey],
           miniature.requestedPixelSize >= request.pixelSize {
            return miniature.image
        }

        guard let cached = cache.object(forKey: request.cacheKey),
              cached.requestedPixelSize >= request.pixelSize else { return nil }
        // Reuse the exact higher-resolution source image for smaller requests.
        // Do not compare its actual width against the requested point-derived
        // size: AppKit may return a larger representation than requested, and
        // that comparison could incorrectly reuse a 1x image for a 2x request.
        return cached.image
    }

    private func cacheKey(for application: ApplicationRecord) -> NSString {
        "\(application.id)|\(application.bundleURL.path)" as NSString
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

    private func loadPinnedFirstPageCGImage(
        for application: ApplicationRecord,
        pointSize: CGFloat,
        scale: CGFloat
    ) async -> CGImage? {
        let request = makeRequest(for: application, pointSize: pointSize, scale: scale)
        if let pinned = pinnedFirstPageIcons[request.cacheKey],
           pinned.requestedPixelSize >= request.pixelSize {
            return pinned.image
        }
        guard !Task.isCancelled else { return nil }

        let decodeTask = Task.detached(priority: .utility) {
            AppIconDecoder.decodeExact(path: request.path, pixelSize: request.pixelSize)
        }
        let image = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        guard !Task.isCancelled, let image else { return nil }

        if let pinned = pinnedFirstPageIcons[request.cacheKey],
           pinned.requestedPixelSize >= request.pixelSize {
            return pinned.image
        }

        pinnedFirstPageIcons[request.cacheKey] = CachedIcon(
            requestedPixelSize: request.pixelSize,
            image: image
        )

        // Never keep the same first-page bitmap in both stores while idle.
        cache.removeObject(forKey: request.cacheKey)
        return image
    }

    private func loadPinnedFirstPageFolderMiniature(
        for application: ApplicationRecord,
        pixelSize: Int
    ) async -> CGImage? {
        let request = Request(
            identity: application.id,
            path: application.bundleURL.path,
            pixelSize: max(1, pixelSize)
        )

        // A full-size first-page pin can satisfy the miniature for free. This
        // also prevents duplicate storage if a layout ever references the same
        // application in both roles.
        if let fullSize = pinnedFirstPageIcons[request.cacheKey],
           fullSize.requestedPixelSize >= request.pixelSize {
            return fullSize.image
        }
        if let miniature = pinnedFirstPageFolderMiniatures[request.cacheKey],
           miniature.requestedPixelSize >= request.pixelSize {
            return miniature.image
        }
        guard !Task.isCancelled else { return nil }

        let decodeTask = Task.detached(priority: .utility) {
            AppIconDecoder.decodeExact(path: request.path, pixelSize: request.pixelSize)
        }
        let image = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        guard !Task.isCancelled, let image else { return nil }

        if let fullSize = pinnedFirstPageIcons[request.cacheKey],
           fullSize.requestedPixelSize >= request.pixelSize {
            return fullSize.image
        }
        if let miniature = pinnedFirstPageFolderMiniatures[request.cacheKey],
           miniature.requestedPixelSize >= request.pixelSize {
            return miniature.image
        }

        pinnedFirstPageFolderMiniatures[request.cacheKey] = CachedIcon(
            requestedPixelSize: request.pixelSize,
            image: image
        )
        cache.removeObject(forKey: request.cacheKey)
        return image
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

    /// Returns a predictable RGBA8 bitmap whose dimensions are exactly what
    /// the launcher will display. This is used only for the small pinned cache.
    static func decodeExact(path: String, pixelSize: Int) -> CGImage? {
        guard pixelSize > 0, !Task.isCancelled else { return nil }
        guard let source = decode(path: path, pixelSize: pixelSize) else { return nil }
        guard !Task.isCancelled else { return nil }

        if source.width == pixelSize, source.height == pixelSize {
            return source
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: pixelSize * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return source
        }

        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        )
        return Task.isCancelled ? nil : context.makeImage()
    }
}
