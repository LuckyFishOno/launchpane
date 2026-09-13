import AppCore
import AppKit
import QuartzCore

@MainActor
final class AppTilePresentation {
    let tileLayer: CALayer
    let selectionLayer: CALayer
    let iconLayer: CALayer
    let labelLayer: CATextLayer
    let button: AppTileButton

    init(
        tileLayer: CALayer,
        selectionLayer: CALayer,
        iconLayer: CALayer,
        labelLayer: CATextLayer,
        button: AppTileButton
    ) {
        self.tileLayer = tileLayer
        self.selectionLayer = selectionLayer
        self.iconLayer = iconLayer
        self.labelLayer = labelLayer
        self.button = button
    }
}

@MainActor
final class FolderTilePresentation {
    let tileLayer: CALayer
    let selectionLayer: CALayer
    let iconLayer: CALayer
    let labelLayer: CATextLayer
    let button: FolderTileButton

    init(
        tileLayer: CALayer,
        selectionLayer: CALayer,
        iconLayer: CALayer,
        labelLayer: CATextLayer,
        button: FolderTileButton
    ) {
        self.tileLayer = tileLayer
        self.selectionLayer = selectionLayer
        self.iconLayer = iconLayer
        self.labelLayer = labelLayer
        self.button = button
    }
}

struct AppTileRenderInput {
    let application: ApplicationRecord
    let cellFrame: CGRect
    let iconFrame: CGRect
    let labelFrame: CGRect
    let scale: CGFloat
    let selected: Bool
    let icon: CGImage?
}

struct FolderTileRenderInput {
    let folderID: UUID
    let title: String
    let cellFrame: CGRect
    let iconFrame: CGRect
    let labelFrame: CGRect
    let scale: CGFloat
    let selected: Bool
    let childIcons: [CGImage]
    let layoutDirection: NSUserInterfaceLayoutDirection

    init(
        folderID: UUID,
        title: String,
        cellFrame: CGRect,
        iconFrame: CGRect,
        labelFrame: CGRect,
        scale: CGFloat,
        selected: Bool,
        childIcons: [CGImage],
        layoutDirection: NSUserInterfaceLayoutDirection = .leftToRight
    ) {
        self.folderID = folderID
        self.title = title
        self.cellFrame = cellFrame
        self.iconFrame = iconFrame
        self.labelFrame = labelFrame
        self.scale = scale
        self.selected = selected
        self.childIcons = childIcons
        self.layoutDirection = layoutDirection
    }
}

@MainActor
enum AppTilePresentationFactory {
    private enum FolderMetrics {
        static let gridDimension = 3
        static let maximumVisibleChildren = gridDimension * gridDimension
        // App artwork contains transparent optical padding inside the logical
        // icon frame. The folder surface is drawn procedurally and otherwise
        // fills that entire frame, making it look noticeably larger than apps.
        // Match the visible footprint of modern macOS app icons instead.
        static let surfaceScale: CGFloat = 0.80
        static let contentInsetFraction: CGFloat = 0.17
        static let itemSpacingFraction: CGFloat = 0.055
        static let cornerRadiusFraction: CGFloat = 0.22
        static let borderWidth: CGFloat = 0.75
        static let backgroundOpacity: CGFloat = 0.42
        static let borderOpacity: CGFloat = 0.52
        static let shadowOpacity: Float = 0.16
        static let shadowVerticalOffset: CGFloat = -1
        static let shadowRadius: CGFloat = 4
    }

    private enum LabelMetrics {
        static let fontSize: CGFloat = 14
        static let foregroundOpacity: CGFloat = 0.94
        static let shadowOpacity: Float = 0.62
        static let shadowVerticalOffset: CGFloat = -1
        static let shadowRadius: CGFloat = 2
    }

    private struct FolderChildLayout {
        let origin: CGPoint
        let iconSide: CGFloat
        let spacing: CGFloat
        let scale: CGFloat
        let layoutDirection: NSUserInterfaceLayoutDirection
    }

    static func make(_ input: AppTileRenderInput) -> AppTilePresentation {
        let tileLayer = CALayer()
        tileLayer.frame = input.cellFrame

        let selectionLayer = LaunchpadVisualStyle.makeSelectionLayer(
            cellFrame: input.cellFrame,
            iconFrame: input.iconFrame,
            selected: input.selected
        )
        tileLayer.addSublayer(selectionLayer)

        let iconLayer = makeIconLayer(
            icon: input.icon,
            frame: input.iconFrame,
            cellFrame: input.cellFrame,
            scale: input.scale
        )
        tileLayer.addSublayer(iconLayer)
        let labelLayer = makeLabelLayer(
            input.application.displayName,
            frame: input.labelFrame,
            cellFrame: input.cellFrame,
            scale: input.scale
        )
        tileLayer.addSublayer(labelLayer)

        // Cache the fully composed tile (selection + icon shadow + label shadow)
        // as one small Retina surface. Paging then moves cached tile surfaces
        // instead of repeatedly compositing every child layer and shadow.
        //
        // Do this per tile rather than on the full page: a full-screen Retina/5K
        // raster surface is large and can itself cause a hitch when allocated.
        configurePagingRasterCache(
            tileLayer,
            scale: input.scale
        )

        return AppTilePresentation(
            tileLayer: tileLayer,
            selectionLayer: selectionLayer,
            iconLayer: iconLayer,
            labelLayer: labelLayer,
            button: AppTileButton(application: input.application)
        )
    }

    static func make(_ input: FolderTileRenderInput) -> FolderTilePresentation {
        let tileLayer = CALayer()
        tileLayer.frame = input.cellFrame

        let folderIconFrame = folderSurfaceFrame(input.iconFrame)
        let selectionLayer = LaunchpadVisualStyle.makeSelectionLayer(
            cellFrame: input.cellFrame,
            iconFrame: folderIconFrame,
            selected: input.selected
        )
        tileLayer.addSublayer(selectionLayer)

        let iconLayer = makeFolderIconLayer(input, iconFrame: folderIconFrame)
        tileLayer.addSublayer(iconLayer)
        let labelLayer = makeLabelLayer(
            input.title,
            frame: input.labelFrame,
            cellFrame: input.cellFrame,
            scale: input.scale
        )
        tileLayer.addSublayer(labelLayer)

        // Folder tiles have an even deeper layer tree because of the miniature
        // child icons. Cache the finished tile so page motion stays compositor-
        // friendly without flattening the entire Launchpad page.
        configurePagingRasterCache(
            tileLayer,
            scale: input.scale
        )

        return FolderTilePresentation(
            tileLayer: tileLayer,
            selectionLayer: selectionLayer,
            iconLayer: iconLayer,
            labelLayer: labelLayer,
            button: FolderTileButton(folderID: input.folderID, title: input.title)
        )
    }

    private static func configurePagingRasterCache(
        _ layer: CALayer,
        scale: CGFloat
    ) {
        guard scale.isFinite, scale > 0 else { return }

        // Rasterizing at the backing scale preserves Retina sharpness.
        //
        // The cache remains valid while an ancestor page layer changes position,
        // which is exactly what interactive paging and settle animations do.
        // Child changes such as hover, selection, or refreshed icons naturally
        // invalidate only the affected tile.
        layer.shouldRasterize = true
        layer.rasterizationScale = scale
    }

    private static func makeIconLayer(
        icon: CGImage?,
        frame: CGRect,
        cellFrame: CGRect,
        scale: CGFloat
    ) -> CALayer {
        let layer = CALayer()
        layer.frame = frame.offsetBy(dx: -cellFrame.minX, dy: -cellFrame.minY)
        layer.contents = icon
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = scale
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.shadowRadius = 6
        return layer
    }

    static func updateFolderIcon(
        _ presentation: FolderTilePresentation,
        childIcons: [CGImage],
        scale: CGFloat,
        layoutDirection: NSUserInterfaceLayoutDirection
    ) {
        let folderLayer = presentation.iconLayer

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Keep the existing folder surface but replace its miniature app icons.
        folderLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        configureFolderSurface(folderLayer, scale: scale)

        let side = min(folderLayer.bounds.width, folderLayer.bounds.height)
        let inset = side * FolderMetrics.contentInsetFraction
        let spacing = side * FolderMetrics.itemSpacingFraction
        let availableSide = side - inset * 2
        let miniIconSide = (
            availableSide - spacing * CGFloat(FolderMetrics.gridDimension - 1)
        ) / CGFloat(FolderMetrics.gridDimension)

        let origin = CGPoint(
            x: (folderLayer.bounds.width - availableSide) / 2,
            y: (folderLayer.bounds.height - availableSide) / 2
        )

        addChildIcons(
            childIcons,
            to: folderLayer,
            layout: FolderChildLayout(
                origin: origin,
                iconSide: miniIconSide,
                spacing: spacing,
                scale: scale,
                layoutDirection: layoutDirection
            )
        )

        CATransaction.commit()
    }

    private static func folderSurfaceFrame(_ iconFrame: CGRect) -> CGRect {
        let horizontalInset = iconFrame.width * (1 - FolderMetrics.surfaceScale) / 2
        let verticalInset = iconFrame.height * (1 - FolderMetrics.surfaceScale) / 2
        return iconFrame.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    /// Scale of one closed-folder miniature icon relative to the normal
    /// logical app icon frame. Merge landing reuses this exact ratio so the
    /// dragged icon reaches the same visible size as its persisted miniature.
    static var folderMiniatureIconScale: CGFloat {
        let availableFraction = 1 - FolderMetrics.contentInsetFraction * 2
        let miniIconFractionWithinSurface = (
            availableFraction
                - FolderMetrics.itemSpacingFraction
                    * CGFloat(FolderMetrics.gridDimension - 1)
        ) / CGFloat(FolderMetrics.gridDimension)
        return FolderMetrics.surfaceScale * miniIconFractionWithinSurface
    }

    static var folderMaximumVisibleChildren: Int {
        FolderMetrics.maximumVisibleChildren
    }

    /// Returns the exact center used by the closed-folder miniature grid.
    /// Keeping merge landing geometry here prevents the animation target from
    /// drifting away from the miniature icon that appears after the commit.
    static func folderChildCenter(
        iconFrame: CGRect,
        logicalIndex: Int,
        layoutDirection: NSUserInterfaceLayoutDirection
    ) -> CGPoint? {
        guard (0 ..< FolderMetrics.maximumVisibleChildren).contains(logicalIndex) else {
            return nil
        }

        let surfaceFrame = folderSurfaceFrame(iconFrame)
        let side = min(surfaceFrame.width, surfaceFrame.height)
        let inset = side * FolderMetrics.contentInsetFraction
        let spacing = side * FolderMetrics.itemSpacingFraction
        let availableSide = side - inset * 2
        let miniIconSide = (
            availableSide - spacing * CGFloat(FolderMetrics.gridDimension - 1)
        ) / CGFloat(FolderMetrics.gridDimension)
        let origin = CGPoint(
            x: surfaceFrame.midX - availableSide / 2,
            y: surfaceFrame.midY - availableSide / 2
        )

        let logicalColumn = logicalIndex % FolderMetrics.gridDimension
        let column = layoutDirection == .rightToLeft
            ? FolderMetrics.gridDimension - logicalColumn - 1
            : logicalColumn
        let topDownRow = logicalIndex / FolderMetrics.gridDimension
        let row = FolderMetrics.gridDimension - topDownRow - 1

        return CGPoint(
            x: origin.x + CGFloat(column) * (miniIconSide + spacing) + miniIconSide / 2,
            y: origin.y + CGFloat(row) * (miniIconSide + spacing) + miniIconSide / 2
        )
    }

    private static func makeFolderIconLayer(
        _ input: FolderTileRenderInput,
        iconFrame: CGRect
    ) -> CALayer {
        let localFrame = iconFrame.offsetBy(
            dx: -input.cellFrame.minX,
            dy: -input.cellFrame.minY
        )
        let folderLayer = CALayer()
        folderLayer.frame = localFrame
        configureFolderSurface(folderLayer, scale: input.scale)

        let side = min(folderLayer.bounds.width, folderLayer.bounds.height)
        let inset = side * FolderMetrics.contentInsetFraction
        let spacing = side * FolderMetrics.itemSpacingFraction
        let availableSide = side - inset * 2
        let miniIconSide = (
            availableSide - spacing * CGFloat(FolderMetrics.gridDimension - 1)
        ) / CGFloat(FolderMetrics.gridDimension)
        let origin = CGPoint(
            x: (folderLayer.bounds.width - availableSide) / 2,
            y: (folderLayer.bounds.height - availableSide) / 2
        )
        addChildIcons(
            input.childIcons,
            to: folderLayer,
            layout: FolderChildLayout(
                origin: origin,
                iconSide: miniIconSide,
                spacing: spacing,
                scale: input.scale,
                layoutDirection: input.layoutDirection
            )
        )
        return folderLayer
    }

    private static func configureFolderSurface(_ folderLayer: CALayer, scale: CGFloat) {
        folderLayer.cornerRadius = min(folderLayer.bounds.width, folderLayer.bounds.height)
            * FolderMetrics.cornerRadiusFraction
        folderLayer.cornerCurve = .continuous
        folderLayer.allowsEdgeAntialiasing = true
        folderLayer.backgroundColor = NSColor.white
            .withAlphaComponent(FolderMetrics.backgroundOpacity)
            .cgColor
        folderLayer.borderColor = NSColor.white
            .withAlphaComponent(FolderMetrics.borderOpacity)
            .cgColor
        folderLayer.borderWidth = FolderMetrics.borderWidth
        folderLayer.shadowColor = NSColor.black.cgColor
        folderLayer.shadowOpacity = FolderMetrics.shadowOpacity
        folderLayer.shadowOffset = CGSize(width: 0, height: FolderMetrics.shadowVerticalOffset)
        folderLayer.shadowRadius = FolderMetrics.shadowRadius
        folderLayer.contentsScale = scale
    }

    private static func addChildIcons(
        _ childIcons: [CGImage],
        to folderLayer: CALayer,
        layout: FolderChildLayout
    ) {
        for (logicalIndex, image) in childIcons.prefix(FolderMetrics.maximumVisibleChildren).enumerated() {
            let logicalColumn = logicalIndex % FolderMetrics.gridDimension
            let column = layout.layoutDirection == .rightToLeft
                ? FolderMetrics.gridDimension - logicalColumn - 1
                : logicalColumn
            let topDownRow = logicalIndex / FolderMetrics.gridDimension
            let row = FolderMetrics.gridDimension - topDownRow - 1

            let miniIconLayer = CALayer()
            miniIconLayer.frame = CGRect(
                x: layout.origin.x + CGFloat(column) * (layout.iconSide + layout.spacing),
                y: layout.origin.y + CGFloat(row) * (layout.iconSide + layout.spacing),
                width: layout.iconSide,
                height: layout.iconSide
            )
            miniIconLayer.contents = image
            miniIconLayer.contentsGravity = .resizeAspect
            miniIconLayer.contentsScale = layout.scale
            folderLayer.addSublayer(miniIconLayer)
        }
    }

    private static func makeLabelLayer(
        _ title: String,
        frame: CGRect,
        cellFrame: CGRect,
        scale: CGFloat
    ) -> CATextLayer {
        let layer = CATextLayer()
        layer.frame = frame.offsetBy(dx: -cellFrame.minX, dy: -cellFrame.minY)
        layer.string = title
        layer.alignmentMode = .center
        layer.truncationMode = .end
        layer.fontSize = LabelMetrics.fontSize
        layer.foregroundColor = NSColor.white
            .withAlphaComponent(LabelMetrics.foregroundOpacity)
            .cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = LabelMetrics.shadowOpacity
        layer.shadowOffset = CGSize(width: 0, height: LabelMetrics.shadowVerticalOffset)
        layer.shadowRadius = LabelMetrics.shadowRadius
        layer.contentsScale = scale
        return layer
    }
}
