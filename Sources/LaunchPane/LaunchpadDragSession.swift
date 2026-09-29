import AppCore
import AppKit
import LayoutCore
import QuartzCore

enum DragSourceOrigin {
    case root
    case folder(UUID)

    var folderID: UUID? {
        guard case .folder(let folderID) = self else { return nil }
        return folderID
    }
}

@MainActor struct PendingFolderTilePress {
    let folderID: UUID
    let entry: LaunchpadPageEntry
    let point: CGPoint
}

@MainActor final class FolderItemDragSession {
    let folderID: UUID
    let sourceEntry: LaunchpadPageEntry
    let proxyLayer: CALayer
    let pointerOffset: CGVector
    let trackingButton: AppTileButton
    let sourceAbsoluteIndex: Int
    var destinationAbsoluteIndex: Int

    // LAUNCHPANE_FOLDER_DRAG_ROOT_PARITY_V19
    // Keep one immutable Folder-order snapshot exactly like the root drag's
    // projectionBaselineDocument. Every page turn/reflow is projected from
    // this baseline, never from an already-mutated preview.
    let baselineApplications: [ApplicationRecord]
    let sourcePage: Int
    var hasCrossedPages = false

    // LAUNCHPANE_FOLDER_DRAG_EDGE_PAGING_V18
    // Keep edge-paging state on the gesture owner so cancellation, mouseUp,
    // Folder->Root promotion, and repeated multi-page turns all invalidate
    // the same asynchronous dwell/waiter deterministically.
    var lastPointerPoint = CGPoint.zero
    var lastProxyCenter = CGPoint.zero
    var edgePagingTask: Task<Void, Never>?
    var edgePagingDirection: Int?
    var edgePagingGeneration = 0
    var isEdgePageTurnInFlight = false
    var pendingReleasePoint: CGPoint?

    // LAUNCHPANE_FOLDER_DRAG_OWNERSHIP_V2
    // Folder-local dragging follows the same ownership rule as root drag:
    // once the proxy exists, the source tile is detached rather than made
    // transparent. Keep its exact parent/index for an atomic local rollback.
    let sourceTileParent: CALayer
    let sourceTileIndex: Int

    init(
        folderID: UUID, sourceEntry: LaunchpadPageEntry, proxyLayer: CALayer, pointerOffset: CGVector,
        trackingButton: AppTileButton, sourceAbsoluteIndex: Int, baselineApplications: [ApplicationRecord],
        sourcePage: Int, sourceTileParent: CALayer, sourceTileIndex: Int
    ) {
        self.folderID = folderID
        self.sourceEntry = sourceEntry
        self.proxyLayer = proxyLayer
        self.pointerOffset = pointerOffset
        self.trackingButton = trackingButton
        self.sourceAbsoluteIndex = sourceAbsoluteIndex
        destinationAbsoluteIndex = sourceAbsoluteIndex
        self.baselineApplications = baselineApplications
        self.sourcePage = sourcePage
        self.sourceTileParent = sourceTileParent
        self.sourceTileIndex = sourceTileIndex
    }
}

@MainActor struct PendingTilePress {
    let entry: LaunchpadPageEntry
    let point: CGPoint
}

struct DragPageLocation: Equatable {
    let page: Int
    let index: Int
}

@MainActor final class FolderCreationPreview {
    let folderID: UUID
    let target: LauncherDropTarget
    let sourceIdentity: ApplicationIdentity
    var sourceLandingCenter: CGPoint?

    init(folderID: UUID, target: LauncherDropTarget, sourceIdentity: ApplicationIdentity) {
        self.folderID = folderID
        self.target = target
        self.sourceIdentity = sourceIdentity
    }
}

@MainActor final class LaunchpadDragSession {
    let sourceEntry: LaunchpadPageEntry

    var draft: LauncherLayoutDraft

    let proxyLayer: CALayer
    let pointerOffset: CGVector
    let originalSurface: LaunchpadPageSurface
    let sourcePage: Int
    let sourceOrigin: DragSourceOrigin
    let projectionBaselineDocument: LauncherLayoutDocument

    var previousIntentIconFrame: CGRect?
    var lastPointerPoint: CGPoint = .zero

    var edgePagingDirection: Int?

    var hasReleased = false
    var hasCrossedPages = false
    var edgeGeneration = 0
    var edgeIncomingSurface: LaunchpadPageSurface?
    var edgeOutgoingSurface: LaunchpadPageSurface?
    var previewLocation: DragPageLocation?
    var projectedDocument: LauncherLayoutDocument?

    var edgePagingTask: Task<Void, Never>?

    var isEdgePageTransitionActive = false

    var pendingCompletionPoint: CGPoint?

    // Immutable geometry captured before dragging begins.
    //
    // In-place preview changes entry.frames / position,
    // therefore cancellation must restore from this snapshot.
    let originalFramesByIdentifier: [LauncherLayoutItemIdentifier: GridItemFrames]

    let originalIndexByIdentifier: [LauncherLayoutItemIdentifier: Int]

    // Normal same-page reorder path.
    //
    // true means:
    //
    // originalSurface itself is the preview.
    //
    // No second page CALayer tree exists.
    var usesInPlacePreview = false

    // Snapshot of the target folder/app icon at mouse-up. Merge landing uses
    // this frozen geometry while the final page surface waits to reflow.
    var mergeLandingTargetIconFrame: CGRect?

    var previewSurface: LaunchpadPageSurface?
    var previewState: LauncherDragPreviewState

    var previewDestinationIdentifier: LauncherLayoutItemIdentifier { previewState.destination }

    // LAUNCHPANE_REORDER_RESPONSE_080_V4
    // The spatial gate prevents accidental swaps; keep the temporal confirmation
    // short so a deliberate crossing feels immediate.
    var intentState = LauncherDragIntentState(mergeDwell: 0.15, reorderDwell: 0.16)
    var intentTask: Task<Void, Never>?
    var folderSpringOpenTask: Task<Void, Never>?
    var folderCreationPreview: FolderCreationPreview?
    var isSourceLabelHiddenForMerge = false

    var target: LauncherDropTarget = .outside

    init(
        sourceEntry: LaunchpadPageEntry, draft: LauncherLayoutDraft, proxyLayer: CALayer, pointerOffset: CGVector,
        originalSurface: LaunchpadPageSurface, sourcePage: Int, sourceOrigin: DragSourceOrigin = .root,
        projectionBaselineDocument: LauncherLayoutDocument? = nil
    ) {
        self.sourceEntry = sourceEntry
        self.draft = draft
        self.proxyLayer = proxyLayer
        self.pointerOffset = pointerOffset
        self.originalSurface = originalSurface

        self.sourcePage = sourcePage

        self.sourceOrigin = sourceOrigin
        self.projectionBaselineDocument = projectionBaselineDocument ?? draft.snapshot

        lastPointerPoint = sourceEntry.frames.cell.center

        originalFramesByIdentifier = Dictionary(
            uniqueKeysWithValues: originalSurface.entries.map { ($0.item.id, $0.frames) })

        originalIndexByIdentifier = Dictionary(
            uniqueKeysWithValues: originalSurface.entries.map { ($0.item.id, $0.absoluteIndex) })
        previewState = LauncherDragPreviewState(source: sourceEntry.item.id)
    }
}

@MainActor final class LaunchpadDragCommitContext {
    let session: LaunchpadDragSession

    var completionState = LauncherDragCommitState()

    // True only after the persisted document has been compared page-by-page
    // with the existing layer surfaces and the live drag preview was proven to
    // be an exact match. This covers both insertion and same-page folder merges.
    var didAdoptCommittedPreview = false

    init(session: LaunchpadDragSession) { self.session = session }
}
