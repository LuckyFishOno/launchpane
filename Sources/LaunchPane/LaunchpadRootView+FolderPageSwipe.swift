import AppCore
import AppKit
import DisplayCore
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    func presentInteractiveFolderPageSwipe(_ swipe: InteractiveFolderPageSwipe) {
        folderPaging.presentSwipe(swipe)
    }

    func handleInteractiveFolderPageSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return false }

        let disposition = InteractivePageSwipeDecision.disposition(
            hasActiveSwipe: folderPaging.swipe != nil, phase: PageScrollPhase(event.phase),
            hasHorizontalMovement: event.scrollingDeltaX != 0,
            isHorizontalDominant: abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        switch disposition {
        case .useDiscretePaging:
            if folderPaging.swipe != nil { cancelInteractiveFolderPageSwipeImmediately() }
            return false
        case .cancel:
            finishInteractiveFolderPageSwipe(commit: false)
            return true
        case .finish: return finishInteractiveFolderPageSwipeAfterRelease()
        case .beginOrUpdate: return continueInteractiveFolderPageSwipe(event)
        }
    }

    func finishInteractiveFolderPageSwipeAfterRelease() -> Bool {
        guard let swipe = folderPaging.swipe else { return false }
        guard swipe.phase == .tracking else { return true }
        let width = max(1, swipe.width)
        let progress = min(1, max(0, -swipe.translation * CGFloat(swipe.direction) / width))
        let forwardVelocity = -swipe.velocity * CGFloat(swipe.direction)
        let normalizedForwardVelocity = forwardVelocity / width
        let projectedProgress = progress + normalizedForwardVelocity * 0.10
        let commit =
            progress >= 0.025 || (progress >= 0.012 && projectedProgress >= 0.040)
            || (progress >= 0.008 && normalizedForwardVelocity >= 0.25)

        finishInteractiveFolderPageSwipe(commit: commit)
        return true
    }

    func continueInteractiveFolderPageSwipe(_ event: NSEvent) -> Bool {
        guard folderPaging.swipe?.phase != .settling else { return true }
        if !event.momentumPhase.isEmpty { return true }

        if event.phase.contains(.began) { cancelInteractiveFolderPageSwipeImmediately() }

        if folderPaging.swipe == nil {
            let direction = event.scrollingDeltaX < 0 ? 1 : -1
            if beginInteractiveFolderPageSwipe(direction: direction, timestamp: event.timestamp) {
                folderPaging.scrollGesture = PageScrollGesture()
            }
        }

        if let swipe = folderPaging.swipe, event.scrollingDeltaX != 0 {
            updateInteractiveFolderPageSwipe(swipe, deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
        }
        return true
    }

    @discardableResult func beginInteractiveFolderPageSwipe(
        direction: Int, timestamp: TimeInterval) -> Bool {
        guard !folderPaging.animator.isAnimating, folderPaging.swipe == nil, let openFolderID,
            let folder = resolvedFolder(id: openFolderID), let viewportLayer = folderPaging.viewportLayer
        else { return false }

        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let targetPage = folderPaging.page + direction
        guard (0..<metrics.pageCount).contains(targetPage) else { return false }

        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)
        guard let outgoingSurface = folderPaging.surfaces[folderPaging.page],
            let incomingSurface = folderPageSurface(
                folder: folder, metrics: metrics, pageIndex: targetPage, scale: scale)
        else { return false }

        folderPresentation.cancelIconLoading()
        for presentation in outgoingSurface.presentations { presentation.button.isHidden = true }

        let resting = metrics.panelFrame.center
        let width = max(1, metrics.panelFrame.width)

        let swipe = InteractiveFolderPageSwipe(
            outgoingSurface: outgoingSurface, incomingSurface: incomingSurface, targetPage: targetPage,
            direction: direction, restingPosition: resting, width: width, timestamp: timestamp)
        folderPaging.beginSwipe(swipe, in: viewportLayer)
        return true
    }

    func updateInteractiveFolderPageSwipe(
        _ swipe: InteractiveFolderPageSwipe, deltaX: CGFloat, timestamp: TimeInterval
    ) {
        guard swipe.phase == .tracking else { return }
        folderPaging.updateSwipe(swipe, deltaX: deltaX, timestamp: timestamp)
        if let pagingDisplayLink {
            pagingDisplayLink.isPaused = false
        } else {
            presentInteractiveFolderPageSwipe(swipe)
        }
    }

    func finishInteractiveFolderPageSwipe(commit: Bool) {
        guard folderPaging.swipe?.phase == .tracking else { return }
        pagingDisplayLink?.isPaused = true
        folderPaging.settleSwipe(commit: commit) { [weak self] swipe in
            self?.completeInteractiveFolderPageSwipe(swipe, commit: commit)
        }
    }

    func completeInteractiveFolderPageSwipe(_ swipe: InteractiveFolderPageSwipe, commit: Bool) {
        pagingDisplayLink?.isPaused = true
        guard folderPaging.completeSwipe(swipe, commit: commit) else { return }

        if commit {
            detachFolderButtons(from: swipe.outgoingSurface)
            folderPresentation.folderPresentations = swipe.incomingSurface.presentations
            attachFolderButtons(to: swipe.incomingSurface, hidden: false)
        } else {
            attachFolderButtons(to: swipe.outgoingSurface, hidden: false)
        }

        guard let openFolderID, let folder = resolvedFolder(id: openFolderID) else { return }
        let metrics = solver.solveFolder(
            display: displayContext, requested: layoutPreferences, itemCount: folder.applications.count)
        let scale = window?.backingScaleFactor ?? displayContext.backingScaleFactor
        updateFolderPageIndicator(pageCount: metrics.pageCount)
        stageAdjacentFolderPageSurfaces(folder: folder, metrics: metrics, scale: scale)

        if commit { warmFolderIcons(swipe.incomingSurface.applications, pointSize: metrics.iconSize, scale: scale) }
    }

    func cancelInteractiveFolderPageSwipeImmediately() {
        guard let swipe = folderPaging.swipe else { return }
        pagingDisplayLink?.isPaused = true
        folderPaging.cancelInteractiveSwipe()
        attachFolderButtons(to: swipe.outgoingSurface, hidden: false)
    }
}
