import AppKit
import QuartzCore

@main struct FolderPagingCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        checkSelection(check)
        checkCancellation(check)
        print("FOLDER PAGING: \(assertions) assertions passed")
    }

    @MainActor private static func checkSelection(_ check: (Bool, String) -> Void) {
        let paging = FolderPagingController()
        paging.selectPage(2, selectedIndex: 17)
        paging.selectPage(3)
        check(paging.page == 3 && paging.selectedIndex == 17, "Drag page handoff preserves selection")
        paging.selectPage(1, selectedIndex: -1)
        check(paging.page == 1 && paging.selectedIndex == -1, "Explicit page navigation clears selection")
        paging.selectItem(8)
        check(paging.selectedIndex == 8 && paging.page == 1, "Keyboard selection does not silently change page")
        paging.clampPage(pageCount: 0)
        check(paging.page == 0, "Empty folders clamp to page zero")
        let container = CALayer()
        let layer = CALayer()
        container.addSublayer(layer)
        paging.viewportLayer = container
        let indicator = CATextLayer()
        container.addSublayer(indicator)
        paging.indicatorLayer = indicator
        paging.replaceCurrentSurface(layer: layer, presentations: [], applications: [])
        check(paging.surfaces.count == 1 && paging.contentLayer === layer, "Reorder replaces the current page cache")
        paging.resetTransition()
        paging.removeAllSurfaces(preserving: nil)
        check(paging.surfaces.isEmpty && layer.superlayer == nil, "Retired page layers leave the render tree")
        paging.releaseLayerReferences()
        check(paging.contentLayer == nil && paging.viewportLayer == nil, "Cleanup releases page layer references")
        check(paging.indicatorLayer == nil, "Cleanup releases the page indicator")
    }

    @MainActor private static func checkCancellation(_ check: (Bool, String) -> Void) {
        for width: CGFloat in [480, 900, 1400] {
            for direction in [-1, 1] {
                let paging = FolderPagingController()
                paging.selectPage(1, selectedIndex: 5)
                let outgoing = FolderPageSurface(pageIndex: 1, layer: CALayer(), presentations: [], applications: [])
                let incoming = FolderPageSurface(
                    pageIndex: 1 + direction, layer: CALayer(), presentations: [], applications: [])
                let resting = CGPoint(x: 700, y: 450)
                paging.swipe = InteractiveFolderPageSwipe(
                    outgoingSurface: outgoing, incomingSurface: incoming, targetPage: 1 + direction,
                    direction: direction, restingPosition: resting, width: width, timestamp: 1)
                outgoing.layer.position = CGPoint(x: resting.x + 20, y: resting.y)
                incoming.layer.add(CABasicAnimation(keyPath: "position"), forKey: "settle")
                let generation = paging.generation
                paging.cancelInteractiveSwipe()
                check(
                    paging.generation == generation + 1 && paging.swipe == nil, "Cancel invalidates delayed completion")
                check(paging.page == 1 && paging.selectedIndex == 5, "Cancel preserves page and selection")
                check(outgoing.layer.position == resting && !outgoing.layer.isHidden, "Original page returns to rest")
                check(
                    incoming.layer.position.x == resting.x + CGFloat(direction) * width && incoming.layer.isHidden,
                    "Incoming page parks beyond the panel edge")
                check(incoming.layer.animationKeys()?.isEmpty != false, "Cancel removes settling animations")
                paging.cancelInteractiveSwipe()
                check(paging.generation == generation + 1, "Repeated cancellation is a no-op")
            }
        }
    }
}
