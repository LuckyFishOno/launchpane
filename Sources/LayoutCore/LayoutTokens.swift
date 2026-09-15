import CoreGraphics

public struct LayoutTokens: Equatable, Sendable {
    public var preferredIconSize: CGFloat
    public var minimumIconSize: CGFloat
    public var maximumIconSize: CGFloat
    public var minimumHorizontalGap: CGFloat
    public var minimumVerticalGap: CGFloat
    public var horizontalMargin: CGFloat
    public var verticalMargin: CGFloat
    public var maximumContentWidth: CGFloat
    public var searchReservation: CGFloat
    public var pageIndicatorReservation: CGFloat
    public var labelHeight: CGFloat
    public var minimumInteractionTarget: CGFloat
    public var defaultRows: Int
    public var defaultColumns: Int
    public var maximumRows: Int
    public var maximumColumns: Int
    public var folder: FolderLayoutTokens

    public init(
        // LAUNCHPANE_BALANCED_ICON_LAYOUT_108_V6
        // Reduce the 144pt experiment by one quarter. Root applications and
        // open-folder children still share the exact same resolved geometry.
        preferredIconSize: CGFloat = 108,
        minimumIconSize: CGFloat = 48,
        maximumIconSize: CGFloat = 144,
        minimumHorizontalGap: CGFloat = 24,
        minimumVerticalGap: CGFloat = 24,
        horizontalMargin: CGFloat = 48,
        verticalMargin: CGFloat = 32,
        // LAUNCHPANE_ADAPTIVE_LARGE_DISPLAY_LAYOUT_V7
        // LAUNCHPANE_WIDER_4K_HORIZONTAL_SPACING_V10
        // Keep the 1520pt MacBook baseline unchanged, but give large native
        // logical canvases more horizontal breathing room. At a 3840pt canvas
        // the seven-column root grid now tops out at 2160pt instead of 1920pt.
        // Icon size and vertical geometry are intentionally unchanged.
        maximumContentWidth: CGFloat = 2160,
        searchReservation: CGFloat = 72,
        pageIndicatorReservation: CGFloat = 44,
        labelHeight: CGFloat = 34,
        minimumInteractionTarget: CGFloat = 64,
        // 108pt + 34pt label fits five rows with useful vertical breathing room
        // on the MacBook logical canvas, so restore the denser 7x5 launcher.
        defaultRows: Int = 5,
        defaultColumns: Int = 7,
        maximumRows: Int = 8,
        maximumColumns: Int = 12,
        folder: FolderLayoutTokens = .standard
    ) {
        self.preferredIconSize = preferredIconSize
        self.minimumIconSize = minimumIconSize
        self.maximumIconSize = maximumIconSize
        self.minimumHorizontalGap = minimumHorizontalGap
        self.minimumVerticalGap = minimumVerticalGap
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
        self.maximumContentWidth = maximumContentWidth
        self.searchReservation = searchReservation
        self.pageIndicatorReservation = pageIndicatorReservation
        self.labelHeight = labelHeight
        self.minimumInteractionTarget = minimumInteractionTarget
        self.defaultRows = defaultRows
        self.defaultColumns = defaultColumns
        self.maximumRows = maximumRows
        self.maximumColumns = maximumColumns
        self.folder = folder
    }

    public static let standard = LayoutTokens()
}
