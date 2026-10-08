import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func openFolder(_ folderID: UUID, sourceFrame: CGRect? = nil) {
        guard resolvedFolder(id: folderID) != nil else { return }

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Folder interaction owns the foreground. Stop opportunistic root/session
        // icon decoding before the zoom starts so Core Animation does not compete
        // with AppKit image decode/upload work during the 210ms transition.
        cancelIconPrewarming()
        iconPrewarmTasks.cancelPresentation()

        folderPresentation.folderAnimationSourceFrame = sourceFrame ?? folderSourceFrame(for: folderID)
        openFolderID = folderID
        folderPaging.selectPage(0, selectedIndex: -1)
        folderPaging.scrollGesture = PageScrollGesture()
        window?.makeFirstResponder(self)
        searchField.isHidden = true
        setPageHitTargetsEnabled(false)
        setFolderBackgroundVisible(true, animated: true)
        renderFolderOverlay(animated: true)
    }

    func folderSourceFrame(for folderID: UUID) -> CGRect? {
        activeSurface?.entries.first { $0.item.folderID == folderID }?.frames.icon
    }

    func resolvedFolder(id: UUID) -> ResolvedLaunchpadFolder? {
        let document: LauncherLayoutDocument
        if let session = dragSession, session.folderCreationPreview?.folderID == id {
            document = session.draft.document
        } else {
            document = layoutDocument
        }

        return ResolvedLaunchpadItemFactory.makeItems(document: document, applications: applications, query: "").first {
            $0.id == .folder(id)
        }.flatMap {
            guard case .folder(let folder) = $0 else { return nil }
            return folder
        }
    }

    func setFolderBackgroundVisible(_ visible: Bool, animated: Bool) {
        // Open folders own the stage. Hide the root app grid completely;
        // wallpaper remains visible and AppKit hit targets are managed separately.
        let targetOpacity: Float = visible ? 0 : 1
        let indicatorOpacity: Float = visible ? 0 : 1
        let duration: CFTimeInterval = animated ? 0.18 : 0

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        activeSurface?.layer.opacity = targetOpacity
        pageIndicatorLayer.opacity = indicatorOpacity
        CATransaction.commit()
    }

    struct FolderOverlayRenderContext {
        let folder: ResolvedLaunchpadFolder
        let metrics: FolderGridMetrics
        let scale: CGFloat
        let page: Int
        let generation: Int

        var startIndex: Int { page * metrics.itemsPerPage }
        let visibleApplications: [ApplicationRecord]

        init(folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics, scale: CGFloat, page: Int, generation: Int) {
            self.folder = folder
            self.metrics = metrics
            self.scale = scale
            self.page = page
            self.generation = generation
            let start = page * metrics.itemsPerPage
            let end = min(start + metrics.itemsPerPage, folder.applications.count)
            visibleApplications = Array(folder.applications[start..<end])
        }
    }

    func renderFolderOverlay(animated: Bool) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else {
            closeFolder(animated: false)
            return
        }
        folderPresentation.invalidateAnimation()
        resetFolderOverlayRendering()
        let scale = window?.backingScaleFactor ?? 1
        // Resolve one geometry for the whole folder so partial pages retain the same grid.
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        folderPaging.clampPage(pageCount: metrics.pageCount)
        folderPresentation.folderPanelFrame = metrics.panelFrame
        let context = FolderOverlayRenderContext(
            folder: folder, metrics: metrics, scale: scale, page: folderPaging.page,
                generation: folderPresentation.folderAnimationGeneration)
        let visualScale = max(1, metrics.iconSize / max(1, solver.tokens.preferredIconSize))
        let (contentLayer, dimLayer) = makeFolderOverlayContainer(
            metrics: metrics, scale: scale, folderVisualScale: visualScale, animated: animated)
        FolderOverlayPresentationFactory.addPanel(to: contentLayer, metrics: metrics, folderVisualScale: visualScale)
        let title = FolderOverlayPresentationFactory.addTitle(
            to: contentLayer, folder: folder, metrics: metrics, scale: scale, folderVisualScale: visualScale)
        folderPresentation.folderTitleLayer = title.layer
        folderPresentation.folderTitleFrame = metrics.titleFrame
        folderPresentation.folderTitleHitFrame = title.hitFrame
        populateFolderOverlay(contentLayer: contentLayer, context: context, animated: animated)
        addFolderPageIndicator(to: contentLayer, context: context, folderVisualScale: visualScale)
        animateFolderOverlay(context: context, contentLayer: contentLayer, dimLayer: dimLayer, animated: animated)
    }

    func resetFolderOverlayRendering() {
        folderPresentation.folderIconTask?.cancel()
        cancelInteractiveFolderPageSwipeImmediately()
        folderPaging.inputGate = PageSwipeInputGate()
        folderPaging.removeAllSurfaces(preserving: dragInteraction.preservedButton)

        folderPaging.resetTransition()
        folderPaging.releaseLayerReferences()

        removeFolderButtons()
        folderPresentation.folderTitleLayer = nil
        folderPresentation.folderTitleFrame = .zero
        folderPresentation.folderTitleHitFrame = .zero
        folderPresentation.folderOverlayLayer.removeAllAnimations()
        folderPresentation.folderOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        folderPresentation.folderOverlayLayer.opacity = 1
        folderPresentation.folderOverlayLayer.isHidden = false

    }

    func finishFolderOpening(context: FolderOverlayRenderContext, contentLayer: CALayer) {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        let animationGeneration = context.generation
        let visibleApplications = context.visibleApplications
        guard self.openFolderID == folder.id,
            folderPresentation.finishOpening(generation: animationGeneration, contentLayer: contentLayer)
        else { return }
        // Retire the opening presentation before descendant pages ever
        // start moving. This guarantees paging never shares a frame with
        // the just-finished full-folder zoom presentation.
        // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
        // V13 deliberately used one parent raster for the zoom. Once
        // that animation ends, hand caching back to individual tiles
        // exactly like root pages so horizontal motion stays GPU-cheap.
        self.enableFolderTileRasterCaches(folderPresentation.folderPresentations, scale: scale)

        for presentation in folderPresentation.folderPresentations {
            let isDraggedSource = self.folderHiddenApplicationID == presentation.button.application.id
            presentation.button.isHidden = isDraggedSource
        }

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // Resume any missing HQ folder icons only after the zoom reaches
        // its final state. Existing cache/fallback images remain visible
        // during the transition, so frame pacing wins without blanks.
        self.warmFolderIcons(visibleApplications, pointSize: metrics.iconSize, scale: scale)

        // Build the adjacent page after the opening frame has settled.
        // This removes layer/text creation from the first swipe frame.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, animationGeneration == self.folderPresentation.folderAnimationGeneration,
                self.openFolderID == folder.id else {
                return
            }
            self.stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        }
    }

    func closeFolder(animated: Bool = true, preservingTrackedButton: AppTileButton? = nil) {
        guard openFolderID != nil else { return }
        if folderPresentation.folderTitleEditor != nil { finishFolderTitleEditing(commit: true) }
        folderPresentation.invalidateAnimation()
        let sourceFrame = folderPresentation.folderAnimationSourceFrame
        let panelFrame = folderPresentation.folderPanelFrame
        let contentLayer = folderPresentation.folderContentAnimationLayer
        let dimLayer = folderPresentation.folderDimAnimationLayer

        openFolderID = nil
        folderPaging.selectPage(0, selectedIndex: -1)
        folderPresentation.folderPanelFrame = .zero
        folderPresentation.cancelIconLoading()
        cancelInteractiveFolderPageSwipeImmediately()

        // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14
        // If Escape/outside-click closes the folder mid-page-slide, stop the
        // nested page animator before starting the folder collapse animation.
        folderPaging.resetTransition()

        if let preservingTrackedButton { dragInteraction.preserve(preservingTrackedButton) }
        removeFolderButtons(preserving: dragInteraction.preservedButton)
        folderHiddenApplicationID = nil
        searchField.isHidden = false
        setFolderBackgroundVisible(false, animated: animated)
        if dragSession == nil, !isCommittingLayout {
            setPageHitTargetsEnabled(true)
        } else {
            // The original tracking button must live until AppKit delivers the
            // matching mouseUp, but every root target stays disabled during the
            // ownership handoff.
            setPageHitTargetsEnabled(false, preserving: preservingTrackedButton)
        }
        if renderedConfiguration == nil { needsLayout = true }

        guard animated, let contentLayer, let dimLayer,
            let transition = LaunchpadVisualStyle.folderTransition(sourceFrame: sourceFrame, panelFrame: panelFrame)
        else {
            cleanupFolderOverlay()
            resumeRootIconPrewarmingAfterFolder()
            return
        }

        animateFolderClosing(
            contentLayer: contentLayer, dimLayer: dimLayer, transition: transition)
    }

    func resumeRootIconPrewarmingAfterFolder() {
        guard presentationResourcesActive, openFolderID == nil, let metrics = currentMetrics else { return }

        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        scheduleIconPrewarming(metrics: metrics, scale: scale)
        scheduleSessionHighQualityIconWarm(metrics: metrics, scale: scale)
    }

    func cleanupFolderOverlay() {
        folderPaging.resetTransition()
        folderPaging.removeAllSurfaces(preserving: dragInteraction.preservedButton)
        folderPaging.swipe = nil
        folderPaging.inputGate = PageSwipeInputGate()
        folderPaging.releaseLayerReferences()

        folderPresentation.clearOverlay()
    }

    func removeFolderButtons(preserving preservedButton: AppTileButton? = nil) {
        folderPresentation.removeButtons(preserving: preservedButton ?? dragInteraction.preservedButton)
    }

    func animateFolderOverlay(
        context: FolderOverlayRenderContext, contentLayer: CALayer, dimLayer: CALayer, animated: Bool
    ) {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        let visibleApplications = context.visibleApplications
        let sourceFrame = folderPresentation.folderAnimationSourceFrame
        guard animated,
            let transition = LaunchpadVisualStyle.folderTransition(
                sourceFrame: sourceFrame, panelFrame: metrics.panelFrame)
        else {
            contentLayer.shouldRasterize = false
            contentLayer.rasterizationScale = 1

            for presentation in folderPresentation.folderPresentations {
                let isDraggedSource = folderHiddenApplicationID == presentation.button.application.id
                presentation.button.isHidden = isDraggedSource
            }

            // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
            // Once there is no full-folder zoom, switch to the same per-tile
            // raster cache used by root pages before any paging begins.
            enableFolderTileRasterCaches(folderPresentation.folderPresentations, scale: scale)

            // A page change has no opening zoom to protect, so remaining HQ
            // icons may start filling immediately.
            warmFolderIcons(visibleApplications, pointSize: metrics.iconSize, scale: scale)
            stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
            return
        }

        folderPresentation.animateOpening(
            contentLayer: contentLayer, dimLayer: dimLayer, transition: transition, generation: context.generation
        ) { [weak self] in
            self?.finishFolderOpening(context: context, contentLayer: contentLayer)
        }
    }

    func animateFolderClosing(
        contentLayer: CALayer, dimLayer: CALayer, transition: LaunchpadVisualStyle.FolderTransition
    ) {
        folderPresentation.animateClosing(
            contentLayer: contentLayer, dimLayer: dimLayer, transition: transition,
            scale: window?.backingScaleFactor ?? 1
        ) { [weak self] in
            guard let self, openFolderID == nil else { return }
            cleanupFolderOverlay()
            resumeRootIconPrewarmingAfterFolder()
        }
    }
}
