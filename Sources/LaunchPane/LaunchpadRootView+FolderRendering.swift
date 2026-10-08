import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func makeFolderOverlayContainer(
        metrics: FolderGridMetrics, scale: CGFloat, folderVisualScale: CGFloat, animated: Bool
    ) -> (CALayer, CALayer) {
        let sourceFrame = folderPresentation.folderAnimationSourceFrame
        let sourcePoint = sourceFrame?.center ?? metrics.panelFrame.center

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Animate/rasterize only the visual folder region, not a transparent
        // full-screen 4K layer. A small safety inset includes the panel shadow.
        // Keeping the layer's bounds origin in screen coordinates means all
        // existing child frames/reorder positions remain valid unchanged.
        let visualPadding = max(48, 52 * folderVisualScale)
        let proposedVisualBounds = metrics.panelFrame.union(metrics.titleFrame).insetBy(
            dx: -visualPadding, dy: -visualPadding)
        let clippedVisualBounds = proposedVisualBounds.intersection(bounds)
        let folderVisualBounds =
            clippedVisualBounds.isNull || clippedVisualBounds.isEmpty ? proposedVisualBounds : clippedVisualBounds
        let normalizedAnchor = CGPoint(
            x: folderVisualBounds.width > 0
                ? (sourcePoint.x - folderVisualBounds.minX) / folderVisualBounds.width : 0.5,
            y: folderVisualBounds.height > 0
                ? (sourcePoint.y - folderVisualBounds.minY) / folderVisualBounds.height : 0.5)

        let dimLayer = CALayer()
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.clear.cgColor
        dimLayer.opacity = 1
        folderPresentation.folderOverlayLayer.addSublayer(dimLayer)
        folderPresentation.folderDimAnimationLayer = dimLayer

        // All folder visuals live in one tightly-bounded container. Scaling this
        // layer around the source tile makes the panel, title and icons expand
        // together while avoiding a full-screen 4K compositing surface.
        let contentLayer = CALayer()
        contentLayer.bounds = folderVisualBounds
        contentLayer.anchorPoint = normalizedAnchor
        contentLayer.position = sourcePoint
        contentLayer.opacity = 1
        contentLayer.contentsScale = scale

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // During open/close animation flatten the complex subtree (up to 35
        // icons, labels and shadows) into one compositor-friendly surface.
        // Disable it as soon as animation ends so the resting folder stays live
        // and the temporary raster cache is released.
        contentLayer.shouldRasterize = animated
        contentLayer.rasterizationScale = max(1, scale)

        folderPresentation.folderOverlayLayer.addSublayer(contentLayer)
        folderPresentation.folderContentAnimationLayer = contentLayer

        return (contentLayer, dimLayer)
    }

    func populateFolderOverlay(contentLayer: CALayer, context: FolderOverlayRenderContext, animated: Bool) {
        let metrics = context.metrics
        let scale = context.scale
        let visibleApplications = context.visibleApplications
        // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14
        // Keep the panel/title fixed while the page contents slide behind a
        // clipped viewport, matching the root Launchpad page composition.
        let pageViewportLayer = CALayer()
        pageViewportLayer.bounds = metrics.panelFrame
        pageViewportLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pageViewportLayer.position = metrics.panelFrame.center
        pageViewportLayer.masksToBounds = true
        pageViewportLayer.contentsScale = scale
        contentLayer.addSublayer(pageViewportLayer)
        folderPaging.viewportLayer = pageViewportLayer

        let pageLayer = CALayer()
        pageLayer.bounds = metrics.panelFrame
        pageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pageLayer.position = metrics.panelFrame.center
        pageLayer.contentsScale = scale
        pageViewportLayer.addSublayer(pageLayer)
        folderPaging.contentLayer = pageLayer

        for (localIndex, application) in visibleApplications.enumerated() {
            guard
                let presentation = makeFolderOverlayTile(
                    application: application, localIndex: localIndex, context: context, animated: animated)
            else { continue }
            pageLayer.addSublayer(presentation.tileLayer)
            addSubview(presentation.button)
            folderPresentation.folderPresentations.append(presentation)
        }

        // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
        // Root paging never builds its incoming page at gesture time; surfaces
        // already exist. Keep the current folder page in the same kind of cache
        // and stage its neighbor after the opening animation.
        folderPaging.surfaces = [
            folderPaging.page: FolderPageSurface(
                pageIndex: folderPaging.page, layer: pageLayer, presentations: folderPresentation.folderPresentations,
                applications: visibleApplications)
        ]

    }

    func makeFolderOverlayTile(
        application: ApplicationRecord, localIndex: Int, context: FolderOverlayRenderContext, animated: Bool
    ) -> AppTilePresentation? {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        let startIndex = context.startIndex
        let visibleApplications = context.visibleApplications
        guard
            let frames = folderPageItemFrames(
                localIndex: localIndex, visibleCount: visibleApplications.count, metrics: metrics)
        else { return nil }
        let presentation = AppTilePresentationFactory.make(
            AppTileRenderInput(
                application: application, cellFrame: frames.cell, iconFrame: frames.icon, labelFrame: frames.label,
                scale: scale, selected: startIndex + localIndex == folderPaging.selectedIndex,
                // LAUNCHPANE_FOLDER_LOW_RES_FALLBACK_V6
                // If the exact HQ bitmap has not landed yet, show the best
                // resident miniature immediately instead of a blank icon.
                icon: iconCache.bestAvailableCGImage(for: application, pointSize: metrics.iconSize, scale: scale)))
        // LAUNCHPANE_FOLDER_CHILD_NO_RASTER_CACHE_V6
        // Folder children are already inside one animated content container
        // and do not participate in root-page swipes. Avoid allocating a
        // second Retina raster surface per child during the open animation.
        presentation.tileLayer.shouldRasterize = false
        presentation.tileLayer.rasterizationScale = 1
        presentation.button.frame = frames.icon
        presentation.button.target = self
        presentation.button.action = #selector(applicationButtonPressed(_:))

        let isDraggedSource = folderHiddenApplicationID == application.id
        if isDraggedSource {
            // The model already contains the provisional child, but the
            // floating drag proxy remains its sole visual owner until drop.
            presentation.tileLayer.opacity = 0
            presentation.button.isHidden = true
            dragSession?.folderCreationPreview?.sourceLandingCenter = frames.cell.center
        } else {
            presentation.button.isHidden = animated
        }

        presentation.button.onHoverChanged = { [weak iconLayer = presentation.iconLayer, weak self] isHovering in
            self?.animateHover(on: iconLayer, isHovering: isHovering)
        }
        presentation.button.onPointerDown = { [weak self, weak presentation] event in
            guard let self, let presentation else { return }
            self.folderItemPointerDown(
                // LAUNCHPANE_FOLDER_COMPILE_REPAIR_V1
                // This callback belongs to the concrete folder snapshot that
                // renderFolderOverlay() already resolved. Do not pass the
                // mutable optional openFolderID (UUID?) to a UUID parameter.
                folderID: folder.id, absoluteIndex: startIndex + localIndex, frames: frames,
                presentation: presentation, event: event)
        }
        presentation.button.onPointerDragged = { [weak self] update in self?.folderItemPointerDragged(update) }
        presentation.button.onPointerUp = { [weak self] release in self?.folderItemPointerUp(release) }
        presentation.button.onPointerCancelled = { [weak self] in self?.folderItemPointerCancelled() }
        return presentation
    }

    func addFolderPageIndicator(
        to contentLayer: CALayer, context: FolderOverlayRenderContext, folderVisualScale: CGFloat
    ) {
        let metrics = context.metrics
        let pageCount = metrics.pageCount
        let scale = context.scale
        if pageCount > 1 {
            let dots = CATextLayer()
            dots.frame = CGRect(
                x: metrics.panelFrame.minX, y: metrics.panelFrame.minY + 7 * folderVisualScale,
                width: metrics.panelFrame.width, height: 18 * folderVisualScale)
            dots.string = (0..<pageCount).map { $0 == folderPaging.page ? "●" : "○" }.joined(separator: "  ")
            dots.alignmentMode = .center
            dots.fontSize = 10 * folderVisualScale
            dots.foregroundColor = NSColor.white.withAlphaComponent(0.64).cgColor
            dots.contentsScale = scale
            contentLayer.addSublayer(dots)
            folderPaging.indicatorLayer = dots
        } else {
            folderPaging.indicatorLayer = nil
        }

    }

    func warmFolderIcons(_ applications: [ApplicationRecord], pointSize: CGFloat, scale: CGFloat) {
        folderPresentation.folderIconTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Warm four icons at a time. Previously the folder waited for every
            // visible child to finish before rebinding even the icons that had
            // already decoded, so one slow bundle could hold the whole page.
            let batchSize = 4
            var batchStart = 0
            while batchStart < applications.count, !Task.isCancelled {
                let batchEnd = min(batchStart + batchSize, applications.count)
                let batch = Array(applications[batchStart..<batchEnd])

                await iconCache.warm(batch, pointSize: pointSize, scale: scale, maximumConcurrentLoads: batchSize)
                guard !Task.isCancelled else { return }

                let loadedIDs = Set(batch.map(\.id))
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for presentation in folderPresentation.folderPresentations
                    where loadedIDs.contains(presentation.button.application.id) {
                    if let image = iconCache.cgImage(
                        for: presentation.button.application, pointSize: pointSize, scale: scale) {
                        presentation.iconLayer.contents = image
                    }
                }
                CATransaction.commit()

                // Give the compositor a chance to present each completed batch
                // before scheduling the next four misses.
                await Task.yield()
                batchStart = batchEnd
            }
        }
    }
}
