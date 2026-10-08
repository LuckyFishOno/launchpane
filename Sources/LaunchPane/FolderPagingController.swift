import AppCore
import AppKit
import QuartzCore

/// Owns folder page selection, cached surfaces, tracking, and swipe animation lifetimes.
/// The root coordinates pointer ownership and asynchronous icon loading.
@MainActor final class FolderPagingController {
    private(set) var page = 0
    private(set) var selectedIndex = -1
    var scrollGesture = PageScrollGesture()
    var inputGate = PageSwipeInputGate()
    var swipe: InteractiveFolderPageSwipe?
    private(set) var generation = 0
    var surfaces: [Int: FolderPageSurface] = [:]
    // LAUNCHPANE_FOLDER_PAGING_ROOT_MOTION_V14
    // LAUNCHPANE_FOLDER_PAGING_FRAME_PACED_V15
    // Folder paging uses the exact same compositor animator and motion profile
    // as root paging. Only the travel distance changes from the full display
    // width to the open folder panel width.
    let animator = PageTransitionAnimator()
    weak var viewportLayer: CALayer?
    weak var contentLayer: CALayer?
    weak var indicatorLayer: CATextLayer?

    /// A drag page handoff preserves selection unless the caller supplies one.
    func selectPage(_ page: Int, selectedIndex: Int? = nil) {
        self.page = page
        if let selectedIndex { self.selectedIndex = selectedIndex }
    }

    func selectItem(_ index: Int) {
        selectedIndex = index
    }

    func clampPage(pageCount: Int) {
        page = min(page, max(0, pageCount - 1))
    }

    func replaceCurrentSurface(
        layer: CALayer, presentations: [AppTilePresentation], applications: [ApplicationRecord]
    ) {
        contentLayer = layer
        surfaces = [page: FolderPageSurface(
            pageIndex: page, layer: layer, presentations: presentations, applications: applications)]
    }

    func removeAllSurfaces(preserving pointerOwner: AppTileButton?) {
        for surface in surfaces.values {
            for presentation in surface.presentations where presentation.button !== pointerOwner {
                presentation.button.removeFromSuperview()
            }
            surface.layer.removeAllAnimations()
            surface.layer.removeFromSuperlayer()
        }
        surfaces.removeAll(keepingCapacity: true)
    }

    func invalidateSwipe() {
        generation &+= 1
    }

    func resetTransition() {
        guard let contentLayer else { return }
        animator.reset(contentLayer: contentLayer, canvasBounds: viewportLayer?.bounds ?? contentLayer.bounds)
    }

    func releaseLayerReferences() {
        viewportLayer = nil
        contentLayer = nil
        indicatorLayer = nil
    }

    func cancelInteractiveSwipe() {
        guard let swipe else { return }
        invalidateSwipe()
        swipe.outgoingSurface.layer.removeAllAnimations()
        swipe.incomingSurface.layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipe.outgoingSurface.layer.position = swipe.restingPosition
        swipe.incomingSurface.layer.position = CGPoint(
            x: swipe.restingPosition.x + CGFloat(swipe.direction) * swipe.width, y: swipe.restingPosition.y)
        swipe.outgoingSurface.layer.isHidden = false
        swipe.incomingSurface.layer.isHidden = true
        CATransaction.commit()

        self.swipe = nil
    }
}
