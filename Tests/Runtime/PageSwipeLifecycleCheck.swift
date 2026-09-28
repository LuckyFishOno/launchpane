// Exercises the production swipe lifecycle without opening a window or discovering apps.
import AppKit
import DisplayCore
import QuartzCore

@main struct PageSwipeLifecycleCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        for width: CGFloat in [1024, 1710, 2560] {
            for direction in [-1, 1] {
                let frame = CGRect(x: 0, y: 0, width: width, height: 900)
                let display = DisplayContext(
                    displayID: 0, frame: frame, visibleFrame: frame, backingScaleFactor: 2)
                let root = LaunchpadRootView(frame: frame, displayContext: display)
                let outgoing = LaunchpadPageSurface(pageIndex: 1, layer: CALayer())
                let incoming = LaunchpadPageSurface(pageIndex: 1 + direction, layer: CALayer())
                let resting = CGPoint(x: frame.midX, y: frame.midY)
                root.activeSurface = outgoing
                root.pageContentLayer = outgoing.layer
                root.currentPage = 1
                root.pageSurfaces = [1: outgoing, 1 + direction: incoming]
                let swipe = InteractivePageSwipe(
                    outgoingSurface: outgoing, incomingSurface: incoming, targetPage: 1 + direction,
                    direction: direction, restingPosition: resting, width: width, timestamp: 1)
                root.interactivePageSwipe = swipe
                swipe.translation = -CGFloat(direction) * width * 0.3
                swipe.needsPresentationUpdate = true
                root.presentInteractivePageSwipe(swipe)
                check(!swipe.needsPresentationUpdate, "A refresh consumes the pending sample")
                check(outgoing.layer.position.x == resting.x + swipe.translation, "Outgoing follows the finger")
                check(
                    abs(incoming.layer.position.x - outgoing.layer.position.x) == width,
                    "Both pages retain exactly one display width of separation")
                let generation = root.interactivePageGeneration
                root.cancelInteractivePageSwipeImmediately()
                check(root.interactivePageGeneration == generation + 1, "Cancellation invalidates completion callbacks")
                check(root.interactivePageSwipe == nil, "Cancellation releases the gesture")
                check(root.activeSurface === outgoing && root.currentPage == 1, "Cancellation keeps the original page")
                check(outgoing.layer.position == resting, "Cancellation restores original geometry")

                // At the destination there is no remaining motion. Exercise real completion
                // synchronously, independent of display refresh rate or Reduce Motion.
                root.interactivePageSwipe = swipe
                swipe.translation = -CGFloat(direction) * width
                swipe.needsPresentationUpdate = true
                root.finishInteractivePageSwipe(commit: true)
                check(root.interactivePageSwipe == nil, "A completed swipe releases the gesture")
                check(root.activeSurface === incoming, "Completion adopts the incoming surface")
                check(root.pageContentLayer === incoming.layer, "Content ownership follows the committed page")
                check(root.currentPage == 1 + direction, "Completion selects the destination page")
                check(incoming.layer.position == resting, "The committed page is centered")
            }
        }
        print("PAGE SWIPE LIFECYCLE: \(assertions) assertions passed")
    }
}
