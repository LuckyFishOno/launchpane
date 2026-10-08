import AppCore
import AppKit
import QuartzCore

@main struct FolderPresentationCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        checkCleanup(check)
        checkPointerOwner(check)
        checkAnimationOwnership(check)
        print("FOLDER PRESENTATION: \(assertions) assertions passed")
    }

    @MainActor private static func checkCleanup(_ check: (Bool, String) -> Void) {
        let owner = FolderPresentation()
        let host = NSView()
        let editor = NSTextField()
        host.addSubview(editor)
        owner.folderTitleEditor = editor
        owner.folderTitleLayer = CATextLayer()
        owner.folderTitleFrame = CGRect(x: 5, y: 5, width: 100, height: 30)
        owner.folderTitleHitFrame = owner.folderTitleFrame
        let content = CALayer()
        owner.folderContentAnimationLayer = content
        owner.folderDimAnimationLayer = CALayer()
        owner.folderAnimationSourceFrame = owner.folderTitleFrame
        owner.folderOverlayLayer.addSublayer(content)
        owner.folderOverlayLayer.add(CABasicAnimation(keyPath: "opacity"), forKey: "test")
        let task = Task { @MainActor in }
        owner.folderIconTask = task
        let generation = owner.folderAnimationGeneration
        owner.invalidateAnimation()
        check(owner.folderAnimationGeneration != generation, "Closing invalidates old animation callbacks")
        owner.cancelIconLoading()
        check(task.isCancelled && owner.folderIconTask == nil, "Closing cancels and releases icon work")
        owner.clearOverlay()
        check(owner.folderOverlayLayer.sublayers?.isEmpty != false, "Cleanup releases attached layers")
        check(owner.folderOverlayLayer.animationKeys()?.isEmpty != false, "Cleanup removes overlay animations")
        check(owner.folderOverlayLayer.isHidden && owner.folderOverlayLayer.opacity == 1, "Overlay is ready for reuse")
        check(owner.folderContentAnimationLayer == nil && owner.folderDimAnimationLayer == nil,
            "Animation layers release")
        check(owner.folderAnimationSourceFrame == nil, "Old source geometry is released")
        check(owner.folderTitleEditor == nil && editor.superview == nil && editor.delegate == nil,
            "Editor detaches safely")
        check(owner.folderTitleLayer == nil && owner.folderTitleFrame == .zero, "Title resources reset")
        check(owner.folderTitleHitFrame == .zero, "Old title hit region is removed")
        owner.clearOverlay()
        check(owner.folderOverlayLayer.isHidden, "Repeated cleanup is safe")
    }

    @MainActor private static func checkPointerOwner(_ check: (Bool, String) -> Void) {
        let owner = FolderPresentation()
        let host = NSView()
        func presentation(_ name: String) -> AppTilePresentation {
            let app = ApplicationRecord(
                displayName: name, bundleIdentifier: "test.folder.\(name)",
                bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"))
            return AppTilePresentation(
                tileLayer: CALayer(), selectionLayer: CALayer(), iconLayer: CALayer(), labelLayer: CATextLayer(),
                button: AppTileButton(application: app))
        }
        let tracked = presentation("Tracked")
        let other = presentation("Other")
        host.addSubview(tracked.button)
        host.addSubview(other.button)
        owner.folderPresentations = [tracked, other]
        owner.removeButtons(preserving: tracked.button)
        check(tracked.button.superview === host, "Visual cleanup preserves the exact drag pointer owner")
        check(other.button.superview == nil, "Unrelated hit targets detach")
        check(owner.folderPresentations.isEmpty, "Retired visual presentations release")
        owner.clearOverlay()
        check(tracked.button.superview === host, "Overlay cleanup cannot steal pointer ownership")
        tracked.button.removeFromSuperview()
    }
    @MainActor private static func checkAnimationOwnership(_ check: (Bool, String) -> Void) {
        let owner = FolderPresentation()
        let layer = CALayer()
        layer.shouldRasterize = true
        owner.folderContentAnimationLayer = layer
        let generation = owner.folderAnimationGeneration
        check(owner.isCurrentAnimation(generation, contentLayer: layer), "Current layer and generation are accepted")
        check(!owner.isCurrentAnimation(generation, contentLayer: CALayer()),
              "Another layer cannot finish this opening")
        owner.invalidateAnimation()
        check(!owner.finishOpening(generation: generation, contentLayer: layer),
              "Stale opening cannot retire new visuals")
        check(layer.shouldRasterize, "Rejected callback leaves raster ownership intact")
        check(owner.finishOpening(generation: owner.folderAnimationGeneration, contentLayer: layer),
              "Current opening retires animation resources")
        check(!layer.shouldRasterize && layer.rasterizationScale == 1, "Resting content releases parent raster cache")
        owner.clearOverlay()
        check(!owner.isCurrentAnimation(owner.folderAnimationGeneration, contentLayer: layer),
              "Released layers reject late animation completion")
    }

}
