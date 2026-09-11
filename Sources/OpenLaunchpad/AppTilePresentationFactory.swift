import AppCore
import AppKit
import QuartzCore

@MainActor
final class AppTilePresentation {
    let tileLayer: CALayer
    let selectionLayer: CALayer
    let iconLayer: CALayer
    let button: AppTileButton

    init(
        tileLayer: CALayer,
        selectionLayer: CALayer,
        iconLayer: CALayer,
        button: AppTileButton
    ) {
        self.tileLayer = tileLayer
        self.selectionLayer = selectionLayer
        self.iconLayer = iconLayer
        self.button = button
    }
}

@MainActor
final class FolderTilePresentation {
    let tileLayer: CALayer
    let selectionLayer: CALayer
    let iconLayer: CALayer
    let button: FolderTileButton

    init(
        tileLayer: CALayer,
        selectionLayer: CALayer,
        iconLayer: CALayer,
        button: FolderTileButton
    ) {
        self.tileLayer = tileLayer
        self.selectionLayer = selectionLayer
        self.iconLayer = iconLayer
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
        tileLayer.addSublayer(makeLabelLayer(
            input.application.displayName,
            frame: input.labelFrame,
            cellFrame: input.cellFrame,
            scale: input.scale
        ))

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
            button: AppTileButton(application: input.application)
        )
    }

    static func make(_ input: FolderTileRenderInput) -> FolderTilePresentation {
        let tileLayer = CALayer()
        tileLayer.frame = input.cellFrame

        let selectionLayer = LaunchpadVisualStyle.makeSelectionLayer(
            cellFrame: input.cellFrame,
            iconFrame: input.iconFrame,
            selected: input.selected
        )
        tileLayer.addSublayer(selectionLayer)

        let iconLayer = makeFolderIconLayer(input)
        tileLayer.addSublayer(iconLayer)
        tileLayer.addSublayer(makeLabelLayer(
            input.title,
            frame: input.labelFrame,
            cellFrame: input.cellFrame,
            scale: input.scale
        ))

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

    private static func makeFolderIconLayer(_ input: FolderTileRenderInput) -> CALayer {
        let localFrame = input.iconFrame.offsetBy(
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
