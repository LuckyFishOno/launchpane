import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    struct FolderPageTransitionContext {
        let folder: ResolvedLaunchpadFolder
        let metrics: FolderGridMetrics
        let scale: CGFloat
    }

    func finishFolderPageTransition(
        outgoing outgoingSurface: FolderPageSurface, incoming incomingSurface: FolderPageSurface,
        context: FolderPageTransitionContext, queuedDirection: Int
    ) {
        let folder = context.folder
        let metrics = context.metrics
        let scale = context.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingSurface.layer.isHidden = true
        incomingSurface.layer.isHidden = false
        CATransaction.commit()

        self.attachFolderButtons(to: incomingSurface, hidden: false)
        self.warmFolderIcons(incomingSurface.applications, pointSize: metrics.iconSize, scale: scale)
        self.stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        if queuedDirection != 0 { self.changeFolderPage(by: queuedDirection) }
    }

    func presentFolderPageWithoutMotion(
        _ incomingSurface: FolderPageSurface, folder: ResolvedLaunchpadFolder,
        metrics: FolderGridMetrics, scale: CGFloat
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingSurface.layer.position = metrics.panelFrame.center
        CATransaction.commit()
        attachFolderButtons(to: incomingSurface, hidden: false)
        warmFolderIcons(incomingSurface.applications, pointSize: metrics.iconSize, scale: scale)
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
    }

    func transitionFolderPage(to nextPage: Int, direction: Int, selectedIndex: Int?) {
        guard direction != 0, folderPaging.swipe == nil, let openFolderID,
            let folder = resolvedFolder(id: openFolderID)
        else { return }

        if folderPaging.animator.isAnimating {
            if selectedIndex == nil { _ = folderPaging.animator.queueLatestIfAnimating(direction: direction) }
            return
        }

        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        guard nextPage >= 0, nextPage < metrics.pageCount, nextPage != folderPaging.page,
            let viewportLayer = folderPaging.viewportLayer,
            let outgoingSurface = folderPaging.surfaces[folderPaging.page]
        else { return }

        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        guard
            let incomingSurface = folderPageSurface(folder: folder, metrics: metrics, pageIndex: nextPage, scale: scale)
        else { return }

        folderPresentation.cancelIconLoading()
        detachFolderButtons(from: outgoingSurface)

        folderPaging.selectPage(nextPage, selectedIndex: selectedIndex ?? -1)
        folderPaging.contentLayer = incomingSurface.layer
        folderPresentation.folderPresentations = incomingSurface.presentations
        updateFolderPageIndicator(pageCount: metrics.pageCount)

        if incomingSurface.layer.superlayer == nil { viewportLayer.addSublayer(incomingSurface.layer) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingSurface.layer.isHidden = false
        incomingSurface.layer.isHidden = false
        CATransaction.commit()

        guard
            let style = LaunchpadVisualStyle.pageTransition(
                direction: direction, displayWidth: metrics.panelFrame.width)
        else {
            presentFolderPageWithoutMotion(incomingSurface, folder: folder, metrics: metrics, scale: scale)
            return
        }

        let request = PageTransitionAnimator.Request(
            outgoingLayer: outgoingSurface.layer, incomingLayer: incomingSurface.layer, direction: direction,
            style: style, canvasBounds: metrics.panelFrame)

        let context = FolderPageTransitionContext(folder: folder, metrics: metrics, scale: scale)
        folderPaging.animator.start(request) { [weak self] queuedDirection in
            guard let self else { return }

            self.finishFolderPageTransition(
                outgoing: outgoingSurface, incoming: incomingSurface, context: context,
                queuedDirection: queuedDirection)
        }
    }

    func changeFolderPage(by offset: Int) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let nextPage = min(max(folderPaging.page + offset, 0), max(0, metrics.pageCount - 1))
        guard nextPage != folderPaging.page else { return }

        transitionFolderPage(to: nextPage, direction: nextPage - folderPaging.page, selectedIndex: nil)
    }

    func moveFolderSelection(_ movement: GridNavigationMovement) {
        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let currentSelection = folder.applications.indices.contains(folderPaging.selectedIndex)
            ? folderPaging.selectedIndex : nil
        guard
            let nextIndex = GridSelectionNavigator.nextIndex(
                from: currentSelection, movement: movement,
                context: GridNavigationContext(
                    currentPage: folderPaging.page, itemsPerPage: metrics.itemsPerPage, columns: metrics.columns,
                    itemCount: folder.applications.count, isRightToLeft: metrics.isRightToLeft))
        else { return }

        let previousPage = folderPaging.page
        let nextPage = nextIndex / metrics.itemsPerPage
        if nextPage != previousPage {
            transitionFolderPage(to: nextPage, direction: nextPage - previousPage, selectedIndex: nextIndex)
        } else {
            folderPaging.selectItem(nextIndex)
            updateFolderSelectionAppearance(itemsPerPage: metrics.itemsPerPage)
        }
    }

    func updateFolderSelectionAppearance(itemsPerPage: Int) {
        let pageStartIndex = folderPaging.page * itemsPerPage
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (localIndex, presentation) in folderPresentation.folderPresentations.enumerated() {
            presentation.selectionLayer.opacity = pageStartIndex + localIndex == folderPaging.selectedIndex ? 1 : 0
        }
        CATransaction.commit()
    }

    func activateSelectedFolderItem() {
        guard !folderPaging.animator.isAnimating, folderPaging.swipe == nil, let openFolderID,
            let folder = resolvedFolder(id: openFolderID),
            folder.applications.indices.contains(folderPaging.selectedIndex)
        else { return }
        launch(folder.applications[folderPaging.selectedIndex])
    }
}
