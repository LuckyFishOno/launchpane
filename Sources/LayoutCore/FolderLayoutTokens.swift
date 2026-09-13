import CoreGraphics

/// Typed visual and interaction constraints for the folder overlay.
public struct FolderLayoutTokens: Equatable, Sendable {
    public var preferredIconSize: CGFloat
    public var minimumIconSize: CGFloat
    public var maximumIconSize: CGFloat
    public var preferredCellWidth: CGFloat
    public var preferredCellHeight: CGFloat
    public var minimumHorizontalGap: CGFloat
    public var minimumVerticalGap: CGFloat
    public var minimumInteractionTarget: CGFloat
    public var labelHeight: CGFloat
    public var titleHeight: CGFloat
    public var titleToGridSpacing: CGFloat
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat
    public var displayMargin: CGFloat
    public var maximumPanelWidth: CGFloat
    public var maximumPanelHeight: CGFloat
    public var defaultRows: Int
    public var defaultColumns: Int
    public var maximumRows: Int
    public var maximumColumns: Int

    public init(
        preferredIconSize: CGFloat = 88,
        minimumIconSize: CGFloat = 40,
        maximumIconSize: CGFloat = 96,
        preferredCellWidth: CGFloat = 196,
        preferredCellHeight: CGFloat = 170,
        minimumHorizontalGap: CGFloat = 18,
        minimumVerticalGap: CGFloat = 16,
        minimumInteractionTarget: CGFloat = 56,
        labelHeight: CGFloat = 28,
        titleHeight: CGFloat = 36,
        titleToGridSpacing: CGFloat = 16,
        horizontalPadding: CGFloat = 16,
        verticalPadding: CGFloat = 24,
        displayMargin: CGFloat = 32,
        maximumPanelWidth: CGFloat = 1600,
        maximumPanelHeight: CGFloat = 1000,
        defaultRows: Int = 5,
        defaultColumns: Int = 7,
        maximumRows: Int = 5,
        maximumColumns: Int = 7
    ) {
        self.preferredIconSize = preferredIconSize
        self.minimumIconSize = minimumIconSize
        self.maximumIconSize = maximumIconSize
        self.preferredCellWidth = preferredCellWidth
        self.preferredCellHeight = preferredCellHeight
        self.minimumHorizontalGap = minimumHorizontalGap
        self.minimumVerticalGap = minimumVerticalGap
        self.minimumInteractionTarget = minimumInteractionTarget
        self.labelHeight = labelHeight
        self.titleHeight = titleHeight
        self.titleToGridSpacing = titleToGridSpacing
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.displayMargin = displayMargin
        self.maximumPanelWidth = maximumPanelWidth
        self.maximumPanelHeight = maximumPanelHeight
        self.defaultRows = defaultRows
        self.defaultColumns = defaultColumns
        self.maximumRows = maximumRows
        self.maximumColumns = maximumColumns
    }

    public static let standard = FolderLayoutTokens()
}
