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
        preferredIconSize: CGFloat = 96,
        minimumIconSize: CGFloat = 48,
        maximumIconSize: CGFloat = 128,
        minimumHorizontalGap: CGFloat = 20,
        minimumVerticalGap: CGFloat = 18,
        horizontalMargin: CGFloat = 48,
        verticalMargin: CGFloat = 32,
        maximumContentWidth: CGFloat = 1600,
        searchReservation: CGFloat = 72,
        pageIndicatorReservation: CGFloat = 44,
        labelHeight: CGFloat = 34,
        minimumInteractionTarget: CGFloat = 64,
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
