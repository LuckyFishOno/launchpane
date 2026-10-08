import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func folderPageItemFrames(localIndex: Int, visibleCount: Int, metrics: FolderGridMetrics)
        -> GridItemFrames? {
        // LAUNCHPANE_FOLDER_PAGE_LOCAL_LAYOUT_V16_COMPILE_REPAIR
        //
        // GridItemFrames belongs to LayoutCore. Its synthesized memberwise
        // initializer is internal to that module, so LaunchPane must not
        // construct it directly. FolderGridMetrics already exposes the public
        // page-local frame calculation we need.
        //
        // visibleCount remains an explicit guard so a sparse later page can
        // never accidentally expose unused slots from the full-folder lattice.
        guard localIndex >= 0, localIndex < visibleCount, localIndex < metrics.itemsPerPage else { return nil }

        return metrics.itemFrames(forItemAt: localIndex)
    }

    struct FolderPageContents {
        let layer: CALayer
        let presentations: [AppTilePresentation]
        let applications: [ApplicationRecord]
    }

    func makeFolderPageLayer(
        folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, pageIndex: Int, scale: CGFloat
    ) -> FolderPageContents {
        let startIndex = pageIndex * metrics.itemsPerPage
        let endIndex = min(startIndex + metrics.itemsPerPage, folder.applications.count)
        let pageLayer = CALayer()
        pageLayer.bounds = metrics.panelFrame
        pageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pageLayer.position = metrics.panelFrame.center
        pageLayer.contentsScale = scale
        guard startIndex < endIndex else {
            return FolderPageContents(layer: pageLayer, presentations: [], applications: [])
        }
        let applications = Array(folder.applications[startIndex..<endIndex])

        var presentations: [AppTilePresentation] = []
        presentations.reserveCapacity(applications.count)

        for (localIndex, application) in applications.enumerated() {
            guard
                let frames = folderPageItemFrames(
                    localIndex: localIndex, visibleCount: applications.count, metrics: metrics)
            else { continue }

            let presentation = AppTilePresentationFactory.make(
                AppTileRenderInput(
                    application: application, cellFrame: frames.cell, iconFrame: frames.icon, labelFrame: frames.label,
                    scale: scale, selected: startIndex + localIndex == folderPaging.selectedIndex,
                    icon: iconCache.bestAvailableCGImage(for: application, pointSize: metrics.iconSize, scale: scale)))

            // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
            // Folder pages use the same per-tile raster strategy as root pages.
            pageLayer.addSublayer(presentation.tileLayer)

            presentation.button.frame = frames.icon
            presentation.button.target = self
            presentation.button.action = #selector(applicationButtonPressed(_:))
            presentation.button.isHidden = true

            let isDraggedSource = folderHiddenApplicationID == application.id
            if isDraggedSource {
                presentation.tileLayer.opacity = 0
                dragSession?.folderCreationPreview?.sourceLandingCenter = frames.cell.center
            }

            presentation.button.onHoverChanged = { [weak iconLayer = presentation.iconLayer, weak self] isHovering in
                self?.animateHover(on: iconLayer, isHovering: isHovering)
            }
            presentation.button.onPointerDown = { [weak self, weak presentation] event in
                guard let self, let presentation else { return }
                self.folderItemPointerDown(
                    folderID: folder.id, absoluteIndex: startIndex + localIndex,
                    frames: frames, presentation: presentation, event: event)
            }
            presentation.button.onPointerDragged = { [weak self] update in self?.folderItemPointerDragged(update) }
            presentation.button.onPointerUp = { [weak self] release in self?.folderItemPointerUp(release) }
            presentation.button.onPointerCancelled = { [weak self] in self?.folderItemPointerCancelled() }

            // Staged pages own no NSView hit targets until they become current.
            presentations.append(presentation)
        }

        return FolderPageContents(layer: pageLayer, presentations: presentations,
                applications: applications)
    }

    func updateFolderPageIndicator(pageCount: Int) {
        guard let dots = folderPaging.indicatorLayer else { return }
        dots.string = (0..<pageCount).map { $0 == folderPaging.page ? "●" : "○" }.joined(separator: "  ")
    }

    func folderPageSurface(
        folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, pageIndex: Int, scale: CGFloat
    ) -> FolderPageSurface? {
        if let cached = folderPaging.surfaces[pageIndex] { return cached }

        guard (0..<metrics.pageCount).contains(pageIndex) else { return nil }
        let built = makeFolderPageLayer(folder: folder, metrics: metrics, pageIndex: pageIndex, scale: scale)
        let surface = FolderPageSurface(
            pageIndex: pageIndex, layer: built.layer, presentations: built.presentations,
            applications: built.applications)
        folderPaging.surfaces[pageIndex] = surface
        return surface
    }

    func attachFolderButtons(to surface: FolderPageSurface, hidden: Bool) {
        for presentation in surface.presentations {
            if presentation.button.superview == nil { addSubview(presentation.button) }
            let isDraggedSource = folderHiddenApplicationID == presentation.button.application.id
            presentation.button.isHidden = hidden || isDraggedSource
        }
    }

    func detachFolderButtons(from surface: FolderPageSurface) {
        for presentation in surface.presentations {
            // LAUNCHPANE_FOLDER_EXTRACTION_POINTER_OWNERSHIP_V17
            //
            // Folder close/page-cache cleanup may discard the presentation that
            // originally owned mouseDown. Keep that one transparent NSButton in
            // the view hierarchy until real mouseUp/cancel. Removing it here
            // synchronously triggers PointerTrackingTileButton.viewWillMove()
            // and corrupts the in-flight Folder -> root ownership handoff.
            if presentation.button === dragInteraction.preservedButton { continue }
            presentation.button.removeFromSuperview()
        }
    }

    func enableFolderTileRasterCaches(_ presentations: [AppTilePresentation], scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        for presentation in presentations {
            presentation.tileLayer.shouldRasterize = true
            presentation.tileLayer.rasterizationScale = scale
        }
    }

    func stageAdjacentFolderPageSurfaces(
        folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, scale: CGFloat
    ) {
        guard folderPaging.swipe == nil, !folderPaging.animator.isAnimating,
            let viewportLayer = folderPaging.viewportLayer
        else { return }

        let lower = max(0, folderPaging.page - 1)
        let upper = min(max(0, metrics.pageCount - 1), folderPaging.page + 1)
        let keep = Set(lower...upper)
        let width = max(1, metrics.panelFrame.width)
        let resting = metrics.panelFrame.center

        let stalePageIndices = folderPaging.surfaces.keys.filter { !keep.contains($0) }
        for pageIndex in stalePageIndices {
            guard let surface = folderPaging.surfaces.removeValue(forKey: pageIndex) else { continue }
            detachFolderButtons(from: surface)
            surface.layer.removeAllAnimations()
            surface.layer.removeFromSuperlayer()
        }

        for pageIndex in keep.sorted() {
            guard let surface = folderPageSurface(folder: folder, metrics: metrics, pageIndex: pageIndex, scale: scale)
            else { continue }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.layer.removeAllAnimations()
            surface.layer.position = CGPoint(
                x: resting.x + CGFloat(pageIndex - folderPaging.page) * width, y: resting.y)
            surface.layer.opacity = 1

            // LAUNCHPANE_FOLDER_PAGE_LOCAL_LAYOUT_V16
            // Adjacent pages are prebuilt for smooth paging, but they do not
            // need to be visible while resting. Hide them until a transition
            // actually starts so a sparse current page cannot expose content
            // from an off-page surface.
            surface.layer.isHidden = pageIndex != folderPaging.page
            surface.layer.contentsScale = scale
            if surface.layer.superlayer == nil { viewportLayer.addSublayer(surface.layer) }
            CATransaction.commit()

            if pageIndex != folderPaging.page { detachFolderButtons(from: surface) }
        }
    }
}
