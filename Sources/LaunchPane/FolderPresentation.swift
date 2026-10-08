import AppKit
import QuartzCore

/// Owns folder visual resources and opening/closing animation lifetimes.
@MainActor final class FolderPresentation {
    let folderOverlayLayer = CALayer()
    var folderPanelFrame = CGRect.zero
    var folderPresentations: [AppTilePresentation] = []
    var folderIconTask: Task<Void, Never>?
    var folderAnimationSourceFrame: CGRect?
    var folderContentAnimationLayer: CALayer?
    var folderDimAnimationLayer: CALayer?
    private(set) var folderAnimationGeneration = 0
    var folderTitleFrame = CGRect.zero
    var folderTitleHitFrame = CGRect.zero
    var folderTitleLayer: CATextLayer?
    var folderTitleEditor: NSTextField?
    var isEndingFolderTitleEditing = false

    func invalidateAnimation() {
        folderAnimationGeneration &+= 1
    }

    func cancelIconLoading() {
        folderIconTask?.cancel()
        folderIconTask = nil
    }

    func clearOverlay() {
        folderOverlayLayer.removeAllAnimations()
        folderOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        folderOverlayLayer.opacity = 1
        folderOverlayLayer.isHidden = true
        folderContentAnimationLayer = nil
        folderDimAnimationLayer = nil
        folderAnimationSourceFrame = nil
        folderTitleLayer = nil
        folderTitleFrame = .zero
        folderTitleHitFrame = .zero
        if let editor = folderTitleEditor {
            editor.delegate = nil
            editor.removeFromSuperview()
            folderTitleEditor = nil
        }
    }

    func removeButtons(preserving pointerOwner: AppTileButton?) {
        for presentation in folderPresentations where presentation.button !== pointerOwner {
            presentation.button.removeFromSuperview()
        }
        folderPresentations.removeAll(keepingCapacity: true)
    }
}
