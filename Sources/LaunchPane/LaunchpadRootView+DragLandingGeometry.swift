import AppCore
import AppKit
import LayoutCore
import QuartzCore

extension LaunchpadRootView {
    struct DragLanding {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        var revealLayer: CALayer?
        var revealSurface: LaunchpadPageSurface?
    }

    struct DragLandingAnimation {
        let kind: LaunchpadVisualStyle.DragCompletionKind
        let transition: LaunchpadVisualStyle.DragCompletionTransition
        let duration: CFTimeInterval
        let visualDuration: CFTimeInterval
    }

    func mergedFolderEntry(in surface: LaunchpadPageSurface?, for target: LauncherDropTarget)
        -> LaunchpadPageEntry? {
        guard let surface else { return nil }
        switch target {
        case .folder(let folderID): return surface.entries.first { $0.item.id == .folder(folderID) }
        case .application(let targetIdentity):
            return surface.entries.first { entry in
                guard case .folder(let folder) = entry.item else { return false }
                return folder.applications.contains { $0.id == targetIdentity }
            }
        case .insertion, .pageInsertion, .outside: return nil
        }
    }

    func mergeLandingScale(session: LaunchpadDragSession) -> CGFloat {
        guard case .application(let sourceIdentity) = session.sourceEntry.item.id else {
            let sourceIconSize = min(session.sourceEntry.frames.icon.width, session.sourceEntry.frames.icon.height)
            return AppTilePresentationFactory.folderMiniatureIconScale(forRootIconSize: sourceIconSize)
        }

        let finalFolder: LauncherFolder?

        switch session.target {
        case .folder(let folderID):
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item, folder.id == folderID else { return nil }
                    return folder
                }.first

        case .application(let targetIdentity):
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item else { return nil }
                    let identities = folder.applications.map(\.identity)
                    guard identities.contains(sourceIdentity), identities.contains(targetIdentity) else { return nil }
                    return folder
                }.first

        case .insertion, .pageInsertion, .outside: finalFolder = nil
        }

        guard let finalFolder, finalFolder.applications.count > AppTilePresentationFactory.folderMaximumVisibleChildren
        else {
            let sourceIconSize = min(session.sourceEntry.frames.icon.width, session.sourceEntry.frames.icon.height)
            return AppTilePresentationFactory.folderMiniatureIconScale(forRootIconSize: sourceIconSize)
        }

        return FolderMergeVisualMetrics.fullFolderAbsorbScale
    }

    func mergeLandingDestination(in surface: LaunchpadPageSurface?, session: LaunchpadDragSession)
        -> CGPoint? {
        guard let surface, case .application(let sourceIdentity) = session.sourceEntry.item.id else { return nil }

        let visualEntry: LaunchpadPageEntry?
        let finalFolder: LauncherFolder?

        switch session.target {
        case .folder(let folderID):
            visualEntry = surface.entries.first { $0.item.id == .folder(folderID) }
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item, folder.id == folderID else { return nil }
                    return folder
                }.first

        case .application(let targetIdentity):
            // A same-page committed preview already contains the new folder.
            // Cross-page / conservative paths may still be rendering the target
            // application, so accept either visual owner for the same location.
            visualEntry =
                mergedFolderEntry(in: surface, for: session.target)
                ?? surface.entries.first { $0.item.id == .application(targetIdentity) }
            finalFolder =
                session.draft.document.items.compactMap { (item: LauncherLayoutItem) -> LauncherFolder? in
                    guard case .folder(let folder) = item else { return nil }
                    let ids = folder.applications.map(\.identity)
                    guard ids.contains(sourceIdentity), ids.contains(targetIdentity) else { return nil }
                    return folder
                }.first

        case .insertion, .pageInsertion, .outside: return nil
        }

        guard let visualEntry else { return nil }

        let landingScale = mergeLandingScale(session: session)
        let landingIconFrame = session.mergeLandingTargetIconFrame ?? visibleIconFrame(for: visualEntry)
        let targetCenter: CGPoint

        if let finalFolder,
            let sourceIndex = finalFolder.applications.firstIndex(where: { $0.identity == sourceIdentity }),
            let childCenter = AppTilePresentationFactory.folderChildCenter(
                iconFrame: landingIconFrame, logicalIndex: sourceIndex, layoutDirection: userInterfaceLayoutDirection) {
            targetCenter = childCenter
        } else {
            // Closed folders expose only nine miniature slots. Once all nine
            // are occupied, land at the *folder icon* center, not the cell
            // center (which is lower because the cell also contains the label).
            targetCenter = landingIconFrame.center
        }

        // The drag proxy is cell-sized, while the visible app icon sits above
        // the cell center. Compensate that offset after scaling so the visible
        // icon itself — not the proxy's transparent cell — lands exactly on
        // the miniature-slot / folder center.
        let sourceIconOffset = CGPoint(
            x: session.sourceEntry.frames.icon.midX - session.sourceEntry.frames.cell.midX,
            y: session.sourceEntry.frames.icon.midY - session.sourceEntry.frames.cell.midY)

        return CGPoint(
            x: targetCenter.x - sourceIconOffset.x * landingScale, y: targetCenter.y - sourceIconOffset.y * landingScale
        )
    }

    func prepareDragLanding(_ session: LaunchpadDragSession, committed: Bool, shouldAnimate: Bool)
        -> DragLanding {
        let proxy = session.proxyLayer
        let previewSurface = session.previewSurface
        let originalSurface = session.originalSurface
        let sourceID = session.sourceEntry.item.id
        let originalSourceLayer = session.sourceEntry.tileLayer

        let destination: CGPoint
        let destinationScale: CGFloat
        let destinationOpacity: Float

        var revealLayer: CALayer?
        var revealSurface: LaunchpadPageSurface?

        if committed {
            switch session.target {
            case .insertion, .pageInsertion:
                let previewSource = previewSurface?.entries.first { $0.item.id == sourceID }

                destination = previewSource?.frames.cell.center ?? session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1

                revealLayer = previewSource?.tileLayer

                revealSurface = previewSurface

            case .application, .folder:
                destination = mergeLandingDestination(in: previewSurface, session: session) ?? proxy.position

                destinationScale = mergeLandingScale(session: session)
                destinationOpacity = 0

            case .outside:
                destination = session.sourceEntry.frames.cell.center

                destinationScale = 1
                destinationOpacity = 1
            }

            promoteDragPreviewSurface(session)
        } else {
            destination = session.sourceEntry.frames.cell.center

            destinationScale = 1
            destinationOpacity = 1

            revealLayer = originalSourceLayer

            revealSurface = originalSurface

            if shouldAnimate, previewSurface != nil {
                // Keep the reordered preview visible while every displaced tile
                // travels back. Revealing the original surface here used to show
                // both layouts during the rollback and created a fading ghost.
                originalSurface.layer.opacity = 0
            } else {
                previewSurface?.layer.removeFromSuperlayer()

                originalSurface.layer.opacity = 1
            }

            activeSurface = originalSurface

            pageContentLayer = originalSurface.layer
        }

        return DragLanding(
            position: destination, scale: destinationScale, opacity: destinationOpacity, revealLayer: revealLayer,
            revealSurface: revealSurface)
    }

    func dragLandingAnimation(_ session: LaunchpadDragSession, committed: Bool, shouldAnimate: Bool)
        -> DragLandingAnimation {
        let previewSurface = session.previewSurface
        let completionKind: LaunchpadVisualStyle.DragCompletionKind

        if !committed {
            completionKind = .rollback
        } else {
            switch session.target {
            case .insertion, .pageInsertion, .outside: completionKind = .insertion
            case .application, .folder: completionKind = .merge
            }
        }

        let completionTransition = LaunchpadVisualStyle.dragCompletionTransition(kind: completionKind)

        let duration: CFTimeInterval = shouldAnimate ? completionTransition.duration : 0

        let visualCompletionDuration: CFTimeInterval = {
            guard shouldAnimate, committed, previewSurface != nil else { return duration }

            switch session.target {
            case .application, .folder:
                // The source proxy can finish its short merge landing first, but
                // keep the preview alive until surrounding apps complete the same
                // reflow used by ordinary App exchanges.
                return duration + FolderMergeVisualMetrics.postLandingReflowDelay
                    + LaunchpadVisualStyle.dragReflowTransition(movedForward: false).duration
            case .insertion, .pageInsertion, .outside: return duration
            }
        }()

        return DragLandingAnimation(
            kind: completionKind, transition: completionTransition, duration: duration,
            visualDuration: visualCompletionDuration)
    }
}
