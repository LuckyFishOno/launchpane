import AppKit
import LayoutCore
import QuartzCore

// Builds folder decoration without owning interaction, persistence, or animation state.
@MainActor enum FolderOverlayPresentationFactory {
    static func addPanel(to contentLayer: CALayer, metrics: FolderGridMetrics, folderVisualScale: CGFloat) {
        let panelLayer = CALayer()
        panelLayer.frame = metrics.panelFrame
        panelLayer.cornerRadius = min(32 * folderVisualScale, metrics.panelFrame.height * 0.14)
        panelLayer.cornerCurve = .continuous
        panelLayer.backgroundColor = NSColor.white.withAlphaComponent(0.46).cgColor
        panelLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panelLayer.borderWidth = 0.6
        panelLayer.shadowColor = NSColor.black.cgColor
        panelLayer.shadowOpacity = 0.22
        panelLayer.shadowOffset = CGSize(width: 0, height: -10 * folderVisualScale)
        panelLayer.shadowRadius = 30 * folderVisualScale

        // LAUNCHPANE_FOLDER_OPEN_FPS_V13
        // A fixed shadow path avoids deriving a large translucent alpha mask on
        // every transformed frame, which is particularly expensive on 4K.
        panelLayer.shadowPath = CGPath(
            roundedRect: panelLayer.bounds, cornerWidth: panelLayer.cornerRadius, cornerHeight: panelLayer.cornerRadius,
            transform: nil)

        contentLayer.addSublayer(panelLayer)

    }

    static func addTitle(
        to contentLayer: CALayer, folder: ResolvedLaunchpadFolder, metrics: FolderGridMetrics,
        scale: CGFloat, folderVisualScale: CGFloat
    ) -> (layer: CATextLayer, hitFrame: CGRect) {
        // LAUNCHPANE_FOLDER_TITLE_27PT_V1
        // Keep 27pt on the MacBook baseline and enlarge it with the folder panel
        // on wider logical displays.
        let titleFontSize = 27 * folderVisualScale
        let titleFont = NSFont.systemFont(ofSize: titleFontSize, weight: .regular)
        let titleLayer = CATextLayer()
        titleLayer.frame = metrics.titleFrame
        titleLayer.string = folder.title
        titleLayer.alignmentMode = .center
        titleLayer.fontSize = titleFontSize
        titleLayer.font = titleFont
        titleLayer.foregroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        titleLayer.contentsScale = scale
        contentLayer.addSublayer(titleLayer)
        let measuredTitleWidth = ceil((folder.title as NSString).size(withAttributes: [.font: titleFont]).width)
        let titleHitWidth = min(
            metrics.titleFrame.width, max(88 * folderVisualScale, measuredTitleWidth + 28 * folderVisualScale))
        let hitFrame = CGRect(
            x: metrics.titleFrame.midX - titleHitWidth / 2, y: metrics.titleFrame.minY, width: titleHitWidth,
            height: metrics.titleFrame.height)

        return (titleLayer, hitFrame)
    }
}
