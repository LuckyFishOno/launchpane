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
