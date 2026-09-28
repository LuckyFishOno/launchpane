import AppCore
import AppKit
import LayoutCore
import QuartzCore

@MainActor final class FolderPageSurface {
    let pageIndex: Int
    let layer: CALayer
    let presentations: [AppTilePresentation]
    let applications: [ApplicationRecord]

    init(pageIndex: Int, layer: CALayer, presentations: [AppTilePresentation], applications: [ApplicationRecord]) {
        self.pageIndex = pageIndex
        self.layer = layer
        self.presentations = presentations
        self.applications = applications
    }
}

@MainActor final class InteractiveFolderPageSwipe {
    enum Phase {
        case tracking
        case settling
    }

    var phase: Phase = .tracking
    let outgoingSurface: FolderPageSurface
    let incomingSurface: FolderPageSurface
    let targetPage: Int
    let direction: Int
    let restingPosition: CGPoint
    let width: CGFloat

    var translation: CGFloat = 0
    var velocity: CGFloat = 0
    var lastTimestamp: TimeInterval
    var needsPresentationUpdate = false

    init(
        outgoingSurface: FolderPageSurface, incomingSurface: FolderPageSurface, targetPage: Int, direction: Int,
        restingPosition: CGPoint, width: CGFloat, timestamp: TimeInterval
    ) {
        self.outgoingSurface = outgoingSurface
        self.incomingSurface = incomingSurface
        self.targetPage = targetPage
        self.direction = direction
        self.restingPosition = restingPosition
        self.width = width
        lastTimestamp = timestamp
    }
}

@MainActor final class InteractivePageSwipe {
    enum Phase {
        case tracking
        case settling
    }

    var phase: Phase = .tracking
    let outgoingSurface: LaunchpadPageSurface
    let incomingSurface: LaunchpadPageSurface
    let targetPage: Int
    let direction: Int
    let restingPosition: CGPoint
    let width: CGFloat

    var translation: CGFloat = 0
    var velocity: CGFloat = 0
    var lastTimestamp: TimeInterval
    var needsPresentationUpdate = false

    init(
        outgoingSurface: LaunchpadPageSurface, incomingSurface: LaunchpadPageSurface, targetPage: Int, direction: Int,
        restingPosition: CGPoint, width: CGFloat, timestamp: TimeInterval
    ) {
        self.outgoingSurface = outgoingSurface
        self.incomingSurface = incomingSurface
        self.targetPage = targetPage
        self.direction = direction
        self.restingPosition = restingPosition
        self.width = width
        lastTimestamp = timestamp
    }
}

struct PageSurfaceConfiguration: Equatable {
    let bounds: CGRect
    let scale: CGFloat
    let contentRevision: Int
    let metrics: GridMetrics
}

@MainActor final class LaunchpadPageSurface {
    let pageIndex: Int
    let layer: CALayer
    var entries: [LaunchpadPageEntry] = []

    init(pageIndex: Int, layer: CALayer) {
        self.pageIndex = pageIndex
        self.layer = layer
    }
}

@MainActor enum LaunchpadTilePresentation {
    case application(AppTilePresentation)
    case folder(FolderTilePresentation)

    var tileLayer: CALayer {
        switch self {
        case .application(let presentation): presentation.tileLayer
        case .folder(let presentation): presentation.tileLayer
        }
    }

    var selectionLayer: CALayer {
        switch self {
        case .application(let presentation): presentation.selectionLayer
        case .folder(let presentation): presentation.selectionLayer
        }
    }

    var iconLayer: CALayer {
        switch self {
        case .application(let presentation): presentation.iconLayer
        case .folder(let presentation): presentation.iconLayer
        }
    }

    var labelLayer: CATextLayer {
        switch self {
        case .application(let presentation): presentation.labelLayer
        case .folder(let presentation): presentation.labelLayer
        }
    }

    var button: PointerTrackingTileButton {
        switch self {
        case .application(let presentation): presentation.button
        case .folder(let presentation): presentation.button
        }
    }
}

@MainActor final class LaunchpadPageEntry {
    let item: ResolvedLaunchpadItem
    var absoluteIndex: Int
    var frames: GridItemFrames
    let presentation: LaunchpadTilePresentation

    var tileLayer: CALayer { presentation.tileLayer }
    var selectionLayer: CALayer { presentation.selectionLayer }
    var iconLayer: CALayer { presentation.iconLayer }
    var labelLayer: CATextLayer { presentation.labelLayer }
    var button: PointerTrackingTileButton { presentation.button }

    init(
        item: ResolvedLaunchpadItem, absoluteIndex: Int, frames: GridItemFrames, presentation: LaunchpadTilePresentation
    ) {
        self.item = item
        self.absoluteIndex = absoluteIndex
        self.frames = frames
        self.presentation = presentation
    }
}
