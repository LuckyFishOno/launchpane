import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func finishFolderCreationPreviewVisuals(
        _ session: LaunchpadDragSession, animated: Bool, completion: (() -> Void)?
    ) {
        guard let preview = session.folderCreationPreview else {
            completion?()
            return
        }

        updateDropHighlight(.outside)
        refreshDragProxyForRelease(session.proxyLayer, sourceEntry: session.sourceEntry, hidesLabel: true)

        let sourcePresentation = folderPresentation.folderPresentations.first {
            $0.button.application.id == preview.sourceIdentity
        }
        let destination =
            preview.sourceLandingCenter ?? sourcePresentation?.tileLayer.frame.center ?? session.proxyLayer.position
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = LaunchpadVisualStyle.dragCompletionTransition(kind: .insertion)
        // LAUNCHPANE_SPRING_OPEN_RELEASE_HANDOFF_V1
        // Spring-open Folder release is still an ordinary positional landing.
        // Use the exact same insertion/reflow transition as App swaps, rollback,
        // and Folder->root landing instead of the old 0.22s fast path.
        let duration: CFTimeInterval = shouldAnimate ? transition.duration : 0

        // mouseUp has completed the AppKit tracking chain. The transparent root
        // source button can finally retire; the folder child will become the
        // next interactive owner after the proxy lands.
        session.sourceEntry.button.isEnabled = false
        session.sourceEntry.button.isHidden = true

        let finalize: @MainActor () -> Void = { [weak self, weak proxy = session.proxyLayer, weak sourcePresentation] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            proxy?.opacity = 0
            DragVisualCoordinator.retire(proxy)
            sourcePresentation?.tileLayer.opacity = 1
            sourcePresentation?.button.isHidden = false
            sourcePresentation?.button.isEnabled = true
            CATransaction.commit()
            self?.folderHiddenApplicationID = nil
            completion?()
        }

        guard shouldAnimate else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.proxyLayer.position = destination
            session.proxyLayer.setAffineTransform(.identity)
            session.proxyLayer.opacity = 1
            CATransaction.commit()
            finalize()
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(transition.timingFunction)
        session.proxyLayer.position = destination
        session.proxyLayer.setAffineTransform(.identity)
        session.proxyLayer.opacity = 1
        CATransaction.commit()

        dragVisuals.schedule(for: session.proxyLayer, after: duration, completion: finalize)
    }
}
